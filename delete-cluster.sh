#!/bin/bash

# Prerequisites (macOS):
# - aws cli => to create AWS resources
#   => pip install --upgrade --user awscli
#   => aws configure

# - jq => to parse JSON results returned by the AWS CLI
#   => brew install jq

# - chronic => to suppress output unless there's a non-zero exit code
#   => brew install moreutils

# - terraform => to destroy the DB on AWS
#   => brew install terraform

# - kops => to create the actual kubernetes cluster
#   => brew install kops

export PREFIX="chapati"
export URL="example.com"

echo "⚠️  WARNING ⚠️"
echo "You're about to delete a cluster"
echo "Please confirm, that you know what you're doing by writing 'i know what i am doing'"
read CONFIRM
if [ "$CONFIRM" = "i know what i am doing" ]
then
  echo "No risk no fun, huh? Alright, here we go…"
else
  echo "Cool, it's probably better this way :)"
  exit 1
fi
printf "\n"



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



###############################
# CLEAN UP ROUTE 53 RESOURCES #
###############################

echo "2️⃣  Clean Up Route53 Resources"
printf "   What's the subdomain associated with this cluster?\n"
printf "   e.g. 'development' or 'canary': "
read SUBDOMAIN
export CLUSTER_FQDN="$SUBDOMAIN.$URL"
export MAIN_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq -r --arg url $(echo "$URL.") '.HostedZones[] | select(.Name == $url) | .Id')
export CLUSTER_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq -r --arg url "$CLUSTER_FQDN." '.HostedZones[] | select(.Name == $url) | .Id')
export CLUSTER_NS_RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id $MAIN_HOSTED_ZONE_ID | jq -r --arg url "$CLUSTER_FQDN." '.ResourceRecordSets[] | select(.Name == $url) | .ResourceRecords')
export CLUSTER_A_RECORD=$(aws route53 list-resource-record-sets --hosted-zone-id $CLUSTER_HOSTED_ZONE_ID | jq -r --arg url "$CLUSTER_FQDN." '.ResourceRecordSets[] | select(.Type == "A") | .')
printf "\n"

printf "   a) Deleting NS records associated with cluster from main hosted zone…"
envsubst < templates/route53-delete-cluster-ns-records-from-main-hosted-zone.template.json > delete-cluster-ns-records-from-main-hosted-zone.json
chronic aws route53 change-resource-record-sets --hosted-zone-id $MAIN_HOSTED_ZONE_ID --change-batch file://delete-cluster-ns-records-from-main-hosted-zone.json
chronic rm delete-cluster-ns-records-from-main-hosted-zone.json
printf "  ✅ \n"

printf "   b) Deleting A record from hosted zone…"
envsubst < templates/route53-delete-cluster-records-from-hosted-zone.template.json > delete-cluster-records-from-hosted-zone.json
chronic aws route53 change-resource-record-sets --hosted-zone-id $CLUSTER_HOSTED_ZONE_ID --change-batch file://delete-cluster-records-from-hosted-zone.json
chronic rm delete-cluster-records-from-hosted-zone.json
printf "  ✅ \n"

printf "   c) Deleting hosted zone itself…"
chronic aws route53 delete-hosted-zone --id $CLUSTER_HOSTED_ZONE_ID
printf "  ✅ \n"
printf "\n"



###################
# DELETE DATABASE #
###################

echo "3️⃣  Delete Database"

DB_CONFIG_BUCKET=$PREFIX.$CLUSTER_NAME.db.terraform.config
printf "   a) Fetching DB terraform state from S3…"
chronic aws s3 cp s3://$DB_CONFIG_BUCKET/terraform.tfstate.enc .
printf "  ✅ \n"

printf "   b) Decrypting DB terraform state…"
chronic openssl enc -d -aes-256-cbc -salt -in terraform.tfstate.enc -out terraform.tfstate

echo "   c) Destroying DB…"
terraform destroy

printf "   d) Deleting terraform config S3 bucket…"
./helper/s3-delete-buckets.sh $DB_CONFIG_BUCKET
printf "  ✅ \n"

printf "   e) Clean up temp files…"
rm terraform.tfstate*
printf "  ✅ \n"
printf "\n"



#######################
# DELETE KOPS CLUSTER #
#######################

echo "4️⃣  Delete kops cluster"

CLUSTER_URL="k8-$CLUSTER_NAME.$URL"


printf "   a) Detaching autoscaling policy…"
ASG_NAME="nodes.$CLUSTER_URL"
ASG_POLICY_NAME=aws-cluster-autoscaler
ASG_POLICY_ARN=$(aws iam list-policies | jq -r --arg policy $ASG_POLICY_NAME '.Policies[] | select(.PolicyName == $policy) | .Arn')
aws iam detach-role-policy \
  --role-name $ASG_POLICY_NAME \
  --policy-arn $ASG_POLICY_ARN
printf "  ✅ \n"

printf "   b) Deleting kops cluster…"
KOPS_CONFIG_BUCKET=${PREFIX}.kops-${CLUSTER_NAME}.config
K8_CONFIG_BUCKET=${PREFIX}.k8-${CLUSTER_NAME}.config
kops delete cluster \
  --state s3://${KOPS_CONFIG_BUCKET} \
  --name ${CLUSTER_URL} \
  --yes
printf "\n"



############################
# DELETE S3 CONFIG BUCKETS #
############################

echo "5️⃣  Delete S3 config buckets"

printf "   a) Deleting kubernetes config S3 bucket…"
./helper/s3-delete-buckets.sh $K8_CONFIG_BUCKET
printf "  ✅ \n"

printf "   b) Deleting kops config S3 bucket…"
./helper/s3-delete-buckets.sh $KOPS_CONFIG_BUCKET
printf "  ✅ \n"
printf "\n"



#########
# Done! #
#########
echo "🏁  Finished!  🏁"
echo "    All cluster resources have been cleared"
