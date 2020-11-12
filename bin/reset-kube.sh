#!/bin/bash
[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

. ./etc/kube.conf

# More reading for dns
# https://github.com/kubernetes-sigs/external-dns

sudo kubeadm reset -f
PROCIDS=`docker ps | grep k8s`
if [ ! -z "${PROCIDS}" ]; then
  docker update --restart=no `docker ps | grep k8s | awk '{print $1}'` && docker stop `docker ps | grep k8s | awk '{print $1}'` 
fi
sudo systemctl stop kubelet.service
sudo rm -rf /etc/kubernetes ~/.kube/config ~/.kube/cache /var/lib/etcd /var/lib/kubelet /var/lib/etcd /var/lib/kubelet /var/lib/dockershim /var/run/kubernetes /var/lib/cni /etc/cni/net.d
sudo swapoff -a
# Try to detect the primary IP.  Can be overridden with an entry in kube.conf
if [ -z "${IP}" ]; then
  IP=$(ip -o addr show up primary scope global dynamic| grep -v flannel | head -1 | sed 's,/, ,g' | awk '{print $4}')
fi
echo Using external IP ${IP}

sudo kubeadm init --apiserver-advertise-address ${IP} --pod-network-cidr=${PODNET} 

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Allow master to act as a compute node
kubectl taint nodes --all node-role.kubernetes.io/master-

# install flannel
if [ ! -f ./yaml/flannel.yaml ]; then
  curl -qso ./yaml/flannel.yaml https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
fi
kubectl apply -f ./yaml/flannel.yaml

# Install MetalLb
if [ ! -f ./yaml/metallb-namespace.yaml ]; then
  curl -qso ./yaml/metallb-namespace.yaml https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/namespace.yaml
fi
kubectl apply -f ./yaml/metallb-namespace.yaml
if [ ! -f ./yaml/metallb.yaml ]; then
  curl -qso ./yaml/metallb.yaml https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/metallb.yaml
fi
kubectl apply -f ./yaml/metallb.yaml

# On first install only
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

# Install the dashboard
if [ ! -f ./yaml/dashboard.yaml ]; then
  curl -qso ./yaml/dashboard.yaml https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.4/aio/deploy/recommended.yaml
fi
kubectl apply -f ./yaml/dashboard.yaml

# expose the dashboard to the loadbalancer
kubectl -n kubernetes-dashboard get service kubernetes-dashboard -o yaml | \
sed -e "s/type: ClusterIP/type: LoadBalancer/" | \
kubectl apply -f - -n kubernetes-dashboard

# Create the admin user
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

cat <<EOF | kubectl apply -f - 
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${METALLBRANGE}
EOF
# Show the bearer token
kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}')
# wait a moment
echo "Waiting for the dashboard external IP to be assigned"
while [ -z "${DASHBOARD}" ]
do
DASHBOARD=$(kubectl -n kubernetes-dashboard get service kubernetes-dashboard | grep LoadBalancer | grep -v ending | awk '{print $4}')
if [ ! -z "${DASHBOARD}" ]; then
  echo "Dashboard running at ${DASHBOARD}"
else
  sleep 3
  echo -n .
fi
done
# Show what port the dashboard is listening on
kubectl -n kubernetes-dashboard get service kubernetes-dashboard
