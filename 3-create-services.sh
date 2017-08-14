#!/bin/bash

# Prerequisites (macOS)
# - ./1-create-cluster.sh needs to have been executed successfully, otherwise we don't have a cluster to work with here
#
# - ./2-create-database.sh needs to have been executed successfully, otherwise we don't have a database for the API services
#
# - envsubst
#   => brew install gettext

# - chronic => to suppress output unless there's a non-zero exit code
#   => brew install moreutils
#
# - kubectl
#   => brew install kubernetes-cli
#
# - helm
#   => brew install kubernetes-helm

export PREFIX="chapati"
export URL="example.com"
export DOCKER_REGISTRY_URL="<your-aws-id>.dkr.ecr.eu-central-1.amazonaws.com"
export AWS_REGION="eu-central-1"
export LETS_ENCRYPT_EMAIL="your@email.com"
export API_SERVICES=( products offers orders )
export FRONTEND_SERVICES=( shop admin )


####################
# SPECIFY CLUSTER #
###################

printf "1️⃣  Please specify the cluster name (e.g. 'canary', or 'dev'): "
read CLUSTER_NAME
export CLUSTER_NAME=$CLUSTER_NAME
export CLUSTER_URL="k8-$CLUSTER_NAME.$URL"
printf "\n\n"

echo "2️⃣  Initialize helm"
chronic helm init
printf "\n"



################################
# SET UP SUBDOMAIN IN ROUTE 53 #
################################

echo "2️⃣  Create subdomain for cluster in Route53"
echo "   What should the subdomain for this cluster be?"
printf "   e.g. 'development' or 'canary': "
read SUBDOMAIN
export CLUSTER_FQDN="$SUBDOMAIN.$URL"
printf "\n"

printf "   a) Creating new hosted zone for cluster…"
export EXISTING_HOSTED_ZONE=$(aws route53 list-hosted-zones-by-name | jq -r --arg url $(echo "$CLUSTER_FQDN.") '.HostedZones[] | select(.Name == $url) | .Id')

if [ "$EXISTING_HOSTED_ZONE" = "" ]
then
  export CLUSTER_HOSTED_ZONE_ID=$(aws route53 create-hosted-zone --name $SUBDOMAIN.$URL --caller-reference "`date`" | jq -r '.HostedZone.Id')
else
  export CLUSTER_HOSTED_ZONE_ID=$EXISTING_HOSTED_ZONE
fi
printf "  ✅ \n"

printf "   b) Adding NS records from new hosted zone to main hosted zone…"
export MAIN_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq -r --arg url $(echo "$URL.") '.HostedZones[] | select(.Name == $url) | .Id')
export CLUSTER_NS_RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id $CLUSTER_HOSTED_ZONE_ID | jq '.ResourceRecordSets[] | select(.Type == "NS") | .ResourceRecords')
envsubst < templates/route53-add-cluster-ns-records-to-main-hosted-zone.template.json > add-cluster-ns-records-to-main-hosted-zone.json
chronic aws route53 change-resource-record-sets --hosted-zone-id $MAIN_HOSTED_ZONE_ID --change-batch file://add-cluster-ns-records-to-main-hosted-zone.json
chronic rm add-cluster-ns-records-to-main-hosted-zone.json
printf "  ✅ \n"
printf "\n"



##############################
# CREATE KUBERNETES SERVICES #
##############################

echo "3️⃣  Create kubernetes deployments and services"
printf "   a) Setting kubectl context to ${CLUSTER_URL}…"
chronic kubectl config set-context $CLUSTER_URL
printf " ✅ \n"

printf "   b) Creating API services…"
for SERVICE in "${API_SERVICES[@]}"
do
  export TIER=backend
  export SERVICE_NAME=${PREFIX}-${SERVICE}-api
  envsubst < ./templates/service-api.template.yml | chronic kubectl apply -f -
  chronic kubectl autoscale deployment ${PREFIX}-${SERVICE}-api --cpu-percent=200 --min=1 --max=20
done
printf " ✅ \n"


