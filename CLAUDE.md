# lab-to-hub

Bash scripts that migrate repositories from our GitLab instance to our GitHub organization. `README.md` documents what the scripts do for the people running them. This file is for whoever changes them next: the decisions already made, how the code is put together and how to check a change.

Open work is tracked in GitHub issues #11–#16, listed in the README's To-do section. Start with #11, a trial run on real repos: so far everything has been tested against fakes only.

## Decisions made by the repo owner
Don't change these without asking.

- **What's migrated:** branches, tags, Git LFS files and the description. Protected branch settings are deliberately not carried over, as GitLab's protected branch feature wasn't used. Issues, merge requests, wikis, CI/CD variables and pipelines aren't migrated either.
- **Team access:** the team (`GITHUB_TEAM`, default `web-development`) gets `maintain` by default, not `admin`. Change it with `GITHUB_TEAM_PERMISSION`.
- **Which groups script 01 lists:** every group the token can see, with no visibility filter.
- **Repo names:** when more than one GitLab repo, archived ones included, would get the same GitHub name (case-insensitive), repos in a group get the group's full path as a prefix with `/` → `-` (`packages-Templates-site`). Repos in a user's personal namespace are "root level" and never get a prefix. Cases that still clash are in #13.
- **History scrubbing:** files over `MAX_BLOB_SIZE` (90M) and `data/**/*.sql` dumps (except `github.sql`) are removed from all of history. Repos where gitleaks finds secrets are held back, not migrated.

## How script 02 is put together
- `migrate_repo` handles one repo and always runs in a subshell, `( migrate_repo )`, so that `fail` can `exit` out of it and its `cd` doesn't leak. Every step goes through `run_step "<action>" cmd…`, which logs the result and remembers the action, so a failure ends up in `_failed.txt` as `…,failed: <action>`. Phrase actions so they read well after "failed:".
- Every step that changes GitHub or GitLab must go through `change_step` rather than `run_step`, so that dry runs (`-n`) skip it. Don't put the side effect in the arguments: `change_step … json_test … <<< "$(gitlab_api POST …)"` still runs the POST in a dry run, because the shell expands the here-string before `change_step` is called. Wrap it in a function instead, like `archive_gitlab_repo`.
- Record files (`_done.txt`, `_failed.txt`, …) are named from `record_prefix`, which a dry run sets to `_dry-run`. Input lines are `http_url,group_name,repo_name,repo_id`; extra fields are ignored.
- The GitLab API functions are in `lib/gitlab.sh`, sourced by both scripts. The secret scan always uses this repo's `gitleaks.toml` and `.gitleaksignore`, never the migrated repo's, because a `.gitleaks.toml` inside a scanned repo can switch every rule off.
- git-lfs's pre-push hook uploads LFS objects during `git push` even without the explicit `git lfs push`. Tests that only check that the objects reached GitHub can't tell whether the explicit step ran; check the log instead.

## Checking a change
- `shellcheck -x *.sh lib/*.sh tests/*.sh tests/bin/gh` must be clean.
- `tests/run-tests.sh` runs both scripts end to end against `tests/fake_gitlab.py` (a fake GitLab API that caps pages at 10 and rejects unknown query parameters), `tests/bin/gh` (a fake gh on local bare repos) and fixture repos built at the start of the run. It needs git, git-lfs, git-filter-repo, gitleaks 8.28+, jq, curl and Python 3, and prints one `ok`/`not ok` line per check.
- When adding a feature, add fixtures and checks for it, then break the feature on purpose and make sure a check fails. Keep anything that looks like a real secret out of committed files: the test key is put together at runtime so push protection and gitleaks don't flag this repo.
- CI (`.github/workflows/test.yml`) runs both of the above on Linux. Actions are pinned to commit SHAs, which Dependabot updates; gitleaks is pinned by version and sha256, updated by hand (#16).

## Workflow
Work on a branch, open a PR against `main` and merge it with a merge commit once CI passes. Keep the README in step with the scripts: its step list, output-file table and To-do section.
