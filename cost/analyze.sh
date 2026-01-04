#!/bin/bash

# Comprehensive AWS Cost Analysis Script
# Checks ALL billable AWS services for potential costs
# Usage: ./analyze.sh [region]

set -e

# Default region (can be overridden with command line argument)
REGION="${1:-us-east-1}"
CURRENT_DATE=$(date +"%B %Y")

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Pricing constants (USD per hour unless specified)
# EC2 & Compute
EKS_CONTROL_PLANE_HOURLY=0.10
NAT_GATEWAY_HOURLY=0.045
NAT_GATEWAY_DATA_GB=0.045
ALB_HOURLY=0.0225
ALB_LCU_HOURLY=0.008
NLB_HOURLY=0.0225
NLB_LCU_HOURLY=0.006
EC2_ELASTIC_IP_HOURLY=0.005

# Storage pricing (per GB per month)
EBS_GP3_GB_MONTHLY=0.08
EBS_GP2_GB_MONTHLY=0.10
EBS_IO1_GB_MONTHLY=0.125
EBS_IO2_GB_MONTHLY=0.125
EBS_ST1_GB_MONTHLY=0.045
EBS_SC1_GB_MONTHLY=0.015
S3_STANDARD_GB_MONTHLY=0.023
S3_INFREQUENT_GB_MONTHLY=0.0125
S3_GLACIER_GB_MONTHLY=0.004
S3_DEEP_ARCHIVE_GB_MONTHLY=0.00099
EFS_STANDARD_GB_MONTHLY=0.30
EFS_INFREQUENT_GB_MONTHLY=0.025
FSX_WINDOWS_GB_MONTHLY=0.13
FSX_LUSTRE_GB_MONTHLY=0.14

# Database pricing
RDS_BACKUP_GB_MONTHLY=0.095
DYNAMODB_GB_MONTHLY=0.25
ELASTICACHE_GB_HOURLY=0.034
DOCUMENTDB_STORAGE_GB_MONTHLY=0.10
NEPTUNE_STORAGE_GB_MONTHLY=0.10
TIMESTREAM_GB_MONTHLY=0.50

# Container & Serverless
LAMBDA_REQUEST_MILLION=0.20
LAMBDA_GB_SECOND=0.0000166667
ECR_STORAGE_GB_MONTHLY=0.10
APP_RUNNER_VCPU_HOURLY=0.064
APP_RUNNER_GB_HOURLY=0.007

# Networking
CLOUDFRONT_GB_OUT=0.085
ROUTE53_HOSTED_ZONE_MONTHLY=0.50
VPN_CONNECTION_HOURLY=0.05
DIRECT_CONNECT_PORT_HOURLY=0.30
TRANSIT_GATEWAY_HOURLY=0.05
TRANSIT_GATEWAY_DATA_GB=0.02

# Analytics & ML
KINESIS_SHARD_HOURLY=0.015
KINESIS_PUT_PAYLOAD_UNIT=0.014
GLUE_DPU_HOURLY=0.44
ATHENA_TB_SCANNED=5.00
REDSHIFT_DC2_LARGE_HOURLY=0.25
SAGEMAKER_NOTEBOOK_ML_T3_MEDIUM_HOURLY=0.0464

# Other Services
SNS_MILLION_REQUESTS=0.50
SQS_MILLION_REQUESTS=0.40
SES_THOUSAND_EMAILS=0.10
CLOUDWATCH_METRIC_MONTHLY=0.30
CLOUDWATCH_DASHBOARD_MONTHLY=3.00
BACKUP_GB_MONTHLY=0.05
SECRETS_MANAGER_SECRET_MONTHLY=0.40
SYSTEMS_MANAGER_CONFIG_ITEM=0.003
WAF_WEB_ACL_MONTHLY=5.00
SHIELD_STANDARD_MONTHLY=0.00
SHIELD_ADVANCED_MONTHLY=3000.00

# EC2 instance pricing function
get_ec2_price() {
    case $1 in
        # T-series (Burstable)
        "t2.nano") echo 0.0058 ;;
        "t2.micro") echo 0.0116 ;;
        "t2.small") echo 0.023 ;;
        "t2.medium") echo 0.0464 ;;
        "t2.large") echo 0.0928 ;;
        "t2.xlarge") echo 0.1856 ;;
        "t2.2xlarge") echo 0.3712 ;;
        "t3.nano") echo 0.0052 ;;
        "t3.micro") echo 0.0104 ;;
        "t3.small") echo 0.0208 ;;
        "t3.medium") echo 0.0416 ;;
        "t3.large") echo 0.0832 ;;
        "t3.xlarge") echo 0.1664 ;;
        "t3.2xlarge") echo 0.3328 ;;
        "t4g.nano") echo 0.0042 ;;
        "t4g.micro") echo 0.0084 ;;
        "t4g.small") echo 0.0168 ;;
        "t4g.medium") echo 0.0336 ;;
        "t4g.large") echo 0.0672 ;;
        # M-series (General Purpose)
        "m5.large") echo 0.096 ;;
        "m5.xlarge") echo 0.192 ;;
        "m5.2xlarge") echo 0.384 ;;
        "m5.4xlarge") echo 0.768 ;;
        "m6i.large") echo 0.096 ;;
        "m6i.xlarge") echo 0.192 ;;
        # C-series (Compute Optimized)
        "c5.large") echo 0.085 ;;
        "c5.xlarge") echo 0.17 ;;
        "c5.2xlarge") echo 0.34 ;;
        "c6i.large") echo 0.085 ;;
        # R-series (Memory Optimized)
        "r5.large") echo 0.126 ;;
        "r5.xlarge") echo 0.252 ;;
        "r6i.large") echo 0.126 ;;
        # Default
        *) echo 0.05 ;;
    esac
}

# Initialize totals
TOTAL_MONTHLY_COST=0
SERVICE_COUNT=0
RESOURCE_COUNT=0
# Initialize all monthly cost variables to prevent bc errors
SECRETS_MONTHLY=0
WAF_MONTHLY=0

# Function to convert hourly to monthly cost
hourly_to_monthly() {
    echo "scale=2; $1 * 730" | bc
}

# Function to add to total
add_to_total() {
    TOTAL_MONTHLY_COST=$(echo "scale=2; $TOTAL_MONTHLY_COST + $1" | bc)
}

