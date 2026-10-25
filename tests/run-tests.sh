#!/bin/bash
#
# End-to-end tests for both scripts, run against a fake GitLab API
# (fake_gitlab.py), a fake gh (bin/gh) and local bare repositories standing in
# for GitLab and GitHub. Needs git, git-filter-repo, jq, curl and python3.
#
# Usage: tests/run-tests.sh

set -uo pipefail

tests_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(dirname "$tests_dir")
work=$(mktemp -d)
server_pid=""
trap '[ -n "$server_pid" ] && kill "$server_pid"; rm -rf "$work"' EXIT

failures=0
check() {
    local description=$1
    shift
    if "$@" > /dev/null 2>&1; then
        echo "ok - $description"
    else
        echo "not ok - $description"
        failures=$((failures + 1))
    fi
}

export HOME="$work/home"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export FAKE_GITHUB_DIR="$work/github"
export PATH="$tests_dir/bin:$PATH"
export GITLAB_TOKEN="secret-token"
export GITHUB_ORG="CORP-GITHUB"
export GITHUB_TEAM="web-development"
export MAX_BLOB_SIZE="1M"
export NO_PROXY="127.0.0.1" no_proxy="127.0.0.1"
mkdir -p "$HOME" "$FAKE_GITHUB_DIR/CORP-GITHUB" "$work/gitlab/websites"
git config --global user.name "Test"
git config --global user.email "test@example.com"
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global protocol.file.allow always
git config --global url."file://$FAKE_GITHUB_DIR/".insteadOf "https://github.com/"

gitlab="$work/gitlab/websites"
github="$FAKE_GITHUB_DIR/CORP-GITHUB"

# --- Fixture repositories -----------------------------------------------------

commit_all() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }

# A WordPress site with database dumps and a large file in its history, a
# second branch and an annotated tag.
src="$work/src/corp-site"
mkdir -p "$src/plugins" "$src/data/nested"
git init -q "$src"
echo "<?php" > "$src/index.php"
echo "plugin" > "$src/plugins/plugin.php"
echo "keep me" > "$src/keep.sql"
echo "keep me too" > "$src/data/github.sql"
commit_all "$src" "site"
echo "secret dump" > "$src/data/dump.sql"
echo "old secret dump" > "$src/data/nested/old.sql"
commit_all "$src" "dumps"
head -c 2000000 /dev/urandom > "$src/big.bin"
commit_all "$src" "large file"
git -C "$src" rm -q big.bin && git -C "$src" commit -qm "remove large file"
git -C "$src" tag -a v1 -m "release 1"
git -C "$src" checkout -qb feature
echo "feature dump" > "$src/data/feature.sql"
echo "feature" > "$src/feature.txt"
commit_all "$src" "feature"
git -C "$src" checkout -q main
git clone -q --bare "$src" "$gitlab/corp-site.git"

# A repo with a submodule whose default branch isn't main.
src="$work/src/lib"
git init -q "$src" && echo "lib" > "$src/lib.txt" && commit_all "$src" "lib"
git clone -q --bare "$src" "$gitlab/lib.git"
src="$work/src/with-submodule"
git init -q "$src" && echo "readme" > "$src/README" && commit_all "$src" "readme"
git -C "$src" checkout -qb develop
git -C "$src" submodule -q add "file://$gitlab/lib.git" vendor/lib
commit_all "$src" "add submodule"
git clone -q --bare "$src" "$gitlab/with-submodule.git"

git init -q --bare "$gitlab/empty-one.git"
for name in excluded-one already-there flaky; do
    src="$work/src/$name"
    git init -q "$src" && echo "$name" > "$src/file.txt" && commit_all "$src" "$name"
    git clone -q --bare "$src" "$gitlab/$name.git"
done
git clone -q --bare "$work/src/already-there" "$github/already-there.git"
already_there_refs=$(git --git-dir="$github/already-there.git" show-ref)

git clone -q --bare "$work/src/lib" "$github/actions.git"
src="$work/src/actions"
git clone -q "$github/actions.git" "$src"
mkdir -p "$src/copy-for-website-repos/.github/workflows"
echo "name: deploy" > "$src/copy-for-website-repos/.github/workflows/deploy.yml"
commit_all "$src" "workflows" && git -C "$src" push -q origin HEAD

# --- Fake GitLab --------------------------------------------------------------

