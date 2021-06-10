#!/bin/bash
set -e

pushd $( dirname $0 )
if [ -f ./env ] ; then
source ./env
fi

cd ~/icap-infrastructure/adaptation
requestImage=$(yq eval '.imagestore.requestprocessing.tag' values.yaml)
requestRepo=$(yq eval '.imagestore.requestprocessing.repository' values.yaml)
sudo docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
sudo docker pull $requestRepo:$requestImage
sudo docker tag $requestRepo:$requestImage localhost:30500/icap-request-processing:$requestImage
sudo docker push localhost:30500/icap-request-processing:$requestImage
sudo docker logout
