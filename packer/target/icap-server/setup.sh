#!/bin/bash
pushd $( dirname $0 )
if [ -f ./env ] ; then
source ./env
fi

# install wizard to setup network (for OVA)
if [ -f ./update_partition_size.sh ] ; then
chmod +x ./update_partition_size.sh
./update_partition_size.sh
fi

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
sudo docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD 


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
sudo snap install yq
requestImage=$(yq eval '.imagestore.requestprocessing.tag' adaptation/values.yaml)
sudo docker pull glasswallsolutions/icap-request-processing:$requestImage
sudo docker tag glasswallsolutions/icap-request-processing:$requestImage localhost:30500/icap-request-processing:$requestImage
sudo docker push localhost:30500/icap-request-processing:$requestImage


# Admin ui default credentials
sudo mkdir -p /var/local/rancher/host/c/userstore
sudo cp -r default-user/* /var/local/rancher/host/c/userstore/

# Create namespaces
kubectl create ns icap-adaptation
kubectl create ns management-ui
kubectl create ns icap-ncfs

kubectl create -n icap-adaptation secret docker-registry regcred \
	--docker-server=https://index.docker.io/v1/ \
	--docker-username="" \
	--docker-password="" \
	--docker-email=""

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
kubectl create -n icap-adaptation secret generic policyupdateservicesecret --from-literal=username=policy-management --from-literal=password='long-password'
kubectl create -n icap-adaptation secret generic transactionqueryservicesecret --from-literal=username=query-service --from-literal=password='long-password'
kubectl create -n icap-adaptation secret generic  rabbitmq-service-default-user --from-literal=username=guest --from-literal=password='guest'
helm upgrade adaptation --values custom-values.yaml --install . --namespace icap-adaptation  --set imagestore.requestprocessing.registry='localhost:30500/' \
--set imagestore.requestprocessing.repository='icap-request-processing'
sudo docker logout
popd

# Setup icap policy management
pushd ncfs
kubectl create -n icap-ncfs secret generic ncfspolicyupdateservicesecret --from-literal=username=policy-update --from-literal=password='long-password'
helm upgrade ncfs --values custom-values.yaml --install . --namespace icap-ncfs
popd

# setup management ui
kubectl create -n management-ui secret generic transactionqueryserviceref --from-literal=username=query-service --from-literal=password='long-password'
kubectl create -n management-ui secret generic policyupdateserviceref --from-literal=username=policy-management --from-literal=password='long-password'
kubectl create -n management-ui secret generic ncfspolicyupdateserviceref --from-literal=username=policy-update --from-literal=password='long-password'

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

# install cs-k8s-api
INSTALL_CSAPI=${INSTALL_CSAPI:-true}
CS_API_IMAGE=${CS_API_IMAGE:-glasswallsolutions/cs-k8s-api:latest}
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
INSTALL_FILEDROP_UI=${INSTALL_FILEDROP_UI:-true}
if [[ "${INSTALL_FILEDROP_UI}" == "true" ]]; then
	# install filedrop
	# get source code
	git clone https://github.com/k8-proxy/k8-rebuild.git --branch ck8s-filedrop --recursive && cd k8-rebuild && git submodule update --init --recursive && git submodule foreach git pull origin main && cd k8-rebuild-rest-api && git pull origin main && cd libs/ && git pull origin master && cd ../../
	# build images
	docker build k8-rebuild-file-drop/app -f k8-rebuild-file-drop/app/Dockerfile -t localhost:30500/k8-rebuild-file-drop
	docker push localhost:30500/k8-rebuild-file-drop
	rm -rf kubernetes/charts/sow-rest-api-0.1.0.tgz
	cat >> kubernetes/values.yaml <<EOF
sow-rest-ui:
image:
	registry: localhost:30500
	repository: k8-rebuild-file-drop
	imagePullPolicy: Never
	tag: latest
EOF
	# install helm charts
	helm upgrade --install k8-rebuild \
	--set nginx.service.type=ClusterIP \
	--atomic kubernetes/
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