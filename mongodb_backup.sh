#!/bin/bash

# MongoDB Backup Script for RodNGun Lightsail Instance
# Creates BSON backup using mongodump

set -e

# Configuration
INSTANCE_NAME="rodngun-api"
REGION="us-east-1"
KEY_PATH="$HOME/.ssh/rodngun-lightsail-key.pem"
BACKUP_DIR="mongodb_backup_$(date +%Y%m%d_%H%M%S)"
LOCAL_BACKUP_PATH="/Users/davisj77/Projects/rodngun-ai/backups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================"
echo -e "${BLUE}MongoDB BSON Backup${NC}"
echo "======================================"

# Create local backup directory if it doesn't exist
mkdir -p "$LOCAL_BACKUP_PATH"

# Step 1: Get instance IP
echo -e "${YELLOW}Getting Lightsail instance IP...${NC}"
INSTANCE_IP=$(aws lightsail get-instance \
    --instance-name $INSTANCE_NAME \
    --region $REGION \
    --query 'instance.publicIpAddress' \
    --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_IP" ]; then
    # Try to get static IP
    INSTANCE_IP=$(aws lightsail get-static-ip \
        --static-ip-name "${INSTANCE_NAME}-ip" \
        --region $REGION \
        --query 'staticIp.ipAddress' \
        --output text 2>/dev/null || echo "")
fi

if [ -z "$INSTANCE_IP" ]; then
    echo -e "${RED}ERROR: Could not find instance IP address${NC}"
    echo "Make sure the instance $INSTANCE_NAME is running in region $REGION"
    exit 1
fi

echo -e "${GREEN}Instance IP: $INSTANCE_IP${NC}"

# Step 2: Check SSH connectivity
echo -e "${YELLOW}Testing SSH connectivity...${NC}"
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@$INSTANCE_IP "echo 'SSH connection successful'" 2>/dev/null; then
    echo -e "${RED}ERROR: Cannot connect to instance via SSH${NC}"
    echo "Please check:"
    echo "  1. SSH key exists at: $KEY_PATH"
    echo "  2. Instance is running"
    echo "  3. Security group allows SSH (port 22)"
    exit 1
fi

# Step 3: Create BSON backup on remote server
echo -e "${YELLOW}Creating BSON backup on remote server...${NC}"
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@$INSTANCE_IP << 'ENDSSH'
    # Check if MongoDB is running
    if ! systemctl is-active --quiet mongod; then
        echo "Starting MongoDB..."
        sudo systemctl start mongod
        sleep 5
    fi
    
    # Get MongoDB statistics
    echo "MongoDB Statistics:"
    mongo --eval "db.adminCommand('listDatabases')" --quiet | grep -E '"name"|"sizeOnDisk"' || echo "Could not get database list"
    
    # Create backup directory
    BACKUP_DIR="/home/ubuntu/mongodb_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Run mongodump to create BSON backup
    echo "Running mongodump..."
    mongodump --out "$BACKUP_DIR" 2>&1 | grep -v "writing" || true
    
    # Check if rodngun database exists and backup it specifically
    if mongo --eval "db.getMongo().getDBNames().indexOf('rodngun') >= 0" --quiet | grep -q "true"; then
        echo "Backing up rodngun database specifically..."
        mongodump --db rodngun --out "$BACKUP_DIR" 2>&1 | grep -v "writing" || true
    fi
    
    # Compress the backup
    echo "Compressing backup..."
    cd /home/ubuntu
    tar -czf "${BACKUP_DIR}.tar.gz" "$(basename $BACKUP_DIR)"
    
    # Get backup size
    BACKUP_SIZE=$(du -sh "${BACKUP_DIR}.tar.gz" | cut -f1)
    echo "Backup size: $BACKUP_SIZE"
    
    # Clean up uncompressed backup
    rm -rf "$BACKUP_DIR"
    
    echo "$BACKUP_DIR.tar.gz"
ENDSSH

# Get the remote backup filename
REMOTE_BACKUP=$(ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@$INSTANCE_IP "ls -t /home/ubuntu/mongodb_backup_*.tar.gz 2>/dev/null | head -1")

if [ -z "$REMOTE_BACKUP" ]; then
    echo -e "${RED}ERROR: Backup creation failed${NC}"
    exit 1
fi

# Step 4: Download backup to local machine
echo -e "${YELLOW}Downloading backup to local machine...${NC}"
LOCAL_BACKUP_FILE="$LOCAL_BACKUP_PATH/$(basename $REMOTE_BACKUP)"

scp -o StrictHostKeyChecking=no -i "$KEY_PATH" \
    "ubuntu@$INSTANCE_IP:$REMOTE_BACKUP" \
    "$LOCAL_BACKUP_FILE"

if [ -f "$LOCAL_BACKUP_FILE" ]; then
    echo -e "${GREEN}✅ Backup downloaded successfully${NC}"
    echo "Location: $LOCAL_BACKUP_FILE"
    
    # Get file size
    BACKUP_SIZE=$(du -sh "$LOCAL_BACKUP_FILE" | cut -f1)
    echo "Size: $BACKUP_SIZE"
    
    # Step 5: Extract and show contents
    echo -e "${YELLOW}Extracting backup contents...${NC}"
    cd "$LOCAL_BACKUP_PATH"
    tar -xzf "$(basename $LOCAL_BACKUP_FILE)"
    
    # Show backup contents
    EXTRACTED_DIR="${LOCAL_BACKUP_FILE%.tar.gz}"
    EXTRACTED_DIR=$(basename "$EXTRACTED_DIR")
    
    if [ -d "$LOCAL_BACKUP_PATH/$EXTRACTED_DIR" ]; then
        echo -e "${BLUE}Backup Contents:${NC}"
        echo "-------------------"
        
        # List databases
        for db_dir in "$LOCAL_BACKUP_PATH/$EXTRACTED_DIR"/*; do
            if [ -d "$db_dir" ]; then
                DB_NAME=$(basename "$db_dir")
                echo -e "${GREEN}Database: $DB_NAME${NC}"
                
                # Count documents in each collection
                for bson_file in "$db_dir"/*.bson; do
                    if [ -f "$bson_file" ]; then
                        COLLECTION=$(basename "$bson_file" .bson)
                        # Try to get document count (approximate from file size)
                        FILE_SIZE=$(du -sh "$bson_file" | cut -f1)
                        echo "  - Collection: $COLLECTION (Size: $FILE_SIZE)"
                    fi
                done
            fi
        done
        
        echo ""
        echo -e "${GREEN}✅ Backup Summary:${NC}"
        echo "  Compressed backup: $LOCAL_BACKUP_FILE"
        echo "  Extracted to: $LOCAL_BACKUP_PATH/$EXTRACTED_DIR"
        echo ""
        echo "To restore this backup to a local MongoDB:"
        echo "  mongorestore --drop $LOCAL_BACKUP_PATH/$EXTRACTED_DIR"
        echo ""
        echo "To restore specific database:"
        echo "  mongorestore --drop --db rodngun $LOCAL_BACKUP_PATH/$EXTRACTED_DIR/rodngun"
    fi
    
    # Step 6: Optional - Clean up remote backup
    echo -e "${YELLOW}Cleaning up remote backup...${NC}"
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@$INSTANCE_IP "rm -f $REMOTE_BACKUP"
    echo -e "${GREEN}Remote backup cleaned up${NC}"
    
else
    echo -e "${RED}ERROR: Failed to download backup${NC}"
    exit 1
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ MongoDB BSON Backup Complete!${NC}"
echo "======================================"
echo ""
echo "Backup location: $LOCAL_BACKUP_FILE"
echo "Extracted location: $LOCAL_BACKUP_PATH/$EXTRACTED_DIR"
echo ""
echo "Next steps:"
echo "1. To restore to local MongoDB: mongorestore --drop $LOCAL_BACKUP_PATH/$EXTRACTED_DIR"
echo "2. To restore to another server: Copy the tar.gz file and use mongorestore"
echo "3. To import specific collections: Use mongorestore with --collection flag"