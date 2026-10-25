## Introduction
This repository contains two bash scripts that assist with the migration of git repositories from our GitLab instance to our organization's GitHub.

Only git data (branches and tags) is migrated. Issues, merge requests, wikis, CI/CD variables and `.gitlab-ci.yml` pipelines are not.

## Prerequisites
Before you can run these scripts there are a few things you need to set up, first.
1. Create a GitLab personal access token
2. Install GitHub CLI and log in with `gh auth login` (using a GitHub personal access token or the browser)
3. Run `gh auth setup-git` so that git can push to CORP-GITHUB over HTTPS
4. Make sure git can clone from GitLab over HTTP(S) without prompting, e.g. with a credential helper
5. Install Python 3.12
6. Install jq dependency
7. Install git-filter-repo dependency by running `python -m pip install --user git-filter-repo`

## Configuration
Both scripts read these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITLAB_TOKEN` | | GitLab token, as an alternative to `-t`. Prefer this: values passed with `-t` end up in your shell history. |
| `GITLAB_URL` | `https://GITLAB-HOSTNAME` | Base URL of the GitLab instance |
| `GITHUB_ORG` | `CORP-GITHUB` | GitHub organization the repos are created in (script 02) |
| `GITHUB_TEAM` | `web-development` | Team given admin access to the new repos (script 02) |
| `MAX_BLOB_SIZE` | `90M` | Files bigger than this are removed from history (script 02) |

## Scripts Overview
The files `01__generate-gitlab-lists.sh` and `02__clone-scrub-import-client-repos.sh` are bash scripts that can be executed from your git bash terminal. These scripts perform the work of pulling repositories out of GitLab, prepping them, and migrating the repos into GitHub.

## Script "01" Overview
### Usage
```
./01__generate-gitlab-lists.sh [ -t <gitlab-token> ] [ -g <gitlab-group-name-or-full-path> ]
```

### "01" Summary
This script makes a request to our GitLab instance's API for all groups the token can see[^1]. The script then loops over the list of groups and queries for all unarchived repositories in that group. The script generates a text file for each group named `group--<gitlab-group-full-path>.txt`, with any `/` in the path replaced by `__`, where each line represents an individual repository in that group[^2]. The following data is recorded for each repository:
* http url
* group name
* repository name
* repository id

This data is comma-separated, one repository per line. The products of this script are generated into a directory named `_script-products`. Any lists from a previous run are replaced once GitLab has been reached.

If a group's repositories can't be retrieved, the script reports it, carries on with the other groups and exits with a non-zero status.

### Tips
* It's strongly recommended that you put these scripts in a new directory as close to the root of your drive as possible because the migration process will involve cloning repositories to your drive and Windows doesn't like files with very, very long paths.

## Script "02" Overview
### Usage
```
./02__clone-scrub-import-client-repos.sh [ -t <gitlab-token> ] -f <path-to-repo-list.txt> [ -c <repo-topics> ] [ -x <path-to-exclusions-list.txt> ]
```

### "02" Summary
This script reads the provided group text file and performs the following for each repository in the list. If a step fails, the repository is recorded in `_failed.txt` and the script moves onto the next one.
<details><summary>1. Checks GitLab that the repo isn't empty.</summary>Empty repositories have nothing to migrate.</details>
<details><summary>2. Checks GitHub for a repo by the same name.</summary>If none is found then we are good to proceed. If an empty one is found, it was left behind by an earlier run that failed and it is reused. Otherwise we assume the repo has already been migrated or needs to be renamed. Characters GitHub doesn't allow in repository names, such as spaces, are replaced with <code>-</code>.</details>
<details><summary>3. Clones the repo locally.</summary>If a non-empty directory with the same name exists at the target location, the clone fails. Delete the directory left behind by a failed run before retrying a repo.</details>
<details><summary>4. Removes files bigger than 90MB and database dumps from the whole history.</summary>Every <code>.sql</code> file under <code>data/</code> is removed from every commit of every branch, except for files named <code>github.sql</code>. What gets removed is recorded in <code>_scrubbed.txt</code>.</details>
<details><summary>5. Checks for the existence of a .gitmodules file.</summary>If .gitmodules exist, then the script works to unsubmodule any submodules found 1-level deep and .gitmodules is removed. Repos with nested submodules are recorded in <code>_has_modules.txt</code> and skipped.</details>
<details><summary>6. Copies the webdev-actions workflows into WordPress repos.</summary>Repos with a <code>plugins</code> directory get the <code>.github</code> directory of the CORP-GITHUB/actions repo, which is cloned to or updated in <code>~/actions</code>.</details>
<details><summary>7. Create a new GitHub repo using the name of the current GitLab repo.</summary>In addition, this new repo is marked as <strong>internal</strong> and the <strong>web-development</strong> team is given admin access to it. Repos with <code>.aspx</code> files at their root get the <code>legacy-framework</code> topic, and all of them get the topics given with -c.</details>
<details><summary>8. A new remote named github is added to the local repo's config which points to the new GitHub repo.</summary>The unsubmodule and webdev-actions work is added and committed locally so we can migrate the new, submoduleless state of the repo to GitHub.</details>
<details><summary>9. Pushes every branch and tag to GitHub and checks they all arrived.</summary>Any work that was not already merged before migrating its repository would be lost if we didn't carry over these branches. The repo is recorded in <code>_done.txt</code> and its GitHub default branch is set to match GitLab's.</details>
<details><summary>10. Archive the GitLab repo.</summary>Archived repositories do not appear in GitLab so it'll help serve as a clear indicator as to whether or not a particular repository has been migrated. Also, the repository will not get pulled in by script "01" should the script need to be executed, again, to produce a fresh list of unmigrated repos.</details>
<details><summary>11. Delete the local repo.</summary>If the script has successfully executed all of its instructions and reaches the end of its tasks, the last thing it does is delete the cloned repo before moving onto the next one.</details>

Every step is logged to `_log.txt`.

### "02" Tips
* You can author your own input files as long as you follow the expected format. This means you can curate a list of GitLab repositories spanning multiple groups in a new text file and feed that into the script. Blank lines and Windows line endings are fine.
* `_failed.txt` uses the same format, so you can feed it back into the script to retry the repos that failed.
* If you want to add one or more topics to the repos you are processing in a given list then provide them using the -c option.
* You can provide a list of repositories to ignore by providing the filename to the -x option. This file follows the same format as the group input files, and a repository is ignored when its http url matches the first field of a line exactly. Ignored repositories are recorded in `_excluded.txt`.

## Tests
`tests/run-tests.sh` runs both scripts end to end against a fake GitLab API, a fake `gh` and local repositories, so it doesn't touch GitLab or GitHub. It needs git, git-filter-repo, jq, curl and Python 3.

[^1]: There is no visibility filter on this request, so the lists cover internal and public groups alike.
[^2]: GitLab returns subgroups as groups of their own, so a subgroup gets its own file named after its full path. For example, a group named `templates` and a subgroup `Templates` of a parent group `packages` produce `group--templates.txt` and `group--packages__Templates.txt`.
