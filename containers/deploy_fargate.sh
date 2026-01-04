#!/bin/bash

# AWS Fargate/ECS Deployment Script for RodNGun API
# This script deploys the API as a serverless container using AWS Fargate

set -e

# Configuration
CLUSTER_NAME="rodngun-cluster"
SERVICE_NAME="rodngun-api-service"
TASK_FAMILY="rodngun-api-task"
CONTAINER_NAME="rodngun-api"
REGION="us-east-1"
ECR_REPO_NAME="rodngun-api"
IMAGE_TAG="latest"
CPU="512"  # 0.5 vCPU
MEMORY="1024"  # 1 GB
DESIRED_COUNT="1"
VPC_NAME="rodngun-vpc"

# MongoDB Configuration (using MongoDB Atlas)
MONGODB_URI="${MONGODB_URI:-mongodb+srv://username:password@cluster.mongodb.net/rodngun}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "RodNGun API Fargate/ECS Deployment"
echo "======================================"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME"

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "ECR URI: $ECR_URI"

# Step 1: Create VPC and networking (if not exists)
echo -e "${YELLOW}Setting up networking...${NC}"

# Check for existing VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [ "$VPC_ID" == "" ] || [ "$VPC_ID" == "None" ]; then
    echo "Creating VPC..."
    
    # Create VPC
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block 10.0.0.0/16 \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME}]" \
        --query 'Vpc.VpcId' \
        --output text \
        --region $REGION)
    
    # Enable DNS
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support --region $REGION
    
    # Create Internet Gateway
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$VPC_NAME-igw}]" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text \
        --region $REGION)
    
    aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION
    
    # Create public subnets
    SUBNET1_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block 10.0.1.0/24 \
        --availability-zone ${REGION}a \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$VPC_NAME-public-1}]" \
        --query 'Subnet.SubnetId' \
        --output text \
        --region $REGION)
    
    SUBNET2_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block 10.0.2.0/24 \
        --availability-zone ${REGION}b \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$VPC_NAME-public-2}]" \
        --query 'Subnet.SubnetId' \
        --output text \
        --region $REGION)
    
    # Enable auto-assign public IP
    aws ec2 modify-subnet-attribute --subnet-id $SUBNET1_ID --map-public-ip-on-launch --region $REGION
    aws ec2 modify-subnet-attribute --subnet-id $SUBNET2_ID --map-public-ip-on-launch --region $REGION
    
    # Create and configure route table
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$VPC_NAME-public-rt}]" \
        --query 'RouteTable.RouteTableId' \
        --output text \
        --region $REGION)
    
    aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
    aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET1_ID --region $REGION
    aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET2_ID --region $REGION
    
    echo -e "${GREEN}VPC and networking created${NC}"
else
    echo "Using existing VPC: $VPC_ID"
    
    # Get subnet IDs
    SUBNET1_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region $REGION)
    
    SUBNET2_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[1].SubnetId' \
        --output text \
        --region $REGION)
fi

# Step 2: Create Security Group
echo -e "${YELLOW}Creating security group...${NC}"

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SERVICE_NAME-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [ "$SG_ID" == "" ] || [ "$SG_ID" == "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SERVICE_NAME-sg" \
        --description "Security group for RodNGun API Fargate service" \
        --vpc-id $VPC_ID \
        --query 'GroupId' \
        --output text \
        --region $REGION)
    
    # Allow HTTP and HTTPS
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 8080 \
        --cidr 0.0.0.0/0 \
        --region $REGION
    
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --region $REGION
    
    echo -e "${GREEN}Security group created: $SG_ID${NC}"
else
    echo "Using existing security group: $SG_ID"
fi

# Step 3: Build and push Docker image to ECR
echo -e "${YELLOW}Building and pushing Docker image...${NC}"

# Create ECR repository if not exists
aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $REGION 2>/dev/null || {
    aws ecr create-repository \
        --repository-name $ECR_REPO_NAME \
        --region $REGION \
        --image-scanning-configuration scanOnPush=true
}

# Build Docker image
cd /Users/davisj77/Projects/rodngun-ai/api
docker build -t $ECR_REPO_NAME:$IMAGE_TAG .

# Push to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
docker tag $ECR_REPO_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
docker push $ECR_URI:$IMAGE_TAG

echo -e "${GREEN}Docker image pushed to ECR${NC}"

# Step 4: Create ECS Cluster
echo -e "${YELLOW}Creating ECS cluster...${NC}"

aws ecs describe-clusters --clusters $CLUSTER_NAME --region $REGION 2>/dev/null || {
    aws ecs create-cluster \
        --cluster-name $CLUSTER_NAME \
        --capacity-providers FARGATE FARGATE_SPOT \
        --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
        --region $REGION
    echo -e "${GREEN}ECS cluster created${NC}"
}

# Step 5: Create IAM role for task execution
echo -e "${YELLOW}Creating IAM roles...${NC}"

# Task execution role
cat > /tmp/task-execution-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

EXECUTION_ROLE_NAME="rodngun-ecs-execution-role"
aws iam create-role \
    --role-name $EXECUTION_ROLE_NAME \
    --assume-role-policy-document file:///tmp/task-execution-trust-policy.json \
    --region $REGION 2>/dev/null || echo "Execution role already exists"

aws iam attach-role-policy \
    --role-name $EXECUTION_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    --region $REGION 2>/dev/null || echo "Policy already attached"

EXECUTION_ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/$EXECUTION_ROLE_NAME"

# Step 6: Create Task Definition
echo -e "${YELLOW}Creating task definition...${NC}"

