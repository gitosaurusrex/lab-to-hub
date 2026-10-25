#!/bin/bash
#
# Writes one list file per GitLab group. Each line describes an unarchived
# repository in that group: http_url,group_name,repo_name,repo_id

set -uo pipefail

gitlab_url="${GITLAB_URL:-https://GITLAB-HOSTNAME}"
main_output_dir="_script-products"
output_dir="$main_output_dir/01__generate-gitlab-lists"
per_page=100

usage() {
  echo "Usage: $0 [ -t <your-gitlab-access-token> ] [ -g <gitlab-group-name-or-full-path> ]"
  echo "The token can also be provided through the GITLAB_TOKEN environment variable."
  exit 1
}

gl_token="${GITLAB_TOKEN:-}"
gl_group=""
while getopts ":t:g:" opt; do
    case $opt in
        t) gl_token="$OPTARG";;
        g) gl_group="$OPTARG";;
        \?) echo "Invalid option: -$OPTARG" >&2; usage;;
        :) echo "Option -$OPTARG requires a value." >&2; usage;;
    esac
done
if [ -z "$gl_token" ]; then
    echo "A GitLab token is required (-t or GITLAB_TOKEN) whereas -g is optional."
    usage
fi

# Prints every item of a paginated GitLab API collection, one JSON object per
# line. Fails when a page can't be fetched or isn't a JSON array, rather than
# requesting further pages forever.
gitlab_get_all() {
    local endpoint=$1 query=$2 page=1 response
    while :; do
        response=$(printf 'header = "PRIVATE-TOKEN: %s"\n' "$gl_token" |
            curl -sSf --config - "$gitlab_url/api/v4/$endpoint?${query:+$query&}per_page=$per_page&page=$page") || return 1
        jq -e 'type == "array"' <<< "$response" > /dev/null || return 1
        [ "$(jq 'length' <<< "$response")" -eq 0 ] && return 0
        jq -c '.[]' <<< "$response"
        page=$((page + 1))
    done
}

echo "Requesting group data from GitLab"
if ! groups=$(gitlab_get_all "groups" ""); then
    echo "Error: Unable to retrieve groups from GitLab." >&2
    exit 1
fi

mkdir -p "$main_output_dir"
rm -rf "$output_dir"
mkdir "$output_dir"

exit_status=0
while IFS=$'\t' read -r group_id group_name group_path; do
    if [ -n "$gl_group" ] && [ "$gl_group" != "$group_name" ] && [ "$gl_group" != "$group_path" ]; then
        continue
    fi

    # Named after the full path so that subgroups sharing a name with another
    # group (e.g. templates and packages/Templates) get separate files.
    output_file="$output_dir/group--${group_path//\//__}.txt"
    echo "Requesting all repos from group: $group_path"
    if ! repos=$(gitlab_get_all "groups/$group_id/projects" "order_by=last_activity_at&sort=asc&archived=false"); then
        echo "Error: Unable to retrieve the repos of group $group_path." >&2
        exit_status=1
        continue
    fi
    jq -r '"\(.http_url_to_repo),\(.namespace.name),\(.name),\(.id)"' <<< "$repos" > "$output_file"
done < <(jq -r '[.id, .name, .full_path] | @tsv' <<< "$groups")

echo "Done"
exit "$exit_status"
