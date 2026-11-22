## Introduction
This repository contains two bash scripts that assist with the migration of git repositories from our GitLab instance to our organization's GitHub.

What gets migrated is every branch and tag, the Git LFS files they refer to and the repository's description. Before anything reaches GitHub, each repository has files bigger than 90MB and database dumps removed from its history, its submodules flattened into regular directories and its whole history scanned for secrets.

What isn't migrated: issues, merge requests, wikis, protected branch settings, CI/CD variables and `.gitlab-ci.yml` pipelines. Repositories with a `.gitlab-ci.yml` are listed so their pipelines can be ported to GitHub Actions.

## Prerequisites
Before you can run these scripts there are a few things you need to set up, first.
1. Create a GitLab personal access token
2. Install GitHub CLI and log in with `gh auth login` (using a GitHub personal access token or the browser)
3. Run `gh auth setup-git` so that git can push to CORP-GITHUB over HTTPS
4. Make sure git can clone from GitLab over HTTP(S) without prompting, e.g. with a credential helper
5. Install Python 3.12
6. Install jq dependency
7. Install git-filter-repo dependency by running `python -m pip install --user git-filter-repo`
8. Install [Git LFS](https://git-lfs.com) (bundled with Git for Windows) and run `git lfs install`
9. Install [gitleaks](https://github.com/gitleaks/gitleaks/releases) 8.28 or later and put it on your `PATH`

Script 02 checks for git-filter-repo, Git LFS, gitleaks, gh and jq when it starts and stops straight away if one is missing.

## Configuration
Both scripts read these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITLAB_TOKEN` | | GitLab token, as an alternative to `-t`. Prefer this: values passed with `-t` end up in your shell history. |
| `GITLAB_URL` | `https://GITLAB-HOSTNAME` | Base URL of the GitLab instance |
| `GITHUB_ORG` | `CORP-GITHUB` | GitHub organization the repos are created in (script 02) |
| `GITHUB_TEAM` | `web-development` | Team given access to the new repos (script 02) |
| `GITHUB_TEAM_PERMISSION` | `maintain` | Permission the team gets: `pull`, `triage`, `push`, `maintain` or `admin` (script 02) |
| `MAX_BLOB_SIZE` | `90M` | Files bigger than this are removed from history (script 02) |

## Repository layout
| Path | What it is |
| --- | --- |
| `01__generate-gitlab-lists.sh` | Lists the repositories of each GitLab group |
| `02__clone-scrub-import-client-repos.sh` | Migrates the repositories in a list to GitHub |
| `lib/gitlab.sh` | The GitLab API functions both scripts use |
| `gitleaks.toml` | Secret scanning rules used by script 02. Add allowlists for reviewed false positives here. |
| `tests/` | End-to-end tests, see [Tests](#tests) |
| `.github/workflows/test.yml` | Runs shellcheck and the tests on every push and pull request |
| `.github/dependabot.yml` | Has Dependabot propose updates to the actions the CI workflow uses |

## Scripts Overview
The files `01__generate-gitlab-lists.sh` and `02__clone-scrub-import-client-repos.sh` are bash scripts that can be executed from your git bash terminal. These scripts perform the work of pulling repositories out of GitLab, prepping them, and migrating the repos into GitHub.

## Script "01" Overview
### Usage
```
./01__generate-gitlab-lists.sh [ -t <gitlab-token> ] [ -g <gitlab-group-name-or-full-path> ]
```

| Option | Purpose |
| --- | --- |
| `-t` | GitLab token, if `GITLAB_TOKEN` isn't set |
| `-g` | Only list the group with this name or full path, e.g. `templates` or `packages/Templates` |

### "01" Summary
This script makes a request to our GitLab instance's API for all groups the token can see[^1]. The script then loops over the list of groups and queries for all unarchived repositories in that group. The script generates a text file for each group named `group--<gitlab-group-full-path>.txt`, with any `/` in the path replaced by `__`, where each line represents an individual repository in that group[^2]. The following data is recorded for each repository:
* http url
* group name
* repository name
* repository id

This data is comma-separated, one repository per line. The products of this script are generated into a directory named `_script-products/01__generate-gitlab-lists`. Any lists from a previous run are replaced once GitLab has been reached.

If a group's repositories can't be retrieved, the script reports it, carries on with the other groups and exits with a non-zero status.

### Tips
* It's strongly recommended that you put these scripts in a new directory as close to the root of your drive as possible because the migration process will involve cloning repositories to your drive and Windows doesn't like files with very, very long paths. Clone or copy the whole repository there: the scripts need `lib/` and `gitleaks.toml` next to them.

## Script "02" Overview
### Usage
```
./02__clone-scrub-import-client-repos.sh [ -t <gitlab-token> ] -f <path-to-repo-list.txt> [ -c <repo-topics> ] [ -x <path-to-exclusions-list.txt> ] [ -n ]
```

| Option | Purpose |
| --- | --- |
| `-t` | GitLab token, if `GITLAB_TOKEN` isn't set |
| `-f` | The list of repositories to migrate, in the format script 01 writes |
| `-c` | Comma-separated topics to add to every repository in the list |
| `-x` | A list of repositories to skip, in the same format |
| `-n` | Dry run, see [Dry runs](#dry-runs) |

### "02" Summary
When it starts, the script fetches the names of every GitLab repository once, to work out which names clash on GitHub (see step 2). It then performs the following for each repository in the list. If a step fails, the repository is recorded in `_failed.txt`, followed by the step that failed, and the script moves onto the next one.
<details><summary>1. Checks GitLab that the repo isn't empty.</summary>Empty repositories have nothing to migrate.</details>
<details><summary>2. Works out the GitHub name and checks GitHub for a repo by that name.</summary>Characters GitHub doesn't allow in repository names, such as spaces, are replaced with <code>-</code>.<br><br>GitHub repo names must be unique within the organization, ignoring case. So when more than one GitLab repo, archived ones included, would get the same name, the ones in a group get the group's name as a prefix: <code>shared</code> in the <code>websites</code> group becomes <code>websites-shared</code>. Repos in a user's namespace, which aren't in a group, keep their name. A repo that was migrated before this rule was added keeps its name on GitHub, so only the other repos with that name get a prefix.<br><br>If no GitHub repo by that name is found then we are good to proceed. If an empty one is found, it was left behind by an earlier run that failed and it is reused. Otherwise the repo fails, as it has either already been migrated or still clashes with another one (see the <a href="#to-do">To-do</a> list).</details>
<details><summary>3. Clones the repo locally.</summary>A local clone left behind by an earlier run that stopped is deleted first. Repos with a <code>.gitlab-ci.yml</code> on their default branch are recorded in <code>_has_gitlab_ci.txt</code> once they're migrated, because their pipelines need porting to GitHub Actions.</details>
<details><summary>4. Fetches the Git LFS files of every branch.</summary>Repos that don't use Git LFS have nothing to fetch. If a file can't be fetched, the repo fails rather than being migrated without it.</details>
<details><summary>5. Removes files bigger than 90MB and database dumps from the whole history.</summary>Every <code>.sql</code> file under <code>data/</code> is removed from every commit of every branch, except for files named <code>github.sql</code>. What gets removed is recorded in <code>_scrubbed.txt</code>. The size limit can be changed with <code>MAX_BLOB_SIZE</code>. Git LFS files aren't affected by it, because only small pointers to them are kept in the history.</details>
<details><summary>6. Checks for the existence of a .gitmodules file.</summary>If .gitmodules exist, then the script works to unsubmodule any submodules found 1-level deep and .gitmodules is removed. Repos with nested submodules are recorded in <code>_has_modules.txt</code> and skipped. Files from the submodules that are bigger than the size limit in step 5 are left out, as GitHub would refuse the push, and recorded in <code>_scrubbed.txt</code>. Their Git LFS files are kept and migrated.</details>
<details><summary>7. Copies the webdev-actions workflows into WordPress repos.</summary>Repos with a <code>plugins</code> directory get the <code>.github</code> directory of the CORP-GITHUB/actions repo, which is cloned to or updated in <code>~/actions</code>.</details>
<details><summary>8. Commits the changes above and scans the whole history for secrets.</summary>gitleaks checks every commit of every branch, including the files from flattened submodules, for keys, tokens and passwords. If it finds any, nothing is created on GitHub: the repo is recorded in <code>_has_secrets.txt</code>, a report saying where each secret is (without the secret itself) is written to <code>_script-products/secret-reports/</code>, and the local clone is kept for review. The scan always uses this repo's <code>gitleaks.toml</code>, so a <code>.gitleaks.toml</code> inside a migrated repo can't switch it off.</details>
<details><summary>9. Create a new GitHub repo using the name from step 2.</summary>In addition, this new repo is marked as <strong>internal</strong>, gets the GitLab repo's description, and the <strong>web-development</strong> team is given <strong>maintain</strong> access to it (see <code>GITHUB_TEAM</code> and <code>GITHUB_TEAM_PERMISSION</code>). Repos with <code>.aspx</code> files at their root get the <code>legacy-framework</code> topic, and all of them get the topics given with -c.</details>
<details><summary>10. A new remote named github is added to the local repo's config which points to the new GitHub repo.</summary>The new, submoduleless state of the repo committed in step 8 is what gets migrated.</details>
<details><summary>11. Pushes every branch, tag and Git LFS file to GitHub and checks the branches and tags all arrived.</summary>Any work that was not already merged before migrating its repository would be lost if we didn't carry over these branches. The repo is recorded in <code>_done.txt</code> and its GitHub default branch is set to match GitLab's.</details>
<details><summary>12. Archive the GitLab repo.</summary>Archived repositories do not appear in GitLab so it'll help serve as a clear indicator as to whether or not a particular repository has been migrated. Also, the repository will not get pulled in by script "01" should the script need to be executed, again, to produce a fresh list of unmigrated repos.</details>
<details><summary>13. Delete the local repo.</summary>If the script has successfully executed all of its instructions and reaches the end of its tasks, the last thing it does is delete the cloned repo before moving onto the next one.</details>

Every step is logged to `_log.txt`. At the end, the script prints a summary of how many repositories ended up in each of the files below, followed by the ones that failed and why. The summary is added to `_log.txt` as well.

### Output files
Script 02 writes these files to the directory you run it from. Each run adds to them rather than replacing them.

| File | What's in it |
| --- | --- |
| `_log.txt` | Every step of every repository, and each run's summary |
| `_done.txt` | Repositories that were migrated |
| `_failed.txt` | Repositories that failed, each followed by the step that failed |
| `_excluded.txt` | Repositories skipped because they're in the `-x` list |
| `_has_modules.txt` | Repositories skipped because they have nested submodules |
| `_has_secrets.txt` | Repositories held back because the secret scan found something |
| `_has_gitlab_ci.txt` | Migrated repositories whose `.gitlab-ci.yml` needs porting to GitHub Actions |
| `_scrubbed.txt` | The large files and database dumps removed from each repository's history, and the large files left out of its flattened submodules |
| `_script-products/secret-reports/` | One redacted report per repository with secrets |
| `_script-products/02__clone-scrub-import-client-repos/` | Local clones. Only those of repositories that failed or were held back are left. |

### Dry runs
With `-n`, every repository is cloned, scrubbed and scanned for secrets as usual, but nothing is created or changed on GitHub and nothing is archived in GitLab. Each step that would change something is logged as `SKIPPED (dry run)`. The results go to files of their own, prefixed `_dry-run` (`_dry-run_done.txt` lists what would be migrated), so they don't mix with those of real runs. A dry run is a quick way to find the repos with secrets, nested submodules or other problems before a real run.

### "02" Tips
* You can author your own input files as long as you follow the expected format. This means you can curate a list of GitLab repositories spanning multiple groups in a new text file and feed that into the script. Blank lines and Windows line endings are fine.
* `_failed.txt` uses the same format, with the step that failed as an extra field, so you can feed it back into the script to retry the repos that failed. Fields after the fourth are ignored.
* If you want to add one or more topics to the repos you are processing in a given list then provide them using the -c option.
* When a repo is recorded in `_has_secrets.txt`, look up each finding in its report and the local clone. If a secret is real, rotate it: it has been in GitLab all along, and removing it from history doesn't make it safe again. Before retrying, either remove it from history in GitLab or, if it's a false positive, add an allowlist to `gitleaks.toml` or add the report's `Fingerprint` to a `.gitleaksignore` file next to it. Then run the repo again.
* Git LFS files count against the GitHub organization's LFS storage and bandwidth.
* You can provide a list of repositories to ignore by providing the filename to the -x option. This file follows the same format as the group input files, and a repository is ignored when its http url matches the first field of a line exactly. Ignored repositories are recorded in `_excluded.txt`.

## Tests
`tests/run-tests.sh` runs both scripts end to end against a fake GitLab API (`tests/fake_gitlab.py`), a fake `gh` (`tests/bin/gh`) and local repositories, so it doesn't touch GitLab or GitHub. It needs git, Git LFS, git-filter-repo, gitleaks, jq, curl and Python 3, and prints one line per check.

The test fixtures cover, among other things: pagination and API errors, exclusions, removing dumps and large files from history, submodules, Git LFS, secrets, dry runs, name clashes, retries and reruns. CI runs the tests and shellcheck on Linux. They haven't been run on Windows.

## To-do
- [ ] **Try the scripts on a small real batch.** Everything so far has been tested against fakes only. Do a dry run (`-n`) on 3–5 real repos, including a WordPress site, an LFS repo and one with submodules, then a real run. Check that:
  - GitLab returns the `empty_repo` field the script relies on
  - `GITLAB_URL` works over `https://`
  - the secret scan doesn't flag too many false positives (add allowlists to `gitleaks.toml`)
  - renamed repos get the names you expect
  - branches, tags, LFS files, team access and the description arrive on GitHub
- [ ] **Resolve the name clashes that remain.** Two repos still get the same GitHub name, and the second fails as "already exists", when both are in user namespaces, or when their groups share a name (e.g. `templates/site` and `packages/Templates/site`). Prefixing with the group's full path would fix the latter.
- [x] **Remove large files that come in with flattened submodules.** Done: they're left out of the final commit and recorded in `_scrubbed.txt`.
- [ ] **Decide what to do with repos that have nested submodules.** They're only listed in `_has_modules.txt` for now.
- [x] **Share the GitLab API code between the scripts.** Done: it's in `lib/gitlab.sh`.
- [x] **Pin the CI workflow's actions to commit SHAs and turn on Dependabot.** Done. Dependabot doesn't cover the gitleaks version pinned in the workflow, which is updated by hand.
- [ ] **Run the tests on Windows in CI**, since the scripts are meant to be run from Git Bash.
- [ ] **Port the pipelines listed in `_has_gitlab_ci.txt` to GitHub Actions** as repos are migrated.

[^1]: There is no visibility filter on this request, so the lists cover internal and public groups alike.
[^2]: GitLab returns subgroups as groups of their own, so a subgroup gets its own file named after its full path. For example, a group named `templates` and a subgroup `Templates` of a parent group `packages` produce `group--templates.txt` and `group--packages__Templates.txt`.
