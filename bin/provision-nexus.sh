#!/bin/bash
. ./etc/kube.conf
set -x
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
host=https://nexus-repo.k8s.${DOMAIN}

# add a script to the repository manager and run it
function addAndRunScript {
  name=$1
  file=$2
  # using grape config that points to local Maven repo and Central Repository , default grape config fails on some downloads although artifacts are in Central
  # change the grapeConfig file to point to your repository manager, if you are already running one in your organization
  groovy -Djavax.net.ssl.trustStorePassword=password -Djavax.net.ssl.trustStore=${BASE}/nexus/etc/ssl/keystore.jks -Dgroovy.grape.report.downloads=true -Dgrape.config=grapeConfig.xml bin/addUpdateScript.groovy -u "$username" -p "$password" -n "$name" -f "$file" -h "$host"
  printf "\nExecuting $file as $name\n\n"
  echo curl --cacert /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}/ca.crt -v -X POST -u $username:$password --header "Content-Type: text/plain" "$host/service/rest/v1/script/$name/run"

  curl --cacert /etc/docker/certs.d/docker-repo.k8s.${DOMAIN}/ca.crt -v -X POST -u $username:$password --header "Content-Type: text/plain" "$host/service/rest/v1/script/$name/run"
  printf "\nSuccessfully executed $name script\n\n\n"
}

printf "Provisioning Integration API Scripts Starting \n\n" 
printf "Publishing and executing on $host\n"

addAndRunScript npmAndDocker bin/npmAndDockerRepositories.groovy

printf "\nProvisioning Scripts Completed\n\n"