#!/bin/bash

migration_logger() {
    local last_action=$1
    local group_name=$2
    local project_name=$3
    local exit_code=$4
    local log_file_location=$5
    local return_as_boolean=${6:-false}
    local log_message=""
    local echo_reset_color='\033[0m'

    if [ $exit_code -eq 0 ]; then
        if [[ "$return_as_boolean" == true ]]; then
            local echo_color='\033[0;34m'
            log_message="$(date "+[%d-%b-%Y %H:%M:%S]")[group: $group_name][repo: $project_name] -- TRUE -- $last_action"
        else
            local echo_color='\033[0;32m'
            log_message="$(date "+[%d-%b-%Y %H:%M:%S]")[group: $group_name][repo: $project_name] -- SUCCESSFULL -- $last_action"
        fi
    else
        if [[ "$return_as_boolean" == true ]]; then
            local echo_color='\033[0;34m'
            log_message="$(date "+[%d-%b-%Y %H:%M:%S]")[group: $group_name][repo: $project_name] -- FALSE -- $last_action"
        else
            local echo_color='\033[0;31m'
            log_message="$(date "+[%d-%b-%Y %H:%M:%S]")[group: $group_name][repo: $project_name] -- FAILED -- $last_action"
        fi
    fi

    echo -e "${echo_color}$log_message${echo_reset_color}"
    echo "$log_message" >> "$log_file_location"
}

usage() {
  echo "Usage: $0 -t <your-gitlab-access-token> -f <path-to-input-textfile> [ -c <comma-separated-repo-topics> ] [ -x <path-to-exclusions-textfile> ]"
  exit 1
}

while getopts ":t:f:c:x:" opt; do
    case $opt in
        t) gl_token="$OPTARG";;
        f) group_file="$OPTARG";;
        c) repo_topics="$OPTARG";;
        x) exclusions_file="$OPTARG";;
        \?) echo "Invalid option: -$OPTARG" >&2; usage;;
        :) echo "Option -$OPTARG is required." >&2; usage;;
    esac
done
if [ -z "$gl_token" ] || [ -z "$group_file" ]; then
  echo "Both -t and -f options are required."
  usage
fi

script_name=$(basename "$0" .sh)
main_output_dir="_script-products"
output_dir="$main_output_dir/$script_name"
logfile="_log.txt"
github_repo_target="CORP-GITHUB"

mkdir -p $main_output_dir
mkdir -p $output_dir

if [ ! -e "$group_file" ]; then
    echo "Error: Input file $group_file not found."
    exit 1
fi

if [ -n "$exclusions_file" ] && [ ! -f "$exclusions_file" ]; then
  echo "Exclusions file not found: $exclusions_file"
  exit 1
fi

echo -e "\n$(date "+[%d-%b-%Y %H:%M:%S]")[executing: $script_name]" >> "$logfile"
echo -e "                      [input file: $(realpath "$group_file")]" >> "$logfile"
echo -e "                      [input file line count: $(grep -c -v '^$' "$group_file")]" >> "$logfile"
if [ -f "$exclusions_file" ]; then
echo -e "                      [exclusions file: $(realpath "$exclusions_file")]" >> "$logfile"
echo -e "                      [exclusions file line count: $(grep -c -v '^$' "$exclusions_file")]" >> "$logfile"
fi

echo "" >> _failed.txt
echo "" >> _done.txt

