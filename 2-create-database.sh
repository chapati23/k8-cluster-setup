#!/bin/bash

# Prerequisites (macOS):
# - ./1-create-cluster.sh needs to have been executed successfully, otherwise we don't have a cluster to work with here

# - aws cli => to create AWS resources
#   => pip install --upgrade --user awscli
#   => aws configure

# - jq => to parse JSON results returned by the AWS CLI
#   => brew install jq

# - chronic => to suppress output unless there's a non-zero exit code
#   => brew install moreutils

# - terraform => to create the DB on AWS
#   => brew install terraform

# - kubectl => to create a new db-secret so our API services know how to talk to the database
#   => brew install kubernetes-cli

export PREFIX="chapati"
export URL="example.com"
export DB_INSTANCE_CLASS="db.m3.medium"
export DB_NAME_DEFAULT="my-db"
export DB_PORT="5432"
export DB_POSTGRES_VERSION="9.6.2"
export DB_USER_DEFAULT="chapati"
export AWS_REGION="eu-central-1"


####################
# SPECIFY CLUSTER #
###################

printf "1️⃣  Please specify the cluster name (e.g. 'canary', or 'dev'): "
read CLUSTER_NAME

if [ "$CLUSTER_NAME" != "canary" ] &&  [ "$CLUSTER_NAME" != "dev" ]
then
  echo "Sorry, but I can only help you with the 'dev' and 'canary' clusters right now"
  exit 1
fi
printf "\n"



########################
# ENTER DB CREDENTIALS #
########################

echo "2️⃣  What should the DB username be? (Press enter to confirm the default value)"
read -p "   Username: ($DB_USER_DEFAULT) " DB_USER
DB_USERNAME=${DB_USER:-$DB_USER_DEFAULT}
printf "\n"

printf "3️⃣  And the password? "
read -s DB_PASSWORD
printf "\n"

printf "\n4️⃣  Let's confirm the password, just to be sure: "
read -s DB_PASSWORD_CONFIRMATION
printf "\n"