echo "======================================================="
echo -e "${BOLD}  COMPREHENSIVE AWS COST ANALYSIS - ${CURRENT_DATE}${NC}"
echo "======================================================="
echo "Region: $REGION"
echo "Account: $(aws sts get-caller-identity --query 'Account' --output text)"
echo "Generated: $(date)"
echo ""
echo -e "${YELLOW}Checking ALL AWS services for billable resources...${NC}"
echo ""

# Check AWS CLI availability
if ! command -v aws &> /dev/null; then
    echo -e "${RED}ERROR: AWS CLI is not installed${NC}"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}ERROR: AWS credentials not configured${NC}"
    exit 1
fi

# ==============================================================================
# 1. COMPUTE SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ COMPUTE SERVICES ━━━${NC}"
echo ""

# EC2 Instances
echo -e "${BOLD}EC2 Instances:${NC}"
EC2_MONTHLY=0
INSTANCES=$(aws ec2 describe-instances --region $REGION \
    --query 'Reservations[].Instances[?State.Name==`running`].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

if [ -z "$INSTANCES" ]; then
    echo "  ✓ No running instances"
else
    while IFS=$'\t' read -r id type state name; do
        if [ ! -z "$id" ]; then
            price=$(get_ec2_price "$type")
            monthly=$(hourly_to_monthly $price)
            EC2_MONTHLY=$(echo "scale=2; $EC2_MONTHLY + $monthly" | bc)
            printf "  %-20s %-12s %-20s ${YELLOW}\$%.2f/mo${NC}\n" "$id" "$type" "${name:-unnamed}" "$monthly"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$INSTANCES"
    add_to_total $EC2_MONTHLY
    printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$EC2_MONTHLY"
fi
echo ""

# Lightsail Instances
echo -e "${BOLD}Lightsail Instances:${NC}"
LIGHTSAIL_MONTHLY=0
LIGHTSAIL=$(aws lightsail get-instances --region $REGION \
    --query 'instances[].[name,bundleId,state.name]' \
    --output text 2>/dev/null || echo "")

if [ -z "$LIGHTSAIL" ]; then
    echo "  ✓ No Lightsail instances"
else
    while IFS=$'\t' read -r name bundle state; do
        if [ ! -z "$name" ] && [ "$state" == "running" ]; then
            # Estimate based on bundle
            case $bundle in
                *nano*) monthly=3.50 ;;
                *micro*) monthly=5.00 ;;
                *small*) monthly=10.00 ;;
                *medium*) monthly=20.00 ;;
                *large*) monthly=40.00 ;;
                *xlarge*) monthly=80.00 ;;
                *2xlarge*) monthly=160.00 ;;
                *) monthly=10.00 ;;
            esac
            LIGHTSAIL_MONTHLY=$(echo "scale=2; $LIGHTSAIL_MONTHLY + $monthly" | bc)
            printf "  %-30s %-15s ${YELLOW}\$%.2f/mo${NC}\n" "$name" "$bundle" "$monthly"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$LIGHTSAIL"
    add_to_total $LIGHTSAIL_MONTHLY
    [ ! -z "$LIGHTSAIL" ] && printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$LIGHTSAIL_MONTHLY"
fi
echo ""

# Lambda Functions
echo -e "${BOLD}Lambda Functions:${NC}"
LAMBDA_COUNT=$(aws lambda list-functions --region $REGION --query 'length(Functions)' --output text 2>/dev/null || echo 0)
if [ "$LAMBDA_COUNT" -eq 0 ]; then
    echo "  ✓ No Lambda functions"
else
    echo "  Found $LAMBDA_COUNT functions (cost depends on invocations)"
    LAMBDA_EST=5.00  # Estimate $5/month for active functions
    add_to_total $LAMBDA_EST
    printf "  ${BOLD}Estimated: \$%.2f/month${NC}\n" "$LAMBDA_EST"
    ((RESOURCE_COUNT+=$LAMBDA_COUNT))
fi
echo ""

# ==============================================================================
# 2. CONTAINER SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ CONTAINER SERVICES ━━━${NC}"
echo ""

# ECS Clusters
echo -e "${BOLD}ECS Clusters & Services:${NC}"
ECS_MONTHLY=0
CLUSTERS=$(aws ecs list-clusters --region $REGION --output text 2>/dev/null | grep -v CLUSTERARNS || echo "")
if [ -z "$CLUSTERS" ]; then
    echo "  ✓ No ECS clusters"
else
    for cluster in $CLUSTERS; do
        cluster_name=$(basename $cluster)
        SERVICES=$(aws ecs list-services --cluster $cluster --region $REGION --output text 2>/dev/null | grep -v SERVICEARNS || echo "")
        service_count=$(echo "$SERVICES" | wc -w)
        if [ "$service_count" -gt 0 ]; then
            printf "  Cluster: %-30s Services: %d\n" "$cluster_name" "$service_count"
            ((RESOURCE_COUNT+=$service_count))
        fi
    done
fi
echo ""

# EKS Clusters
echo -e "${BOLD}EKS Clusters:${NC}"
EKS_MONTHLY=0
EKS_CLUSTERS=$(aws eks list-clusters --region $REGION --output text 2>/dev/null | grep -v CLUSTERS || echo "")
if [ -z "$EKS_CLUSTERS" ]; then
    echo "  ✓ No EKS clusters"
else
    for cluster in $EKS_CLUSTERS; do
        monthly=$(hourly_to_monthly $EKS_CONTROL_PLANE_HOURLY)
        EKS_MONTHLY=$(echo "scale=2; $EKS_MONTHLY + $monthly" | bc)
        printf "  %-30s ${YELLOW}\$%.2f/mo${NC}\n" "$cluster" "$monthly"
        ((RESOURCE_COUNT++))
    done
    add_to_total $EKS_MONTHLY
    printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$EKS_MONTHLY"
fi
echo ""

# App Runner Services
echo -e "${BOLD}App Runner Services:${NC}"
APP_RUNNER_MONTHLY=0
APP_RUNNER=$(aws apprunner list-services --region $REGION \
    --query 'ServiceSummaryList[].[ServiceName,Status]' \
    --output text 2>/dev/null || echo "")

if [ -z "$APP_RUNNER" ]; then
    echo "  ✓ No App Runner services"
else
    while IFS=$'\t' read -r name status; do
        if [ ! -z "$name" ] && [ "$status" == "RUNNING" ]; then
            # Minimum cost for App Runner
            monthly=20.00
            APP_RUNNER_MONTHLY=$(echo "scale=2; $APP_RUNNER_MONTHLY + $monthly" | bc)
            printf "  %-30s %-10s ${YELLOW}\$%.2f/mo${NC}\n" "$name" "$status" "$monthly"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$APP_RUNNER"
    add_to_total $APP_RUNNER_MONTHLY
    [ ! -z "$APP_RUNNER" ] && printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$APP_RUNNER_MONTHLY"
