#!/bin/bash

# Prerequisites (macOS):
# - aws cli => to create AWS resources
#   => pip install --upgrade --user awscli
#   => aws configure

# - jq => to parse JSON results returned by the AWS CLI
#   => brew install jq

# - chronic => to suppress output unless there's a non-zero exit code
#   => brew install moreutils

# - kops => to create the actual kubernetes cluster
#   => brew install kops

export PREFIX="chapati"
export URL="example.com"
export AWS_REGION="eu-central-1"


####################
# SPECIFY CLUSTER #
###################

printf "1️⃣  Please specify a cluster name (e.g. 'canary', or 'dev'): "
read CLUSTER_NAME
printf "\n"

if [ "$CLUSTER_NAME" != "canary" ] &&  [ "$CLUSTER_NAME" != "dev" ]
then
  echo "Sorry, but I can only help you with the 'dev' and 'canary' clusters right now"
  exit 1
fi
printf "\n"



################################
# Generate SSH key for cluster #
################################

echo "2️⃣  Let's generate a new SSH key for this cluster"
ssh-keygen -t rsa -f ${PREFIX}-${CLUSTER_NAME}
export PUBLIC_SSH_KEY=./${PREFIX}-${CLUSTER_NAME}.pub
printf "\n"
echo "  🔑  Awesome, now please put the private key into our 1password team vault"
printf "  Type 'done' to confirm that you safely stored the private key in the team vault: "
read CONFIRM
printf "\n"

if [ "$CONFIRM" != "done" ]
then
  echo "❗️ Ok, one more chance: Type 'done' to confirm you've stored the private ssh key in the 1password team vault"
  read CONFIRM
fi

if [ "$CONFIRM" != "done" ]
then
  echo "❌  Aborting, you've had your chance…"
  exit 1
fi

echo "  Cool, now let's go create a cluster!"
printf "\n"



#####################
# Create S3 Buckets #
#####################

echo "3️⃣  Create S3 buckets for kops and kubernetes config"
printf "  a) Creating S3 bucket for kops config…"
KOPS_CONFIG_BUCKET=${PREFIX}.kops-${CLUSTER_NAME}.config
aws s3 ls | grep $KOPS_CONFIG_BUCKET > /dev/null
if [ $? -eq 0 ]
then
  printf "    ✅  Bucket already exists\n"
else
  chronic aws s3api create-bucket \
    --bucket $KOPS_CONFIG_BUCKET \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=${AWS_REGION}

  chronic aws s3api put-bucket-versioning \
    --bucket $KOPS_CONFIG_BUCKET \
    --versioning-configuration Status=Enabled
  printf "  ✅\n"
fi

printf "  b) Creating S3 bucket for kubernetes config…"
K8_CONFIG_BUCKET=${PREFIX}.k8-${CLUSTER_NAME}.config
aws s3 ls | grep $K8_CONFIG_BUCKET > /dev/null
if [ $? -eq 0 ]
then
  printf "    ✅  Bucket already exists\n"
else
  chronic aws s3api create-bucket \
    --bucket $K8_CONFIG_BUCKET \
    --region $AWS_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_REGION

  chronic aws s3api put-bucket-versioning \
    --bucket $K8_CONFIG_BUCKET \
    --versioning-configuration Status=Enabled
  printf "  ✅\n"
fi
printf "\n"



########################
# Create IAM Resources #
########################
echo "4️⃣  Create IAM user and group for kops"
printf "  a) Creating IAM group for kops…"
aws iam list-groups | grep kops > /dev/null
if [ $? -eq 0 ]
then
  printf "  ✅  IAM group 'kops' already exisst\n"
else
  chronic aws iam create-group --group-name kops
  printf "  ✅\n"
fi

printf "  b) Attaching IAM policies to kops usergroup…"
export policies="
AmazonEC2FullAccess
AmazonRoute53FullAccess
AmazonS3FullAccess
IAMFullAccess
AmazonVPCFullAccess"

NEW_POLICY_CREATED=false
for policy in $policies; do
  ARN_EXISTS=$(aws iam list-attached-group-policies --group-name kops | jq --arg policy $policy '.AttachedPolicies[] | select(.PolicyName == $policy) | .PolicyName' > /dev/null)
  if [ "$ARN_EXISTS" = "null" ]
  then
    aws iam attach-group-policy --policy-arn "arn:aws:iam::aws:policy/$policy" --group-name kops;
    $NEW_POLICY_CREATED=true
  fi
done
if [ "$NEW_POLICY_CREATED" = true ]
then
  printf "  ✅\n"
else
  printf "  ✅  Policies already exist\n"
fi

printf "  c) Creating IAM user for kops…"
aws iam list-users | grep kops > /dev/null
if [ $? -eq 0 ]
then
  printf "  ✅  IAM user 'kops' already exists\n"
else
  aws iam create-user --user-name kops
  aws iam add-user-to-group --user-name kops --group-name kops
  aws iam create-access-key --user-name kops
  printf "  ✅\n"
fi
printf "\n"



#######################
# Create kops cluster #
#######################
echo "5️⃣  Create new kops cluster"
export CLUSTER_URL="k8-$CLUSTER_NAME.$URL"
kops create cluster \
  --state s3://${KOPS_CONFIG_BUCKET} \
  --ssh-public-key $PUBLIC_SSH_KEY \
  --cloud aws \
  --zones ${AWS_REGION}a \
  --topology private \
  --networking calico \
  --network-cidr=10.0.0.0/16 \
  --bastion \
  --master-size m3.medium \
  --node-size m3.medium \
  --node-count 3 \
  --yes \
  $CLUSTER_URL
printf "\n"
echo "  ✅  Successfully kicked off cluster creation"
printf "o\n"



#####################
# Export kubeconfig #
#####################
echo "6️⃣  Export kubeconfig from new cluster"
# To export the kubectl configuration to a specific file we need to
# set the KUBECONFIG environment variable.
# see `kops export kubecfg --help` for further information
export KUBECONFIG=./kubeconfig
chronic kops export kubecfg $CLUSTER_URL --state=s3://${KOPS_CONFIG_BUCKET}
printf "\n"



######################
# Encrypt kubeconfig #
######################
echo "7️⃣  Encrypt kubeconfig with OpenSSL"
openssl enc -aes-256-cbc -salt -in kubeconfig -out kubeconfig.enc
printf "\n"



#####################
# Upload kubeconfig #
#####################
echo "8️⃣  Upload encrypted kubeconfig to S3"
chronic aws s3 cp kubeconfig.enc s3://${K8_CONFIG_BUCKET}/kubeconfig.enc
printf "\n\n"



#########
# Done! #
#########
echo "🏁  Finished!  🏁"
echo "   It will take 10-15mins until your cluster is fully functional"
echo "   You can see if the cluster is ready by running 'kops validate cluster --state s3://${KOPS_CONFIG_BUCKET} --name ${CLUSTER_URL}'"

