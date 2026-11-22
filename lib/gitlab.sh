# shellcheck shell=bash
# shellcheck disable=SC2154 # gitlab_url and gl_token are set by the scripts
#
# GitLab API functions shared by both scripts, which source this file. They
# use the scripts' gitlab_url and gl_token variables.

# Sends one request to the GitLab API and prints the response, failing on an
# HTTP error. The token goes to curl on stdin, not as an argument, so that it
# doesn't show up in the process list.
gitlab_api() {
    local method=$1 endpoint=$2
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$gl_token" |
        curl -sSf --config - --request "$method" "$gitlab_url/api/v4/$endpoint"
}

# Prints every item of a paginated GitLab API collection, one JSON object per
# line. Fails when a page can't be fetched or isn't a JSON array, rather than
# requesting further pages forever.
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
