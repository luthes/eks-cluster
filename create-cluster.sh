#!/bin/bash
# This script creates an EKS Cluster with an Autoscaling group of nodes,
# The number if nodes is from 1-3.
# These commands are from various sources in the documentation:
#   https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html

CLUSTER_NAME=$1
NODE_COUNT=$2
CLEANUP=$3
SERVICE_ROLE_ARN=arn:aws:iam::905753290725:role/eksServiceRole

CONFIRM="n"
if [ "$CLEANUP" = "cleanup" ]
then
  read -p "Delete cluster and worker boxes? [yn] " CONFIRM 
  if [ "$CONFIRM" = "y" ]
  then
    printf "Deleting EKS Cluster\n"
    aws eks delete-cluster --name $CLUSTER_NAME 
    printf "Deleting Worker Cluster\n"
    aws cloudformation delete-stack --stack-name EKS-$CLUSTER_NAME-Worker-Nodes
    exit 0
  fi
fi


# Install AWS IAM Authenticator for Linux
# TODO Check for Mac?
printf "Installing AWS Authenticator for Linux\n"
curl -s -o aws-iam-authenticator https://amazon-eks.s3-us-west-2.amazonaws.com/1.10.3/2018-07-26/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-iam-authenticator
printf "\n"

DIRECTORY=$HOME/bin/

if [ ! -d "$DIRECTORY" ]
then
  printf "%s" "$DIRECTORY"
  mkdir $HOME/bin/
else
  printf "Directory %s exists, skipping...\n" "$DIRECTORY"
  printf "\n"
fi

cp ./aws-iam-authenticator $HOME/bin/aws-iam-authenticator
export PATH=$HOME/bin:$PATH

# Create Cluster
# Example Command:
# aws eks create-cluster --name devel --role-arn arn:aws:iam::111122223333:role/eks-service-role-AWSServiceRoleForAmazonEKS-EXAMPLEBKZRQR --resources-vpc-config subnetIds=subnet-a9189fe2,subnet-50432629,securityGroupIds=sg-f5c54184
#
# This creates the cluster in two private subnets, with the default allow all security group.
printf "Creating EKS Cluster, this could take up to 10 minutes."
aws eks create-cluster --name $CLUSTER_NAME --role-arn $SERVICE_ROLE_ARN --resources-vpc-config subnetIds=subnet-39d56240,subnet-037394b38c80a1a0c,securityGroupIds=sg-385c8c46 > /dev/null 2>&1
printf "\n"

CLUSTER_STATUS=$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.status | sed 's/"//g')
COUNTER=0
while [ "$CLUSTER_STATUS" = "CREATING" ]
do
  printf "Checking Cluster Status: %s - Time taken: %s\r" "$CLUSTER_STATUS" "$COUNTER"
  aws eks describe-cluster --name $CLUSTER_NAME --query cluster.status > /dev/null 2>&1
  CLUSTER_STATUS=$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.status | sed 's/"//g')
  sleep 1
  ((COUNTER++))
done

# Configure Kubectl to use EKS Cluster
printf "Updating kubeconfig\n"
aws eks update-kubeconfig --name $CLUSTER_NAME
printf "\n"

# Make sure it's working
printf "Testing kubeconfig\n"
kubectl get svc
printf "\n"

# Launch Worker Nodes
printf "Creating Worker Nodes from AWS provided CloudFormation Template"
aws cloudformation create-stack --stack-name EKS-$CLUSTER_NAME-Worker-Nodes \
  --template-url htpps://s3.amazonaws.com/amazon-eks/cloudformation/2018-08-30/amazon-eks-nodegroup.yaml \
  --parameters \
  ParameterKey=KeyName,ParameterValue=stevenluther-aws \
  ParameterKey=NodeImageId,ParameterValue=ami-0a54c984b9f908c81 \
  ParameterKey=NodeInstanceType,ParameterValue=t2.small \
  ParameterKey=NodeAutoScalingGroupMinSize,ParameterValue=1 \
  ParameterKey=NodeAutoScalingGroupMaxSize,ParameterValue=$NODE_COUNT \
  ParameterKey=NodeVolumeSize,ParameterValue=20 \
  ParameterKey=NodeGroupName,ParameterValue=$CLUSTER_NAME-worker-node-group \
  ParameterKey=ClusterName,ParameterValue=$CLUSTER_NAME \
  ParameterKey=ClusterControlPlaneSecurityGroup,ParameterValue=sg-385c8c46 \
  ParameterKey=VpcId,ParameterValue=vpc-94c689ed \
  ParameterKey=Subnets,ParameterValue=\"subnet-39d56240,subnet-037394b38c80a1a0c\" \
  --capabilities CAPABILITY_IAM > /dev/null 2>&1
