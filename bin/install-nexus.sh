#!/bin/bash

[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

ID=$(id -u)
[[ "${ID}" -ne "0" ]] && echo "You must run this script as root" && exit 0

GROOVY=$(which groovy)
[ -z "${GROOVY}" ] && echo "You must have groovy installed for this step" && exit 0

. ./etc/kube.conf 

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
echo "Recreating nexus installation"
mkdir -p ${BASE}/nexus >/dev/null
if [ ! -d "${BASE}/nexus" ]; then
  echo Could not create nexus folder in ${BASE}
  exit 0
fi

mkdir -p ${BASE}/secrets >/dev/null
if [ ! -d "${BASE}/secrets" ]; then
  echo Could not create secrets folder in ${BASE}
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
keytool -genkeypair -keystore ./keystore.jks -storepass password -alias ${DOMAIN} \
 -keyalg RSA -keysize 2048 -validity 5000 -keypass password \
 -dname "CN=*.k8s.${DOMAIN}, OU=Sonatype, O=Sonatype, L=Unspecified, ST=Unspecified, C=US" \
 -ext "SAN=DNS:nexus-repo.k8s.${DOMAIN},DNS:docker-repo.k8s.${DOMAIN}"
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
  - port: 5000
    targetPort: 5000
    name: https
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

echo "Using RNDC key with BIND: ${SECRET}"
echo "Adding a BIND entry for docker-repo.k8s.${DOMAIN}"

cat <<EOF | nsupdate -L 0 -y externaldns:${SECRET} > /dev/null 2>&1 --
server ${BINDIP}
update add docker-repo.k8s.${DOMAIN} 300 A ${DOCKERIP}
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

# Make the local docker daemon respect the CA
echo "Adding a trusted certificate to /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}"
mkdir -p /etc/docker/certs.d/docker-repo.k8s.${DOMAIN} >> /dev/null
keytool -printcert -sslserver ${DOCKERIP}:443 -rfc >/etc/docker/certs.d/docker-repo.k8s.${DOMAIN}/ca.crt
# NOTE: the docker daemon must now be restarted for this to work
echo "Provisioning nexus"
bin/provision-nexus.sh
PASSWORD=$(cat ${BASE}/nexus/admin.password)
echo "Logging into nexus docker repo using password: ${PASSWORD}"
echo ${PASSWORD} | docker login --username admin --password-stdin docker-repo.k8s.${DOMAIN}

# Now for giggles we will create a node application and deploy it as a docker image into kubernetes.cluster
echo "Building a Dockerfile"

cat <<EOF | docker build . -t docker-repo.k8s.${DOMAIN}/hello-world:1.0 -f -
FROM docker-repo.k8s.${DOMAIN}/mhart/alpine-node
WORKDIR /app

ADD . /app/
RUN npm init -y
RUN echo "Consulting nexus-repo.k8s.${DOMAIN} for npm install ..."
RUN npm install -y --registry=nexus-repo.k8s.${DOMAIN}/npm --save express
RUN cat <<EOF >index.js \
 const express = require('express'); \
 const app = express(); \
 const port = 3000; \
 \
 app.get('/', (req, res) => { \
   res.send('Hello World!'); \
 }); \
 \
 app.listen(port, () => { \
   console.log(\`Example app listening at http://localhost:${port}\`); \
 }); \
 EOF
CMD ["node", "./index.js"]
EOF

echo "Pushing the image to the local docker-repo.k8s.${DOMAIN} registry"

docker push docker-repo.k8s.${DOMAIN}/hello-world:1.0

echo "Deploying the application"
cat <<EOF | kubectl -f -
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
          image: docker-repo.k8s.${DOMAIN}/hello-world:1.0
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
echo "You can now access the application at the IP address below"
kubectl get service | grep hello-world