fi
echo ""

# ECR Repositories
echo -e "${BOLD}ECR Repositories:${NC}"
ECR_MONTHLY=0
ECR_REPOS=$(aws ecr describe-repositories --region $REGION \
    --query 'repositories[].[repositoryName,repositorySizeInBytes]' \
    --output text 2>/dev/null || echo "")

if [ -z "$ECR_REPOS" ]; then
    echo "  ✓ No ECR repositories"
else
    total_size_gb=0
    while IFS=$'\t' read -r name size; do
        if [ ! -z "$name" ]; then
            # Handle empty or None values
            if [ "$size" == "None" ] || [ -z "$size" ]; then
                size=0
            fi
            size_gb=$(echo "scale=3; $size / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0.000")
            total_size_gb=$(echo "scale=3; $total_size_gb + $size_gb" | bc 2>/dev/null || echo "0.000")
            printf "  %-30s %.3f GB\n" "$name" "$size_gb"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$ECR_REPOS"
    ECR_MONTHLY=$(echo "scale=2; $total_size_gb * $ECR_STORAGE_GB_MONTHLY" | bc)
    add_to_total $ECR_MONTHLY
    printf "  ${BOLD}Total: %.3f GB - \$%.2f/month${NC}\n" "$total_size_gb" "$ECR_MONTHLY"
fi
echo ""

# ==============================================================================
# 3. STORAGE SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ STORAGE SERVICES ━━━${NC}"
echo ""

# EBS Volumes
echo -e "${BOLD}EBS Volumes:${NC}"
EBS_MONTHLY=0
VOLUMES=$(aws ec2 describe-volumes --region $REGION \
    --query 'Volumes[].[VolumeId,Size,VolumeType,State,Attachments[0].InstanceId]' \
    --output text 2>/dev/null || echo "")

GP3=0; GP2=0; IO1=0; IO2=0; ST1=0; SC1=0
UNATTACHED=0

while IFS=$'\t' read -r vol_id size vol_type state instance; do
    if [ ! -z "$vol_id" ]; then
        if [ "$instance" == "None" ] || [ -z "$instance" ]; then
            ((UNATTACHED++))
        fi
        case $vol_type in
            gp3) GP3=$((GP3 + size)) ;;
            gp2) GP2=$((GP2 + size)) ;;
            io1) IO1=$((IO1 + size)) ;;
            io2) IO2=$((IO2 + size)) ;;
            st1) ST1=$((ST1 + size)) ;;
            sc1) SC1=$((SC1 + size)) ;;
        esac
        ((RESOURCE_COUNT++))
    fi
done <<< "$VOLUMES"

[ "$GP3" -gt 0 ] && printf "  GP3: %d GB @ \$0.08/GB = ${YELLOW}\$%.2f/mo${NC}\n" "$GP3" $(echo "scale=2; $GP3 * $EBS_GP3_GB_MONTHLY" | bc)
[ "$GP2" -gt 0 ] && printf "  GP2: %d GB @ \$0.10/GB = ${YELLOW}\$%.2f/mo${NC}\n" "$GP2" $(echo "scale=2; $GP2 * $EBS_GP2_GB_MONTHLY" | bc)
[ "$IO1" -gt 0 ] && printf "  IO1: %d GB @ \$0.125/GB = ${YELLOW}\$%.2f/mo${NC}\n" "$IO1" $(echo "scale=2; $IO1 * $EBS_IO1_GB_MONTHLY" | bc)
[ "$IO2" -gt 0 ] && printf "  IO2: %d GB @ \$0.125/GB = ${YELLOW}\$%.2f/mo${NC}\n" "$IO2" $(echo "scale=2; $IO2 * $EBS_IO2_GB_MONTHLY" | bc)
[ "$ST1" -gt 0 ] && printf "  ST1: %d GB @ \$0.045/GB = ${YELLOW}\$%.2f/mo${NC}\n" "$ST1" $(echo "scale=2; $ST1 * $EBS_ST1_GB_MONTHLY" | bc)
[ "$SC1" -gt 0 ] && printf "  SC1: %d GB @ \$0.015/GB = ${YELLOW}\$%.2f/mo${NC}\n" "$SC1" $(echo "scale=2; $SC1 * $EBS_SC1_GB_MONTHLY" | bc)

if [ "$UNATTACHED" -gt 0 ]; then
    echo -e "  ${RED}⚠ Warning: $UNATTACHED unattached volumes (wasting money!)${NC}"
fi

EBS_MONTHLY=$(echo "scale=2; \
    ($GP3 * $EBS_GP3_GB_MONTHLY) + \
    ($GP2 * $EBS_GP2_GB_MONTHLY) + \
    ($IO1 * $EBS_IO1_GB_MONTHLY) + \
    ($IO2 * $EBS_IO2_GB_MONTHLY) + \
    ($ST1 * $EBS_ST1_GB_MONTHLY) + \
    ($SC1 * $EBS_SC1_GB_MONTHLY)" | bc)

TOTAL_EBS=$((GP3 + GP2 + IO1 + IO2 + ST1 + SC1))
if [ "$TOTAL_EBS" -gt 0 ]; then
    add_to_total $EBS_MONTHLY
    printf "  ${BOLD}Total: %d GB - \$%.2f/month${NC}\n" "$TOTAL_EBS" "$EBS_MONTHLY"
else
    echo "  ✓ No EBS volumes"
fi
echo ""

# EBS Snapshots
echo -e "${BOLD}EBS Snapshots:${NC}"
SNAPSHOT_COUNT=$(aws ec2 describe-snapshots --owner-ids self --region $REGION --query 'length(Snapshots)' --output text 2>/dev/null || echo 0)
if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
    echo "  ✓ No snapshots"
else
    SNAPSHOT_SIZE=$(aws ec2 describe-snapshots --owner-ids self --region $REGION \
        --query 'sum(Snapshots[].VolumeSize)' --output text 2>/dev/null || echo 0)
    SNAPSHOT_COST=$(echo "scale=2; $SNAPSHOT_SIZE * 0.05" | bc)
    add_to_total $SNAPSHOT_COST
    printf "  %d snapshots, ~%d GB total = ${YELLOW}\$%.2f/mo${NC}\n" "$SNAPSHOT_COUNT" "$SNAPSHOT_SIZE" "$SNAPSHOT_COST"
    ((RESOURCE_COUNT+=$SNAPSHOT_COUNT))
