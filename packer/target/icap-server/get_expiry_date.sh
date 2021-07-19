#!/in/bash

get_expiry_date() {
    
    repo_name=$1
    image_tag=$2
    sub_mod=$3
    commit_sha=$(echo $image_tag | cut -d"-" -f2)
    folder_name=$(echo $repo_name | cut -d"/" -f2)
    if [[ "$sub_mod" = "lib" ]]; then
        git clone https://github.com/$repo_name --recursive --branch main && pushd $folder_name && git checkout $commit_sha
    else
        git clone https://github.com/$repo_name --recursive --branch main && pushd $folder_name && git checkout $commit_sha
    fi
    pushd $sub_mod
    last_updated_date=$(git log -1 --date iso --format=%cd libs/rebuild/linux/libglasswall.classic.so)
    echo $last_updated_date
    export last_updated_date=$(date -d"${last_updated_date}+30 days" "+%Y-%m-%d")
    echo $last_updated_date
    popd && popd && rm -rf $folder_name
}