printf "   c) Creating frontend services…"
for SERVICE in "${FRONTEND_SERVICES[@]}"
do
  export TIER=frontend
  export SERVICE_NAME=${PREFIX}-${SERVICE}
  envsubst < ./templates/service-frontend.template.yml | chronic kubectl apply -f -
  chronic kubectl autoscale deployment ${PREFIX}-${SERVICE} --cpu-percent=80 --min=1 --max=20
done
printf " ✅ \n"

printf "   d) Creating ingress controller…"
chronic helm install stable/nginx-ingress --set controller.image.tag=0.9.0-beta.7
chronic rm nginx-ingress-*.tgz
printf " ✅ \n"
printf "\n"


printf "   e) Creating ingress rules…"
envsubst < ./templates/frontend-ingress.template.yml | chronic kubectl apply -f -
printf " ✅ \n"
printf "\n"



##############
# SET UP SSL #
##############

echo "5️⃣  Set up SSL via letsencrypt.org"
echo "   a) Waiting for helm to finish bootstrapping…"

COUNTER=0
while [  $COUNTER -lt 30 ]; do
  let COUNTER=COUNTER+1
  TOTAL_TILLER_PODS=$(kubectl get pods --namespace=kube-system | grep tiller-deploy | wc -l)
  READY_TILLER_PODS=$(kubectl get pods --namespace=kube-system | grep tiller-deploy | grep Running | wc -l)
  echo "      Check #${COUNTER}: $TOTAL_TILLER_PODS Total Tiller Pods — $READY_TILLER_PODS Ready Tiller Pods"
  if [ "$TOTAL_TILLER_PODS" -eq "$READY_TILLER_PODS" ]; then
    echo "      ✅  helm is ready to go!"
    break
  else
    sleep 10
    false
  fi
done


printf "   b) Installing helm chart 'kube-lego'…"
chronic helm install stable/kube-lego \
    --set config.LEGO_EMAIL=$LETS_ENCRYPT_EMAIL \
    --set config.LEGO_URL=https://acme-v01.api.letsencrypt.org/directory \
    --set config.LEGO_PORT=8080
chronic rm kube-lego-*.tgz
printf " ✅ \n"
printf "\n"



################################
# SET UP KUBERNETES MONITORING #
################################

echo "6️⃣  Set up Kubernetes Monitoring"

printf "   a) Installing kubernetes dashboard…"
chronic kubectl create -f https://raw.githubusercontent.com/kubernetes/kops/master/addons/kubernetes-dashboard/v1.6.0.yaml
printf " ✅ \n"

printf "   b) Installing kube-ops-view…"
chronic helm install stable/kube-ops-view
rm kube-ops-view-*.tgz
printf " ✅ \n"

printf "   c) Installing heapster…"
chronic kubectl create -f https://raw.githubusercontent.com/kubernetes/kops/master/addons/monitoring-standalone/v1.6.0.yaml
printf " ✅ \n"

printf "   d) Installing ELK stack…"
chronic kubectl create -f https://raw.githubusercontent.com/kubernetes/kops/master/addons/logging-elasticsearch/v1.5.0.yaml
printf " ✅ \n"
printf "\n"



######################
# SET UP AUTOSCALING #
######################

echo "7️⃣  Set up Autoscaling"

echo "   First, we need to update the minSize and maxSize attributes for the kops instancegroup."
echo "   The next command will open the instancegroup config in your default editor, please save and exit the file once you're done…"
KOPS_CONFIG_BUCKET=${PREFIX}.kops-${CLUSTER_NAME}.config
kops edit ig nodes --state s3://${KOPS_CONFIG_BUCKET} --name ${CLUSTER_URL}
kops update cluster --yes --state s3://${KOPS_CONFIG_BUCKET} --name ${CLUSTER_URL}
printf "\n"


printf "   a) Creating IAM policy to allow aws-cluster-autoscaler access to AWS autoscaling groups…"
# Unfortunately AWS does not support ARNs for autoscaling groups yet so you must use "*" as the resource.
cat > asg-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup"
            ],
            "Resource": "*"
        }
    ]
}
EOF

