#!/bin/bash

# Script to restore RodNGun EKS cluster from paused state

set -e

# Configuration
CLUSTER_NAME="rodngun-eks"
REGION="us-east-1"
BACKUP_DIR=$1

echo "========================================="
echo "RodNGun EKS Cluster Restoration Script"
echo "========================================="
echo "This script will restore your EKS cluster from paused state"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""

# Check if backup directory provided
if [ -z "$BACKUP_DIR" ]; then
    echo "Usage: ./restore_eks_cluster.sh <backup-directory>"
    echo ""
    echo "Available backups:"
    ls -d eks-backup-* 2>/dev/null || echo "No backups found"
    exit 1
fi

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory $BACKUP_DIR not found"
    exit 1
fi

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# Confirmation prompt
read -p "Are you sure you want to restore the EKS cluster? (yes/no): " confirm
if [[ $confirm != "yes" ]]; then
    echo "Operation cancelled"
    exit 0
fi

echo ""
echo "========================================="
echo "Step 1: Scaling Up Node Groups"
echo "========================================="

# Get all node groups
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION --query 'nodegroups[]' --output text)

if [ -z "$NODE_GROUPS" ]; then
    echo "No node groups found to restore"
else
    for nodegroup in $NODE_GROUPS; do
        echo "Scaling up node group: $nodegroup"
        
        # Different scaling for different node groups based on Terraform config
        if [[ "$nodegroup" == "mongodb-nodes" ]]; then
            # MongoDB nodes - restore to 3 nodes as per Terraform
            echo "  Restoring MongoDB node group to 3 nodes (production configuration)"
            aws eks update-nodegroup-config \
                --cluster-name $CLUSTER_NAME \
                --nodegroup-name $nodegroup \
                --scaling-config minSize=3,maxSize=3,desiredSize=3 \
                --region $REGION
        elif [[ "$nodegroup" == "general-nodes" ]]; then
            # General nodes - restore based on Terraform defaults (3 desired, 2 min, 10 max)
            echo "  Restoring general node group to default configuration"
            aws eks update-nodegroup-config \
                --cluster-name $CLUSTER_NAME \
                --nodegroup-name $nodegroup \
                --scaling-config minSize=2,maxSize=10,desiredSize=3 \
                --region $REGION
        else
            # Unknown node group - use conservative defaults
            aws eks update-nodegroup-config \
                --cluster-name $CLUSTER_NAME \
                --nodegroup-name $nodegroup \
                --scaling-config minSize=1,maxSize=5,desiredSize=2 \
                --region $REGION
        fi
        
        echo "Node group $nodegroup scaled up"
    done
fi

# Wait for nodes to be ready
echo ""
echo "Waiting for nodes to be ready (this may take a few minutes)..."
sleep 30

# Check node status
kubectl get nodes

echo ""
echo "========================================="
echo "Step 2: Restoring Workloads"
echo "========================================="

# Restore deployments from backup
if [ -f "$BACKUP_DIR/deployments.json" ]; then
    echo "Restoring deployments from backup..."
    
    # Parse and restore each deployment's replica count
    kubectl get deployments --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
        # Get original replica count from backup
        REPLICAS=$(jq -r ".items[] | select(.metadata.namespace==\"$ns\" and .metadata.name==\"$name\") | .spec.replicas // 1" $BACKUP_DIR/deployments.json)
        
        if [ "$REPLICAS" != "null" ] && [ "$REPLICAS" != "0" ]; then
            echo "  Restoring $ns/$name to $REPLICAS replicas..."
            kubectl scale deployment/$name -n $ns --replicas=$REPLICAS
        fi
    done
else
    echo "No deployment backup found, using default scaling..."
    # Scale up deployments to 1 replica as default
    kubectl get deployments --all-namespaces -o name | while read deployment; do
        ns=$(echo $deployment | cut -d'/' -f1)
        name=$(echo $deployment | cut -d'/' -f2)
        if [[ $ns != "kube-system" ]]; then
            echo "  Scaling $deployment to 1 replica..."
            kubectl scale $deployment --replicas=1
        fi
    done
