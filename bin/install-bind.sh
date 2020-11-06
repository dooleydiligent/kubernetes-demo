#!/bin/bash
[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

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

sudo mkdir -p ${BASE}/bind  >/dev/null
if [ ! -d "${BASE}/bind" ]; then
  echo Could not create bind folder in ${BASE}/bind
  exit 0
fi

# We'll download the container in advance so that we can generate a proper key
echo "Downloading ventz/bind:9.16.6-r0.  This will take some time"
EDNS=$(docker run --entrypoint /usr/sbin/tsig-keygen ventz/bind:9.16.6-r0 -a hmac-sha256 externaldns)
EXTERNALDNSKEY=$(echo ${EDNS} | sed 's/\t/      /g' | sed 's/};/      };/g')
SECRET=$(echo ${EDNS}| awk '{print $7}' | sed 's/"//g')
#echo SECRET is ${SECRET}
#echo EDNS is ${EDNS}
# Create a named.conf configMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: named-conf
data:
  named.conf: |
    ${EXTERNALDNSKEY}
    controls {
      inet 0.0.0.0 allow { any; } keys { "externaldns"; };
    };
    // include "/etc/bind/rndc.key";
    include "/etc/bind/named.conf.options";
    include "/etc/bind/named.conf.local";
EOF

# Create a named.conf.options configMap
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: named-conf-options
data:
  named.conf.options: |
    options {
      directory "/var/cache/bind";
      version "";
      listen-on    { any; };
      pid-file "/var/run/named/named.pid";
      allow-query { any; };
      allow-transfer { none; };
      recursion no;
      auth-nxdomain yes;
    };
EOF

# Create an authoritative zone file for the cluster
cat <<EOF >./k8s.zone
zone "k8s.${DOMAIN}" {
   type master;
   file "/var/cache/bind/${DOMAIN}.k8s.zone";
   allow-transfer {
       key "externaldns";
   };
   update-policy {
       grant externaldns zonesub ANY;
   };
};
EOF

# Move the zone file into place
sudo mv k8s.zone ${BASE}/bind/k8s.zone

# NOTE: We are supplying the expected IP for the nameserver here.  It will be updated later
cat <<EOF > ./${DOMAIN}.k8s.zone
\$TTL 60 ; 1 minute
@        IN SOA  k8s.${DOMAIN}. root.k8s.${DOMAIN}. (
             16         ; serial
             60         ; refresh (1 minute)
             60         ; retry (1 minute)
             60         ; expire (1 minute)
             60         ; minimum (1 minute)
             )
             NS      ns.k8s.${DOMAIN}.
ns           A       172.20.1.1
EOF
sudo mv ${DOMAIN}.k8s.zone ${BASE}/bind/${DOMAIN}.k8s.zone
# give this mount to the bind user
sudo chown -R  100:101 ${BASE}/bind/

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: named-conf-local
data:
  named.conf.local: |
    include "/etc/bind/named.conf.default-zones";
    include "/etc/bind/named.conf.rfc1918";
    include "/var/cache/bind/k8s.zone";
EOF
RESET=$(kubectl get services | grep 'bind-service')
if [ ! -z "${RESET}" ]; then
  kubectl delete service bind-service
fi
kubectl apply -f yaml/bind-deployment.yaml
kubectl expose deployment bind-service --type=LoadBalancer --name=bind-service

#kubectl logs `kubectl get pods | grep bind | awk '{print $1}'`

kubectl describe services bind-service
sleep 3
NSIP=$(kubectl describe services bind-service | grep 'LoadBalancer Ingress' | awk '{print $3}')
echo Attempting to lookup the nameserver on ${NSIP}
echo nslookup ns.k8s.${DOMAIN} ${NSIP}
nslookup ns.k8s.${DOMAIN} ${NSIP}
# Install external-dns
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: external-dns
  labels:
    name: external-dns
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  namespace: external-dns
spec:
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      containers:
      - name: external-dns
        image: k8s.gcr.io/external-dns/external-dns:v0.7.3
        args:
        - --txt-owner-id=k8s
        - --provider=rfc2136
        - --rfc2136-host=${NSIP}
        - --rfc2136-port=53
        - --rfc2136-zone=${DOMAIN}
        - --rfc2136-tsig-secret=${SECRET}
        - --rfc2136-tsig-secret-alg=hmac-sha256
        - --rfc2136-tsig-keyname=externaldns
        - --rfc2136-tsig-axfr
        - --source=ingress
        - --domain-filter=${DOMAIN}
EOF
