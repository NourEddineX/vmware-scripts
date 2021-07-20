#!/bin/bash

get_sdk_version() {
    repo_name=$1
    image_tag=$2
    sub_mod=$3
    commit_sha=$(echo $image_tag | cut -d"-" -f2)
    folder_name=$(echo $repo_name | cut -d"/" -f2)
    git clone https://github.com/$repo_name --recursive --branch main && pushd $folder_name && git checkout ${commit_sha}
    submodule_status=$(git submodule status)
    commit_msg=$(git log -1 --format=%s $sub_mod)
    sdk_version=$(echo $submodule_status | grep  "[0-9]*\.[0-9]*" -o || true)
    if [[ -z "$sdk_version" ]]; then
        sdk_version=$(echo $commit_msg | grep  "[0-9]*\.[0-9]*" -o || true)
    fi
    echo $sdk_version > /home/ubuntu/sdk_version.txt
    pushd $sub_mod
    last_updated_date=$(git log -1 --date iso --format=%cd libs/rebuild/linux/libglasswall.classic.so)
    echo $last_updated_date
    export last_updated_date=$(date -d"${last_updated_date}+30 days" "+%Y-%m-%d")
    echo $last_updated_date && popd
    echo "copied sdk version to file" && popd
    rm -rf $folder_name
}
