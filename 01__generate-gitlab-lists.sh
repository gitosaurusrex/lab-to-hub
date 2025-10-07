#!/bin/bash

main_output_dir="_script-products"
output_dir="$main_output_dir/01__generate-gitlab-lists"

usage() {
  echo "Usage: $0 -t <your-gitlab-access-token> [ -g <gitlab-group-name> ]"
  exit 1
}

while getopts ":t:g:" opt; do
    case $opt in
        t) gl_token="$OPTARG";;
        g) gl_group="$OPTARG";;
        \?) echo "Invalid option: -$OPTARG" >&2; usage;;
        :) echo "Option -$OPTARG is required." >&2; usage;;
    esac
done
if [ -z "$gl_token" ]; then
    echo "-t is required whereas -g is optional."
    usage
fi

mkdir -p $main_output_dir
rm -rf "$output_dir"
mkdir $output_dir

echo "Requesting group data from GitLab"
groups_endpoint="http://GITLAB-HOSTNAME/api/v4/groups"
group_response=$(curl -s --header "PRIVATE-TOKEN: $gl_token" "$groups_endpoint" | jq -c '.')

if [ $? -eq 0 ]; then
    group_ids=$(echo "$group_response" | jq -r '.[].id')
    for group_id in $group_ids; do
        group_id=$(echo "$group_id" | jq -c '.')
        group_name=$(echo "$group_response" | jq -r --arg group_id "$group_id" '.[] | select(.id == ($group_id|tonumber)) | .name')

        if [ -z "$gl_group" ] || [ "$gl_group" == "$group_name" ]; then
            output_file="$output_dir/group--$group_name.txt"
            touch "$output_file"

            page=1
            per_page=100
            repo_response=""
            echo ""
            echo -n "Requesting all repos from group: $group_name"
            until [ "$repo_response" = "[]" ]; do
                echo -n "."
                repos_endpoint="http://GITLAB-HOSTNAME/api/v4/groups/$group_id/projects??order_by=last_activity_at&sort=asc&archived=false&per_page=$per_page&page=$page"
                repo_response=$(curl -s --header "PRIVATE-TOKEN: $gl_token" "$repos_endpoint" | jq -c '.')
                echo "$repo_response" | jq -r '.[] | "\(.http_url_to_repo),\(.namespace.name),\(.name),\(.id)"' >> "$output_file"
                ((page++))
            done
        fi
    done
    echo "Done"
else
    echo "Error: Unable to retrieve public groups from GitLab."

fi
