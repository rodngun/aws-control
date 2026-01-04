#!/bin/bash

# Script to safely pause/disable RodNGun EKS cluster
# This scales down workloads and node groups without deleting the cluster

set -e

# Configuration
CLUSTER_NAME="rodngun-eks"
REGION="us-east-1"
NAMESPACE="rodngun"

echo "========================================="
echo "RodNGun EKS Cluster Pause Script"
echo "========================================="
echo "This script will safely pause your EKS cluster to save costs"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

# Verify cluster exists
echo "Verifying cluster exists..."
if ! aws eks describe-cluster --name $CLUSTER_NAME --region $REGION &> /dev/null; then
    echo "Error: Cluster $CLUSTER_NAME not found in region $REGION"
    exit 1
fi

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# Function to scale down deployments
scale_down_deployments() {
    echo ""
    echo "Scaling down deployments in namespace: $1"
    kubectl get deployments -n $1 -o name | while read deployment; do
        echo "  Scaling down $deployment to 0 replicas..."
        kubectl scale $deployment -n $1 --replicas=0
    done
}

# Function to scale down statefulsets
scale_down_statefulsets() {
    echo ""
    echo "Scaling down statefulsets in namespace: $1"
    kubectl get statefulsets -n $1 -o name | while read statefulset; do
        echo "  Scaling down $statefulset to 0 replicas..."
        kubectl scale $statefulset -n $1 --replicas=0
    done
}

# Function to save current replica counts
save_replica_counts() {
    echo ""
    echo "Saving current replica counts for restoration..."
    
    # Create backup directory
    BACKUP_DIR="eks-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p $BACKUP_DIR
    
    # Save deployment replica counts
    kubectl get deployments --all-namespaces -o json > $BACKUP_DIR/deployments.json
    
    # Save statefulset replica counts
    kubectl get statefulsets --all-namespaces -o json > $BACKUP_DIR/statefulsets.json
    
    # Save node group configurations (both general and mongodb)
    for nodegroup_name in general-nodes mongodb-nodes; do
        aws eks describe-nodegroup \
            --cluster-name $CLUSTER_NAME \
            --nodegroup-name $nodegroup_name \
            --region $REGION > $BACKUP_DIR/nodegroup-$nodegroup_name.json 2>/dev/null || true
    done
    
    echo "Backup saved to: $BACKUP_DIR"
    echo ""
}

# Confirmation prompt
read -p "Are you sure you want to pause the EKS cluster? (yes/no): " confirm
if [[ $confirm != "yes" ]]; then
    echo "Operation cancelled"
    exit 0
fi

# Save current state
save_replica_counts

# Scale down application workloads
echo "========================================="
echo "Step 1: Scaling Down Workloads"
echo "========================================="

# Scale down RodNGun namespace
if kubectl get namespace $NAMESPACE &> /dev/null; then
    scale_down_deployments $NAMESPACE
    scale_down_statefulsets $NAMESPACE
else
    echo "Namespace $NAMESPACE not found, skipping..."
fi

# Scale down other common namespaces (adjust as needed)
for ns in default kube-system; do
    if [[ $ns == "kube-system" ]]; then
        echo ""
        echo "Note: Keeping kube-system components running for cluster management"
    else
        scale_down_deployments $ns
        scale_down_statefulsets $ns
    fi
done

# Scale down node groups
echo ""
echo "========================================="
echo "Step 2: Scaling Down Node Groups"
echo "========================================="

# Get all node groups
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION --query 'nodegroups[]' --output text)

if [ -z "$NODE_GROUPS" ]; then
    echo "No node groups found"
else
    for nodegroup in $NODE_GROUPS; do
        echo "Scaling down node group: $nodegroup"
        
        # MongoDB nodes need special handling - keep at least 1 node for data persistence
        if [[ "$nodegroup" == "mongodb-nodes" ]]; then
            echo "  Note: MongoDB node group will be scaled to minimum (1 node) to preserve data"
            aws eks update-nodegroup-config \
                --cluster-name $CLUSTER_NAME \
                --nodegroup-name $nodegroup \
                --scaling-config minSize=1,maxSize=1,desiredSize=1 \
                --region $REGION
            echo "Node group $nodegroup scaled to 1 instance (data preservation mode)"
        else
            # Scale general nodes to 0
            aws eks update-nodegroup-config \
                --cluster-name $CLUSTER_NAME \
                --nodegroup-name $nodegroup \
                --scaling-config minSize=0,maxSize=1,desiredSize=0 \
                --region $REGION
            echo "Node group $nodegroup scaled to 0 instances"
        fi
    done
