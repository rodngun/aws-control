#!/bin/bash

# Script to check the status of RodNGun EKS cluster

# Configuration
CLUSTER_NAME="rodngun-eks"
REGION="us-east-1"

echo "========================================="
echo "RodNGun EKS Cluster Status Check"
echo "========================================="
echo ""

# Check cluster status
echo "Cluster Information:"
echo "-------------------"
aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --region $REGION \
    --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' \
    --output table 2>/dev/null || echo "Cluster not found"

echo ""
echo "Node Groups:"
echo "------------"
aws eks list-nodegroups \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --output table 2>/dev/null || echo "No node groups found"

# Get node group details
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION --query 'nodegroups[]' --output text 2>/dev/null)
if [ ! -z "$NODE_GROUPS" ]; then
    for nodegroup in $NODE_GROUPS; do
        echo ""
        echo "Node Group: $nodegroup"
        
        # Get scaling config and instance types
        aws eks describe-nodegroup \
            --cluster-name $CLUSTER_NAME \
            --nodegroup-name $nodegroup \
            --region $REGION \
            --query 'nodegroup.{ScalingConfig:scalingConfig,InstanceTypes:instanceTypes,Status:status}' \
            --output json 2>/dev/null | jq '.'
        
        # Show special note for MongoDB nodes
        if [[ "$nodegroup" == "mongodb-nodes" ]]; then
            echo "  Note: MongoDB nodes run database workloads with persistent storage"
        fi
    done
fi

# If kubectl is configured, show kubernetes resources
if command -v kubectl &> /dev/null; then
    if aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION &> /dev/null; then
        echo ""
        echo "Kubernetes Resources:"
        echo "--------------------"
        echo "Nodes:"
        kubectl get nodes 2>/dev/null || echo "No nodes available"
        
        echo ""
        echo "Deployments (all namespaces):"
        kubectl get deployments --all-namespaces 2>/dev/null | head -10
        
        echo ""
        echo "Pods (running):"
        kubectl get pods --all-namespaces --field-selector=status.phase=Running 2>/dev/null | wc -l | xargs echo "Running pods:"
    fi
fi

echo ""
echo "========================================="
echo "EC2 Instances (Non-EKS):"
echo "========================================="

# Check for standalone EC2 instances
INSTANCES=$(aws ec2 describe-instances \
    --region $REGION \
    --filters "Name=tag:Application,Values=rodngun" \
    --query 'Reservations[].Instances[?!Tags[?Key==`eks:nodegroup-name`]].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
    --output table 2>/dev/null)

if [ ! -z "$INSTANCES" ]; then
    echo "$INSTANCES"
else
    echo "No standalone EC2 instances found"
fi

echo ""
echo "========================================="
echo "RDS Database Instances:"
echo "========================================="

# Check for RDS instances
RDS_OUTPUT=$(aws rds describe-db-instances \
    --region $REGION \
    --query 'DBInstances[?contains(TagList[].Value, `rodngun`)].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus,AllocatedStorage]' \
    --output table 2>/dev/null)

if [ ! -z "$RDS_OUTPUT" ] && [ "$RDS_OUTPUT" != "None" ]; then
    echo "$RDS_OUTPUT"
else
    echo "No RDS instances found"
fi

echo ""
echo "========================================="
echo "Cost Estimation:"
echo "========================================="

# Calculate approximate costs based on node types
echo "Calculating costs based on node groups..."

# Get instance counts and types
GENERAL_NODES=0
MONGODB_NODES=0
EC2_INSTANCES=0
RDS_INSTANCES_COUNT=0

if [ ! -z "$NODE_GROUPS" ]; then
    for nodegroup in $NODE_GROUPS; do
        DESIRED=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $nodegroup --region $REGION --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null || echo 0)
        if [[ "$nodegroup" == "mongodb-nodes" ]]; then
            MONGODB_NODES=$DESIRED
        elif [[ "$nodegroup" == "general-nodes" ]]; then
            GENERAL_NODES=$DESIRED
        fi
    done
fi

# Count running EC2 instances
EC2_INSTANCES=$(aws ec2 describe-instances \
    --region $REGION \
    --filters "Name=tag:Application,Values=rodngun" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?!Tags[?Key==`eks:nodegroup-name`]].InstanceId' \
    --output text 2>/dev/null | wc -w)

# Count active RDS instances
RDS_INSTANCES_COUNT=$(aws rds describe-db-instances \
    --region $REGION \
    --query 'DBInstances[?contains(TagList[].Value, `rodngun`) && DBInstanceStatus==`available`].DBInstanceIdentifier' \
    --output text 2>/dev/null | wc -w)

echo "Resource Summary:"
echo "  - General EKS nodes (t3.medium): $GENERAL_NODES"
echo "  - MongoDB EKS nodes (t3.large): $MONGODB_NODES"
echo "  - Standalone EC2 instances: $EC2_INSTANCES"
echo "  - RDS database instances: $RDS_INSTANCES_COUNT"
echo ""
echo "Estimated hourly cost:"
echo "  - EKS control plane: ~\$0.10/hour"
echo "  - General nodes ($GENERAL_NODES x t3.medium): ~\$$(printf "%.2f" $(echo "$GENERAL_NODES * 0.0416" | bc -l))/hour"
echo "  - MongoDB nodes ($MONGODB_NODES x t3.large): ~\$$(printf "%.2f" $(echo "$MONGODB_NODES * 0.0832" | bc -l))/hour"
echo "  - EC2 instances ($EC2_INSTANCES x ~t3.medium): ~\$$(printf "%.2f" $(echo "$EC2_INSTANCES * 0.0416" | bc -l))/hour"
echo "  - RDS instances ($RDS_INSTANCES_COUNT x ~db.t3.micro): ~\$$(printf "%.2f" $(echo "$RDS_INSTANCES_COUNT * 0.018" | bc -l))/hour"

TOTAL_HOURLY=$(echo "0.10 + $GENERAL_NODES * 0.0416 + $MONGODB_NODES * 0.0832 + $EC2_INSTANCES * 0.0416 + $RDS_INSTANCES_COUNT * 0.018" | bc -l)
echo "  - Total: ~\$$(printf "%.2f" $TOTAL_HOURLY)/hour"
echo ""
MONTHLY=$(echo "$TOTAL_HOURLY * 730" | bc -l)
echo "Monthly estimate (730 hours): ~\$$(printf "%.0f" $MONTHLY)"

# Show savings if cluster is paused
if [ "$GENERAL_NODES" -eq 0 ] && [ "$EC2_INSTANCES" -eq 0 ] && [ "$RDS_INSTANCES_COUNT" -eq 0 ]; then
    echo ""
    echo "🎉 Cluster is in PAUSED state - saving ~85-90% on compute costs!"
fi