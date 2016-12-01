#!/bin/bash

ethernet="eth0"
repo_dir=$(pwd)

if [[ $1 && $2 ]]; then
  if [ "$1"=="--ethernet" ]; then
    ethernet="$2"
  fi
fi

./initial-checks.sh --ethernet $ethernet || exit 1

#Ensure data dump file is in our directory
if [ ! -f geonames.tar ]; then
  aws s3 cp s3://bsve-integration/geonames.tar ./geonames.tar
fi

#Build and spin up our mongodb
./mongodb.sh --ethernet $ethernet

#Build and spin up redis
./redis.sh --ethernet $ethernet

#Import the geonames dataset
ln -s $(pwd)/geonames.tar /var/log/geonames.tar
cd /var/log/ && tar -xf geonames.tar &&\ 
docker exec -t mongodb mongorestore --db geonames /var/log/geonames

#Ensure we have a copy of the grits image
if [[ ! -f grits.tar.gz && ! -f grits.tar ]]; then
  aws s3 cp s3://bsve-integration/grits.tar.gz ./grits.tar.gz
  gzip -d grits.tar.gz
fi

#Load the image
docker load < grits.tar

#Instantiate a new grits container
cd $repo_dir &&\
docker-compose -f compose/grits.yml up -d grits

#Reusable function for executing inside of docker container
function inside_container { docker exec -ti grits "$@"; }

#Find the AWS credentials
if [ -f ~/.aws/credentials ]; then
  AWS_CRED_FILE=~/.aws/credentials
elif [ -f ~/.aws/config ]; then
  AWS_CRED_FILE=~/.aws/config
else
  echo "Could not file AWS credentials file"
  exit 1
fi
export AWS_CRED_FILE

#Configure settings
export LOCAL_IP=$(ifconfig $ethernet|grep "inet addr"|awk -F":" '{print $2}'|awk '{print $1}')
export AWS_KEY=$(cat $AWS_CRED_FILE | grep aws_access_key_id | awk '{print $3}')
export AWS_SECRET=$(cat $AWS_CRED_FILE | grep aws_secret_access_key | awk '{print $3}')
inside_container sed -i "s/mongodb:\/\/CHANGEME/mongodb:\/\/$LOCAL_IP/" /source-vars.sh
inside_container sed -i "s/http:\/\/CHANGEME/http:\/\/$LOCAL_IP/" /source-vars.sh
inside_container sed -i "s/AWS_ACCESS_KEY_ID=CHANGEME/AWS_ACCESS_KEY_ID=$AWS_KEY/" /source-vars.sh
inside_container sed -i "s/AWS_SECRET_ACCESS_KEY=CHANGEME/AWS_SECRET_ACCESS_KEY=$AWS_SECRET/" /source-vars.sh

#Modify Apache config to be more compatible with BSVE hosting
inside_container sed -i "1,7d" /etc/apache2/conf-enabled/proxy.conf
inside_container sed -i "s/443/80/" /etc/apache2/conf-enabled/proxy.conf
inside_container sed -i "/SSL/d" /etc/apache2/conf-enabled/proxy.conf

#Run setup scripts
inside_container bash -c "source /source-vars.sh && /scripts/update-settings.sh"
inside_container bash -c "source /source-vars.sh && /scripts/disease-label-autocomplete.sh"
inside_container bash -c "source /source-vars.sh && /scripts/classifiers.sh"

#Restart container
docker kill grits && docker start grits
echo "Sleeping 10 secs, and then starting all services"
sleep 10
#Sometimes services crash when they all start up at the same time.
#Usually this fixes the problem if it's not config related.
inside_container supervisorctl start all

echo "*****************************************************************************************"
echo "Grits should be running with a few default settings. To change these settings:"
echo "Step 1: Edit /source-vars.sh"
echo "Step 2: Inside the container do: source /source-vars.sh && /scripts/update-settings.sh"
echo "Step 3: Restart the entire container"
echo "*****************************************************************************************"
echo ""
echo ""
echo "Grits app will be available at http://$LOCAL_IP/new?compact=true&bsveAccessKey=loremipsumhello714902&hideBackButton=true"

