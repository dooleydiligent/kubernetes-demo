#!/bin/bash

[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

ID=$(id -u)
[[ "${ID}" -ne "0" ]] && echo "You must run this script as root" && exit 0

GROOVY=$(which groovy)
[ -z "${GROOVY}" ] && echo "You must have groovy installed for this step" && exit 0

. ./etc/kube.conf 

[ -f ./etc/kube.conf.local ] && . ./etc/kube.conf.local

#set -x

if [ -z "${BASE}" ]; then
  echo BASE is not set in ./kube.conf
  exit 0
fi

if [ -z "${DOMAIN}" ]; then
  echo DOMAIN is not set in ./kube.conf
  exit 0
fi

KEYTOOL=$(which keytool)
if [ -z "${KEYTOOL}" ]; then
  echo Could not locate keytool.  You must install a JDK to continue
  exit 0
fi
NSUPDATE=$(which nsupdate)
if [ -z "${NSUPDATE}" ]; then
  echo Could not locate nsupdate.  You must install BIND tools to continue
  exit 0
fi
# Stop the running service 
SVC=$(kubectl get service | grep 'nexus-repo')
if [ ! -z "${SVC}" ]; then
  kubectl delete service nexus-repo
  kubectl delete service docker-repo
  kubectl delete deployment nexus-repo
fi

# Reset nexus/docker base
if [ -d ${BASE}/nexus ]; then
echo "Removing nexus installation at ${BASE}/nexus"
rm -rf ${BASE}/nexus >/dev/null
fi
if [ -d /etc/docker/certs.d/docker-repo.k8s.${DOMAIN} ]; then
echo "Removing docker ssl certificates at /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}"
rm -rf /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}*
fi

echo "Recreating nexus installation"
mkdir -p ${BASE}/nexus >/dev/null
if [ ! -d "${BASE}/nexus" ]; then
  echo Could not create nexus folder in ${BASE}
  exit 0
fi

mkdir -p ${BASE}/nexus/etc/ssl

echo 'application-port-ssl=8443' > ./nexus.properties
echo 'nexus-args=${jetty.etc}/jetty.xml,${jetty.etc}/jetty-https.xml,${jetty.etc}/jetty-requestlog.xml' >> ./nexus.properties
echo 'ssl.etc=${karaf.data}/etc/ssl' >> ./nexus.properties
# Reenable script configuration
echo 'nexus.scripts.allowCreation=true' >> ./nexus.properties
mv ./nexus.properties ${BASE}/nexus/etc

if [ ! -f ${BASE}/nexus/etc/ssl/keystore.jks ]; then
echo "Regenerating nexus keystore"
keytool -genkeypair -keystore ./keystore.jks -storepass password -keypass password -alias jetty \
 -keyalg RSA -keysize 2048 -validity 5000 \
 -dname "CN=*.k8s.${DOMAIN}, OU=Sonatype, O=Sonatype, L=Unspecified, ST=Unspecified, C=US" \
 -ext "SAN=DNS:nexus-repo.k8s.${DOMAIN},DNS:docker-repo.k8s.${DOMAIN},DNS:k8s.${DOMAIN}" -ext "BC=ca:true"
mv keystore.jks ${BASE}/nexus/etc/ssl
fi
chown -R 200:200 ${BASE}/nexus

echo "Creating permanent storage on the master node"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nexus-store
  labels:
    type: local
spec:
  storageClassName: manual
  capacity:
    storage: 20Gi
  accessModes:
  - ReadWriteOnce
  hostPath:
    path: "${BASE}/nexus"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nexus-store
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-repo
  labels:
    app: nexus-repo
  annotations:
    external-dns.alpha.kubernetes.io/hostname: nexus-repo.k8s.${DOMAIN}
    external-dns.alpha.kubernetes.io/ttl: "300"
spec:
  type: LoadBalancer
  ports:
  - name: https
    protocol: TCP
    port: 443
    targetPort: 8443
  selector:
    app: nexus-repo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus-repo
  labels:
    app: nexus-repo
spec:
  selector:
    matchLabels:
      app: nexus-repo
  template:
    metadata:
      labels:
        app: nexus-repo
    spec:
      containers:
      - name: nexus-repo
        image: sonatype/nexus3:3.28.1
        ports:
        - containerPort: 443
        volumeMounts:
        - name: nexus-store
          mountPath: "/nexus-data"
      volumes:
      - name: nexus-store
        persistentVolumeClaim:
          claimName: nexus-store
EOF
# Expose nexus repo as a docker repo on a different name/ip
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: docker-repo
  labels:
    app: docker-repo
spec:
  type: LoadBalancer
  ports:
  - port: 443
    targetPort: 5000
    name: https
  - port: 4999
    targetPort: 4999
    name: docker
  selector:
    app: nexus-repo
EOF

kubectl get service | grep '\-repo'
echo "After nexus has booted the admin password will be at ${BASE}/nexus/admin.password"
echo "You must change the password the first time you log in"

# externaldns doesn't assign the ip to docker-repo so we'll  do that here
BINDIP=$(kubectl get services | grep bind-service | awk '{print $3}')
DOCKERIP=$(kubectl get service | grep 'docker-repo' | awk '{print $4}')
SECRET=$(kubectl get configmap rndc-key -o jsonpath='{@.data}' | sed 's/\\n//g' | sed 's/\\//g' | sed 's/"//g' | sed 's/;//g' | awk '{print $7}')
# Also having problem with nexus-repo
NEXUSIP=$(kubectl get service | grep 'nexus-repo' | awk '{print $4}')

