#!/bin/bash
[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

. ./etc/kube.conf

#set -x
#DIG=$(which dig)
#if [ -z "${DIG}" ]; then
#  echo You must have dig to test the bind installation properly
#fi

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
EXTERNALDNSKEY=$(docker run --entrypoint /usr/sbin/tsig-keygen ventz/bind:9.16.6-r0 -a hmac-sha256 externaldns | sed 's/\t/      /g' | sed 's/};/      };/g')
SECRET=$(echo ${EXTERNALDNSKEY} | sed 's/"/ /'g | awk '{print $7}')
IFEXISTS=$(kubectl get configmap | grep named-conf)
if [ ! -z "${IFEXISTS}" ]; then 
  kubectl delete configmap named-conf
fi
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
# Overwrite the existing rndc key in the container
IFEXISTS=$(kubectl get configmap | grep rndc-key)
if [ ! -z "${IFEXISTS}" ]; then 
  kubectl delete configmap rndc-key
fi

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rndc-key
data:
  rndc.key: |
    ${EXTERNALDNSKEY}
EOF
IFEXISTS=$(kubectl get configmap | grep named-conf-options)
if [ ! -z "${IFEXISTS}" ]; then 
  kubectl delete configmap named-conf-options
fi

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
      allow-transfer { any; };
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

# NOTE: We are deliberately supplying an invalid IP for the nameserver here.  It will be updated later
cat <<EOF > ./${DOMAIN}.k8s.zone
\$TTL 60 ; 1 minute
@        IN SOA  k8s.${DOMAIN}. root.k8s.${DOMAIN}. (
              1         ; serial
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

IFEXISTS=$(kubectl get configmap | grep named-conf-local)
if [ ! -z "${IFEXISTS}" ]; then 
  kubectl delete configmap named-conf-local
fi

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
  echo "Deleting previous bind-service"
  kubectl delete service bind-service
fi
RESET=$(kubectl get deployment | grep 'bind-service')
if [ ! -z "${RESET}" ]; then
  echo "Deleting previous bind-service deployment"
  kubectl delete deployment bind-service
fi
kubectl apply -f yaml/bind-deployment.yaml
#kubectl expose deployment bind-service --type=LoadBalancer --name=bind-service

#kubectl logs `kubectl get pods | grep bind | awk '{print $1}'`
echo "Waiting for nameserver to become available"
kubectl describe services bind-service
while [ -z "${NSIP}" ]
do
NSIP=$(kubectl describe services bind-service | grep 'LoadBalancer Ingress' | awk '{print $3}')
if [ ! -z "${NSIP}" ]; then
  echo "Got name server IP: ${NSIP}"
else
  sleep 3
  echo -n .
fi
done

#if [ ! -z "${DIG}" ]; then
#echo Attempting an AXFR request for ns.k8s.${DOMAIN} ${NSIP}
#dig @${NSIP} -t AXFR k8s.${DOMAIN} -y hmac-sha256:externaldns:${SECRET}
#else
#echo "Cannot test the bind installation - no dig"
#fi

RESET=$(kubectl get deployments | grep 'external-dns')
if [ ! -z "${RESET}" ]; then
  kubectl delete deployment external-dns
fi
# We are going to tell external-dns to query the PODIP because we can't expose both UDP and TCP with the loadbalancer
echo "Waiting for PODIP ..."
while [ -z "${PODIP}" ]
do
PODIP=$(kubectl get pods -o yaml | grep podIP: | grep -v f | awk '{print $2}'| head -n 1)
if [ ! -z "${PODIP}" ]; then
  echo "Got PODIP ${PODIP}"
else
sleep 3
echo -n .
fi
done
echo "Installing external-dns"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
- apiGroups:
  - ""
  resources:
  - services
  - endpoints
  - pods
  - nodes
  verbs:
  - get
  - watch
  - list
- apiGroups:
  - extensions
  - networking.k8s.io
  resources:
  - ingresses
  verbs:
  - get
  - list
  - watch
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
- kind: ServiceAccount
  name: external-dns
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
spec:
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      serviceAccountName: external-dns
      containers:
      - name: external-dns
        image: k8s.gcr.io/external-dns/external-dns:v0.7.3
        args:
        - --registry=txt
        - --txt-owner-id=external-dns
        - --provider=rfc2136
        - --rfc2136-zone=k8s.${DOMAIN}
        - --rfc2136-tsig-secret=${SECRET}
        - --rfc2136-tsig-secret-alg=hmac-sha256
        - --rfc2136-tsig-keyname=externaldns
        - --rfc2136-tsig-axfr
        - --source=service
        - --domain-filter=k8s.${DOMAIN}
        - --rfc2136-host=${PODIP}
        - --rfc2136-port=53
EOF

kubectl apply -f ./produce-an-a.yaml

netcat -zvuw0 172.20.1.1 53
echo nslookup ns.k8s.${DOMAIN} ${NSIP}
nslookup ns.k8s.${DOMAIN} ${NSIP}

echo "Waiting for nginx ip to appear in BIND"
WAITFOR=""
while [ -z "${WAITFOR}" ]
do
WAITFOR=$(nslookup nginx.k8s.${DOMAIN} ${NSIP} | grep Name: | grep nginx)
if [ -z "${WAITFOR}" ]; then
  sleep 3
  echo -n .
fi
done
echo nslookup nginx.k8s.${DOMAIN} ${NSIP}
nslookup nginx.k8s.${DOMAIN} ${NSIP}