fi
echo ""

# S3 Buckets
echo -e "${BOLD}S3 Buckets:${NC}"
S3_MONTHLY=0
BUCKETS=$(aws s3 ls 2>/dev/null | awk '{print $3}')
if [ -z "$BUCKETS" ]; then
    echo "  ✓ No S3 buckets"
else
    TOTAL_S3_SIZE=0
    for bucket in $BUCKETS; do
        # Get bucket size (this can be slow for large buckets)
        # macOS compatible date command
        if [[ "$OSTYPE" == "darwin"* ]]; then
            START_TIME=$(date -u -v-2d +%Y-%m-%dT%H:%M:%S)
            END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
        else
            START_TIME=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%S)
            END_TIME=$(date -u +%Y-%m-%dT%H:%M:%S)
        fi
        
        SIZE_BYTES=$(aws s3api head-bucket --bucket $bucket 2>/dev/null && \
            aws cloudwatch get-metric-statistics \
                --namespace AWS/S3 \
                --metric-name BucketSizeBytes \
                --dimensions Name=BucketName,Value=$bucket Name=StorageType,Value=StandardStorage \
                --statistics Maximum \
                --start-time $START_TIME \
                --end-time $END_TIME \
                --period 86400 \
                --region $REGION \
                --query 'Datapoints[0].Maximum' \
                --output text 2>/dev/null || echo 0)
        
        if [ "$SIZE_BYTES" == "None" ] || [ -z "$SIZE_BYTES" ]; then
            SIZE_BYTES=0
        fi
        
        SIZE_GB=$(echo "scale=3; $SIZE_BYTES / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0.000")
        BUCKET_COST=$(echo "scale=2; $SIZE_GB * $S3_STANDARD_GB_MONTHLY" | bc 2>/dev/null || echo "0.00")
        
        if [ "$(echo "$SIZE_GB > 0.001" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
            printf "  %-40s %8.3f GB  ${YELLOW}\$%.2f/mo${NC}\n" "$bucket" "$SIZE_GB" "$BUCKET_COST"
            TOTAL_S3_SIZE=$(echo "scale=3; $TOTAL_S3_SIZE + $SIZE_GB" | bc 2>/dev/null || echo "$TOTAL_S3_SIZE")
            S3_MONTHLY=$(echo "scale=2; $S3_MONTHLY + $BUCKET_COST" | bc 2>/dev/null || echo "$S3_MONTHLY")
        else
            printf "  %-40s    empty\n" "$bucket"
        fi
        ((RESOURCE_COUNT++))
    done
    add_to_total $S3_MONTHLY
    printf "  ${BOLD}Total: %.3f GB - \$%.2f/month${NC}\n" "$TOTAL_S3_SIZE" "$S3_MONTHLY"
fi
echo ""

# EFS File Systems
echo -e "${BOLD}EFS File Systems:${NC}"
EFS_MONTHLY=0
EFS_FS=$(aws efs describe-file-systems --region $REGION \
    --query 'FileSystems[].[Name,FileSystemId,SizeInBytes.Value]' \
    --output text 2>/dev/null || echo "")

if [ -z "$EFS_FS" ]; then
    echo "  ✓ No EFS file systems"
else
    while IFS=$'\t' read -r name fsid size; do
        if [ ! -z "$fsid" ]; then
            # Handle empty or None values
            if [ "$size" == "None" ] || [ -z "$size" ]; then
                size=0
            fi
            size_gb=$(echo "scale=3; $size / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0.000")
            cost=$(echo "scale=2; $size_gb * $EFS_STANDARD_GB_MONTHLY" | bc 2>/dev/null || echo "0.00")
            EFS_MONTHLY=$(echo "scale=2; $EFS_MONTHLY + $cost" | bc 2>/dev/null || echo "0.00")
            printf "  %-30s %.3f GB  ${YELLOW}\$%.2f/mo${NC}\n" "${name:-$fsid}" "$size_gb" "$cost"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$EFS_FS"
    add_to_total $EFS_MONTHLY
    [ ! -z "$EFS_FS" ] && printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$EFS_MONTHLY"
fi
echo ""

# ==============================================================================
# 4. DATABASE SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ DATABASE SERVICES ━━━${NC}"
echo ""

# RDS Instances
echo -e "${BOLD}RDS Instances:${NC}"
RDS_MONTHLY=0
RDS_INSTANCES=$(aws rds describe-db-instances --region $REGION \
    --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,AllocatedStorage,DBInstanceStatus]' \
    --output text 2>/dev/null || echo "")

if [ -z "$RDS_INSTANCES" ]; then
    echo "  ✓ No RDS instances"
else
    while IFS=$'\t' read -r db_id class engine storage status; do
        if [ ! -z "$db_id" ] && [ "$status" == "available" ]; then
            # Rough pricing based on instance class
            case $class in
                *micro*) monthly=15 ;;
                *small*) monthly=30 ;;
                *medium*) monthly=60 ;;
                *large*) monthly=120 ;;
                *xlarge*) monthly=240 ;;
                *2xlarge*) monthly=480 ;;
                *) monthly=100 ;;
            esac
            # Add storage cost
            storage_cost=$(echo "scale=2; $storage * 0.115" | bc)
            total_monthly=$(echo "scale=2; $monthly + $storage_cost" | bc)
            RDS_MONTHLY=$(echo "scale=2; $RDS_MONTHLY + $total_monthly" | bc)
            printf "  %-25s %-15s %s %dGB  ${YELLOW}\$%.2f/mo${NC}\n" "$db_id" "$class" "$engine" "$storage" "$total_monthly"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$RDS_INSTANCES"
    add_to_total $RDS_MONTHLY
    [ ! -z "$RDS_INSTANCES" ] && printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$RDS_MONTHLY"
fi
echo ""

# DynamoDB Tables
echo -e "${BOLD}DynamoDB Tables:${NC}"
DYNAMO_MONTHLY=0
DYNAMO_TABLES=$(aws dynamodb list-tables --region $REGION --output text 2>/dev/null | grep -v TABLENAMES || echo "")
if [ -z "$DYNAMO_TABLES" ]; then
    echo "  ✓ No DynamoDB tables"
