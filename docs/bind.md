### Install Bind

Start by re-reading the configuration created previously
```
#!/bin/bash

[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

. ./etc/kube.conf

# Override any variables here
[ -f ./etc/kube.conf.local ] && . ./etc/kube.conf.local

# Do some sanity checks

if [ -z "${BASE}" ]; then
  echo BASE is not set in ./kube.conf
  exit 0
fi

if [ -z "${DOMAIN}" ]; then
  echo DOMAIN is not set in ./kube.conf
  exit 0
fi

# You must have root access to do much of this

# Remove any previous update to the local resolver
[ ! -f /etc/resolvconf/resolv.conf.d/head ] && "This script expects package resolvconf.  Please 'apt -y install resolvconf' to contine" && exit 0
sudo chmod go+w /etc/resolvconf/resolv.conf.d/head
sudo sed 's/nameserver '${IP}'//g' /etc/resolvconf/resolv.conf.d/head | \
 sudo sed "s/search ${DOMAIN}//g" > /etc/resolvconf/resolv.conf.d/head 
sudo resolvconf -u

echo "Checking for previous installation"
if [ -d ${BASE}/bind ]; then
  echo "Removing previous installation"
  sudo rm -rf ${BASE}/bind
fi
sudo mkdir -p ${BASE}/bind  >/dev/null
if [ ! -d "${BASE}/bind" ]; then
  echo Could not create bind folder in ${BASE}/bind
  exit 0
fi

# We'll download the container in advance so that we can generate a proper key
DOWNLOADED=$(docker image ls | grep ventz/bind)
if [ -z "${DOWNLOADED}" ]; then
  echo "Downloading ventz/bind:9.16.6-r0.  This will take some time"
fi
echo "Generating RNDC secret"
EXTERNALDNSKEY=$(docker run --entrypoint /usr/sbin/tsig-keygen ventz/bind:9.16.6-r0 -a hmac-md5 externaldns | sed 's/\t/      /g' | sed 's/};/      };/g')
echo "RNDC Key is ${EXTERNALDNSKEY}"
SECRET=$(echo ${EXTERNALDNSKEY} | sed 's/"/ /'g | awk '{print $7}')
echo "Checking for existing named-conf configmap"
IFEXISTS=$(kubectl get configmap | grep named-conf)
if [ ! -z "${IFEXISTS}" ]; then
  echo "Deleting previous installation of named-conf configmap"
  kubectl delete configmap named-conf
fi
echo "Creating named-conf configmap"
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
    include "/etc/bind/named.conf.options";
    include "/etc/bind/named.conf.local";
EOF
# Overwrite the existing rndc key in the container
echo "Checking for configmap rndc-key"
IFEXISTS=$(kubectl get configmap | grep rndc-key)
if [ ! -z "${IFEXISTS}" ]; then 
  echo "Deleting rndc-key configmap"
  kubectl delete configmap rndc-key
fi
echo "Creating rndc-key configmap"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rndc-key
data:
  rndc.key: |
    ${EXTERNALDNSKEY}
EOF
echo "Checking for configmap named-conf-options"
IFEXISTS=$(kubectl get configmap | grep named-conf-options)
if [ ! -z "${IFEXISTS}" ]; then 
  echo "Deleting named-conf-options configmap"
  kubectl delete configmap named-conf-options
fi
echo "Creating named-conf-options configmap"
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
      recursion yes;
      auth-nxdomain yes;
      forwarders {
        ${IP};
      };
    };
EOF
echo "Generating DNS zone files"
# Create an authoritative zone file for the cluster
cat <<EOF >./k8s.zone
zone "k8s.${DOMAIN}" {
   type master;
   file "/var/cache/bind/${DOMAIN}.k8s.zone";
   allow-transfer {
       key "externaldns";
   };
   update-policy {
       grant externaldns subdomain k8s.${DOMAIN}. ANY;
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
             IN NS   ns.k8s.${DOMAIN}.
ns           IN A    172.20.1.1
EOF
sudo mv ${DOMAIN}.k8s.zone ${BASE}/bind/${DOMAIN}.k8s.zone

# give this mount to the bind user
sudo chown -R  100:101 ${BASE}/bind/
echo "Checking for existing named-conf-local configmap"
IFEXISTS=$(kubectl get configmap | grep named-conf-local)
if [ ! -z "${IFEXISTS}" ]; then 
  echo "Deleting previous configmap named-conf-local"
  kubectl delete configmap named-conf-local
fi
echo "Creating configmap named-conf-local"
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
echo "Checking for existing BIND service"
RESET=$(kubectl get services | grep 'bind-service')
if [ ! -z "${RESET}" ]; then
  echo "Deleting previous bind-service"
  kubectl delete service bind-service
fi
echo "Checking for existing BIND deployment"
RESET=$(kubectl get deployment | grep 'bind-service')
if [ ! -z "${RESET}" ]; then
  echo "Deleting previous bind-service deployment"
  kubectl delete deployment bind-service
fi
echo "Deploying BIND"
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

echo "Updating local /etc/resolv.conf"
sudo echo "nameserver ${NSIP}" >>/etc/resolvconf/resolv.conf.d/head
sudo echo "search ${DOMAIN}" >>/etc/resolvconf/resolv.conf.d/head
sudo resolvconf -u
cat /etc/resolv.conf
#if [ ! -z "${DIG}" ]; then
#echo Attempting an AXFR request for ns.k8s.${DOMAIN} ${NSIP}
#dig @${NSIP} -t AXFR k8s.${DOMAIN} -y hmac-md5:externaldns:${SECRET}
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
        - --rfc2136-tsig-secret-alg=hmac-md5
        - --rfc2136-tsig-keyname=externaldns
        - --rfc2136-tsig-axfr
        - --source=service
        - --domain-filter=k8s.${DOMAIN}
        - --rfc2136-host=${PODIP}
        - --rfc2136-port=53
EOF

#kubectl apply -f ./produce-an-a.yaml
echo "Waiting for BIND on ${NSIP}"
WAITFOR=""
while [ -z "${WAITFOR}" ]
do
WAITFOR=$(netcat -zvu ${NSIP} 53 2>&1 | grep succeeded)
if [ ! -z "${WAITFOR}" ]; then
  echo "BIND is listening on ${NSIP}"
else
  sleep 3
  echo -n .
fi
done
echo nslookup ns.k8s.${DOMAIN} ${NSIP}
nslookup ns.k8s.${DOMAIN} ${NSIP}
```

PAU!  You now have an authoritative BIND name server serving the local network with deployed service information in the kubernetes cluster.

Next up:
### [Task 2](https://github.com/dooleydiligent/kubernetes-demo/tree/master/docs/nexusrepo.md) Install sonatype nexus to serve as an npm and docker registry