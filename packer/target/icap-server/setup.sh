#!/bin/bash
set -e
pushd $( dirname $0 )
if [ -f ./env ] ; then
source ./env
fi

ICAP_FLAVOUR=${ICAP_FLAVOUR:-classic}

# Integrate Instance based healthcheck
# pwd
# sudo apt update -y
# sudo apt install c-icap -y
# cp -r healthcheck ~
# chmod +x ~/healthcheck/healthcheck.sh
# sudo apt install python3-pip -y
# export PATH=$PATH:$HOME/.local/bin
# pip3 install fastapi
# pip3 install uvicorn
# pip3 install uvloop
# pip3 install httptools
# pip3 install requests
# pip3 install aiofiles
# sudo apt install gunicorn -y
# sudo mv ~/healthcheck/gunicorn.service /etc/systemd/system/
# sudo systemctl start gunicorn
# sudo systemctl enable gunicorn
# crontab -l 2>/dev/null | { cat; echo "* * * * *  flock -n /home/ubuntu/healthcheck/status.lock /home/ubuntu/healthcheck/healthcheck.sh 2>> /home/ubuntu/healthcheck/cronstatus.log"; } | crontab -

sudo apt-get install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install docker-ce docker-ce-cli containerd.io -y

# install local docker registry
sudo docker run -d -p 127.0.0.1:30500:5000 --restart always --name registry registry:2

# install k3s
curl -sfL https://get.k3s.io | sh -
mkdir ~/.kube && sudo install -T /etc/rancher/k3s/k3s.yaml ~/.kube/config -m 600 -o $USER

# install kubectl and helm
curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
echo "Done installing kubectl"

curl -sfL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
echo "Done installing helm"

# get source code, we clone in in home dir so we can easilly update in place
cd ~
ICAP_BRANCH=${ICAP_BRANCH:-k8-develop}
git clone https://github.com/k8-proxy/icap-infrastructure.git -b $ICAP_BRANCH && cd icap-infrastructure

# Clone ICAP SOW Version 
ICAP_SOW_BRANCH=${ICAP_SOW_BRANCH:-main}
git clone https://github.com/filetrust/icap-infrastructure.git -b $ICAP_SOW_BRANCH /tmp/icap-infrastructure-sow
cp  /tmp/icap-infrastructure-sow/adaptation/values.yaml adaptation/
cp  /tmp/icap-infrastructure-sow/administration/values.yaml administration/
cp  /tmp/icap-infrastructure-sow/ncfs/values.yaml ncfs/

# Create namespaces
kubectl create ns icap-adaptation

# Setup rabbitMQ
pushd rabbitmq && helm upgrade rabbitmq --install . --namespace icap-adaptation && popd

# Setup icap-server
cat >> openssl.cnf <<EOF
[ req ]
prompt = no
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C = GB
ST = London
L = London
O = Glasswall
OU = IT
CN = icap-server
emailAddress = admin@glasswall.com
EOF

openssl req -newkey rsa:2048 -config openssl.cnf -nodes -keyout  /tmp/tls.key -x509 -days 365 -out /tmp/certificate.crt
kubectl create secret tls icap-service-tls-config --namespace icap-adaptation --key /tmp/tls.key --cert /tmp/certificate.crt

pushd adaptation
kubectl create -n icap-adaptation secret generic policyupdateservicesecret --from-literal=username=policy-management --from-literal=password=$TRANSACTIONS_SECRET
kubectl create -n icap-adaptation secret generic transactionqueryservicesecret --from-literal=username=query-service --from-literal=password=$TRANSACTIONS_SECRET
kubectl create -n icap-adaptation secret generic  rabbitmq-service-default-user --from-literal=username=guest --from-literal=password=$RABBIT_SECRET

if [[ "$ICAP_FLAVOUR" == "classic" ]]; then
	requestImage=$(yq eval '.imagestore.requestprocessing.tag' values.yaml)
	sudo docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
	sudo docker pull glasswallsolutions/icap-request-processing:$requestImage
	sudo docker tag glasswallsolutions/icap-request-processing:$requestImage localhost:30500/icap-request-processing:$requestImage
	sudo docker push localhost:30500/icap-request-processing:$requestImage
	helm upgrade adaptation --values custom-values.yaml --install . --namespace icap-adaptation  --set imagestore.requestprocessing.registry='localhost:30500/' \
	--set imagestore.requestprocessing.repository='icap-request-processing'
	sudo docker logout
	popd
fi

if [[ "$ICAP_FLAVOUR" == "golang" ]]; then
	helm upgrade adaptation --values custom-values.yaml --install . --namespace icap-adaptation
	popd
	# Install minio
	kubectl create ns minio
	helm repo add minio https://helm.min.io/
	helm install -n minio --set accessKey=minio,secretKey=$MINIO_SECRET,buckets[0].name=sourcefiles,buckets[0].policy=none,buckets[0].purge=false,buckets[1].name=cleanfiles,buckets[1].policy=none,buckets[1].purge=false,fullnameOverride=minio-server,persistence.enabled=false minio/minio --generate-name
	kubectl create -n icap-adaptation secret generic minio-credentials --from-literal=username='minio' --from-literal=password=$MINIO_SECRET

	# deploy new Go services
	git clone https://github.com/k8-proxy/go-k8s-infra.git -b develop && pushd go-k8s-infra

	# Scale the existing adaptation service to 0
	kubectl -n icap-adaptation scale --replicas=0 deployment/adaptation-service

	# Apply helm chart to create the services
	helm upgrade servicesv2 --install services --namespace icap-adaptation
	popd
