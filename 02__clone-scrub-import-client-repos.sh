#!/bin/bash
#
# Migrates every GitLab repository listed in the input file to GitHub. See the
# README for the steps performed on each repository.

set -uo pipefail

gitlab_url="${GITLAB_URL:-https://GITLAB-HOSTNAME}"
github_repo_target="${GITHUB_ORG:-CORP-GITHUB}"
github_team="${GITHUB_TEAM:-web-development}"
github_team_permission="${GITHUB_TEAM_PERMISSION:-maintain}"
max_blob_size="${MAX_BLOB_SIZE:-90M}"
# Database dumps under data/ are removed from every commit; github.sql is kept.
sql_dump_regex='^data/(?:.*/)?(?!github\.sql$)[^/]*\.sql$'

base_dir=$(pwd)
script_dir=$(cd "$(dirname "$0")" && pwd)
# The secret scan always uses this repo's gitleaks.toml and .gitleaksignore, so
# that the ones inside a migrated repo can't switch it off.
gitleaks_config="$script_dir/gitleaks.toml"
script_name=$(basename "$0" .sh)
main_output_dir="$base_dir/_script-products"
output_dir="$main_output_dir/$script_name"
logfile="$base_dir/_log.txt"
secret_reports_dir="$main_output_dir/secret-reports"

migration_logger() {
    local last_action=$1
    local exit_code=$2
    local style=${3:-}
    local log_message=""
    local echo_reset_color='\033[0m'
    local echo_color result

    if [[ "$style" == true ]]; then
        echo_color='\033[0;34m'
        if [ "$exit_code" -eq 0 ]; then result="TRUE"; else result="FALSE"; fi
    elif [[ "$style" == skipped ]]; then
        echo_color='\033[0;33m'
        result="SKIPPED (dry run)"
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
  echo "Usage: $0 [ -t <your-gitlab-access-token> ] -f <path-to-input-textfile> [ -c <comma-separated-repo-topics> ] [ -x <path-to-exclusions-textfile> ] [ -n ]"
  echo "The token can also be provided through the GITLAB_TOKEN environment variable."
  echo "-n does a dry run: every repo is cloned, scrubbed and scanned, but nothing is changed in GitHub or GitLab."
  exit 1
}

gl_token="${GITLAB_TOKEN:-}"
group_file=""
repo_topics=""
exclusions_file=""
dry_run=false
while getopts ":t:f:c:x:n" opt; do
    case $opt in
        t) gl_token="$OPTARG";;
        f) group_file="$OPTARG";;
        c) repo_topics="$OPTARG";;
        x) exclusions_file="$OPTARG";;
        n) dry_run=true;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage;;
        :) echo "Option -$OPTARG requires a value." >&2; usage;;
    esac
done
if [ -z "$gl_token" ] || [ -z "$group_file" ]; then
  echo "Both a GitLab token (-t or GITLAB_TOKEN) and -f are required."
  usage
fi

# A dry run records its results in files of its own, so that they don't mix
# with those of real runs.
if $dry_run; then record_prefix="_dry-run"; else record_prefix=""; fi
done_file="$base_dir/${record_prefix}_done.txt"
failed_file="$base_dir/${record_prefix}_failed.txt"
excluded_file="$base_dir/${record_prefix}_excluded.txt"
has_modules_file="$base_dir/${record_prefix}_has_modules.txt"
has_secrets_file="$base_dir/${record_prefix}_has_secrets.txt"
has_gitlab_ci_file="$base_dir/${record_prefix}_has_gitlab_ci.txt"
scrubbed_file="$base_dir/${record_prefix}_scrubbed.txt"

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

# Prints every item of a paginated GitLab API collection, one JSON object per
# line, failing when a page can't be fetched or isn't a JSON array.
gitlab_get_all() {
    local endpoint=$1 query=$2 page=1 response
    while :; do
        response=$(gitlab_api GET "$endpoint?${query:+$query&}per_page=100&page=$page") || return 1
        jq -e 'type == "array"' <<< "$response" > /dev/null || return 1
        [ "$(jq 'length' <<< "$response")" -eq 0 ] && return 0
        jq -c '.[]' <<< "$response"
        page=$((page + 1))
    done
}

# Makes the names on stdin valid GitHub repo names, e.g. by replacing spaces.
github_name() {
    sed -E 's/[^A-Za-z0-9._-]+/-/g'
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
    [ "$exit_code" -eq 0 ] || failed_step=$action
    return "$exit_code"
}