else
    table_count=0
    for table in $DYNAMO_TABLES; do
        billing=$(aws dynamodb describe-table --table-name $table --region $REGION \
            --query 'Table.BillingModeSummary.BillingMode' --output text 2>/dev/null || echo "PAY_PER_REQUEST")
        if [ "$billing" == "PROVISIONED" ]; then
            # Provisioned tables have ongoing costs
            monthly=25.00  # Estimate
            DYNAMO_MONTHLY=$(echo "scale=2; $DYNAMO_MONTHLY + $monthly" | bc)
            printf "  %-30s PROVISIONED  ${YELLOW}\$%.2f/mo${NC}\n" "$table" "$monthly"
        else
            printf "  %-30s ON-DEMAND\n" "$table"
        fi
        ((table_count++))
        ((RESOURCE_COUNT++))
    done
    add_to_total $DYNAMO_MONTHLY
    printf "  ${BOLD}Tables: %d - Estimated: \$%.2f/month${NC}\n" "$table_count" "$DYNAMO_MONTHLY"
fi
echo ""

# ElastiCache Clusters
echo -e "${BOLD}ElastiCache Clusters:${NC}"
CACHE_MONTHLY=0
CACHE_CLUSTERS=$(aws elasticache describe-cache-clusters --region $REGION \
    --query 'CacheClusters[].[CacheClusterId,CacheNodeType,Engine,NumCacheNodes,CacheClusterStatus]' \
    --output text 2>/dev/null || echo "")

if [ -z "$CACHE_CLUSTERS" ]; then
    echo "  ✓ No ElastiCache clusters"
else
    while IFS=$'\t' read -r cluster_id node_type engine nodes status; do
        if [ ! -z "$cluster_id" ] && [ "$status" == "available" ]; then
            # Pricing based on node type
            case $node_type in
                *micro*) hourly=0.008 ;;
                *small*) hourly=0.016 ;;
                *medium*) hourly=0.032 ;;
                *large*) hourly=0.064 ;;
                *xlarge*) hourly=0.128 ;;
                *) hourly=0.05 ;;
            esac
            monthly=$(echo "scale=2; $hourly * 730 * $nodes" | bc)
            CACHE_MONTHLY=$(echo "scale=2; $CACHE_MONTHLY + $monthly" | bc)
            printf "  %-25s %-15s %s x%d  ${YELLOW}\$%.2f/mo${NC}\n" "$cluster_id" "$node_type" "$engine" "$nodes" "$monthly"
            ((RESOURCE_COUNT++))
        fi
    done <<< "$CACHE_CLUSTERS"
    add_to_total $CACHE_MONTHLY
    [ ! -z "$CACHE_CLUSTERS" ] && printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$CACHE_MONTHLY"
fi
echo ""

# ==============================================================================
# 5. NETWORKING SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ NETWORKING SERVICES ━━━${NC}"
echo ""

# VPCs
echo -e "${BOLD}VPCs:${NC}"
VPC_COUNT=$(aws ec2 describe-vpcs --region $REGION --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)
echo "  Found $VPC_COUNT VPCs (no direct cost)"
echo ""

