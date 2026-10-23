#!/bin/bash
#
# Migrates every GitLab repository listed in the input file to GitHub. See the
# README for the steps performed on each repository.

set -uo pipefail

gitlab_url="${GITLAB_URL:-https://GITLAB-HOSTNAME}"
github_repo_target="${GITHUB_ORG:-CORP-GITHUB}"
github_team="${GITHUB_TEAM:-web-development}"
max_blob_size="${MAX_BLOB_SIZE:-90M}"
# Database dumps under data/ are removed from every commit; github.sql is kept.
sql_dump_regex='^data/(?:.*/)?(?!github\.sql$)[^/]*\.sql$'

base_dir=$(pwd)
script_name=$(basename "$0" .sh)
main_output_dir="$base_dir/_script-products"
output_dir="$main_output_dir/$script_name"
logfile="$base_dir/_log.txt"
done_file="$base_dir/_done.txt"
failed_file="$base_dir/_failed.txt"
excluded_file="$base_dir/_excluded.txt"
has_modules_file="$base_dir/_has_modules.txt"
scrubbed_file="$base_dir/_scrubbed.txt"

migration_logger() {
    local last_action=$1
    local exit_code=$2
    local return_as_boolean=${3:-false}
    local log_message=""
    local echo_reset_color='\033[0m'
    local echo_color result

    if [[ "$return_as_boolean" == true ]]; then
        echo_color='\033[0;34m'
        if [ "$exit_code" -eq 0 ]; then result="TRUE"; else result="FALSE"; fi
    elif [ "$exit_code" -eq 0 ]; then
        echo_color='\033[0;32m'
        result="SUCCESSFUL"
    else
        echo_color='\033[0;31m'
        result="FAILED"
    fi
    log_message="$(date "+[%d-%b-%Y %H:%M:%S]")[group: $group_name][repo: $project_name] -- $result -- $last_action"

    echo -e "${echo_color}$log_message${echo_reset_color}"
    echo "$log_message" >> "$logfile"
}

usage() {
  echo "Usage: $0 [ -t <your-gitlab-access-token> ] -f <path-to-input-textfile> [ -c <comma-separated-repo-topics> ] [ -x <path-to-exclusions-textfile> ]"
  echo "The token can also be provided through the GITLAB_TOKEN environment variable."
  exit 1
}

gl_token="${GITLAB_TOKEN:-}"
group_file=""
repo_topics=""
exclusions_file=""
while getopts ":t:f:c:x:" opt; do
    case $opt in
        t) gl_token="$OPTARG";;
        f) group_file="$OPTARG";;
        c) repo_topics="$OPTARG";;
        x) exclusions_file="$OPTARG";;
        \?) echo "Invalid option: -$OPTARG" >&2; usage;;
        :) echo "Option -$OPTARG requires a value." >&2; usage;;
    esac
done
if [ -z "$gl_token" ] || [ -z "$group_file" ]; then
  echo "Both a GitLab token (-t or GITLAB_TOKEN) and -f are required."
  usage
fi

if [ ! -f "$group_file" ]; then
    echo "Error: Input file $group_file not found."
    exit 1
fi

if [ -n "$exclusions_file" ] && [ ! -f "$exclusions_file" ]; then
  echo "Exclusions file not found: $exclusions_file"
  exit 1
fi

# Strips surrounding whitespace, including the \r of Windows line endings.
trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

gitlab_api() {
    local method=$1 endpoint=$2
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$gl_token" |
        curl -sSf --config - --request "$method" "$gitlab_url/api/v4/$endpoint"
}

# Succeeds when the JSON on stdin satisfies the given jq condition.
json_test() {
    jq -e "$1" > /dev/null
}

record_repo() {
    echo "$http_url,$group_name,$project_name,$project_id" >> "$1"
}

# Exclusion files use the same format as input files. A repo is excluded when
# its http url equals the first field of a line.
is_excluded() {
    local exclusion_url _
    [ -n "$exclusions_file" ] || return 1
    while IFS=, read -r exclusion_url _ || [ -n "$exclusion_url" ]; do
        exclusion_url=$(trim "$exclusion_url")
        if [ -n "$exclusion_url" ] && [ "$exclusion_url" = "$http_url" ]; then
            return 0
        fi
    done < "$exclusions_file"
    return 1
}

