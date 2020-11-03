## Welcome to your future

This is a brief introduction to [kubernetes](https://kubernetes.io/).

*Beware* the code and commentary are probably full of inaccuracies and erroneous observations.

## Install kubernetes

I will assume you are using a recent (18.04+) version of ubuntu.  If you are using some other version of linux or unix then good on you.  These instructions will probably work for you, too.  Windows see [here].

You must already have containerd and Docker installed.  See [here](https://kubernetes.io/docs/setup/production-environment/container-runtimes/) for some more information.

Then see [here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/) for how to install it.  And [here](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) for some fine detail.

## Landscape

We'll build a single node kubernetes master cluster with permission to act like a regular node.  In a production environment we would not allow this and there would be clusters available to take over if the primary master has to take a break.

We start by gathering some basic details about what our node will manage.  We specify the internal ip range for the [load balancer](https://metallb.universe.tf/).

Build the file [kube.conf](../etc/kube.conf) which is
```
BASE="/mnt/disks/k8s-storage"
DOMAIN=example.com
METALLBRANGE=172.20.1.0/24
PODNET=10.244.0.0/16
NSIP=172.20.1.1
```
- BASE

the path to somewhere on the pod where you will grant the pod access to your server's disk.  In the real internet these are S3 buckets or other network attached storage.  In abstract terms it is a file system.  

- DOMAIN

how the pod will know itself.  Ultimately we expect the pod to be able to handle authoritative DNS queries.  This can be a subdomain of the larger local network, or it can manage the local network.

- METALLBRANGE

An otherwise made up range of IP's that your cluster will manage.  In a multi-pod cluster this could be fairly wide network.  These will be externally routeable - meaning that the cluster will advertise an IP for a service to the external internet, and will route that traffic in toward it's deployed service.  In this single node cluster that means nothing.  In a private network it means on-premesis cloud.  In the cloud it means part of a [VPC](https://www.ibm.com/cloud/vpc).


- PODNET

An equally made up range of IP's that the kube will manage.  These are internal IP addresses that are only reachable from 'within' the cluster.

- NSIP

This is the IP of the first server we'll deploy.  It will be a nameserver running BIND9.  Together with [external-dns](https://github.com/kubernetes-sigs/external-dns/blob/master/README.md) it will expose the node's internal services for lookup on the local network managed by the node using [DDNS](https://tools.ietf.org/html/rfc2136) specifications.

## Reset

I don't recommend minikube because you'll end up having to learn the difference between the two.  Just use kubectl, and be done with it.  Work in a bare-metal sandbox with access to the internet.  Leave your desktop behind.

We will build a script to fully reset kubernetes from scratch and then reinitialize it.

### Shebang!
Read the contents of kube.conf
```
#!/bin/bash
. ./kube.conf
```
Get the IP of the host we're working on.

```IP=$(ip -o addr show up primary scope global | head -1 | sed 's,/, ,g' | awk '{print $4}')```

Reset kubeadm
```
sudo kubeadm reset -f
```
Stop all running docker containers
```
PROCIDS=`docker ps | grep k8s`
if [ ! -z "${PROCIDS}" ]; then
  docker update --restart=no `docker ps | grep k8s | awk '{print $1}'` && docker stop `docker ps | grep k8s | awk '{print $1}'` 
fi
```
Stop the kubelet service
```
sudo systemctl stop kubelet.service
```
Purge any previous installation and reinitialize
```
sudo rm -rf /etc/kubernetes ~/.kube/config ~/.kube/cache /var/lib/etcd /var/lib/kubelet /var/lib/etcd /var/lib/kubelet /var/lib/dockershim /var/run/kubernetes /var/lib/cni /etc/cni/net.d
sudo swapoff -a
sudo kubeadm init --apiserver-advertise-address ${IP} --pod-network-cidr=${PODNET} 

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

```
Reinstall [flannel](https://github.com/coreos/flannel/blob/master/README.md)
```
if [ ! -f flannel.yaml ]; then
  curl -qso flannel.yaml https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
fi
kubectl apply -f flannel.yaml
```
Allow the master node to act as a compute node
```
kubectl taint nodes --all node-role.kubernetes.io/master-
```
Install [MetalLb](https://metallb.universe.tf/)
```
if [ ! -f metallb-namespace.yaml ]; then
  curl -qso metallb-namespace.yaml https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/namespace.yaml
fi
kubectl apply -f metallb-namespace.yaml
if [ ! -f metallb.yaml ]; then
  curl -qso metallb.yaml https://raw.githubusercontent.com/metallb/metallb/v0.9.4/manifests/metallb.yaml
fi
kubectl apply -f metallb.yaml
```
Create a secret for metallb
```kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
```
Install the [kubernetes dashboard](https://github.com/kubernetes/dashboard/blob/master/README.md)
```
if [ ! -f dashboard.yaml ]; then
  curl -qso dashboard.yaml https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.4/aio/deploy/recommended.yaml
fi
kubectl apply -f dashboard.yaml
```
Expose the dashboard to the loadbalancer.  The default installation of the dashboard is only exposed on localhost.  This allows us to view the dashboard from another location on the network.
```
kubectl -n kubernetes-dashboard get service kubernetes-dashboard -o yaml | \
sed -e "s/type: ClusterIP/type: LoadBalancer/" | \
kubectl apply -f - -n kubernetes-dashboard
```
Create the admin user using inline script
```
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
```
Let MetalLb know what ip range to use
```
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
```
Show the bearer token.  Use this to access [the dashboard](https://172.20.1.0)
```
kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}')
```
You can see more information about the dashboard here
```
kubectl -n kubernetes-dashboard get service kubernetes-dashboard
```

Now you are all reset.