printf "\n"

# Get Stack Info and wait for completion
COUNTER=0
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name EKS-$CLUSTER_NAME-Worker-Nodes \
  --query 'Stacks[0].{Status:StackStatus}' | grep Status | awk '{ print $2 }' | sed 's/"//g')
while [ "$STACK_STATUS" = "CREATE_IN_PROGRESS" ]
do
  printf "Checking Worker Node CFN Status: %s - Time Taken: %s\r" "$STACK_STATUS" "$COUNTER"
 #aws cloudformation describe-stacks --stack-name EKS-$CLUSTER_NAME-Worker-Nodes \
 #  --query 'Stacks[0].{Status:StackStatus}' | grep Status | awk '{ print $2 }' | sed 's/"//g'
  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name EKS-$CLUSTER_NAME-Worker-Nodes \
    --query 'Stacks[0].{Status:StackStatus}' | grep Status | awk '{ print $2 }' | sed 's/"//g')
  sleep 1
  ((COUNTER++))
done

# Join Worker Nodes to Cluster
# Worker Role ARN retrieved from CloudFormation stack output
WORKER_ROLE_ARN=$(aws cloudformation describe-stacks --stack-name EKS-$CLUSTER_NAME-Worker-Nodes --query 'Stacks[0].Outputs[0].{RoleArn:OutputValue}' | grep RoleArn | awk '{ print $2 }' | sed 's/"//g')

# Create aws-auth-cm.yaml
printf "Creating aws-auth-cm and applying\n"
cat << HEREDOC > ./aws-auth-cm-$CLUSTER_NAME.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $WORKER_ROLE_ARN
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
HEREDOC

# Appy Auth file to cluster
kubectl apply -f aws-auth-cm-$CLUSTER_NAME.yaml
rm aws-auth-cm-$CLUSTER_NAME.yaml

# Watch our nodes get added

COUNTER=0
NODE_STATUS=$(kubectl get nodes | grep NotReady)

while [ -z $NODE_STATUS ]
do
  if [ -z $NODE_STATUS ]
  then
    break 2
  else
    printf "Node Status: Not Ready - Time Taken: %s\r" "$COUNTER"
  fi 
  sleep 1
  ((COUNTER++))
done


# Install the Dashboard
printf "\nInstalling Dashboard\n"

printf "Deploying Dashboard to Cluster\n"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml
printf "\n"

printf "Deploying heapster to for cluster monitoring\n"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/heapster.yaml
printf "\n"

printf "Deploying influxdb for heapster\n"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/influxdb.yaml
printf "\n"

printf "Creating Heapster RBAC policy\n"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/rbac/heapster-rbac.yaml
printf "\n"

printf "Creating eks-admin Service Account\n"
kubectl apply -f eks-admin-service-account.yaml
printf "\n"

printf "Create eks-admin Role Binding\n"
kubectl apply -f eks-admin-cluster-role-binding.yaml
printf "\n"

printf "Get Secret Token for EKS admin user\n"
kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep eks-admin | awk '{print $1}')
printf "\n"

#TODO Add Storage Class. Try EBS and NFS(EFS hopefully?)
# https://docs.aws.amazon.com/eks/latest/userguide/storage-classes.html
kubectl create -f gp2-storage-class.yaml
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# TODO Init Helm
# This will require that Helm be installed, and the service account be added
# https://medium.com/@zhaimo/using-helm-to-install-application-onto-aws-eks-36840ff84555
kubectl create serviceaccount tiller --namespace kube-system
kubectl apply -f rbac-config.yaml
helm init --service-account tiller
kubectl get pods --namespace kube-system | grep tiller
helm repo update

PROXY_VAR="n"
read -p "Start kubectl proxy to access dashboard? [yn] " PROXY_VAR
if [ $PROXY_VAR = "y" ]
then
  echo $PROXY_VAR
  printf "Starting proxy. Dashboard URL: http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/\n"
  kubectl proxy
else
  printf "\n\nRun \`kubectl proxy\` to start proxy. Dashboard is located at this URL: http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/\n\n"
fi

CONFIRM="n"
if [ "$CLEANUP" = "cleanup" ]
then
  read -p "Delete cluster and worker boxes? [yn] " CONFIRM 
  if [ "$CONFIRM" = "y" ]
  then
    printf "Deleting EKS Cluster\n"
    aws eks delete-cluster --name $CLUSTER_NAME 
    printf "Deleting Worker Cluster\n"
    aws cloudformation delete-stack --stack-name EKS-$CLUSTER_NAME-Worker-Nodes
  fi
fi

