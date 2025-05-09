#!/bin/bash
set -xe

# This gives remote_host, remote_pass and remote_user
source "$(dirname "$0")/hostdetails"


push_logs_to_server() {
    local run_id=$1
    local local_dir=$2
    if [[ -z "$run_id" || -z "$local_dir"  ]]; then
        echo "Usage: push_logs <run_id> <local_zip_dir>"
        return 1
    fi

    local zip_name="/tmp/${run_id}.zip"
    local remote_dir="/var/log/ci-dashboard/$run_id"

    echo "Zipping logs to $zip_name..."
    pushd $local_dir
    echo "in dir: `pwd`"
    zip -r "$zip_name" "."
    popd

    sshpass -p "$remote_pass" ssh  "${remote_user}@${remote_host}" "mkdir -p \"$remote_dir\""

    echo "Copying zip archive to $remote_host..."
    sshpass -p "$remote_pass" scp "$zip_name" "${remote_user}@${remote_host}:$remote_dir/"

    echo "Unzipping on remote..."
    sshpass -p "$remote_pass" ssh "${remote_user}@${remote_host}" "unzip -o $remote_dir/$(basename "$zip_name") -d $remote_dir && rm $remote_dir/$(basename "$zip_name")"

    echo "Cleaning up local zip..."
    rm "$zip_name"
}

upload_results() {
    local json_file=$1
    local url="http://$remote_host:3000/api/import-test-run"

    if [[ -z "$json_file" || ! -f "$json_file" ]]; then
        echo "Error: JSON file '$json_file' not found."
        return 1
    fi

    echo "Posting test run from $json_file to $url..."
    response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d @"$json_file")

    body=$(echo "$response" | sed '$d')
    status=$(echo "$response" | tail -n1)

    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        echo "Success: Server responded with status $status"
        # echo "$body"
	path=$(echo "$body" | jq -r '.url')
	run_url="http://$remote_host:3000/$path"
	echo "Dashboard URL of run: $run_url"
    else
        echo "Error: Server responded with status $status"
        echo "$body" >&2
        return 1
    fi
}

# push the logs to dashboard server
push_logs_to_server "$1" "$2"

# finally upload the results to the dashboard db
upload_results "$3"