fi

echo ""
echo "========================================="
echo "Step 3: Stopping EC2 Instances"
echo "========================================="

# Stop standalone EC2 instances (not part of node groups)
echo "Checking for standalone EC2 instances tagged with RodNGun..."

# Get running instances with RodNGun tags (excluding EKS managed instances)
INSTANCES=$(aws ec2 describe-instances \
    --region $REGION \
    --filters "Name=tag:Application,Values=rodngun" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?!Tags[?Key==`eks:nodegroup-name`]].InstanceId' \
    --output text)

if [ ! -z "$INSTANCES" ]; then
    echo "Found standalone EC2 instances to stop:"
    echo "$INSTANCES"
    
    # Save instance IDs to backup
    echo "$INSTANCES" > $BACKUP_DIR/ec2-instances.txt
    
    # Stop the instances
    echo "Stopping EC2 instances..."
    aws ec2 stop-instances --instance-ids $INSTANCES --region $REGION
    echo "EC2 instances stopped successfully"
else
    echo "No standalone EC2 instances found"
fi

echo ""
echo "========================================="
echo "Step 4: Scaling Down RDS Databases (if any)"
echo "========================================="

# Check for RDS instances
echo "Checking for RDS database instances..."
RDS_INSTANCES=$(aws rds describe-db-instances \
    --region $REGION \
    --query 'DBInstances[?contains(TagList[].Value, `rodngun`)].DBInstanceIdentifier' \
    --output text 2>/dev/null)

if [ ! -z "$RDS_INSTANCES" ]; then
    echo "Found RDS instances:"
    for db_instance in $RDS_INSTANCES; do
        echo "  - $db_instance"
        
        # Get current status
        STATUS=$(aws rds describe-db-instances \
            --db-instance-identifier $db_instance \
            --region $REGION \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text)
        
        if [ "$STATUS" == "available" ]; then
            echo "    Stopping RDS instance $db_instance..."
            aws rds stop-db-instance \
                --db-instance-identifier $db_instance \
                --region $REGION
            echo "    RDS instance stop initiated"
        else
            echo "    RDS instance is not in available state (current: $STATUS)"
        fi
    done
    
    # Save RDS instance list
    echo "$RDS_INSTANCES" > $BACKUP_DIR/rds-instances.txt
else
    echo "No RDS instances found"
fi

echo ""
echo "========================================="
echo "Step 5: Cost Savings Summary"
echo "========================================="
echo "✅ All deployments scaled to 0 replicas"
echo "✅ All statefulsets scaled to 0 replicas"
echo "✅ General node groups scaled to 0 instances"
echo "✅ MongoDB node group scaled to 1 instance (data preservation)"
[ ! -z "$INSTANCES" ] && echo "✅ EC2 instances stopped"
[ ! -z "$RDS_INSTANCES" ] && echo "✅ RDS databases stopped"
echo ""
echo "The following resources remain active (minimal cost):"
echo "  - EKS control plane (~$0.10/hour)"
echo "  - 1 MongoDB node (t3.large ~$0.08/hour for data persistence)"
echo "  - VPC and networking components"
echo "  - EBS volumes (storage costs only)"
echo ""
echo "Estimated savings: ~85-90% of total compute costs"
echo ""
echo "========================================="
echo "Restoration Instructions"
echo "========================================="
echo "To restore the cluster, run:"
echo "  ./restore_eks_cluster.sh $BACKUP_DIR"
echo ""
echo "Or manually scale up node groups:"
echo "  aws eks update-nodegroup-config \\"
echo "    --cluster-name $CLUSTER_NAME \\"
echo "    --nodegroup-name <nodegroup-name> \\"
echo "    --scaling-config minSize=1,maxSize=3,desiredSize=2 \\"
echo "    --region $REGION"
echo ""
echo "Cluster successfully paused!"