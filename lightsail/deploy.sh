#!/bin/bash

# AWS Lightsail Deployment Script for RodNGun API
# This script creates and configures a Lightsail instance for the MVP deployment

set -e

# Configuration
INSTANCE_NAME="rodngun-api"
STATIC_IP_NAME="rodngun-api-ip"
REGION="us-east-1"
AVAILABILITY_ZONE="us-east-1a"
BLUEPRINT_ID="ubuntu_22_04"
BUNDLE_ID="medium_2_0"  # 2 GB RAM, 1 vCPU, 60 GB SSD, $10/month
KEY_PAIR_NAME="rodngun-lightsail-key"
SECURITY_GROUP_NAME="rodngun-api-sg"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "RodNGun API Lightsail Deployment"
echo "======================================"

# Step 1: Check if instance already exists
echo -e "${YELLOW}Checking for existing instance...${NC}"
EXISTING_INSTANCE=$(aws lightsail get-instance --instance-name $INSTANCE_NAME --region $REGION 2>/dev/null || echo "")

if [ ! -z "$EXISTING_INSTANCE" ]; then
    echo -e "${RED}Instance $INSTANCE_NAME already exists!${NC}"
    read -p "Do you want to delete it and create a new one? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Deleting existing instance...${NC}"
        aws lightsail delete-instance --instance-name $INSTANCE_NAME --region $REGION
        echo "Waiting for instance to be deleted (this may take a few minutes)..."
        sleep 60
    else
        echo "Exiting without changes."
        exit 0
    fi
fi

# Step 2: Create SSH key pair if it doesn't exist
echo -e "${YELLOW}Creating SSH key pair...${NC}"
KEY_EXISTS=$(aws lightsail get-key-pair --key-pair-name $KEY_PAIR_NAME --region $REGION 2>/dev/null || echo "")

if [ -z "$KEY_EXISTS" ]; then
    # Create key pair - AWS returns the actual PEM key, not base64 encoded
    aws lightsail create-key-pair \
        --key-pair-name $KEY_PAIR_NAME \
        --region $REGION \
        --query 'privateKeyBase64' \
        --output text > ~/.ssh/${KEY_PAIR_NAME}.pem
    
    chmod 600 ~/.ssh/${KEY_PAIR_NAME}.pem
    echo -e "${GREEN}SSH key created at ~/.ssh/${KEY_PAIR_NAME}.pem${NC}"
else
    echo "SSH key pair already exists"
fi

# Step 3: Create Lightsail instance
echo -e "${YELLOW}Creating Lightsail instance...${NC}"

# Create user data script for initial setup
cat > /tmp/lightsail_user_data.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get install -y python3-pip python3-venv git nginx certbot python3-certbot-nginx wget gnupg software-properties-common

# Install Python 3.11
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update
apt-get install -y python3.11 python3.11-venv python3.11-dev

# Install MongoDB
wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list
apt-get update
apt-get install -y mongodb-org

# Start MongoDB
systemctl start mongod
systemctl enable mongod

# Install Poetry for ubuntu user with Python 3.11
su - ubuntu -c "curl -sSL https://install.python-poetry.org | python3.11 -"
echo 'export PATH="/home/ubuntu/.local/bin:$PATH"' >> /home/ubuntu/.bashrc

# Configure firewall
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 27017/tcp  # MongoDB (restrict this later)
ufw --force enable

echo "Initial setup complete" > /tmp/setup_complete
EOF

# Create the instance
aws lightsail create-instances \
    --instance-names $INSTANCE_NAME \
    --availability-zone $AVAILABILITY_ZONE \
    --region $REGION \
    --blueprint-id $BLUEPRINT_ID \
    --bundle-id $BUNDLE_ID \
    --key-pair-name $KEY_PAIR_NAME \
    --user-data file:///tmp/lightsail_user_data.sh \
    --tags "key=Environment,value=Production" "key=Application,value=RodNGun-API"

echo -e "${GREEN}Instance creation initiated${NC}"

# Step 4: Allocate and attach static IP
echo -e "${YELLOW}Allocating static IP...${NC}"

# Check if static IP already exists
STATIC_IP_EXISTS=$(aws lightsail get-static-ip --static-ip-name $STATIC_IP_NAME --region $REGION 2>/dev/null || echo "")