state="$work/gitlab-state.json"
python3 - "$state" "$gitlab" <<'EOF'
import json, sys
state_path, gitlab = sys.argv[1:]
# Enough groups to need several pages, with websites on the last one, a
# subgroup sharing its name with another group and a group that errors.
groups = [{"id": i, "name": f"filler-{i}", "full_path": f"filler-{i}"} for i in range(5, 25)]
groups += [
    {"id": 2, "name": "templates", "full_path": "templates"},
    {"id": 3, "name": "Templates", "full_path": "packages/Templates"},
    {"id": 4, "name": "broken", "full_path": "broken", "fail_page": 1},
    {"id": 1, "name": "websites", "full_path": "websites"},
]
def project(id, name, path, group, empty=False, default_branch="main", archived=False):
    return {"id": id, "name": name, "path": path, "archived": archived,
            "empty_repo": empty, "default_branch": None if empty else default_branch,
            "namespace": {"id": group["id"], "name": group["name"]},
            "http_url_to_repo": f"file://{gitlab}/{path}.git"}
websites, templates, sub_templates = groups[-1], groups[-4], groups[-3]
projects = [
    project(101, "Corp Site", "corp-site", websites),
    project(102, "with-submodule", "with-submodule", websites, default_branch="develop"),
    project(103, "empty-one", "empty-one", websites, empty=True),
    project(104, "excluded-one", "excluded-one", websites),
    project(105, "already-there", "already-there", websites),
    project(106, "flaky", "flaky", websites),
    project(107, "old-archived", "old-archived", websites, archived=True),
    project(201, "template-a", "template-a", templates),
    project(301, "template-b", "template-b", sub_templates),
]
json.dump({"groups": groups, "projects": projects}, open(state_path, "w"), indent=2)
EOF
python3 "$tests_dir/fake_gitlab.py" "$state" "$work/port" &
server_pid=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
GITLAB_URL="http://127.0.0.1:$(cat "$work/port")"
export GITLAB_URL

is_archived() { jq -e --argjson id "$1" '.projects[] | select(.id == $id) | .archived' "$state"; }
not() { ! "$@"; }

# --- Script 01 ----------------------------------------------------------------

echo "# 01__generate-gitlab-lists.sh"
run1="$work/run1" && mkdir -p "$run1" && cd "$run1" || exit 1
lists="$run1/_script-products/01__generate-gitlab-lists"

timeout 60 "$repo_root/01__generate-gitlab-lists.sh" > "$work/run1.out" 2>&1
status=$?
check "finishes instead of retrying a failing page forever" test "$status" -ne 124
check "exits non-zero when a group can't be listed" test "$status" -eq 1
check "reports the group that failed" grep -q "repos of group broken" "$work/run1.out"
check "lists groups beyond the first page" test -f "$lists/group--websites.txt"
check "writes a file for every listable group" test "$(find "$lists" -name 'group--*.txt' | wc -l)" -eq 23
check "lists unarchived repos only" test "$(wc -l < "$lists/group--websites.txt")" -eq 6
check "writes url,group,name,id lines" grep -qx "file://$gitlab/corp-site.git,websites,Corp Site,101" "$lists/group--websites.txt"
check "keeps a subgroup apart from a group of the same name" grep -q template-b "$lists/group--packages__Templates.txt"
check "doesn't mix subgroup repos into the other group" not grep -q template-b "$lists/group--templates.txt"
cp "$lists/group--websites.txt" "$work/websites.txt"

"$repo_root/01__generate-gitlab-lists.sh" -g packages/Templates > /dev/null 2>&1
check "-g selects a group by full path" test "$(ls "$lists")" = "group--packages__Templates.txt"
"$repo_root/01__generate-gitlab-lists.sh" -g websites > /dev/null 2>&1
check "-g selects a group by name" test "$(ls "$lists")" = "group--websites.txt"

GITLAB_TOKEN=wrong timeout 60 "$repo_root/01__generate-gitlab-lists.sh" > /dev/null 2>&1
check "fails on a rejected token" test $? -eq 1
check "keeps the previous lists when it can't reach GitLab" test -f "$lists/group--websites.txt"

# --- Script 02 ----------------------------------------------------------------

echo "# 02__clone-scrub-import-client-repos.sh"
run2="$work/run2" && mkdir -p "$run2" && cd "$run2" || exit 1
sed -i 's/$/\r/' "$work/websites.txt"
# README format, Windows line endings, a blank line and a url prefixing another.
printf '%s\r\n' "file://$gitlab/excluded-one.git,websites,excluded-one,104" "" "file://$gitlab/corp" > "$work/exclusions.txt"

FAKE_GH_FAIL_API_FOR=CORP-GITHUB/flaky timeout 300 "$repo_root/02__clone-scrub-import-client-repos.sh" \
    -f "$work/websites.txt" -x "$work/exclusions.txt" -c "client-a,wordpress" > "$work/run2.out" 2>&1
check "finishes the batch" test $? -eq 0

