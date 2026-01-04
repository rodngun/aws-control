#!/bin/bash

# AWS App Runner Deployment Script for RodNGun API
# This script deploys the API as a containerized service using AWS App Runner

set -e

# Configuration
SERVICE_NAME="rodngun-api"
REGION="us-east-1"
ECR_REPO_NAME="rodngun-api"
IMAGE_TAG="latest"
CPU="0.5 vCPU"
MEMORY="1 GB"
PORT="8080"

# MongoDB Atlas connection (required for App Runner)
# You'll need to set up MongoDB Atlas separately
MONGODB_URI="${MONGODB_URI:-mongodb+srv://username:password@cluster.mongodb.net/rodngun}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "RodNGun API App Runner Deployment"
echo "======================================"

# Step 1: Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed. Please install Docker first.${NC}"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}AWS CLI is not installed. Please install AWS CLI first.${NC}"
    exit 1
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME"

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "ECR URI: $ECR_URI"

# Step 2: Create ECR repository
echo -e "${YELLOW}Creating ECR repository...${NC}"

aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $REGION 2>/dev/null || {
    aws ecr create-repository \
        --repository-name $ECR_REPO_NAME \
        --region $REGION \
        --image-scanning-configuration scanOnPush=true
    echo -e "${GREEN}ECR repository created${NC}"
}

# Step 3: Build Docker image
echo -e "${YELLOW}Building Docker image...${NC}"

cd /Users/davisj77/Projects/rodngun-ai/api

docker build -t $ECR_REPO_NAME:$IMAGE_TAG .

echo -e "${GREEN}Docker image built successfully${NC}"

# Step 4: Push image to ECR
echo -e "${YELLOW}Pushing image to ECR...${NC}"

# Get ECR login token
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI

# Tag the image
docker tag $ECR_REPO_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG

# Push the image
docker push $ECR_URI:$IMAGE_TAG

echo -e "${GREEN}Image pushed to ECR${NC}"

# Step 5: Create App Runner configuration file
echo -e "${YELLOW}Creating App Runner configuration...${NC}"

cat > /tmp/apprunner.yaml << EOF
version: 1.0
runtime: docker
build:
  commands:
    build:
      - echo "No build commands"
run:
  runtime-version: latest
  command: uvicorn src.rodngun_api.main:app --host 0.0.0.0 --port 8080 --workers 2
  network:
    port: 8080
    env: PORT
  env:
    - name: "MONGODB_URI"
      value: "$MONGODB_URI"
    - name: "JWT_SECRET_KEY"
      value: "$(openssl rand -hex 32)"
    - name: "JWT_ALGORITHM"
      value: "HS256"
EOF

# Step 6: Create IAM role for App Runner
echo -e "${YELLOW}Creating IAM role for App Runner...${NC}"

cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "build.apprunner.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the role
aws iam create-role \
    --role-name AppRunnerECRAccessRole \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --region $REGION 2>/dev/null || echo "Role already exists"

# Attach ECR access policy
aws iam attach-role-policy \
    --role-name AppRunnerECRAccessRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
    --region $REGION 2>/dev/null || echo "Policy already attached"

ACCESS_ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/AppRunnerECRAccessRole"

# Step 7: Create App Runner service
echo -e "${YELLOW}Creating App Runner service...${NC}"

# Check if service already exists
SERVICE_EXISTS=$(aws apprunner list-services --region $REGION --query "ServiceSummaryList[?ServiceName=='$SERVICE_NAME'].ServiceArn" --output text)

if [ ! -z "$SERVICE_EXISTS" ]; then
    echo -e "${YELLOW}Service already exists. Updating...${NC}"
    
    # Update the service
    aws apprunner update-service \
        --service-arn "$SERVICE_EXISTS" \
        --source-configuration '{
            "ImageRepository": {
                "ImageIdentifier": "'$ECR_URI:$IMAGE_TAG'",
                "ImageConfiguration": {
                    "Port": "'$PORT'",
                    "RuntimeEnvironmentVariables": {
                        "MONGODB_URI": "'$MONGODB_URI'",
                        "JWT_SECRET_KEY": "'$(openssl rand -hex 32)'",
                        "JWT_ALGORITHM": "HS256",
                        "RODNGUN": "",
                        "ADMIN_API_KEY": "'${ADMIN_API_KEY:-your-secure-admin-key-here}'",
                        "ADMIN_API_SECRET": "'${ADMIN_API_SECRET:-your-secure-admin-secret-here}'"
                    }
                },
                "ImageRepositoryType": "ECR"
            },
            "AutoDeploymentsEnabled": false,
            "AuthenticationConfiguration": {
                "AccessRoleArn": "'$ACCESS_ROLE_ARN'"
            }
        }' \
        --region $REGION