# NAT Gateways
echo -e "${BOLD}NAT Gateways:${NC}"
NAT_MONTHLY=0
NAT_GWS=$(aws ec2 describe-nat-gateways --region $REGION \
    --filter "Name=state,Values=available" \
    --query 'NatGateways[].[NatGatewayId,Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

if [ -z "$NAT_GWS" ]; then
    NAT_COUNT=0
else
    NAT_COUNT=$(echo "$NAT_GWS" | grep -c "nat-" 2>/dev/null || echo 0)
    # Take only first line if multiple
    NAT_COUNT=$(echo "$NAT_COUNT" | head -1)
    NAT_COUNT=${NAT_COUNT:-0}
fi
if [ "$NAT_COUNT" -eq 0 ] || [ -z "$NAT_GWS" ]; then
    echo "  ✓ No NAT Gateways"
else
    while IFS=$'\t' read -r gw_id name; do
        if [ ! -z "$gw_id" ]; then
            monthly=$(hourly_to_monthly $NAT_GATEWAY_HOURLY)
            printf "  %-25s %-20s ${RED}\$%.2f/mo${NC}\n" "$gw_id" "${name:-unnamed}" "$monthly"
            NAT_MONTHLY=$(echo "scale=2; $NAT_MONTHLY + $monthly" | bc)
            ((RESOURCE_COUNT++))
        fi
    done <<< "$NAT_GWS"
    add_to_total $NAT_MONTHLY
    echo -e "  ${RED}⚠ NAT Gateways are expensive! Consider alternatives${NC}"
    printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$NAT_MONTHLY"
fi
echo ""

# Elastic IPs
echo -e "${BOLD}Elastic IPs:${NC}"
EIP_MONTHLY=0
UNATTACHED_EIPS=$(aws ec2 describe-addresses --region $REGION \
    --query 'Addresses[?AssociationId==`null`].[PublicIp,AllocationId]' \
    --output text 2>/dev/null || echo "")

if [ -z "$UNATTACHED_EIPS" ]; then
    EIP_COUNT=0
else
    EIP_COUNT=$(echo "$UNATTACHED_EIPS" | grep -c "\." 2>/dev/null || echo 0)
    # Take only first line if multiple
    EIP_COUNT=$(echo "$EIP_COUNT" | head -1)
    EIP_COUNT=${EIP_COUNT:-0}
fi
if [ "$EIP_COUNT" -eq 0 ] || [ -z "$UNATTACHED_EIPS" ]; then
    echo "  ✓ No unattached Elastic IPs"
else
    echo -e "  ${RED}⚠ Unattached Elastic IPs (charged):${NC}"
    while IFS=$'\t' read -r ip alloc_id; do
        if [ ! -z "$ip" ]; then
            monthly=$(hourly_to_monthly $EC2_ELASTIC_IP_HOURLY)
            printf "    %s (%s) ${YELLOW}\$%.2f/mo${NC}\n" "$ip" "$alloc_id" "$monthly"
            EIP_MONTHLY=$(echo "scale=2; $EIP_MONTHLY + $monthly" | bc)
            ((RESOURCE_COUNT++))
        fi
    done <<< "$UNATTACHED_EIPS"
    add_to_total $EIP_MONTHLY
    printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$EIP_MONTHLY"
fi
echo ""

# Load Balancers
echo -e "${BOLD}Load Balancers:${NC}"
LB_MONTHLY=0

# ALBs
ALB_COUNT=$(aws elbv2 describe-load-balancers --region $REGION \
    --query 'length(LoadBalancers[?Type==`application`])' --output text 2>/dev/null || echo 0)
if [ "$ALB_COUNT" -gt 0 ]; then
    alb_monthly=$(echo "scale=2; $ALB_HOURLY * 730 * $ALB_COUNT" | bc)
    LB_MONTHLY=$(echo "scale=2; $LB_MONTHLY + $alb_monthly" | bc)
    printf "  Application Load Balancers: %d @ ${YELLOW}\$%.2f/mo${NC}\n" "$ALB_COUNT" "$alb_monthly"
    ((RESOURCE_COUNT+=$ALB_COUNT))
fi

# NLBs
NLB_COUNT=$(aws elbv2 describe-load-balancers --region $REGION \
    --query 'length(LoadBalancers[?Type==`network`])' --output text 2>/dev/null || echo 0)
if [ "$NLB_COUNT" -gt 0 ]; then
    nlb_monthly=$(echo "scale=2; $NLB_HOURLY * 730 * $NLB_COUNT" | bc)
    LB_MONTHLY=$(echo "scale=2; $LB_MONTHLY + $nlb_monthly" | bc)
    printf "  Network Load Balancers: %d @ ${YELLOW}\$%.2f/mo${NC}\n" "$NLB_COUNT" "$nlb_monthly"
    ((RESOURCE_COUNT+=$NLB_COUNT))
fi

# Classic Load Balancers
CLB_COUNT=$(aws elb describe-load-balancers --region $REGION \
    --query 'length(LoadBalancerDescriptions)' --output text 2>/dev/null || echo 0)
if [ "$CLB_COUNT" -gt 0 ]; then
    clb_monthly=$(echo "scale=2; $ALB_HOURLY * 730 * $CLB_COUNT" | bc)
    LB_MONTHLY=$(echo "scale=2; $LB_MONTHLY + $clb_monthly" | bc)
    printf "  Classic Load Balancers: %d @ ${YELLOW}\$%.2f/mo${NC}\n" "$CLB_COUNT" "$clb_monthly"
    ((RESOURCE_COUNT+=$CLB_COUNT))
fi

if [ "$(echo "$LB_MONTHLY > 0" | bc)" -eq 1 ]; then
    add_to_total $LB_MONTHLY
    printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$LB_MONTHLY"
else
    echo "  ✓ No Load Balancers"
fi
echo ""

# CloudFront Distributions
echo -e "${BOLD}CloudFront Distributions:${NC}"
CF_COUNT=$(aws cloudfront list-distributions --query 'DistributionList.Quantity' --output text 2>/dev/null || echo 0)
# Handle None or invalid values
if [ "$CF_COUNT" = "None" ] || [ -z "$CF_COUNT" ]; then
    CF_COUNT=0
fi
if [ "$CF_COUNT" -eq 0 ]; then
    echo "  ✓ No CloudFront distributions"
else
    echo "  Found $CF_COUNT distributions (usage-based pricing)"
    ((RESOURCE_COUNT+=$CF_COUNT))
fi
echo ""

# Route 53 Hosted Zones
echo -e "${BOLD}Route 53 Hosted Zones:${NC}"
R53_MONTHLY=0
R53_ZONES=$(aws route53 list-hosted-zones --query 'length(HostedZones)' --output text 2>/dev/null || echo 0)
# Handle None or invalid values
if [ "$R53_ZONES" = "None" ] || [ -z "$R53_ZONES" ]; then
    R53_ZONES=0
fi
if [ "$R53_ZONES" -eq 0 ]; then
    echo "  ✓ No Route 53 hosted zones"
else
    R53_MONTHLY=$(echo "scale=2; $R53_ZONES * $ROUTE53_HOSTED_ZONE_MONTHLY" | bc)
    add_to_total $R53_MONTHLY
    printf "  %d zones @ \$0.50/zone = ${YELLOW}\$%.2f/mo${NC}\n" "$R53_ZONES" "$R53_MONTHLY"
    ((RESOURCE_COUNT+=$R53_ZONES))
fi
echo ""

# VPN Connections
echo -e "${BOLD}VPN Connections:${NC}"
VPN_MONTHLY=0
VPN_CONNS=$(aws ec2 describe-vpn-connections --region $REGION \
    --filter "Name=state,Values=available" \
    --query 'length(VpnConnections)' --output text 2>/dev/null || echo 0)

if [ "$VPN_CONNS" -eq 0 ]; then
    echo "  ✓ No VPN connections"
else
    VPN_MONTHLY=$(echo "scale=2; $VPN_CONNECTION_HOURLY * 730 * $VPN_CONNS" | bc)
    add_to_total $VPN_MONTHLY
    printf "  %d connections @ ${YELLOW}\$%.2f/mo${NC}\n" "$VPN_CONNS" "$VPN_MONTHLY"
    ((RESOURCE_COUNT+=$VPN_CONNS))
fi
echo ""

# ==============================================================================
# 6. ANALYTICS & ML SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ ANALYTICS & ML SERVICES ━━━${NC}"
echo ""

# Kinesis Streams
echo -e "${BOLD}Kinesis Data Streams:${NC}"
KINESIS_MONTHLY=0
KINESIS_STREAMS=$(aws kinesis list-streams --region $REGION --output text 2>/dev/null | grep -v STREAMNAMES || echo "")
if [ -z "$KINESIS_STREAMS" ]; then
    echo "  ✓ No Kinesis streams"
else
    stream_count=0
    for stream in $KINESIS_STREAMS; do
        shards=$(aws kinesis describe-stream-summary --stream-name $stream --region $REGION \
            --query 'StreamDescriptionSummary.OpenShardCount' --output text 2>/dev/null || echo 1)
        monthly=$(echo "scale=2; $KINESIS_SHARD_HOURLY * 730 * $shards" | bc)
        KINESIS_MONTHLY=$(echo "scale=2; $KINESIS_MONTHLY + $monthly" | bc)
        printf "  %-30s %d shards  ${YELLOW}\$%.2f/mo${NC}\n" "$stream" "$shards" "$monthly"
        ((stream_count++))
        ((RESOURCE_COUNT++))
    done
    add_to_total $KINESIS_MONTHLY
    printf "  ${BOLD}Subtotal: \$%.2f/month${NC}\n" "$KINESIS_MONTHLY"
fi
echo ""

# SageMaker Endpoints & Notebooks
echo -e "${BOLD}SageMaker:${NC}"
SM_ENDPOINTS=$(aws sagemaker list-endpoints --region $REGION --query 'length(Endpoints)' --output text 2>/dev/null || echo 0)
SM_NOTEBOOKS=$(aws sagemaker list-notebook-instances --region $REGION --query 'length(NotebookInstances)' --output text 2>/dev/null || echo 0)

if [ "$SM_ENDPOINTS" -eq 0 ] && [ "$SM_NOTEBOOKS" -eq 0 ]; then
    echo "  ✓ No SageMaker resources"
else
    [ "$SM_ENDPOINTS" -gt 0 ] && echo "  Endpoints: $SM_ENDPOINTS (usage-based pricing)"
    [ "$SM_NOTEBOOKS" -gt 0 ] && echo "  Notebook instances: $SM_NOTEBOOKS"
    ((RESOURCE_COUNT+=$SM_ENDPOINTS))
    ((RESOURCE_COUNT+=$SM_NOTEBOOKS))
fi
echo ""

# Glue Jobs
echo -e "${BOLD}AWS Glue:${NC}"
GLUE_JOBS=$(aws glue get-jobs --region $REGION --query 'length(Jobs)' --output text 2>/dev/null || echo 0)
if [ "$GLUE_JOBS" -eq 0 ]; then
    echo "  ✓ No Glue jobs"
else
    echo "  Found $GLUE_JOBS jobs (usage-based pricing)"
    ((RESOURCE_COUNT+=$GLUE_JOBS))
fi
echo ""

# ==============================================================================
# 7. OTHER SERVICES
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━ OTHER SERVICES ━━━${NC}"
echo ""

# CloudWatch
echo -e "${BOLD}CloudWatch:${NC}"
CW_MONTHLY=0

# Custom metrics
CW_METRICS=$(aws cloudwatch list-metrics --region $REGION \
    --query 'length(Metrics[?Namespace!=`AWS/EC2` && Namespace!=`AWS/S3` && Namespace!=`AWS/Lambda`])' \
    --output text 2>/dev/null | tr -d '\n\r' || echo 0)
# Handle potential newlines in output
CW_METRICS=$(echo "$CW_METRICS" | tr -d ' ' | head -1)
if ! [[ "$CW_METRICS" =~ ^[0-9]+$ ]]; then
    CW_METRICS=0
fi

# Dashboards
CW_DASHBOARDS=$(aws cloudwatch list-dashboards --region $REGION \
    --query 'length(DashboardEntries)' --output text 2>/dev/null || echo 0)

# Log groups
CW_LOGS=$(aws logs describe-log-groups --region $REGION \
    --query 'length(logGroups)' --output text 2>/dev/null || echo 0)

# Limit metrics to reasonable number
if [ "$CW_METRICS" -gt 10000 ]; then
    CW_METRICS=0  # Likely an error
fi

if [ "$CW_METRICS" -gt 0 ] && [ "$CW_METRICS" -lt 10000 ]; then
    metric_cost=$(echo "scale=2; $CW_METRICS * $CLOUDWATCH_METRIC_MONTHLY" | bc 2>/dev/null || echo "0.00")
    CW_MONTHLY=$(echo "scale=2; $CW_MONTHLY + $metric_cost" | bc 2>/dev/null || echo "0.00")
    printf "  Custom Metrics: %d @ ${YELLOW}\$%.2f/mo${NC}\n" "$CW_METRICS" "$metric_cost"
    ((RESOURCE_COUNT+=$CW_METRICS))
fi

if [ "$CW_DASHBOARDS" -gt 0 ]; then
    dash_cost=$(echo "scale=2; $CW_DASHBOARDS * $CLOUDWATCH_DASHBOARD_MONTHLY" | bc 2>/dev/null || echo "0.00")
    CW_MONTHLY=$(echo "scale=2; $CW_MONTHLY + $dash_cost" | bc 2>/dev/null || echo "0.00")
    printf "  Dashboards: %d @ ${YELLOW}\$%.2f/mo${NC}\n" "$CW_DASHBOARDS" "$dash_cost"
    ((RESOURCE_COUNT+=$CW_DASHBOARDS))
fi

echo "  Log Groups: $CW_LOGS (usage-based pricing)"
[ "$CW_LOGS" -gt 0 ] && ((RESOURCE_COUNT+=$CW_LOGS))

if [ "$(echo "$CW_MONTHLY > 0" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
    add_to_total $CW_MONTHLY
    printf "  ${BOLD}Estimated: \$%.2f/month${NC}\n" "$CW_MONTHLY"
fi
echo ""

# SNS Topics
echo -e "${BOLD}SNS Topics:${NC}"
SNS_TOPICS=$(aws sns list-topics --region $REGION --query 'length(Topics)' --output text 2>/dev/null || echo 0)
if [ "$SNS_TOPICS" -eq 0 ]; then
    echo "  ✓ No SNS topics"
else
    echo "  Found $SNS_TOPICS topics (usage-based pricing)"
    ((RESOURCE_COUNT+=$SNS_TOPICS))
fi
echo ""

# SQS Queues
echo -e "${BOLD}SQS Queues:${NC}"
SQS_QUEUES=$(aws sqs list-queues --region $REGION --query 'length(QueueUrls)' --output text 2>/dev/null || echo 0)
if [ "$SQS_QUEUES" -eq 0 ]; then
    echo "  ✓ No SQS queues"
else
    echo "  Found $SQS_QUEUES queues (usage-based pricing)"
    ((RESOURCE_COUNT+=$SQS_QUEUES))
fi
echo ""

# Secrets Manager
echo -e "${BOLD}Secrets Manager:${NC}"
SECRETS_COUNT=$(aws secretsmanager list-secrets --region $REGION --query 'length(SecretList)' --output text 2>/dev/null || echo 0)
if [ "$SECRETS_COUNT" -eq 0 ]; then
    echo "  ✓ No secrets"
else
    SECRETS_MONTHLY=$(echo "scale=2; $SECRETS_COUNT * $SECRETS_MANAGER_SECRET_MONTHLY" | bc)
    add_to_total $SECRETS_MONTHLY
    printf "  %d secrets @ \$0.40/secret = ${YELLOW}\$%.2f/mo${NC}\n" "$SECRETS_COUNT" "$SECRETS_MONTHLY"
    ((RESOURCE_COUNT+=$SECRETS_COUNT))
fi
echo ""

# WAF
echo -e "${BOLD}WAF Web ACLs:${NC}"
WAF_ACLS=$(aws wafv2 list-web-acls --scope REGIONAL --region $REGION \
    --query 'length(WebACLs)' --output text 2>/dev/null || echo 0)
if [ "$WAF_ACLS" -eq 0 ]; then
    echo "  ✓ No WAF Web ACLs"
else
    WAF_MONTHLY=$(echo "scale=2; $WAF_ACLS * $WAF_WEB_ACL_MONTHLY" | bc)
    add_to_total $WAF_MONTHLY
    printf "  %d Web ACLs @ \$5/ACL = ${YELLOW}\$%.2f/mo${NC}\n" "$WAF_ACLS" "$WAF_MONTHLY"
    ((RESOURCE_COUNT+=$WAF_ACLS))
fi
echo ""

# Backup Plans
echo -e "${BOLD}AWS Backup:${NC}"
BACKUP_PLANS=$(aws backup list-backup-plans --region $REGION --query 'length(BackupPlansList)' --output text 2>/dev/null || echo 0)
if [ "$BACKUP_PLANS" -eq 0 ]; then
    echo "  ✓ No backup plans"
else
    echo "  Found $BACKUP_PLANS backup plans (storage-based pricing)"
    ((RESOURCE_COUNT+=$BACKUP_PLANS))
fi
echo ""

# ==============================================================================
# SUMMARY
# ==============================================================================

echo ""
echo "======================================================="
echo -e "${BOLD}                    COST SUMMARY${NC}"
echo "======================================================="
echo ""
echo -e "${BOLD}Total Resources Found: $RESOURCE_COUNT${NC}"
echo ""

# Display breakdown if there are costs
if [ "$(echo "$TOTAL_MONTHLY_COST > 0" | bc)" -eq 1 ]; then
    echo -e "${BOLD}Service Breakdown:${NC}"
    echo "------------------------------------------------------"
    
    # List all services with costs
    [ "$(echo "$EC2_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "EC2 Instances" "$EC2_MONTHLY"
    [ "$(echo "$LIGHTSAIL_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "Lightsail" "$LIGHTSAIL_MONTHLY"
    [ "$(echo "$EKS_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "EKS Clusters" "$EKS_MONTHLY"
    [ "$(echo "$APP_RUNNER_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "App Runner" "$APP_RUNNER_MONTHLY"
    [ "$(echo "$ECR_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "ECR Storage" "$ECR_MONTHLY"
    [ "$(echo "$EBS_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "EBS Volumes" "$EBS_MONTHLY"
    [ "$(echo "$S3_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "S3 Storage" "$S3_MONTHLY"
    [ "$(echo "$EFS_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "EFS Storage" "$EFS_MONTHLY"
    [ "$(echo "$RDS_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "RDS Databases" "$RDS_MONTHLY"
    [ "$(echo "$DYNAMO_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "DynamoDB" "$DYNAMO_MONTHLY"
    [ "$(echo "$CACHE_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "ElastiCache" "$CACHE_MONTHLY"
    [ "$(echo "$NAT_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${RED}\$%8.2f/month${NC}\n" "NAT Gateways" "$NAT_MONTHLY"
    [ "$(echo "$EIP_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "Elastic IPs" "$EIP_MONTHLY"
    [ "$(echo "$LB_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "Load Balancers" "$LB_MONTHLY"
    [ "$(echo "$R53_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "Route 53" "$R53_MONTHLY"
    [ "$(echo "$VPN_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "VPN Connections" "$VPN_MONTHLY"
    [ "$(echo "$KINESIS_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "Kinesis Streams" "$KINESIS_MONTHLY"
    [ "$(echo "$CW_MONTHLY > 0" | bc)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "CloudWatch" "$CW_MONTHLY"
    [ "$(echo "${SECRETS_MONTHLY:-0} > 0" | bc 2>/dev/null || echo 0)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "Secrets Manager" "${SECRETS_MONTHLY:-0}"
    [ "$(echo "${WAF_MONTHLY:-0} > 0" | bc 2>/dev/null || echo 0)" -eq 1 ] && printf "  %-30s ${YELLOW}\$%8.2f/month${NC}\n" "WAF" "${WAF_MONTHLY:-0}"
    
    echo "------------------------------------------------------"
fi

# Show total
if [ "$(echo "$TOTAL_MONTHLY_COST > 100" | bc)" -eq 1 ]; then
    COLOR=$RED
elif [ "$(echo "$TOTAL_MONTHLY_COST > 50" | bc)" -eq 1 ]; then
    COLOR=$YELLOW
else
    COLOR=$GREEN
fi

echo ""
echo -e "${BOLD}ESTIMATED MONTHLY COST: ${COLOR}\$$TOTAL_MONTHLY_COST${NC}"
echo ""

# Cost optimization recommendations
if [ "$(echo "$TOTAL_MONTHLY_COST > 50" | bc)" -eq 1 ]; then
    echo "======================================================="
    echo -e "${BOLD}     💡 COST OPTIMIZATION RECOMMENDATIONS${NC}"
    echo "======================================================="
    
    if [ "$(echo "$NAT_MONTHLY > 0" | bc)" -eq 1 ]; then
        echo ""
        echo -e "${RED}1. NAT Gateways (\$$NAT_MONTHLY/month):${NC}"
        echo "   • Most expensive networking component"
        echo "   • Consider NAT instances for lower traffic"
        echo "   • Use single NAT Gateway for dev/test"
        echo "   • Remove if instances don't need internet"
    fi
    
    if [ "$UNATTACHED" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}2. Unattached EBS Volumes ($UNATTACHED volumes):${NC}"
        echo "   • Delete or create snapshots"
        echo "   • Run: aws ec2 describe-volumes --filters 'Name=status,Values=available'"
    fi
    
    if [ "$EIP_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}3. Unattached Elastic IPs (\$$EIP_MONTHLY/month):${NC}"
        echo "   • Release unused Elastic IPs immediately"
        echo "   • Run: aws ec2 release-address --allocation-id <id>"
    fi
    
    if [ "$(echo "$RDS_MONTHLY > 50" | bc)" -eq 1 ]; then
        echo ""
        echo -e "${YELLOW}4. RDS Databases (\$$RDS_MONTHLY/month):${NC}"
        echo "   • Use Aurora Serverless for variable workloads"
        echo "   • Enable auto-stop for dev/test databases"
        echo "   • Consider downsizing instance types"
    fi
    
    echo ""
    echo -e "${GREEN}Quick Actions to Reduce Costs:${NC}"
    echo "   • Run: ./rodngun-cloud decommission lightsail"
    echo "   • Run: ./rodngun-cloud decommission containers"
    echo "   • Delete unattached resources"
    echo "   • Use AWS Cost Explorer for detailed analysis"
fi

echo ""
echo "======================================================="
echo "Note: Costs are estimates based on standard pricing."
echo "Actual costs may vary based on usage, region, and discounts."
echo "Data transfer and request charges not included."
echo "======================================================="
echo ""
echo "Report complete!"