if [ -z "$STATIC_IP_EXISTS" ]; then
    aws lightsail allocate-static-ip \
        --static-ip-name $STATIC_IP_NAME \
        --region $REGION
    echo -e "${GREEN}Static IP allocated${NC}"
else
    echo "Static IP already exists"
fi

# Wait for instance to be running
echo -e "${YELLOW}Waiting for instance to be running...${NC}"
aws lightsail wait instance-running --instance-name $INSTANCE_NAME --region $REGION 2>/dev/null || {
    for i in {1..30}; do
        STATE=$(aws lightsail get-instance-state --instance-name $INSTANCE_NAME --region $REGION --query 'state.name' --output text 2>/dev/null || echo "pending")
        if [ "$STATE" == "running" ]; then
            break
        fi
        echo "Instance state: $STATE (attempt $i/30)"
        sleep 10
    done
}

# Attach static IP
echo -e "${YELLOW}Attaching static IP to instance...${NC}"
aws lightsail attach-static-ip \
    --static-ip-name $STATIC_IP_NAME \
    --instance-name $INSTANCE_NAME \
    --region $REGION

# Get the static IP address
STATIC_IP=$(aws lightsail get-static-ip --static-ip-name $STATIC_IP_NAME --region $REGION --query 'staticIp.ipAddress' --output text)
echo -e "${GREEN}Static IP attached: $STATIC_IP${NC}"

# Step 5: Configure firewall rules
echo -e "${YELLOW}Configuring firewall rules...${NC}"

# Open necessary ports
aws lightsail put-instance-public-ports \
    --instance-name $INSTANCE_NAME \
    --region $REGION \
    --port-infos \
        "fromPort=22,toPort=22,protocol=tcp,cidrs=0.0.0.0/0" \
        "fromPort=80,toPort=80,protocol=tcp,cidrs=0.0.0.0/0" \
        "fromPort=443,toPort=443,protocol=tcp,cidrs=0.0.0.0/0" \
        "fromPort=8000,toPort=8000,protocol=tcp,cidrs=0.0.0.0/0"

echo -e "${GREEN}Firewall rules configured${NC}"

# Step 6: Create setup script
echo -e "${YELLOW}Creating application setup script...${NC}"

cat > /tmp/setup_rodngun_api.sh << 'EOF'
#!/bin/bash

# Setup script to run on the Lightsail instance

set -e

echo "Setting up RodNGun API..."

# Ensure Poetry is in PATH
export PATH="/home/ubuntu/.local/bin:$PATH"

# Verify Poetry is available
if ! command -v poetry &> /dev/null; then
    echo "Poetry not found. Installing..."
    # Check if Python 3.11 is available first
    if ! command -v python3.11 &> /dev/null; then
        echo "Python 3.11 not available yet. Waiting for system setup..."
        # Try using the default python3 if available
        if command -v python3 &> /dev/null; then
            curl -sSL https://install.python-poetry.org | python3 -
        else
            echo "ERROR: No Python available for Poetry installation"
            exit 1
        fi
    else
        curl -sSL https://install.python-poetry.org | python3.11 -
    fi
    # Update PATH for current session
    export PATH="/home/ubuntu/.local/bin:$PATH"
fi

# The code will be deployed via tarball, not git clone
cd /opt/rodngun-api

# Check if API directory exists
if [ ! -d "api" ]; then
    echo "ERROR: API directory not found. Please deploy the code first."
    exit 1
fi

# Navigate to API directory
cd /opt/rodngun-api/api

# Install Python dependencies with Poetry using Python 3.11
echo "Configuring Poetry environment..."
# Ensure Python 3.11 is available
if ! command -v python3.11 &> /dev/null; then
    echo "WARNING: Python 3.11 not found, using default Python"
    poetry env use python3
else
    echo "Using Python 3.11 for Poetry environment"
    poetry env use python3.11
fi
echo "Installing dependencies..."
poetry install

# Create environment file
cat > .env << 'ENVEOF'
MONGODB_URI=mongodb://localhost:27017
JWT_SECRET_KEY=$(openssl rand -hex 32)
JWT_ALGORITHM=HS256
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-your_api_key_here}
# API Update Control - disabled by default in production
RODNGUN=
ADMIN_API_KEY=${ADMIN_API_KEY:-your-secure-admin-key-here}
ADMIN_API_SECRET=${ADMIN_API_SECRET:-your-secure-admin-secret-here}
ENVEOF