# Like run_step, for steps that change GitHub or GitLab. A dry run only logs
# them.
change_step() {
    if $dry_run; then
        migration_logger "$1" 0 skipped
        return 0
    fi
    run_step "$@"
}

# Records the repo as failed, along with the step that failed, and moves on to
# the next one. Only ever called from migrate_repo, which runs in a subshell.
fail() {
    echo "$http_url,$group_name,$project_name,$project_id,failed: ${1:-${failed_step:-unknown step}}" >> "$failed_file"
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

archive_gitlab_repo() {
    json_test '.archived == true' <<< "$(gitlab_api POST "projects/$project_id/archive")"
}

# Succeeds when the remote has exactly the local branches and tags.
remote_refs_match() {
    diff <(git for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort) \
        <(git ls-remote --heads --tags "$1" | grep -v '\^{}$' | tr '\t' ' ' | sort)
}

# Migrates the current repo. Runs in a subshell so that it can exit at the
# first failed step and its cd doesn't leak into the main loop.
migrate_repo() {
    local project_json default_branch description target_project_name github_repo is_empty
    local reuse_github_repo=false
    local clone_dir="$output_dir/$group_name/$project_name"

    run_step "checking the repo id is a number" grep -qE '^[0-9]+$' <<< "$project_id" || fail

    project_json=$(gitlab_api GET "projects/$project_id")
    run_step "checking the gitlab repo isn't empty" json_test '.empty_repo == false' <<< "$project_json" || fail
    default_branch=$(jq -r '.default_branch // empty' <<< "$project_json")
    description=$(jq -r '.description // empty' <<< "$project_json")

    # Every step below uses this name. Repos in a group whose names clash with
    # another GitLab repo's get the group's name as a prefix; repos in a user's
    # namespace keep theirs.
    target_project_name=$(github_name <<< "$project_name")
    if json_test '.namespace.kind == "group"' <<< "$project_json" &&
        grep -qixF -- "$target_project_name" <<< "$clashing_names"; then
        target_project_name="$(jq -r '.namespace.name' <<< "$project_json" | github_name)-$target_project_name"
        migration_logger "repo name clashes with another GitLab repo's, so it becomes $target_project_name" 0 true
    fi
    github_repo="$github_repo_target/$target_project_name"

    if is_empty=$(gh repo view "$github_repo" --json isEmpty --jq .isEmpty 2> /dev/null); then
        # An empty repo is left behind when an earlier run failed after
        # creating it, so carry on with it rather than failing forever.
        run_step "checking github repo $github_repo is new or empty" test "$is_empty" = true || fail
        reuse_github_repo=true
    fi

    # The clone is only ever left behind by an earlier run that stopped.
    if [ -e "$clone_dir" ]; then
        run_step "removing local clone left by an earlier run" rm -rf "$clone_dir" || fail
    fi
    run_step "cloning gitlab repo locally" git clone --recursive "$http_url" "$clone_dir" || fail
    cd "$clone_dir" || fail

    # Has to happen before git-filter-repo, which removes the origin remote.
    run_step "fetching Git LFS files of every branch" git lfs fetch --all origin || fail

    # GitLab CI pipelines aren't migrated; these repos need a GitHub Actions port.
    local has_gitlab_ci=false
    if [ -f .gitlab-ci.yml ]; then
        has_gitlab_ci=true
        migration_logger "repo has a .gitlab-ci.yml to port to GitHub Actions" 0 true
    fi
    local uses_lfs=false
    if [ -n "$(find .git/lfs/objects -type f -print -quit 2> /dev/null)" ]; then
        uses_lfs=true
        migration_logger "repo uses Git LFS" 0 true
    else
        migration_logger "repo uses Git LFS" 1 true
    fi

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

    run_step "git adding all for final product" git add --all || fail
    if ! git diff --cached --quiet; then
        run_step "git committing final product" git commit -m "Pre-GitHub Mirroring Commit" || fail
    fi

    # Scanned after the commit above so that files from flattened submodules
    # are covered too. Reports are redacted; the local clone is kept for review.
    local secrets_report="$secret_reports_dir/$group_name--$project_name.json"
    gitleaks git --no-banner --redact --exit-code 3 --config "$gitleaks_config" --gitleaks-ignore-path "$script_dir" \
        --report-format json --report-path "$secrets_report" .
    local exit_code=$?
    migration_logger "scanning history for secrets" "$exit_code"
    if [ "$exit_code" -eq 3 ]; then
        echo "Secrets found, see $secrets_report"
        record_repo "$has_secrets_file"
        exit 1
    fi
    [ "$exit_code" -eq 0 ] || fail "scanning history for secrets"
    rm -f "$secrets_report"

    if ! $reuse_github_repo; then
        local create_args=(--internal -t "$github_team")
        if [ -n "$description" ]; then
            create_args+=(--description "$description")
        fi
        change_step "creating repo in GitHub and adding webdev access" \
            gh repo create "$github_repo" "${create_args[@]}" || fail
    fi

    if [ -n "$(find . -maxdepth 1 -type f -name "*.aspx")" ]; then
        change_step "adding topic legacy-framework" gh repo edit "$github_repo" --add-topic "legacy-framework"
    fi

    if [ -n "$repo_topics" ]; then
        change_step "adding topic(s) $repo_topics" gh repo edit "$github_repo" --add-topic "$repo_topics"
    fi

    change_step "giving $github_team $github_team_permission access" \
        gh api -X PUT "orgs/$github_repo_target/teams/$github_team/repos/$github_repo" -f permission="$github_team_permission" --silent || fail

    run_step "adding github remote to repository" \
        git remote add github "https://github.com/$github_repo.git" || fail

    if $uses_lfs; then
        change_step "pushing Git LFS files to github" git lfs push --all github || fail
    fi
    change_step "mirroring repo to github" git push github 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' || fail
    change_step "verifying every branch and tag reached github" remote_refs_match github || fail
    record_repo "$done_file"
    if $has_gitlab_ci; then
        record_repo "$has_gitlab_ci_file"
    fi

    if [ -n "$default_branch" ]; then
        change_step "setting github default branch to $default_branch" \
            gh repo edit "$github_repo" --default-branch "$default_branch"
    fi

    change_step "post-migration: archiving repo in GitLab" archive_gitlab_repo

    cd "$base_dir" || exit 1
    run_step "post-migration: cleaning up local repo" rm -rf "$clone_dir"
}

for tool in git-filter-repo git-lfs gitleaks gh jq; do
    if ! command -v "$tool" > /dev/null; then
        echo "Error: $tool is required but wasn't found. See the README's prerequisites."
        exit 1
    fi
done

mkdir -p "$output_dir" "$secret_reports_dir"

# GitHub repo names are unique within the organization, ignoring case. Names
# that more than one GitLab repo would get, archived repos included, clash.
echo "Requesting the names of all GitLab repos"
if ! all_repos=$(gitlab_get_all "projects" "simple=true"); then
    echo "Error: Unable to retrieve the list of GitLab repos." >&2
    exit 1
fi
clashing_names=$(jq -r '.name' <<< "$all_repos" | github_name | sort -f | uniq -di)

{
    echo -e "\n$(date "+[%d-%b-%Y %H:%M:%S]")[executing: $script_name$($dry_run && echo " (dry run)")]"
    echo -e "                      [input file: $(realpath "$group_file")]"
    echo -e "                      [input file line count: $(grep -c '[^[:space:]]' "$group_file")]"
    if [ -n "$exclusions_file" ]; then
        echo -e "                      [exclusions file: $(realpath "$exclusions_file")]"
        echo -e "                      [exclusions file line count: $(grep -c '[^[:space:]]' "$exclusions_file")]"
    fi
} >> "$logfile"

# Counts every line, blank ones included, so that the summary can list the
# lines a run added with tail.
count_lines() {
    if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi
}

if $dry_run; then migrated_label="would be migrated"; else migrated_label="migrated"; fi
summary_labels=("$migrated_label" "failed" "excluded" "have nested submodules" "have secrets" "have a .gitlab-ci.yml to port")
summary_files=("$done_file" "$failed_file" "$excluded_file" "$has_modules_file" "$has_secrets_file" "$has_gitlab_ci_file")
summary_starts=()
for file in "${summary_files[@]}"; do
    summary_starts+=("$(count_lines "$file")")
done

# The list is read from fd 3 so that commands in the loop can't consume it.
# Fields after the fourth, such as the reasons in _failed.txt, are ignored.
while IFS=, read -r http_url group_name project_name project_id _ <&3 || [ -n "$http_url" ]; do
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
{
    echo "$(date "+[%d-%b-%Y %H:%M:%S]") $group_file processed. EOL"
    echo "Summary$($dry_run && echo " (dry run)"):"
    for i in "${!summary_files[@]}"; do
        echo "  ${summary_labels[i]}: $(( $(count_lines "${summary_files[i]}") - summary_starts[i] )) (${summary_files[i]##*/})"
    done
    tail -n +"$((summary_starts[1] + 1))" "$failed_file" 2> /dev/null | sed 's/^/    /'
} | tee -a "$logfile"