if [ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRMATION" ]
then
  echo "   ❌  Passwords don't match"
  exit 1
fi

echo "   🔑  Awesome, now please put the DB password into our 1password team vault so it can't get lost"
printf "   🔑  Type 'done' to confirm that you safely stored the DB password in the team vault: "
read CONFIRM

if [ "$CONFIRM" != "done" ]
then
  echo "   ❗️ Ok, one more chance: Type 'done' to confirm you've stored theDB password in the 1password team vault"
  read CONFIRM
fi

if [ "$CONFIRM" != "done" ]
then
  echo "   ❌  Aborting, you've had your chance…"
  exit 1
fi
printf "\n"

echo "5️⃣  What should the name of the default DB be? (Press enter to confirm the default value)"
read -p "   Database name: ($DB_NAME_DEFAULT) " DB_NAME
DB_NAME=${DB_NAME:-$DB_NAME_DEFAULT}
printf "\n"


##############################
# FETCHING VPC ID FOR NEW DB #
##############################

echo "6️⃣  Get VPC ID of the $CLUSTER_NAME cluster from AWS"
CLUSTER_URL="k8-$CLUSTER_NAME.$URL"
VPC_ID=$(aws ec2 describe-vpcs | jq --arg CLUSTER_URL $CLUSTER_URL '.Vpcs[] as $vpc | ($vpc.Tags[] as $tag | select($tag.Key == "Name") | select($tag.Value == $CLUSTER_URL)) | $vpc.VpcId')

if [ -z "$VPC_ID" ]
then
  echo "   ❌  Couldn't find VPC for given cluster name"
  exit 1
fi
printf "\n"



############################
# CREATE DB WITH TERRAFORM #
############################

echo "7️⃣  Create DB with terraform"

DB_IDENTIFIER=$(echo $PREFIX-$CLUSTER_NAME-db-rds)
DB_EXISTS=$(aws rds describe-db-instances | jq -r --arg db $DB_IDENTIFIER '.DBInstances[] | select(.DBInstanceIdentifier == $db) | .DBInstanceArn')
if [ "$DB_EXISTS" != "" ]
then
  echo "   DB already exists, skipping creation"
else
  printf "  a) Exporting terraform environment variables…"
  export TF_VAR_aws_credentials_path="$(echo ~)/.aws/credentials"
  export TF_VAR_aws_region=$AWS_REGION
  export TF_VAR_cluster_name=$CLUSTER_NAME
  export TF_VAR_db_identifier=$DB_IDENTIFIER
  export TF_VAR_db_instance_class=$DB_INSTANCE_CLASS
  export TF_VAR_db_name=$DB_NAME
  export TF_VAR_db_password=$DB_PASSWORD
  export TF_VAR_db_postgres_version=$DB_POSTGRES_VERSION
  export TF_VAR_db_user=$DB_USERNAME
  export TF_VAR_vpc_id=$VPC_ID

  if [ "$CLUSTER_NAME" = "prod" ]
  then
    export TF_VAR_multi_az=true
    export TF_VAR_skip_final_snapshot=false
  else
    export TF_VAR_multi_az=false
    export TF_VAR_skip_final_snapshot=true
  fi
  printf "  ✅ \n"

  echo "  b) Running 'terraform apply'. This can take up to 10 minutes…"
  cd db-setup
  terraform apply
  DB_URL=jdbc:postgresql://$(terraform output db_url):$DB_PORT/$DB_NAME
  cd ..
  if [ -z "$DB_URL" ]
  then
    echo "   ❌  Couldn't find DB URL. Looks like something went wrong :-/"
    exit 1
  else
    printf "\n"
    echo "  ✅  New DB URL: $DB_URL"
  fi
  printf "\n"

  printf "  c) Creating S3 bucket for terraform state…"
  DB_CONFIG_BUCKET=${PREFIX}.${CLUSTER_NAME}.db.terraform.config
  aws s3 ls | grep $DB_CONFIG_BUCKET > /dev/null
  if [ $? -eq 0 ]
  then
    printf "    ✅  Bucket already exists\n"
  else
    chronic aws s3api create-bucket \
      --bucket $DB_CONFIG_BUCKET \
      --region $AWS_REGION \
      --create-bucket-configuration LocationConstraint=$AWS_REGION

    chronic aws s3api put-bucket-versioning \
      --bucket $DB_CONFIG_BUCKET \
      --versioning-configuration Status=Enabled
    printf "  ✅\n"
  fi
  printf "\n"

  echo "  d) Encrypting terraform state…"
  cd db-setup
  openssl enc -aes-256-cbc -salt -in terraform.tfstate -out terraform.tfstate.enc
  cd ..
  printf "\n"

  printf "  e) Uploading terraform state to S3…"
  cd db-setup
  chronic aws s3 cp terraform.tfstate.enc s3://${DB_CONFIG_BUCKET}/terraform.tfstate.enc
  cd ..
  printf "  ✅\n"
  printf "\n"
fi


#######################
# CREATE K8 DB SECRET #
#######################

echo "8️⃣  Create kubernetes DB secret"
chronic kubectl config use-context $CLUSTER_URL
chronic kubectl get secrets | grep db-secret
if [ $? -eq 0 ]
then
  echo "   DB secret already exists, skipping creation"
else
  echo "   Create secret"
  chronic kubectl create secret generic db-secret \
    --from-literal=username=$DB_USERNAME \
    --from-literal=password=$DB_PASSWORD \
    --from-literal=url=$DB_URL
fi



#########
# Done! #
#########
echo "🏁  Finished!  🏁"
echo "    Your new database should be up and running in a few minutes!"
echo "    Check if the DB is ready with: aws rds describe-db-instances | jq -r --arg db $DB_IDENTIFIER  '.DBInstances[] | select(.DBInstanceIdentifier == \$db) | .DBInstanceStatus'"
