#!/bin/bash
. ./etc/kube.conf
#set -x
# fail if anything errors
set -e
# fail if a function call is missing an argument
set -u
echo "Waiting for admin.password to be generated"
username=admin
password=

while [ -z "${password}" ]
do
if [ ! -f "${BASE}/nexus/admin.password" ]; then
  sleep 5
  echo -n .
else
  password=$(cat ${BASE}/nexus/admin.password)
fi
done

# add the context if you are not using the root context
host=https://nexus-repo.k8s.${DOMAIN}:443

# add a script to the repository manager and run it
function addAndRunScript {
  name=npmAndDockerRepositories
  file=$2
  # using grape config that points to local Maven repo and Central Repository , default grape config fails on some downloads although artifacts are in Central
  # change the grapeConfig file to point to your repository manager, if you are already running one in your organization
  # Generate a certificate from the docker host
  echo quit | openssl s_client -showcerts -servername docker-repo.k8s.kubernetes.cluster  -connect nexus-repo.k8s.kubernetes.cluster:443 > /tmp/docker-cacert.pem

  # Post the script
  curl --cacert /tmp/docker-cacert.pem \
    -X POST -u $username:$password \
    --header "Content-Type: application/json" \
    "$host/service/rest/v1/script" -d @$file

  # Show the script
  curl --cacert /tmp/docker-cacert.pem \
  -u $username:$password \
  "$host/service/rest/v1/script"

  # Execute the script
#  groovy -Djavax.net.ssl.trustStorePassword=password -Djavax.net.ssl.trustStore=${BASE}/nexus/etc/ssl/keystore.jks -Dgroovy.grape.report.downloads=true -Dgrape.config=grapeConfig.xml bin/addUpdateScript.groovy -u "$username" -p "$password" -n "$name" -f "$file" -h "$host"
  echo "Executing $file as $name"
  curl --cacert /tmp/docker-cacert.pem \
    -X POST -u $username:$password \
    --header "Content-Type: text/plain" \
    "$host/service/rest/v1/script/$name/run"

#  curl --cacert /tmp/docker-cacert.pem -v -X POST -u $username:$password --header "Content-Type: text/plain" "$host/service/rest/v1/script/$name/run"
  echo "Successfully executed $name script"
}

echo "Provisioning Integration API Scripts publishing and executing on $host"

addAndRunScript npmAndDocker bin/npmAndDockerRepositories.json

echo "Provisioning Scripts Completed"