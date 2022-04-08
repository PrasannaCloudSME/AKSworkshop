#!/bin/bash

#######################
# __   ___ __ ___
# \ \ / / '_ ` _ \
#  \ V /| | | | | |
#   \_/ |_| |_| |_|
# Deployment
#######################

# Create jumpbox virtual machine
# Command: COMPUTE-1
vm_id=$(az vm create \
  --resource-group $resource_group_name  \
  --name $vm_name \
  --image UbuntuLTS \
  --size Standard_DS2_v2 \
  --public-ip-address "" \
  --subnet $vnet_hub_management_subnet_id \
  --admin-username $vm_username \
  --admin-password $vm_password \
  --query id -o tsv)

# QUESTION:
# ---------
# Can you access jumpbox virtual machine?
#

# Create Bastion
# Command: COMPUTE-2
az network public-ip create --resource-group $resource_group_name --name $bastion_public_ip --sku Standard --location $location
bastion_id=$(az network bastion create --name $bastion_name --public-ip-address $bastion_public_ip --resource-group $resource_group_name --vnet-name $vnet_hub_name --location $location --query id -o tsv)
az resource update --ids $bastion_id --set properties.enableTunneling=true

###################
#          _ 
#  ___ ___| |__
# / __/ __| '_ \
# \__ \__ \ | | |
# |___/___/_| |_|
# to jumpbox 
###################
# Connect to a VM using Bastion and the native client on your Windows computer
# https://docs.microsoft.com/en-us/azure/bastion/connect-native-client-windows

echo $vm_password
# Command: COMPUTE-3
az network bastion ssh --name $bastion_name --resource-group $resource_group_name --target-resource-id $vm_id --auth-type "password" --username $vm_username

# Exit jumpbox
exit

#######################################
#     _     ____  ___
#    / \   / ___||_ _|
#   / _ \ | |     | |
#  / ___ \| |___  | |
# /_/   \_\\____||___|
# Azure Container Instances deployment
#######################################

# Command: COMPUTE-4
aci_ip=$(az container create \
  --name $aci_name \
  --image "jannemattila/webapp-network-tester" \
  --ports 80 \
  --cpu 1 \
  --memory 1 \
  --resource-group $resource_group_name \
  --restart-policy Always \
  --ip-address Private \
  --subnet $vnet_spoke1_front_subnet_id \
  --query ipAddress.ip -o tsv)
echo $aci_ip

#######################################
#     _     _  __ ____
#    / \   | |/ // ___|
#   / _ \  | ' / \___ \
#  / ___ \ | . \  ___) |
# /_/   \_\|_|\_\|____/
# Azure Kubernetes Service deployment
#######################################

# Create identity for AKS
# Command: COMPUTE-5
aks_identity_id=$(az identity create --name $aks_identity_name --resource-group $resource_group_name --query id -o tsv)
echo $aks_identity_id

# Find Azure AD Group for AKS Admins
# Command: COMPUTE-6
aks_azure_ad_admin_group_object_id=$(az ad group list --display-name $aks_azure_ad_admin_group_contains --query [].objectId -o tsv)
echo $aks_azure_ad_admin_group_object_id

# Create Log Analytics workspace for our AKS
# Command: COMPUTE-7
aks_workspace_id=$(az monitor log-analytics workspace create -g $resource_group_name -n $aks_workspace_name --query id -o tsv)
echo $aks_workspace_id

# Create Container Registry
# Command: COMPUTE-8
acr_id=$(az acr create -l $location -g $resource_group_name -n $acr_name --sku Basic --query id -o tsv)
echo $acr_id

# See all available Kubernetes versions
# Command: COMPUTE-9
az aks get-versions -l $location -o table

# Note: for public cluster you need to authorize your ip to use api
# Command: COMPUTE-10
my_ip=$(curl --no-progress-meter https://api.ipify.org)
echo $my_ip

# Note about private clusters:
# https://docs.microsoft.com/en-us/azure/aks/private-clusters
#
# For private cluster add these:
#  --enable-private-cluster
#  --private-dns-zone None|System|BYOD

# Command: COMPUTE-11
az aks create -g $resource_group_name -n $aks_name \
 --max-pods 50 --network-plugin azure \
 --node-count 2 --enable-cluster-autoscaler --min-count 2 --max-count 4 \
 --node-osdisk-type Ephemeral \
 --node-vm-size Standard_D8ds_v4 \
 --kubernetes-version 1.22.6 \
 --enable-addons monitoring,azure-policy,azure-keyvault-secrets-provider \
 --enable-aad \
 --enable-managed-identity \
 --disable-local-accounts \
 --aad-admin-group-object-ids $aks_azure_ad_admin_group_object_id \
 --workspace-resource-id $aks_workspace_id \
 --attach-acr $acr_id \
 --load-balancer-sku standard \
 --vnet-subnet-id $vnet_spoke2_aks_subnet_id \
 --assign-identity $aks_identity_id \
 --api-server-authorized-ip-ranges $my_ip \
 -o table 

# QUESTION:
# ---------
# How is AKS Identity connected to ACR?
#

# Note: In case your own ip changes, 
# then you need to update it in order to access Kubernetes api server
# Command: COMPUTE-12
az aks update -g $resource_group_name -n $aks_name --api-server-authorized-ip-ranges $my_ip

# Install kubectl
# Command: COMPUTE-13
sudo az aks install-cli

# Get credentials, so that you can access Kubernetes api server
# Command: COMPUTE-14
az aks get-credentials -n $aks_name -g $resource_group_name --overwrite-existing

# Test connectivity to Kubernetes
# Command: COMPUTE-15
kubectl get nodes

# Deploy simple network test application
# Command: COMPUTE-16
kubectl apply -f network-app/

# Validate
# Command: COMPUTE-17
kubectl get deployment -n network-app
kubectl get service -n network-app
kubectl get pod -n network-app -o custom-columns=NAME:'{.metadata.name}',NODE:'{.spec.nodeName}'

network_app_pod1=$(kubectl get pod -n network-app -o name | head -n 1)
echo $network_app_pod1

network_app_pod1_ip=$(kubectl get pod -n network-app -o name -o jsonpath="{.items[0].status.podIPs[0].ip}")
echo $network_app_pod1_ip

network_app_external_svc_ip=$(kubectl get service network-app-external-svc -n network-app -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
echo $network_app_external_svc_ip

network_app_internal_svc_ip=$(kubectl get service network-app-internal-svc -n network-app -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
echo $network_app_internal_svc_ip

curl $network_app_external_svc_ip
# -> <html><body>Hello there!</body></html>

curl $network_app_internal_svc_ip
# -> Timeout (no private connectivity)