else
    echo -e "${YELLOW}Creating new App Runner service...${NC}"
    
    # Create the service
    SERVICE_ARN=$(aws apprunner create-service \
        --service-name "$SERVICE_NAME" \
        --source-configuration '{
            "ImageRepository": {
                "ImageIdentifier": "'$ECR_URI:$IMAGE_TAG'",
                "ImageConfiguration": {
                    "Port": "'$PORT'",
                    "RuntimeEnvironmentVariables": {
                        "MONGODB_URI": "'$MONGODB_URI'",
                        "JWT_SECRET_KEY": "'$(openssl rand -hex 32)'",
                        "JWT_ALGORITHM": "HS256",
                        "RODNGUN": "",
                        "ADMIN_API_KEY": "'${ADMIN_API_KEY:-your-secure-admin-key-here}'",
                        "ADMIN_API_SECRET": "'${ADMIN_API_SECRET:-your-secure-admin-secret-here}'"
                    }
                },
                "ImageRepositoryType": "ECR"
            },
            "AutoDeploymentsEnabled": false,
            "AuthenticationConfiguration": {
                "AccessRoleArn": "'$ACCESS_ROLE_ARN'"
            }
        }' \
        --instance-configuration '{
            "Cpu": "'$CPU'",
            "Memory": "'$MEMORY'"
        }' \
        --health-check-configuration '{
            "Protocol": "HTTP",
            "Path": "/health",
            "Interval": 10,
            "Timeout": 5,
            "HealthyThreshold": 1,
            "UnhealthyThreshold": 5
        }' \
        --region $REGION \
        --query 'Service.ServiceArn' \
        --output text)
    
    echo -e "${GREEN}App Runner service created: $SERVICE_ARN${NC}"
fi

# Step 8: Wait for service to be running
echo -e "${YELLOW}Waiting for service to be running (this may take 5-10 minutes)...${NC}"

for i in {1..30}; do
    STATUS=$(aws apprunner describe-service \
        --service-arn "$SERVICE_ARN" \
        --region $REGION \
        --query 'Service.Status' \
        --output text 2>/dev/null || echo "PENDING")
    
    if [ "$STATUS" == "RUNNING" ]; then
        break
    fi
    
    echo "Service status: $STATUS (attempt $i/30)"
    sleep 20
done

# Get service URL
SERVICE_URL=$(aws apprunner describe-service \
    --service-arn "$SERVICE_ARN" \
    --region $REGION \
    --query 'Service.ServiceUrl' \
    --output text)

# Step 9: Create custom domain configuration
echo -e "${YELLOW}Setting up custom domain (optional)...${NC}"

cat > /tmp/custom_domain.json << EOF
{
    "DomainName": "api.rodngun.us",
    "EnableWWWSubdomain": false
}
EOF

# Note: Custom domain requires domain validation
# aws apprunner associate-custom-domain \
#     --service-arn "$SERVICE_ARN" \
#     --domain-name "api.rodngun.us" \
#     --region $REGION

# Step 10: Output deployment information
echo ""
echo "======================================"
echo -e "${GREEN}App Runner Deployment Complete!${NC}"
echo "======================================"
echo ""
echo "Service Details:"
echo "  Name: $SERVICE_NAME"
echo "  URL: https://$SERVICE_URL"
echo "  Region: $REGION"
echo "  CPU: $CPU"
echo "  Memory: $MEMORY"
echo ""
echo "Estimated Monthly Cost:"
echo "  Compute: ~\$20 (0.5 vCPU, 1 GB memory)"
echo "  Requests: ~\$0.50 per million requests"
echo "  Data Transfer: ~\$0.10 per GB"
echo "  Total: ~\$20-40/month"
echo ""
echo "Test the API:"
echo "  curl https://$SERVICE_URL/health"
echo ""
echo "Next Steps:"
echo "1. Set up MongoDB Atlas if not already done"
echo "2. Update mobile apps with new API URL"
echo "3. Configure custom domain (optional)"
echo "4. Set up CloudWatch alarms for monitoring"
echo ""
echo "To update the service:"
echo "  1. Build new Docker image"
echo "  2. Push to ECR"
echo "  3. Update App Runner service"
echo ""
echo "To delete the service:"
echo "  aws apprunner delete-service --service-arn $SERVICE_ARN --region $REGION"