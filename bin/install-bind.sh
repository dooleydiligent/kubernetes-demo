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

sudo mkdir -p ${BASE}/bind/var ${BASE}/bind/etc >/dev/null
if [ ! -d "${BASE}/bind/etc" ]; then
  echo Could not create bind folder in ${BASE}/bind/etc
  exit 0
fi

#cat <<EOF >./k8.zone
#zone "k8s.${DOMAIN}" {
#    type master;
#    file "/var/cache/bind/k8s.zone";
#    allow-transfer {
#        key "externaldns";
#    };
#    update-policy {
#        grant externaldns zonesub ANY;
#    };
#};
#EOF
#sudo mv k8.zone ${BASE}/bind/var/k8.zone

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
sudo mv ${DOMAIN}.k8.zone ${BASE}/bind/var/${DOMAIN}.k8.zone
# give this mount to the bind user
sudo chown -R  100:101 ${BASE}/bind/

# We'll download the container in advance so that we can generate a proper key
#EXTERNALDNSKEY=$(docker run --entrypoint /usr/sbin/tsig-keygen ventz/bind:9.16.6-r0 -a hmac-sha256 externaldns | sed 's/\t/      /g' | sed 's/};/      };/g')

#EXTERNALDNSKEY=`echo '      key "externaldns" { \
#      algorithm hmac-sha256; \
#      secret "V7v+l6mbU6Mw0lS1iCj4Zi6ycNbR89tkNha8GkCAeCY="; \
#      };'`

#cat <<EOF | kubectl apply -f -
#apiVersion: v1
#kind: Namespace
#metadata:
#  name: external-dns
#  labels:
#    name: external-dns
#EOF
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: named-conf
data:
  named.conf: |
    controls {
      inet 0.0.0.0 allow { any; } keys { "rndc-key"; };
    };
    include "/etc/bind/rndc.key";
    include "/etc/bind/named.conf.options";
    include "/etc/bind/named.conf.local";
EOF

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
# NOTE:  Under 'include' above, we will add ${EXTERNALDNSKEY} sometime later
kubectl apply -f yaml/bind-deployment.yaml
sleep 3
kubectl get service bind-service
# -n external-dns