fi

if [[ "${INSTALL_M_UI}" == "true" ]]; then
	# Admin ui credentials
	sudo mkdir -p /var/local/rancher/host/c/userstore
	sudo cp -r default-user/* /var/local/rancher/host/c/userstore/
	# create namespaces
	kubectl create ns management-ui
	kubectl create ns icap-ncfs
	# Setup icap policy management
	pushd ncfs
	kubectl create -n icap-ncfs secret generic ncfspolicyupdateservicesecret --from-literal=username=policy-update --from-literal=password=$TRANSACTIONS_SECRET
	helm upgrade ncfs --values custom-values.yaml --install . --namespace icap-ncfs
	popd

	# setup management ui
	kubectl create -n management-ui secret generic transactionqueryserviceref --from-literal=username=query-service --from-literal=password=$TRANSACTIONS_SECRET
	kubectl create -n management-ui secret generic policyupdateserviceref --from-literal=username=policy-management --from-literal=password=$TRANSACTIONS_SECRET
	kubectl create -n management-ui secret generic ncfspolicyupdateserviceref --from-literal=username=policy-update --from-literal=password=$TRANSACTIONS_SECRET

	pushd administration
	helm upgrade administration --values custom-values.yaml --install . --namespace management-ui
	popd

	kubectl delete secret/smtpsecret -n management-ui
	kubectl create -n management-ui secret generic smtpsecret \
		--from-literal=SmtpHost=$SMTPHOST \
		--from-literal=SmtpPort=$SMTPPORT \
		--from-literal=SmtpUser=$SMTPUSER \
		--from-literal=SmtpPass=$SMTPPASS \
		--from-literal=TokenSecret='12345678901234567890123456789012' \
		--from-literal=TokenLifetime='00:01:00' \
		--from-literal=EncryptionSecret='12345678901234567890123456789012' \
		--from-literal=ManagementUIEndpoint='http://management-ui:8080' \
		--from-literal=SmtpSecureSocketOptions='http://management-ui:8080'

	cd ..
fi

INSTALL_CSAPI=${INSTALL_CSAPI:-"true"}
INSTALL_FILEDROP_UI=${INSTALL_FILEDROP_UI:-"true"}
CS_API_IMAGE=${CS_API_IMAGE:-glasswallsolutions/cs-k8s-api:latest}
# install cs-k8s-api
if [[ "${INSTALL_CSAPI}" == "true" ]]; then
	wget https://raw.githubusercontent.com/k8-proxy/cs-k8s-api/main/deployment.yaml
	sudo docker pull $CS_API_IMAGE
	CS_IMAGE_VERSION=$(echo $CS_API_IMAGE | cut -d":" -f2)
	sudo docker tag $CS_API_IMAGE localhost:30500/cs-k8s-api:$CS_IMAGE_VERSION
	sudo docker push localhost:30500/cs-k8s-api:$CS_IMAGE_VERSION
	sed -i 's|glasswallsolutions/cs-k8s-api:.*|localhost:30500/cs-k8s-api:'$CS_IMAGE_VERSION'|' deployment.yaml
	kubectl apply -f deployment.yaml -n icap-adaptation
fi

# install filedrop UI
if [[ "${INSTALL_FILEDROP_UI}" == "true" ]]; then
	git clone https://github.com/k8-proxy/k8-rebuild.git && pushd k8-rebuild
	# build images
	ui_tag=$(yq eval '.sow-rest-ui.image.tag' kubernetes/values.yaml)
	ui_registry=$(yq eval '.sow-rest-ui.image.registry' kubernetes/values.yaml)
	ui_repo=$(yq eval '.sow-rest-ui.image.repository' kubernetes/values.yaml)
	sudo docker pull $ui_registry/$ui_repo:$ui_tag
	sudo docker tag $ui_registry/$ui_repo:$ui_tag localhost:30500/k8-rebuild-file-drop:$ui_tag
	sudo docker push localhost:30500/k8-rebuild-file-drop:$ui_tag
	rm -rf kubernetes/charts/sow-rest-api-0.1.0.tgz
	sed -i 's/sow-rest-api/proxy-rest-api.icap-adaptation.svc.cluster.local:8080/g' kubernetes/values.yaml
	# install helm charts
	helm upgrade --install k8-rebuild --set nginx.service.type=ClusterIP \
	--set sow-rest-ui.image.registry=localhost:30500 \
	--atomic kubernetes/
	popd
fi

# allow password login (useful when deployed to esxi)
SSH_PASSWORD=${SSH_PASSWORD:-glasswall}
printf "${SSH_PASSWORD}\n${SSH_PASSWORD}" | sudo passwd ubuntu
sudo sed -i "s/.*PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
sudo service ssh restart

# install vmware-guestinfo when generating OVA
CREATE_OVA=${CREATE_OVA:-false}
if [[ "$CREATE_OVA" == "true" ]]; then
	echo $CREATE_OVA
	curl -sSL https://raw.githubusercontent.com/vmware/cloud-init-vmware-guestinfo/master/install.sh | sudo sh -
fi