fi

# Restore statefulsets from backup
if [ -f "$BACKUP_DIR/statefulsets.json" ]; then
    echo ""
    echo "Restoring statefulsets from backup..."
    
    kubectl get statefulsets --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
        # Get original replica count from backup
        REPLICAS=$(jq -r ".items[] | select(.metadata.namespace==\"$ns\" and .metadata.name==\"$name\") | .spec.replicas // 1" $BACKUP_DIR/statefulsets.json)
        
        if [ "$REPLICAS" != "null" ] && [ "$REPLICAS" != "0" ]; then
            echo "  Restoring $ns/$name to $REPLICAS replicas..."
            kubectl scale statefulset/$name -n $ns --replicas=$REPLICAS
        fi
    done
fi

echo ""
echo "========================================="
echo "Step 3: Starting EC2 Instances"
echo "========================================="

# Start EC2 instances if they were stopped
if [ -f "$BACKUP_DIR/ec2-instances.txt" ]; then
    INSTANCES=$(cat $BACKUP_DIR/ec2-instances.txt)
    if [ ! -z "$INSTANCES" ]; then
        echo "Starting EC2 instances that were previously stopped..."
        echo "Instances: $INSTANCES"
        
        aws ec2 start-instances --instance-ids $INSTANCES --region $REGION
        echo "EC2 instances start initiated"
        
        # Wait for instances to be running
        echo "Waiting for instances to be running..."
        aws ec2 wait instance-running --instance-ids $INSTANCES --region $REGION
        echo "EC2 instances are now running"
    fi
else
    echo "No EC2 instances to restore"
fi

echo ""
echo "========================================="
echo "Step 4: Starting RDS Databases"
echo "========================================="

# Start RDS instances if they were stopped
if [ -f "$BACKUP_DIR/rds-instances.txt" ]; then
    RDS_INSTANCES=$(cat $BACKUP_DIR/rds-instances.txt)
    if [ ! -z "$RDS_INSTANCES" ]; then
        echo "Starting RDS instances that were previously stopped..."
        
        for db_instance in $RDS_INSTANCES; do
            echo "  Starting RDS instance: $db_instance"
            
            # Check current status
            STATUS=$(aws rds describe-db-instances \
                --db-instance-identifier $db_instance \
                --region $REGION \
                --query 'DBInstances[0].DBInstanceStatus' \
                --output text 2>/dev/null)
            
            if [ "$STATUS" == "stopped" ]; then
                aws rds start-db-instance \
                    --db-instance-identifier $db_instance \
                    --region $REGION
                echo "    RDS instance start initiated"
            else
                echo "    RDS instance is not in stopped state (current: $STATUS)"
            fi
        done
        
        echo "Note: RDS instances may take 5-10 minutes to become available"
    fi
else
    echo "No RDS instances to restore"
fi

echo ""
echo "========================================="
echo "Step 5: Verification"
echo "========================================="

# Check pod status
echo "Checking pod status..."
kubectl get pods --all-namespaces | head -20

echo ""
echo "========================================="
echo "Restoration Summary"
echo "========================================="
echo "✅ Node groups scaled up"
echo "✅ Workloads restored"
[ -f "$BACKUP_DIR/ec2-instances.txt" ] && [ ! -z "$(cat $BACKUP_DIR/ec2-instances.txt)" ] && echo "✅ EC2 instances started"
[ -f "$BACKUP_DIR/rds-instances.txt" ] && [ ! -z "$(cat $BACKUP_DIR/rds-instances.txt)" ] && echo "✅ RDS databases started"
echo ""
echo "Monitor the restoration:"
echo "  kubectl get pods --all-namespaces -w"
echo ""
echo "Check cluster status:"
echo "  kubectl get nodes"
echo "  kubectl get deployments --all-namespaces"
echo ""
echo "Cluster restoration initiated successfully!"
echo "Note: It may take a few minutes for all pods to become ready."