### Install Bind

Start by re-reading the configuration created previously
```
#!/bin/bash

. ../etc/kube.conf

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
sudo mkdir -p ${BASE}/bind/var ${BASE}/bind/etc >/dev/null
if [ ! -d "${BASE}/bind/etc" ]; then
  echo Could not create bind folder in ${BASE}/bind/etc
  exit 0
fi

```
Create the k8s subdomain in the ${DOMAIN} declared in kube.conf.
```
cat <<EOF > ./${DOMAIN}.k8.zone
$TTL 60 ; 1 minute
k8s.${DOMAIN}         IN SOA  k8s.${DOMAIN}. root.k8s.${DOMAIN}. (
                                16         ; serial
                                60         ; refresh (1 minute)
                                60         ; retry (1 minute)
                                60         ; expire (1 minute)
                                60         ; minimum (1 minute)
                                )
                        NS      ns.k8s.${DOMAIN}.
ns                      A       ${NSIP}
EOF
```
Now move it to a location where a node deployment can access it
```
sudo mv ${DOMAIN}.k8.zone ${BASE}/bind/var/${DOMAIN}.k8.zone
```
Give this mount to the bind user
```
sudo chown -R  100:101 ${BASE}/bind/
```
Create a configMap to expose as a read-only file to the BIND service
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
    include "/var/cache/bind/k8.zone";
EOF
```
Now create the bind service deployment.  This will take some time as the docker images must be downloaded.  Get a cup of coffee.
```
kubectl apply -f bind-deployment.yaml
```
View some information about the bind service
```
kubectl get service bind-service
```
