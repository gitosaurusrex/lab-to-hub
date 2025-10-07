## Introduction
This repository contains two bash scripts that assist with the migration of git repositories from our GitLab instance to our organization's GitHub.

## Prerequisites
Before you can run these scripts there are a few things you need to set up, first.
1. Create a GitLab personal access token
2. Set up SSH access to CORP-GITHUB
3. Install and configure GitHub CLI
4. Create a GitHub personal access token
5. Install Python 3.12
6. Install jq dependency
7. Install git-filter-repo dependency by running `python -m pip install --user git-filter-repo`


## Scripts Overview
The files `01__generate-gitlab-lists.sh` and `02__clone-scrub-import-client-repos.sh` are bash scripts that can be executed from your git bash terminal. These scripts perform the work of pulling repositories out of GitLab, prepping them, and migrating the repos into GitHub.

## Script "01" Overview
### Usage
```
./01__generate-gitlab-lists.sh -t <gitlab-token> [ -g <gitlab-group-name> ]
```

### "01" Summary
This script makes a request to our GitLab instance's API for all groups marked as **internal**[^1]. The script then loops over the list of groups and queries for all unarchived repositories in that group. The script generates a text file for each group named `group--<gitlab-group-name>.txt` where each line represents an individual repository in that group[^2]. The following data is recorded for each repository:
* http url
* group name
* repository name
* repository id

This data is comma-separated and an empty line is intentionally left at the bottom of each file. The products of this script are generated into a directory named `_script-products`

### Tips
* It's strongly recommended that you put these scripts in a new directory as close to the root of your drive as possible because the migration process will involve cloning repositories to your drive and Windows doesn't like files with very, very long paths.

## Script "02" Overview
### Usage
```
./02__clone-scrub-import-client-repos.sh -t <gitlab-token> -f <path-to-repo-list.txt> [ -c <repo-topics> ] [ -x <path-to-exclusions-list.txt> ]
```

### "02" Summary
This script reads the provided group text file and performs the following for each repository in the list:
<details><summary>1. Checks GitHub for a repo by the same name.</summary>If none are found then we are good to proceed, otherwise we assume the repo has already been migrated or needs to be renamed.</details>
<details><summary>2. Clones the repo locally.</summary>If the repo already exists or if a non-empty directory with the same name exists at the target location, then we skip the current repo and move onto the next one in the list.</details>
<details><summary>3. Checks for the existence of a .gitmodules file.</summary>If .gitmodules exist, then the script works to unsubmodule any submodules found 1-level deep and .gitmodules is removed.</details>
<details><summary>4. Create a new GitHub repo using the name of the current GitLab repo.</summary>In addition, this new repo is marked as <strong>internal</strong> and access is assigned to the <strong>web-development</strong> team.</details>
<details><summary>5. A new remote named github is added to the local repo's config which points to the new GitHub repo.</summary>The unsubmodule work is added and committed locally before this step so we can migrate the new, submoduleless state of the repo to GitHub</details>
<details><summary>6. Loop through every branch in the local repository and push any unmerged branches to GitHub.</summary>Any work that was not already committed to a branch before migrating its repository would be lost if we didn't carry over these branches.</details>
<details><summary>7. Add a tag named MIGRATED_TO_GITHUB to the GitLab repo.</summary>The comment on this tag will be a timestamp. That way we know when a particualr repo was migrated.</details>
<details><summary>8. Archive the GitLab repo.</summary>Archived repositories do not appear in GitLab so it'll help serve as a clear indicator as to whether or not a particular repository has been migrated. Also, the repository will not get pulled in by script "01" should the script need to be executed, again, to produce a fresh list of unmigrated repos.</details>
<details><summary>9. Delete the local repo.</summary>If the script has successfully executed all of its instructions and reaches the end of the its tasks, the last thing it does is delete the cloned repo before moving onto the next one.</details>

### "02" Tips
* You can author your own input files as long as you follow the expected format. This means you can curate a list of GitLab repositories spanning multiple groups in a new text file and feed that into the script.
* If you want to add one or more topics to the repos you are processing in a given list then provide them using the -c option.
* You can provide a list of repositories to ignore by providing the filename to the -x option. This file follows the same format as the group input files.

[^1]: This request will also return groups marked as **public** because if there is even one repository in a public group that is marked as internal, then the group is returned. It seems when we query GitLab for all **internal** groups, it's more like asking GitLab to provide a list of all groups that contain at least one repo marked as internal.
[^2]: This script does not take into account that in addition to repositories, a group can contain subgroups and that subgroups in different parent groups can have the same name. This has the potential to lead to some wonkiness in terms of what repos appear in what list. Consider the following: a group named `templates` exists and within are a number of repos while another group named `Templates` exists as a subgroup of a parent group `packages`. The result is that the `group--templates.txt` file contains repositories from both `templates` and `Templates`. Regardless of this behavior the script still does its job of pulling every repo that satisfies its queries, even though it doesn't accurately reflect the organization of groups as they are structured in GitLab.