while IFS=, read -r http_url group_name project_name project_id; do

    if [ -n "$exclusions_file" ]; then
        exclude_this_repo=false
        while IFS= read -r exclusion; do
          exclusion=$(echo "$exclusion" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ "$http_url" == *"$exclusion"* ]]; then
                exclude_this_repo=true
                break
            fi
        done < "$exclusions_file"
        if [ "$exclude_this_repo" = true ]; then
            migration_logger "exclude repo" "$group_name" "$project_name" 0 "$logfile" true
            echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
            continue
        else
            migration_logger "exclude repo" "$group_name" "$project_name" 1 "$logfile" true
        fi
    fi

    http_url=$(echo "$http_url" | awk '{$1=$1};1')
    group_name=$(echo "$group_name" | awk '{$1=$1};1')
    project_name=$(echo "$project_name" | awk '{$1=$1};1')
    project_id=$(echo "$project_id" | awk '{$1=$1};1')

        tree_endpoint="http://GITLAB-HOSTNAME/api/v4/projects/$project_id/repository/tree"
        tree_response=$(curl -s --header "PRIVATE-TOKEN: $gl_token" "$tree_endpoint")
        if [ -z "$tree_response" ] || [ "$tree_response" = "{\"message\":\"404 Tree Not Found\"}" ]; then
            migration_logger "nonempty gitlab repo check" "$group_name" "$project_name" 1 "$logfile"
            echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
            continue
        else
            migration_logger "nonempty gitlab repo check" "$group_name" "$project_name" 0 "$logfile"
            target_project_name="$project_name"
        fi


    git clone --recursive "$http_url" "$output_dir/$group_name/$project_name"
    exit_code=$?
    migration_logger "cloning gitlab repo locally" "$group_name" "$project_name" $exit_code "$logfile"
    if [ $exit_code -ne 0 ]; then
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    cd "$output_dir/$group_name/$project_name" || exit 1
    git fetch --all

    git-filter-repo --strip-blobs-bigger-than 90M --force
    exit_code=$?
    migration_logger "pruning 90+MB files from history" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -ne 0 ]; then
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    count=0
    found_in_current_dir=false

    while IFS= read -r -d '' gitmodules_file; do
        ((count++))
        if [[ "$(dirname "$gitmodules_file")" == "$(pwd)" ]]; then
            found_in_current_dir=true
        fi
    done < <(find "$(pwd)" -name ".gitmodules" -type f -print0)

    echo "Number of occurrences of .gitmodules: $count"

    if $found_in_current_dir && [ $count -eq 1 ]; then
        migration_logger "repo has submodules that we can unsubmodule" "$group_name" "$project_name" 0 "../../../../$logfile" true
    elif [ $count -eq 0 ]; then
        do_nothing=true
    else
        migration_logger "repo has submodules that we can unsubmodule" "$group_name" "$project_name" 1 "../../../../$logfile" true
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _has_modules.txt
        continue
    fi

    if [ -f .gitmodules ]; then
        while IFS= read -r line; do
            if [[ $line =~ "path" ]]; then
                submodule_path=$(echo "$line" | sed 's/.*= //')
                echo "Processing submodule: $(basename $submodule_path)"
                echo "Removing section from .git/config file"
                git config --remove-section submodule."$submodule_path"
                echo "Removing submodule files from the git index but keeping files"
                git rm --cached $submodule_path
                echo "Removing reference in .git/modules"
                rm -rf .git/modules/"$submodule_path"
                echo "Removing .git folder"
                rm -rf "$submodule_path"/.git
            fi
        done < .gitmodules
        rm .gitmodules
        git add .gitmodules
    fi

    if [ -d "data" ]; then
        echo "data folder found... cleaning it up"
        cd "data" || exit
        find . -type f -name '*.sql' ! -name 'github.sql' -exec rm -f {} +
        cd - || exit
    fi

    if [ -d "plugins" ]; then
        migration_logger "checking if WordPress" "$group_name" "$project_name" 0 "../../../../$logfile" true
        if [ -d "$HOME/actions" ]; then
          echo "webdev-actions found... executing git pull"
          git --git-dir="$HOME/actions/.git" --work-tree="$HOME/actions" pull
        else
          echo "actions not found... executing git clone"
          git clone https://github.com/CORP-GITHUB/actions.git ~/actions
        fi
        cp -R "$HOME/actions/copy-for-website-repos/.github" .
        exit_code=$?
        migration_logger "copying webdev-actions files" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    else
        migration_logger "checking if WordPress" "$group_name" "$project_name" 1 "../../../../$logfile" true
    fi


    gh repo create "$github_repo_target/$target_project_name" --internal -t web-development
    exit_code=$?
    migration_logger "creating repo in GitHub and adding webdev access" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -ne 0 ]; then
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    aspx_files=$(find . -maxdepth 1 -type f -name "*.aspx")
    if [ -n "$aspx_files" ]; then
        gh repo edit "$github_repo_target/$target_project_name" --add-topic "legacy-framework"
        exit_code=$?
        migration_logger "adding topic legacy-framework" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    fi

    if [ -n "$repo_topics" ]; then
        gh repo edit "$github_repo_target/$target_project_name" --add-topic "$repo_topics"
        exit_code=$?
        migration_logger "adding topic(s) $repo_topics" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    fi

    gh api -X PUT "orgs/$github_repo_target/teams/web-development/repos/$github_repo_target/$project_name" -f permission="admin" --silent
    exit_code=$?
    migration_logger "changing webdev access to admin" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -ne 0 ]; then
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    git remote add github https://github.com/"$github_repo_target"/"$target_project_name".git
    exit_code=$?
    migration_logger "adding github remote to repository" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -ne 0 ]; then
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    echo "" >> .gitignore
    git add --all
    exit_code=$?
    migration_logger "git adding all for final product" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -ne 0 ]; then
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    git commit -m "Pre-GitHub Mirroring Commit"
    exit_code=$?
    migration_logger "git committing final product" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -ne 0 ]; then
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    git push --force --mirror github
    exit_code=$?
    migration_logger "mirroring repo to github" "$group_name" "$project_name" $exit_code "../../../../$logfile"
    if [ $exit_code -eq 0 ]; then
        echo "$http_url,$group_name,$project_name,$project_id" >> ../../../../_done.txt
    else
        cd ../../../../
        echo "$http_url,$group_name,$project_name,$project_id" >> _failed.txt
        continue
    fi

    archive_endpoint="http://GITLAB-HOSTNAME/api/v4/projects/$project_id/archive"
    archive_response=$(curl -s --request POST --header "PRIVATE-TOKEN: $gl_token" "$archive_endpoint" | jq -c '.')
    exit_code=$?
    migration_logger "post-migration: archiving repo in GitLab" "$group_name" "$project_name" $exit_code "../../../../$logfile"

    cd ../../../../
    rm -rf "$output_dir/$group_name/$project_name"
    migration_logger "post-migration: cleaning up local repo" "$group_name" "$project_name" 0 "$logfile"

done < "$group_file"
echo "$(date "+[%d-%b-%Y %H:%M:%S]") $group_file processed. EOL" | tee -a $logfile