# Create systemd service
sudo tee /etc/systemd/system/rodngun-api.service << 'SVCEOF'
[Unit]
Description=RodNGun API Service
After=network.target mongod.service
Wants=mongod.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/rodngun-api/api
Environment="PATH=/home/ubuntu/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="MONGODB_URI=mongodb://localhost:27017"
ExecStart=/home/ubuntu/.local/bin/poetry run uvicorn src.rodngun_api.main:app --host 0.0.0.0 --port 8000 --workers 2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

# Configure Nginx
sudo tee /etc/nginx/sites-available/rodngun-api << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    
    client_max_body_size 10M;
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
    
    location /health {
        proxy_pass http://127.0.0.1:8000/health;
        access_log off;
    }
}
NGINXEOF

# Enable the site
sudo ln -sf /etc/nginx/sites-available/rodngun-api /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload Nginx
sudo nginx -t
sudo systemctl reload nginx

# Enable and start the API service
sudo systemctl daemon-reload
sudo systemctl enable rodngun-api
sudo systemctl start rodngun-api

echo "Setup complete!"
echo "API should be accessible at http://$1:8000 or http://$1"
echo ""
echo "Check service status: sudo systemctl status rodngun-api"
echo "View logs: sudo journalctl -u rodngun-api -f"
EOF

chmod +x /tmp/setup_rodngun_api.sh

# Step 7: Create backup script
cat > /tmp/backup_script.sh << 'EOF'
#!/bin/bash

# Daily backup script for MongoDB

BACKUP_DIR="/opt/backups"
S3_BUCKET="rodngun-api-backups"
DATE=$(date +%Y%m%d_%H%M%S)

# Create backup directory
mkdir -p $BACKUP_DIR

# Perform MongoDB dump
mongodump --out $BACKUP_DIR/dump_$DATE

# Compress the dump
tar -czf $BACKUP_DIR/backup_$DATE.tar.gz -C $BACKUP_DIR dump_$DATE

# Upload to S3 (requires AWS CLI configured)
aws s3 cp $BACKUP_DIR/backup_$DATE.tar.gz s3://$S3_BUCKET/mongodb/

# Clean up local files older than 7 days
find $BACKUP_DIR -type f -mtime +7 -delete

# Remove uncompressed dump
rm -rf $BACKUP_DIR/dump_$DATE

echo "Backup completed: backup_$DATE.tar.gz"
EOF

# Step 8: Wait for instance to be ready and deploy automatically
echo ""
echo -e "${YELLOW}Waiting for instance to be fully ready...${NC}"

# Function to check if SSH is ready
check_ssh_ready() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$1 "echo 'SSH ready'" 2>/dev/null
}

# Wait for SSH to be available (with timeout)
MAX_ATTEMPTS=40
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if check_ssh_ready $STATIC_IP; then
        echo -e "${GREEN}Instance is ready!${NC}"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo "Waiting for SSH... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
    sleep 5
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo -e "${RED}Timeout waiting for instance to be ready${NC}"
    echo "You may need to complete setup manually"
    exit 1
fi

# Wait for initial setup to complete (Python 3.11, MongoDB, Poetry)
echo "Waiting for initial setup to complete..."
MAX_SETUP_ATTEMPTS=30
SETUP_ATTEMPT=0
while [ $SETUP_ATTEMPT -lt $MAX_SETUP_ATTEMPTS ]; do
    # Check if Python 3.11 and MongoDB are installed
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP \
        "python3.11 --version && systemctl is-active mongod" 2>/dev/null | grep -q "Python 3.11"; then
        echo -e "${GREEN}Initial setup complete!${NC}"
        break
    fi
    SETUP_ATTEMPT=$((SETUP_ATTEMPT + 1))
    echo "Waiting for Python 3.11 and MongoDB... (attempt $SETUP_ATTEMPT/$MAX_SETUP_ATTEMPTS)"
    sleep 10
done

if [ $SETUP_ATTEMPT -eq $MAX_SETUP_ATTEMPTS ]; then
    echo -e "${YELLOW}Initial setup may not be complete. Continuing anyway...${NC}"
fi

# Step 9: Deploy API code automatically
echo ""
echo -e "${YELLOW}Deploying API code...${NC}"