ASG_POLICY_NAME=aws-cluster-autoscaler
chronic aws iam list-policies | jq -r '.Policies[] | select(.PolicyName == "aws-cluster-autoscaler") | .Arn'
if [ $? -eq 0 ]
then
  printf " ✅  Policy already exists\n"
  ASG_POLICY_ARN=$(aws iam list-policies | jq -r '.Policies[] | select(.PolicyName == "aws-cluster-autoscaler") | .Arn')
else
  ASG_POLICY=$(aws iam create-policy --policy-name $ASG_POLICY_NAME --policy-document file://asg-policy.json)
  ASG_POLICY_ARN=$(echo $ASG_POLICY | jq -r '.Policy.Arn')
  printf " ✅ \n"
fi


printf "   b) Attaching policy to nodes role…"
ASG_NAME="nodes.$CLUSTER_URL"
chronic aws iam attach-role-policy --policy-arn $ASG_POLICY_ARN --role-name $ASG_NAME
printf " ✅ \n"


printf "   c) Installing aws-cluster-autoscaler…"
CLOUD_PROVIDER=aws
IMAGE=gcr.io/google_containers/cluster-autoscaler:v0.5.4
MIN_NODES=3
MAX_NODES=12
SSL_CERT_PATH="/etc/ssl/certs/ca-certificates.crt"

addon=cluster-autoscaler.yml
chronic curl -o ${addon} https://raw.githubusercontent.com/kubernetes/kops/master/addons/cluster-autoscaler/v1.6.0.yaml

sed -i -e "s@{{CLOUD_PROVIDER}}@${CLOUD_PROVIDER}@g" "${addon}"
sed -i -e "s@{{IMAGE}}@${IMAGE}@g" "${addon}"
sed -i -e "s@{{MIN_NODES}}@${MIN_NODES}@g" "${addon}"
sed -i -e "s@{{MAX_NODES}}@${MAX_NODES}@g" "${addon}"
sed -i -e "s@{{GROUP_NAME}}@${ASG_NAME}@g" "${addon}"
sed -i -e "s@{{AWS_REGION}}@${AWS_REGION}@g" "${addon}"
sed -i -e "s@{{SSL_CERT_PATH}}@${SSL_CERT_PATH}@g" "${addon}"

chronic kubectl apply -f ${addon}
printf " ✅ \n"

printf "   d) Cleaning up temp files…"
chronic rm cluster-autoscaler.yml*
chronic rm asg-policy.json
printf " ✅ \n"
printf "\n"



##############################
# CONNECT SUBDOMAIN TO NGINX #
##############################

echo "8️⃣  Connect Cluster Subdomain with Nginx Ingress"

printf "   a) Fetching Nginx IP…"
export NGINX_SERVICE=$(kubectl get services | grep -o '[a-z-]*nginx-ingress-controller')
export NGINX_INGRESS_IP_STRING=`kubectl describe service ${NGINX_SERVICE} | grep "LoadBalancer Ingress:"`
export NGINX_INGRESS_URL_RAW="${NGINX_INGRESS_IP_STRING/LoadBalancer Ingress:/}"
export NGINX_INGRESS_URL=$(echo ${NGINX_INGRESS_URL_RAW//[[:blank:]]/})
printf "  ✅ \n"

printf "   b) Adding A record…"
export NGINX_INGRESS_HOSTED_ZONE_ID=$(aws elb describe-load-balancers | jq -r --arg url $NGINX_INGRESS_URL '.LoadBalancerDescriptions[] | select(.DNSName == $url) | .CanonicalHostedZoneNameID')
envsubst < templates/route53-add-a-record-for-nginx.template.json > add-a-record-for-nginx.json
chronic aws route53 change-resource-record-sets --hosted-zone-id $CLUSTER_HOSTED_ZONE_ID --change-batch file://add-a-record-for-nginx.json
chronic rm add-a-record-for-nginx.json
printf "  ✅ \n"
printf "\n"



#########
# Done! #
#########

printf "\n💪   Ready to roll!!"
printf "\n    After a few minutes your cluster should be available at $CLUSTER_FQDN"
