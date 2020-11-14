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
  name=$(basename $1 | sed 's/\./ /g' | awk '{print $1}')
  file=$(cat $1 | sed 's/"/\\"/g' | sed -z 's/\n/\\n/g')
  echo '{"name":"'$name'","type":"groovy","content":"'$file'"}' > /tmp/payload

  # Generate a certificate from the docker host
  echo quit | openssl s_client -showcerts -servername docker-repo.k8s.${DOMAIN} -connect nexus-repo.k8s.${DOMAIN}:443 > /tmp/docker-cacert.pem

  # Post the script
  curl --cacert /tmp/docker-cacert.pem \
    -X POST -u $username:$password \
    --header "Content-Type: application/json" \
    "$host/service/rest/v1/script" -d @/tmp/payload

  # Show the script
  curl --cacert /tmp/docker-cacert.pem \
  -u $username:$password \
  "$host/service/rest/v1/script"

  # Execute the script
  echo "Executing $file as $name"
  curl --cacert /tmp/docker-cacert.pem \
    -X POST -u $username:$password \
    --header "Content-Type: text/plain" \
    "$host/service/rest/v1/script/$name/run"
  # TODO: Check the status codes after each call.  Hope is not a method
  echo "Successfully executed $name script"
}

echo "Provisioning Integration API Scripts publishing and executing on $host"

addAndRunScript bin/npmAndDockerRepositories.groovy

echo "Provisioning Scripts Completed"