# Runs a command, logs whether it succeeded and returns its exit code.
run_step() {
    local action=$1
    shift
    "$@"
    local exit_code=$?
    migration_logger "$action" "$exit_code"
    return "$exit_code"
}

# Only ever called from migrate_repo, which runs in a subshell.
fail() {
    record_repo "$failed_file"
    exit 1
}

# Lists what the history rewrite will remove, so there is a record of it.
list_scrubbed_content() {
    local max_bytes
    max_bytes=$(numfmt --from=iec "$max_blob_size")
    git rev-list --objects --all |
        git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' |
        awk -v limit="$max_bytes" -v repo="$group_name/$project_name" '$1 == "blob" {
            path = $0
            sub(/^[^ ]+ [^ ]+ /, "", path)
            if ($2 > limit) print repo ": large file (" $2 " bytes): " path
            else if (path ~ /^data\/(.*\/)?[^\/]*\.sql$/ && path !~ /(^|\/)github\.sql$/) print repo ": sql dump: " path
        }'
}

# Turns the submodules listed in .gitmodules into regular directories.
unsubmodule() {
    local key submodule_name submodule_path
    while read -r key submodule_path; do
        submodule_name=${key#submodule.}
        submodule_name=${submodule_name%.path}
        echo "Processing submodule: $submodule_name ($submodule_path)"
        git config --remove-section "submodule.$submodule_name" 2> /dev/null
        git rm --cached --quiet "$submodule_path" || return 1
        rm -rf ".git/modules/$submodule_name" "$submodule_path/.git"
    done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
    git rm --cached --quiet .gitmodules && rm .gitmodules
}

update_actions_repo() {
    if [ -d "$HOME/actions" ]; then
        git -C "$HOME/actions" pull --ff-only
    else
        git clone "https://github.com/$github_repo_target/actions.git" "$HOME/actions"
    fi
}

# Succeeds when the remote has exactly the local branches and tags.
remote_refs_match() {
    diff <(git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort) \
        <(git ls-remote --heads --tags "$1" | grep -v '\^{}$' | tr '\t' ' ' | sort)
}

# Migrates the current repo. Runs in a subshell so that it can exit at the
# first failed step and its cd doesn't leak into the main loop.
migrate_repo() {
    local project_json default_branch target_project_name github_repo is_empty
    local reuse_github_repo=false
    local clone_dir="$output_dir/$group_name/$project_name"

    # Names GitHub doesn't accept (e.g. with spaces) are made valid here so
    # that every step below uses the same name.
    target_project_name=$(printf '%s' "$project_name" | sed -E 's/[^A-Za-z0-9._-]+/-/g')
    github_repo="$github_repo_target/$target_project_name"

    run_step "valid repo id" grep -qE '^[0-9]+$' <<< "$project_id" || fail

    project_json=$(gitlab_api GET "projects/$project_id")
    run_step "nonempty gitlab repo check" json_test '.empty_repo == false' <<< "$project_json" || fail
    default_branch=$(jq -r '.default_branch // empty' <<< "$project_json")

    if is_empty=$(gh repo view "$github_repo" --json isEmpty --jq .isEmpty 2> /dev/null); then
        # An empty repo is left behind when an earlier run failed after
        # creating it, so carry on with it rather than failing forever.
        run_step "github repo $github_repo is unused" test "$is_empty" = true || fail
        reuse_github_repo=true
    fi

    run_step "cloning gitlab repo locally" git clone --recursive "$http_url" "$clone_dir" || fail
    cd "$clone_dir" || fail

    list_scrubbed_content >> "$scrubbed_file"
    run_step "pruning $max_blob_size+ files and data/*.sql dumps from history" \
        git-filter-repo --force --strip-blobs-bigger-than "$max_blob_size" --invert-paths --path-regex "$sql_dump_regex" || fail

    local count=0 found_in_current_dir=false gitmodules_file
    while IFS= read -r -d '' gitmodules_file; do
        ((count++))
        if [ "$gitmodules_file" = "./.gitmodules" ]; then
            found_in_current_dir=true
        fi
    done < <(find . -path ./.git -prune -o -name ".gitmodules" -type f -print0)
    echo "Number of occurrences of .gitmodules: $count"

    if $found_in_current_dir && [ $count -eq 1 ]; then
        migration_logger "repo has submodules that we can unsubmodule" 0 true
        run_step "unsubmoduling" unsubmodule || fail
    elif [ $count -ne 0 ]; then
        migration_logger "repo has submodules that we can unsubmodule" 1 true
        record_repo "$has_modules_file"
        exit 1
    fi

    # The history rewrite above already removed these; this also catches the
    # ones that came in with flattened submodules.
    if [ -d "data" ]; then
        find data -type f -name '*.sql' ! -name 'github.sql' -exec rm -f {} +
    fi

    if [ -d "plugins" ]; then
        migration_logger "checking if WordPress" 0 true
        run_step "updating webdev-actions" update_actions_repo || fail
        run_step "copying webdev-actions files" cp -R "$HOME/actions/copy-for-website-repos/.github" . || fail
    else
        migration_logger "checking if WordPress" 1 true
    fi

    if ! $reuse_github_repo; then
        run_step "creating repo in GitHub and adding webdev access" \
            gh repo create "$github_repo" --internal -t "$github_team" || fail
    fi

    if [ -n "$(find . -maxdepth 1 -type f -name "*.aspx")" ]; then
        run_step "adding topic legacy-framework" gh repo edit "$github_repo" --add-topic "legacy-framework"
    fi

    if [ -n "$repo_topics" ]; then
        run_step "adding topic(s) $repo_topics" gh repo edit "$github_repo" --add-topic "$repo_topics"
    fi

    run_step "changing webdev access to admin" \
        gh api -X PUT "orgs/$github_repo_target/teams/$github_team/repos/$github_repo" -f permission="admin" --silent || fail

    run_step "adding github remote to repository" \
        git remote add github "https://github.com/$github_repo.git" || fail

    run_step "git adding all for final product" git add --all || fail
    if ! git diff --cached --quiet; then
        run_step "git committing final product" git commit -m "Pre-GitHub Mirroring Commit" || fail
    fi

    run_step "mirroring repo to github" git push github 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' || fail
    run_step "verifying every branch and tag reached github" remote_refs_match github || fail
    record_repo "$done_file"

    if [ -n "$default_branch" ]; then
        run_step "setting github default branch to $default_branch" \
            gh repo edit "$github_repo" --default-branch "$default_branch"
    fi

    run_step "post-migration: archiving repo in GitLab" \
        json_test '.archived == true' <<< "$(gitlab_api POST "projects/$project_id/archive")"

    cd "$base_dir" || exit 1
    run_step "post-migration: cleaning up local repo" rm -rf "$clone_dir"
}

mkdir -p "$output_dir"

{
    echo -e "\n$(date "+[%d-%b-%Y %H:%M:%S]")[executing: $script_name]"
    echo -e "                      [input file: $(realpath "$group_file")]"
    echo -e "                      [input file line count: $(grep -c '[^[:space:]]' "$group_file")]"
    if [ -n "$exclusions_file" ]; then
        echo -e "                      [exclusions file: $(realpath "$exclusions_file")]"
        echo -e "                      [exclusions file line count: $(grep -c '[^[:space:]]' "$exclusions_file")]"
    fi
} >> "$logfile"

# The list is read from fd 3 so that commands in the loop can't consume it.
while IFS=, read -r http_url group_name project_name project_id <&3 || [ -n "$http_url" ]; do
    http_url=$(trim "$http_url")
    group_name=$(trim "$group_name")
    project_name=$(trim "$project_name")
    project_id=$(trim "$project_id")
    [ -n "$http_url" ] || continue

    if is_excluded; then
        migration_logger "exclude repo" 0 true
        record_repo "$excluded_file"
        continue
    fi

    ( migrate_repo )
done 3< "$group_file"
echo "$(date "+[%d-%b-%Y %H:%M:%S]") $group_file processed. EOL" | tee -a "$logfile"
