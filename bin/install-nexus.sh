#!/bin/bash

[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

. ./etc/kube.conf

#set -x

sudo mkdir -p ${BASE}/nexus >/dev/null
if [ ! -d "${BASE}/nexus" ]; then
  echo Could not create nexus folder in ${BASE}
  exit 0
fi

sudo mkdir -p ${BASE}/secrets >/dev/null
if [ ! -d "${BASE}/secrets" ]; then
  echo Could not create secrets folder in ${BASE}
  exit 0
fi

KEYTOOL=$(which keytool)
if [ -z "${KEYTOOL}" ]; then
  echo Could not locate keytool.  You must install a JDK to continue
  exit 0
fi
# Stop the running service 
SVC=$(kubectl get service | grep 'nexus-repo')
if [ ! -z "${SVC}" ]; then
  kubectl delete service nexus-repo
  kubectl delete service docker-repo
  kubectl delete deployment nexus-repo
fi
sudo mkdir -p ${BASE}/nexus/etc/ssl

sudo echo 'application-port-ssl=8443' > ./nexus.properties
sudo echo 'nexus-args=${jetty.etc}/jetty.xml,${jetty.etc}/jetty-https.xml,${jetty.etc}/jetty-requestlog.xml' >> ./nexus.properties
sudo echo 'ssl.etc=${karaf.data}/etc/ssl' >> ./nexus.properties
sudo mv ./nexus.properties ${BASE}/nexus/etc

if [ ! -f ${BASE}/nexus/etc/ssl/keystore.jks ]; then
keytool -genkeypair -keystore ./keystore.jks -storepass password -alias ${DOMAIN} \
 -keyalg RSA -keysize 2048 -validity 5000 -keypass password \
 -dname "CN=*.${DOMAIN}, OU=Sonatype, O=Sonatype, L=Unspecified, ST=Unspecified, C=US" \
 -ext "SAN=DNS:nexus.${DOMAIN},DNS:registry.${DOMAIN}"
sudo mv keystore.jks ${BASE}/nexus/etc/ssl
fi
sudo chown -R 200:200 ${BASE}/nexus

#kubectl apply -f yaml/nexus-repo-deployment.yaml
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
  selector:
    app: nexus-repo
EOF

kubectl get service | grep '\-repo'
echo "After nexus has booted the admin password will be at ${BASE}/nexus/admin.password"
# externaldns doesn't assign the ip to docker-repo so we'll  do that here
BINDIP=$(kubectl get services | grep bind-service | awk '{print $3}')
DOCKERIP=$(kubectl get service | grep 'docker-repo' | awk '{print $4}')
SECRET=$(kubectl get configmap rndc-key -o jsonpath='{@.data}' | sed 's/\\n//g' | sed 's/\\//g' | sed 's/"//g' | sed 's/;//g' | awk '{print $7}')
echo ${SECRET}
cat <<EOF | nsupdate -d -y externaldns:${SECRET} --
server ${BINDIP}
update add docker-repo.k8s.${DOMAIN} 300 A ${DOCKERIP}
send
EOF
nslookup docker-repo.k8s.${DOMAIN} ${BINDIP}
