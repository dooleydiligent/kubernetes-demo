### Install Bind

Start by re-reading the configuration created previously
```
#!/bin/bash

[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

. ./etc/kube.conf

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
sudo mkdir -p ${BASE}/bind >/dev/null
if [ ! -d "${BASE}/bind" ]; then
  echo Could not create bind folder in ${BASE}/bind
  exit 0
fi

```
We'll download the container in advance so that we can generate a proper key
```
echo "Downloading ventz/bind:9.16.6-r0.  This will take some time"
EXTERNALDNSKEY=$(docker run --entrypoint /usr/sbin/tsig-keygen ventz/bind:9.16.6-r0 -a hmac-sha256 externaldns | sed 's/\t/      /g' | sed 's/};/      };/g')
```
Create a named.conf configMap
```
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
```
Create a named.conf.options configMap
```
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
```
Create an authoritative zone file for the cluster
```
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
```
Move the zone file into place
```
sudo mv k8s.zone ${BASE}/bind/k8s.zone
```
NOTE: We are supplying the expected IP for the nameserver here.  It will be updated later
```
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
```
Move it into place
```
sudo mv ${DOMAIN}.k8s.zone ${BASE}/bind/${DOMAIN}.k8s.zone
```
Give this mount to the bind user
```
sudo chown -R  100:101 ${BASE}/bind/
```
Now create the bind configuration
```
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
```
Prepare to delete the bind-service if it already exists
```
RESET=$(kubectl get services | grep 'bind-service')
if [ ! -z "${RESET}" ]; then
  kubectl delete service bind-service
fi
```
Redeploy the bind image
```
kubectl apply -f yaml/bind-deployment.yaml
kubectl expose deployment bind-service --type=LoadBalancer --name=bind-service
```
If you want to see what went wrong you can use this
```
kubectl logs `kubectl get pods | grep bind | awk '{print $1}'`
```
Let's look at what we've done
```
kubectl describe services bind-service
```
Give it some time to stabilize ...
```
sleep 3
```
Now find out what is the assigned network IP
```
NSIP=$(kubectl describe services bind-service | grep 'LoadBalancer Ingress' | awk '{print $3}')
echo Attempting to lookup the nameserver on ${NSIP}
echo nslookup ns.k8s.${DOMAIN} ${NSIP}
```
And look it up on the newly running bind service
```
nslookup ns.k8s.${DOMAIN} ${NSIP}
```
PAU!  You now have an authoritative BIND name server serving the local network with deployed service information in the kubernetes cluster.

Next up:
### [Task 2](https://github.com/dooleydiligent/kubernetes-demo/tree/master/docs/externaldns.md) Install externaldns to dynamically update BIND with service IP's as they are deployed to kubernetes