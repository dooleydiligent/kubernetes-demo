#!/bin/bash

[ ! -f ./etc/kube.conf ] && echo "This expects to be run from the root of the repository" && exit 0

. ./etc/kube.conf

#set -x
SECRET=j53z471ZpDES4ANLntn1WRgQ23Ewuy5PnMQP7m0EYzs=

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
        - --registry=txt
        - --txt-owner-id=k8s
        - --provider=rfc2136
        - --rfc2136-host=172.20.1.1
        - --rfc2136-port=53
        - --rfc2136-zone=${DOMAIN}
        - --rfc2136-tsig-secret=${SECRET}
        - --rfc2136-tsig-secret-alg=hmac-sha256
        - --rfc2136-tsig-keyname=externaldns
        - --rfc2136-tsig-axfr
        - --source=service
        - --domain-filter=${DOMAIN}
EOF