site="$github/Corp-Site.git"
site_git() { git --git-dir="$site" "$@"; }
check "excludes the repo listed in the exclusions file" grep -q "excluded-one" "$run2/_excluded.txt"
check "doesn't exclude anything else" test "$(wc -l < "$run2/_excluded.txt")" -eq 1
check "doesn't migrate the excluded repo" not test -e "$github/excluded-one.git"
check "creates the repo under a valid GitHub name" test -d "$site"
check "migrates every branch" test "$(site_git for-each-ref --format='%(refname)' refs/heads | sort | tr '\n' ' ')" = "refs/heads/feature refs/heads/main "
check "migrates annotated tags" test "$(site_git cat-file -t refs/tags/v1)" = tag
check "removes data/*.sql dumps from all history" not grep -E 'data/(dump|nested/old|feature)\.sql' <(site_git log --all --format= --name-only)
check "removes large files from all history" not grep -q 'big.bin' <(site_git log --all --format= --name-only)
check "keeps data/github.sql" site_git cat-file -e main:data/github.sql
check "keeps sql files outside data/" site_git cat-file -e main:keep.sql
for scrubbed in "sql dump: data/dump.sql" "sql dump: data/nested/old.sql" "sql dump: data/feature.sql" "large file .*: big.bin"; do
    check "records $scrubbed as scrubbed" grep -q "$scrubbed" "$run2/_scrubbed.txt"
done
check "doesn't record github.sql as scrubbed" not grep -q github.sql "$run2/_scrubbed.txt"
check "copies the webdev-actions workflows into WordPress repos" site_git cat-file -e main:.github/workflows/deploy.yml
check "creates the repo as internal for the team" grep -qx -- "--internal -t web-development" "$github/Corp-Site.meta/create-args"
check "gives the team admin access" grep -qx "web-development admin" "$github/Corp-Site.meta/team"
check "adds the -c topics" test "$(sort "$github/Corp-Site.meta/topics" | tr '\n' ' ')" = "client-a wordpress "
check "records the migrated repo as done" grep -q "Corp Site,101" "$run2/_done.txt"
check "archives the migrated repo in GitLab" is_archived 101
check "deletes the local clone after migrating" not test -e "$run2/_script-products/02__clone-scrub-import-client-repos/websites/Corp Site"

sub="$github/with-submodule.git"
check "sets the GitHub default branch to GitLab's" test "$(git --git-dir="$sub" symbolic-ref HEAD)" = refs/heads/develop
check "turns submodules into regular files" test "$(git --git-dir="$sub" cat-file -t develop:vendor/lib/lib.txt)" = blob
check "removes .gitmodules" not git --git-dir="$sub" cat-file -e develop:.gitmodules
check "archives the repo with submodules" is_archived 102

check "fails empty GitLab repos" grep -q "empty-one,103" "$run2/_failed.txt"
check "doesn't create GitHub repos for empty GitLab repos" not test -e "$github/empty-one.git"
check "fails repos that already exist on GitHub" grep -q "already-there,105" "$run2/_failed.txt"
check "leaves existing GitHub repos untouched" test "$(git --git-dir="$github/already-there.git" show-ref)" = "$already_there_refs"
check "doesn't archive repos that weren't migrated" not is_archived 105
check "fails a repo when a GitHub step fails" grep -q "flaky,106" "$run2/_failed.txt"
check "doesn't archive a repo that failed" not is_archived 106
check "logs results without the old typo" not grep -q SUCCESSFULL "$run2/_log.txt"

# Retrying a failed repo reuses the empty GitHub repo the failed run created.
rm -rf "$run2/_script-products/02__clone-scrub-import-client-repos/websites/flaky"
grep "flaky" "$work/websites.txt" > "$work/retry.txt"
timeout 300 "$repo_root/02__clone-scrub-import-client-repos.sh" -f "$work/retry.txt" > "$work/retry.out" 2>&1
check "migrates a failed repo when retried" grep -q "flaky,106" "$run2/_done.txt"
check "pushes the retried repo to the reused GitHub repo" git --git-dir="$github/flaky.git" cat-file -e main:file.txt
check "archives the retried repo" is_archived 106

# Rerunning a list doesn't overwrite repos that are already on GitHub.
site_refs=$(site_git show-ref)
timeout 300 "$repo_root/02__clone-scrub-import-client-repos.sh" -f "$work/websites.txt" > /dev/null 2>&1
check "leaves already-migrated repos untouched on a rerun" test "$(site_git show-ref)" = "$site_refs"

echo
if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed. Script output: $work/run1.out, $work/run2.out, $work/retry.out"
    trap '[ -n "$server_pid" ] && kill "$server_pid"' EXIT
    exit 1
fi
echo "All checks passed."