# Get the project root directory
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Create tarball
echo "Creating code archive..."
cd "$PROJECT_ROOT"
tar --exclude='__pycache__' --exclude='.venv' --exclude='*.pyc' --exclude='node_modules' \
    -czf /tmp/rodngun-api.tar.gz api/ 2>/dev/null || {
    echo -e "${RED}Failed to create tarball. Check that api/ directory exists${NC}"
    exit 1
}

# Ensure target directory exists on server
echo "Preparing server directory..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP \
    "sudo mkdir -p /opt/rodngun-api && sudo chown ubuntu:ubuntu /opt/rodngun-api" || {
    echo -e "${RED}Failed to create directory on server${NC}"
    rm -f /tmp/rodngun-api.tar.gz
    exit 1
}

# Copy code to server
echo "Copying code to server..."
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/${KEY_PAIR_NAME}.pem \
    /tmp/rodngun-api.tar.gz ubuntu@$STATIC_IP:/tmp/ || {
    echo -e "${RED}Failed to copy code to server${NC}"
    rm -f /tmp/rodngun-api.tar.gz
    exit 1
}

# Extract on server
echo "Extracting code on server..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP \
    "cd /opt/rodngun-api && tar -xzf /tmp/rodngun-api.tar.gz && rm -f /tmp/rodngun-api.tar.gz && ls -la" || {
    echo -e "${RED}Failed to extract code on server${NC}"
    rm -f /tmp/rodngun-api.tar.gz
    exit 1
}

# Clean up local tarball
rm -f /tmp/rodngun-api.tar.gz
echo "Code deployment complete"

# Step 10: Run setup script
echo ""
echo -e "${YELLOW}Running setup script...${NC}"

# Copy setup script to server
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/${KEY_PAIR_NAME}.pem \
    /tmp/setup_rodngun_api.sh ubuntu@$STATIC_IP:/tmp/ || {
    echo -e "${RED}Failed to copy setup script${NC}"
    exit 1
}

# Run setup script with proper environment
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP \
    "chmod +x /tmp/setup_rodngun_api.sh && source /home/ubuntu/.bashrc && /tmp/setup_rodngun_api.sh $STATIC_IP" || {
    echo -e "${RED}Setup script failed. You may need to debug manually${NC}"
    echo "SSH into server: ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP"
    exit 1
}

# Step 11: Test the API
echo ""
echo -e "${YELLOW}Testing API deployment...${NC}"

# Wait for service to start
sleep 5

# Test health endpoint
HEALTH_CHECK=$(curl -s -o /dev/null -w "%{http_code}" http://$STATIC_IP/health 2>/dev/null || echo "000")

if [ "$HEALTH_CHECK" = "200" ]; then
    echo -e "${GREEN}✓ API is healthy!${NC}"
    API_RESPONSE=$(curl -s http://$STATIC_IP/health)
    echo "Response: $API_RESPONSE"
else
    echo -e "${YELLOW}⚠ API health check returned: $HEALTH_CHECK${NC}"
    echo "Checking service status..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP \
        "sudo systemctl status rodngun-api | head -20"
fi

# Step 12: Output final information
echo ""
echo "======================================"
echo -e "${GREEN}Deployment Complete!${NC}"
echo "======================================"
echo ""
echo "Instance Details:"
echo "  Name: $INSTANCE_NAME"
echo "  IP Address: $STATIC_IP"
echo "  Region: $REGION"
echo "  Monthly Cost: ~\$10-12"
echo ""
echo "API Endpoints:"
echo "  Health: http://$STATIC_IP/health"
echo "  Docs: http://$STATIC_IP/docs"
echo "  API Base: http://$STATIC_IP"
echo ""
echo "SSH Access:"
echo "  ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP"
echo ""
echo "Service Management:"
echo "  Status: ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP 'sudo systemctl status rodngun-api'"
echo "  Logs: ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP 'sudo journalctl -u rodngun-api -f'"
echo "  Restart: ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP 'sudo systemctl restart rodngun-api'"
echo ""
echo "(Optional) Configure domain and SSL:"
echo "  1. Point api.rodngun.us to $STATIC_IP"
echo "  2. Run: ssh -i ~/.ssh/${KEY_PAIR_NAME}.pem ubuntu@$STATIC_IP"
echo "  3. Run: sudo certbot --nginx -d api.rodngun.us --non-interactive --agree-tos -m admin@rodngun.us --redirect"
echo ""
echo "Backup script available at: /tmp/backup_script.sh"