echo "Using RNDC key with BIND: ${SECRET}"
echo "Adding a BIND entry for docker-repo.k8s.${DOMAIN}"
# Note we are using the POD IP for BIND instead of the public ip
cat <<EOF | nsupdate -L 0 -y externaldns:${SECRET} > /dev/null 2>&1 --
server ${BINDIP}
update delete docker-repo.k8s.${DOMAIN}. A
update delete nexus-repo.k8s.${DOMAIN}. A
update add docker-repo.k8s.${DOMAIN}. 300 A ${DOCKERIP}
update add nexus-repo.k8s.${DOMAIN}. 300 A ${NEXUSIP}
send
EOF
echo "Waiting for nexus to accept connections.  This will take a while"
WAITFOR=""
while [ -z "${WAITFOR}" ]
do
  WAITFOR=$(nc -zv -q -1 nexus-repo.k8s.${DOMAIN} 443 2>&1 | grep succeeded)
  if [ -z "${WAITFOR}" ]; then
    sleep 15
    echo -n .
  fi
done

# Wait for nexus to appear in bind
echo "Waiting for nexus to appear in BIND.  This should NOT take a long time."
WAITFOR=""
while [ -z "${WAITFOR}" ]
do
WAITFOR=$(nslookup nexus-repo.k8s.${DOMAIN} ${NSIP} | grep Name: | grep nexus-repo)
if [ -z "${WAITFOR}" ]; then
  sleep 15
  echo -n .
fi
done

echo "Provisioning nexus"
bin/provision-nexus.sh

# Make the local docker daemon respect the CA
echo "Adding a trusted certificate to /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}"
mkdir -p /etc/docker/certs.d/docker-repo.k8s.${DOMAIN} >> /dev/null
mkdir -p /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}:4999 >> /dev/null
VALIDCERT=$(keytool -printcert -sslserver docker-repo.k8s.${DOMAIN} -rfc | grep 'BEGIN CERTIFICATE')
while [ -z "${VALIDCERT}" ]
do
VALIDCERT=$(keytool -printcert -sslserver docker-repo.k8s.${DOMAIN} -rfc | grep 'BEGIN CERTIFICATE')
if [ -z "${VALIDCERT}" ]; then
  sleep 3
  echo -n .
fi
done
sudo keytool -printcert -sslserver docker-repo.k8s.${DOMAIN} -rfc > /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}/ca.crt
sudo keytool -printcert -sslserver docker-repo.k8s.${DOMAIN} -rfc > /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}:4999/ca.crt
PASSWORD=$(cat ${BASE}/nexus/admin.password)
#if [ ! -z "${RESTART_REQUIRED}" ]; then
# echo "Restarting the docker daemon in order to use the newly created SSL certificates."
# echo "This will take many minutes"
# systemctl restart docker
#fi
WAITFOR=""
while [ -z "${WAITFOR}" ]
do
  WAITFOR=$(nc -zv -q -1 nexus-repo.k8s.${DOMAIN} 443 2>&1 | grep succeeded)
  if [ -z "${WAITFOR}" ]; then
    sleep 15
    echo -n .
  fi
done

echo "Logging into nexus docker repo using password: ${PASSWORD}"
echo ${PASSWORD} | docker login --username admin --password-stdin docker-repo.k8s.${DOMAIN}
echo "Pulling image"

docker pull docker-repo.k8s.${DOMAIN}/mhart/alpine-node:latest

# Now for giggles we will create a node application and deploy it as a docker image into kubernetes.cluster
echo "Building a Dockerfile"
echo quit | openssl s_client -showcerts -servername nexus-repo.k8s.kubernetes.cluster -connect nexus-repo.k8s.kubernetes.cluster:443 > ./nexus-cacert.pem
cat <<EOF | docker build . -t docker-repo.k8s.${DOMAIN}:4999/hello-world:1.0 -f -
FROM docker-repo.k8s.${DOMAIN}/mhart/alpine-node
WORKDIR /app
ENV NODE_EXTRA_CA_CERTS="/app/nexus-cacert.pem"
ADD nexus-cacert.pem /app/nexus-cacert.pem
ADD index.js /app/index.js
RUN cat /etc/resolv.conf
RUN npm init -y && \
  npm config set ca="" && \
  npm config set registry=https://nexus-repo.k8s.${DOMAIN}/repository/npm && \
  npm config set strict-ssl false && \
  npm install --save express -y
CMD ["node", "./index.js"]
EOF
echo "Current Password: ${PASSWORD}"
echo "Pushing the image to the local docker-repo.k8s.${DOMAIN}:4999 registry"

docker push docker-repo.k8s.${DOMAIN}:4999/hello-world:1.0

echo "Deploying the application"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
        - name: hello-world
          image: docker-repo.k8s.${DOMAIN}:4999/hello-world:1.0
          ports:
          - name: http
            containerPort: 3000
---

kind: Service
apiVersion: v1
metadata:
  name: hello-world
  labels:
    app: hello-world
spec:
  type: LoadBalancer
  selector:
    app: hello-world
  ports:
  - name: http
    port: 3000
    targetPort: 3000
EOF
echo "You can now access the application at http://hello-world.k8s.${DOMAIN}:3000 or the ip below"
kubectl get service | grep hello-world