cat > /tmp/task-definition.json << EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "$CPU",
  "memory": "$MEMORY",
  "executionRoleArn": "$EXECUTION_ROLE_ARN",
  "containerDefinitions": [
    {
      "name": "$CONTAINER_NAME",
      "image": "$ECR_URI:$IMAGE_TAG",
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "environment": [
        {
          "name": "MONGODB_URI",
          "value": "$MONGODB_URI"
        },
        {
          "name": "JWT_SECRET_KEY",
          "value": "$(openssl rand -hex 32)"
        },
        {
          "name": "JWT_ALGORITHM",
          "value": "HS256"
        },
        {
          "name": "PORT",
          "value": "8080"
        },
        {
          "name": "RODNGUN",
          "value": ""
        },
        {
          "name": "ADMIN_API_KEY",
          "value": "${ADMIN_API_KEY:-your-secure-admin-key-here}"
        },
        {
          "name": "ADMIN_API_SECRET",
          "value": "${ADMIN_API_SECRET:-your-secure-admin-secret-here}"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/$TASK_FAMILY",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF

# Create CloudWatch log group
aws logs create-log-group --log-group-name /ecs/$TASK_FAMILY --region $REGION 2>/dev/null || echo "Log group already exists"

# Register task definition
TASK_DEFINITION_ARN=$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/task-definition.json \
    --region $REGION \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

echo -e "${GREEN}Task definition registered: $TASK_DEFINITION_ARN${NC}"

# Step 7: Create Application Load Balancer
echo -e "${YELLOW}Creating Application Load Balancer...${NC}"

ALB_NAME="rodngun-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names $ALB_NAME \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [ "$ALB_ARN" == "" ] || [ "$ALB_ARN" == "None" ]; then
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name $ALB_NAME \
        --subnets $SUBNET1_ID $SUBNET2_ID \
        --security-groups $SG_ID \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text \
        --region $REGION)
    
    echo -e "${GREEN}ALB created: $ALB_ARN${NC}"
else
    echo "Using existing ALB: $ALB_ARN"
fi

# Get ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text \
    --region $REGION)

# Create Target Group
TG_NAME="rodngun-tg"
TG_ARN=$(aws elbv2 describe-target-groups \
    --names $TG_NAME \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [ "$TG_ARN" == "" ] || [ "$TG_ARN" == "None" ]; then
    TG_ARN=$(aws elbv2 create-target-group \
        --name $TG_NAME \
        --protocol HTTP \
        --port 8080 \
        --vpc-id $VPC_ID \
        --target-type ip \
        --health-check-path /health \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 5 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text \
        --region $REGION)
    
    echo -e "${GREEN}Target group created${NC}"
else
    echo "Using existing target group: $TG_ARN"
fi

# Create Listener
LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn $ALB_ARN \
    --query 'Listeners[0].ListenerArn' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [ "$LISTENER_ARN" == "" ] || [ "$LISTENER_ARN" == "None" ]; then
    aws elbv2 create-listener \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --region $REGION
    
    echo -e "${GREEN}Listener created${NC}"
fi

# Step 8: Create ECS Service
echo -e "${YELLOW}Creating ECS service...${NC}"

# Check if service exists
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --query 'services[0].serviceArn' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [ "$SERVICE_EXISTS" != "" ] && [ "$SERVICE_EXISTS" != "None" ]; then
    echo "Updating existing service..."
    
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_ARN \
        --desired-count $DESIRED_COUNT \
        --region $REGION
else
    echo "Creating new service..."
    
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_ARN \
        --desired-count $DESIRED_COUNT \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET1_ID,$SUBNET2_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
        --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=8080" \
        --region $REGION
fi

echo -e "${GREEN}ECS service created/updated${NC}"

# Step 9: Wait for service to be stable
echo -e "${YELLOW}Waiting for service to be stable (this may take 5-10 minutes)...${NC}"

aws ecs wait services-stable \
    --cluster $CLUSTER_NAME \
    --services $SERVICE_NAME \
    --region $REGION || {
    echo "Service stabilization timed out, checking status..."
    aws ecs describe-services \
        --cluster $CLUSTER_NAME \
        --services $SERVICE_NAME \
        --query 'services[0].deployments' \
        --region $REGION
}

# Step 10: Output deployment information
echo ""
echo "======================================"
echo -e "${GREEN}Fargate/ECS Deployment Complete!${NC}"
echo "======================================"
echo ""
echo "Service Details:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"
echo "  ALB URL: http://$ALB_DNS"
echo "  Region: $REGION"
echo "  CPU: $CPU (0.5 vCPU)"
echo "  Memory: $MEMORY MB"
echo "  Desired Count: $DESIRED_COUNT"
echo ""
echo "Estimated Monthly Cost:"
echo "  Fargate Compute: ~\$18 (0.5 vCPU, 1GB, 1 task)"
echo "  ALB: ~\$16 base + \$0.008 per LCU hour"
echo "  Data Transfer: ~\$0.09 per GB"
echo "  CloudWatch Logs: ~\$0.50"
echo "  Total: ~\$35-50/month"
echo ""
echo "Test the API:"
echo "  curl http://$ALB_DNS/health"
echo ""
echo "Next Steps:"
echo "1. Configure Route 53 to point api.rodngun.us to ALB"
echo "2. Set up ACM certificate for HTTPS"
echo "3. Update mobile apps with new API URL"
echo "4. Configure auto-scaling policies"
echo "5. Set up CloudWatch alarms"
echo ""
echo "Useful Commands:"
echo "  View logs: aws logs tail /ecs/$TASK_FAMILY --follow"
echo "  Scale service: aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 2"
echo "  Stop service: aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0"
echo "  Delete service: aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force"