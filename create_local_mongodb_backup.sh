#!/bin/bash

# Create BSON Backup from Local Data Files
# This script converts local JSON regulation and boundary data to MongoDB BSON format

set -e

# Configuration
PROJECT_DIR="/Users/davisj77/Projects/rodngun-ai"
REGULATION_DIR="$PROJECT_DIR/src/rodngun_ai/json"
BOUNDARY_DIR="$PROJECT_DIR/boundary_data"
BACKUP_DIR="$PROJECT_DIR/backups/mongodb_local_backup_$(date +%Y%m%d_%H%M%S)"
TEMP_DB_DIR="$BACKUP_DIR/temp_import"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "======================================"
echo -e "${BLUE}MongoDB BSON Backup Creation${NC}"
echo "======================================"
echo ""
echo "This will create a BSON backup from:"
echo "  - Regulations: $REGULATION_DIR"
echo "  - Boundaries: $BOUNDARY_DIR"
echo ""

# Check if MongoDB is running locally
if ! pgrep -x "mongod" > /dev/null; then
    echo -e "${YELLOW}MongoDB is not running locally. Starting MongoDB...${NC}"
    if command -v mongod &> /dev/null; then
        # Try to start MongoDB in background
        mongod --fork --logpath /tmp/mongodb.log --dbpath /tmp/mongodb_data 2>/dev/null || {
            echo -e "${YELLOW}Using brew services to start MongoDB...${NC}"
            brew services start mongodb-community 2>/dev/null || {
                echo -e "${RED}Could not start MongoDB. Please start it manually.${NC}"
                echo "Try: brew services start mongodb-community"
                exit 1
            }
        }
        sleep 3
    else
        echo -e "${RED}MongoDB is not installed locally.${NC}"
        echo "Install with: brew install mongodb-community"
        exit 1
    fi
fi

# Create backup directory structure
echo -e "${YELLOW}Creating backup directory structure...${NC}"
mkdir -p "$BACKUP_DIR"
mkdir -p "$TEMP_DB_DIR"

# Step 1: Import regulation data into temporary MongoDB database
echo -e "${CYAN}Step 1: Processing regulation data...${NC}"
echo "----------------------------------------"

# Count regulation files
REGULATION_COUNT=$(ls -1 "$REGULATION_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "Found $REGULATION_COUNT regulation files"

# Create a combined regulations file for easier import
COMBINED_REGULATIONS="$TEMP_DB_DIR/regulations_combined.json"
echo "[" > "$COMBINED_REGULATIONS"

FIRST=true
for file in "$REGULATION_DIR"/*.json; do
    if [ -f "$file" ]; then
        STATE=$(basename "$file" .json)
        echo "  Processing: $STATE"
        
        # Add comma if not first entry
        if [ "$FIRST" = false ]; then
            echo "," >> "$COMBINED_REGULATIONS"
        fi
        FIRST=false
        
        # Add state identifier to each record and append
        jq --arg state "$STATE" '. + {state_file: $state, import_date: now | todate}' "$file" >> "$COMBINED_REGULATIONS" 2>/dev/null || {
            # If jq fails, just copy the content
            cat "$file" >> "$COMBINED_REGULATIONS"
        }
    fi
done

echo "]" >> "$COMBINED_REGULATIONS"

# Import regulations to MongoDB
echo -e "${YELLOW}Importing regulations to temporary MongoDB...${NC}"
mongoimport --db rodngun_backup --collection regulations \
    --drop --jsonArray \
    --file "$COMBINED_REGULATIONS" 2>&1 | grep -E "imported|documents" || true

# Step 2: Process boundary data
echo ""
echo -e "${CYAN}Step 2: Processing boundary data...${NC}"
echo "----------------------------------------"

BOUNDARY_COUNT=$(ls -1 "$BOUNDARY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
echo "Found $BOUNDARY_COUNT boundary files"

# Process each boundary file separately due to size
for file in "$BOUNDARY_DIR"/*.json; do
    if [ -f "$file" ]; then
        STATE=$(basename "$file" .json | sed 's/_boundaries//')
        echo "  Processing boundary: $STATE"
        
        # Create temporary file with state metadata
        TEMP_BOUNDARY="$TEMP_DB_DIR/${STATE}_boundary_temp.json"
        
        # Check if file is valid JSON first
        if jq empty "$file" 2>/dev/null; then
            # Add metadata and import
            jq --arg state "$STATE" '. + {state: $state, import_date: now | todate}' "$file" > "$TEMP_BOUNDARY"
            
            # Import to MongoDB
            mongoimport --db rodngun_backup --collection boundaries \
                --file "$TEMP_BOUNDARY" 2>&1 | grep -E "imported|documents" || true
        else
            echo "    ⚠️  Skipping $STATE - Invalid JSON format"
        fi
        
        # Clean up temp file
        rm -f "$TEMP_BOUNDARY"
    fi
done

# Step 3: Add indexes and metadata
echo ""
echo -e "${CYAN}Step 3: Creating indexes and metadata...${NC}"
echo "----------------------------------------"

mongo rodngun_backup --eval '
    // Create indexes for regulations
    db.regulations.createIndex({state_file: 1});
    db.regulations.createIndex({species: 1});
    db.regulations.createIndex({"location.state": 1});
    
    // Create indexes for boundaries
    db.boundaries.createIndex({state: 1});
    db.boundaries.createIndex({"properties.STATE": 1});
    
    // Add metadata collection
    db.import_metadata.insertOne({
        import_date: new Date(),
        regulation_count: db.regulations.countDocuments(),
        boundary_count: db.boundaries.countDocuments(),
        source: "Local JSON files",
        version: "1.0"
    });
    
    // Print statistics
    print("Database Statistics:");
    print("  Regulations: " + db.regulations.countDocuments() + " documents");
    print("  Boundaries: " + db.boundaries.countDocuments() + " documents");
    print("  Total size: " + (db.stats().dataSize / 1024 / 1024).toFixed(2) + " MB");
' --quiet

# Step 4: Create BSON dump
echo ""
echo -e "${CYAN}Step 4: Creating BSON dump...${NC}"
echo "----------------------------------------"

DUMP_DIR="$BACKUP_DIR/dump"
mongodump --db rodngun_backup --out "$DUMP_DIR" 2>&1 | grep -v "writing" || true

# Step 5: Compress the backup
echo ""
echo -e "${CYAN}Step 5: Compressing backup...${NC}"
echo "----------------------------------------"

cd "$BACKUP_DIR"
tar -czf "rodngun_mongodb_backup.tar.gz" dump/
BACKUP_SIZE=$(du -sh "rodngun_mongodb_backup.tar.gz" | cut -f1)
echo "Compressed backup size: $BACKUP_SIZE"

# Step 6: Create deployment script
echo ""
echo -e "${CYAN}Step 6: Creating deployment script...${NC}"
echo "----------------------------------------"

cat > "$BACKUP_DIR/deploy_to_lightsail.sh" << 'DEPLOY_SCRIPT'
#!/bin/bash
# Deploy this backup to Lightsail MongoDB instance

INSTANCE_IP="$1"
KEY_PATH="$2"
BACKUP_FILE="rodngun_mongodb_backup.tar.gz"

if [ -z "$INSTANCE_IP" ] || [ -z "$KEY_PATH" ]; then
    echo "Usage: $0 <instance-ip> <ssh-key-path>"
    exit 1
fi

echo "Uploading backup to Lightsail instance..."
scp -o StrictHostKeyChecking=no -i "$KEY_PATH" "$BACKUP_FILE" ubuntu@$INSTANCE_IP:/tmp/

echo "Restoring backup on remote MongoDB..."
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ubuntu@$INSTANCE_IP << 'ENDSSH'
    cd /tmp
    tar -xzf rodngun_mongodb_backup.tar.gz
    
    # Stop any running API to prevent conflicts
    sudo systemctl stop rodngun-api 2>/dev/null || true
    
    # Restore the backup
    mongorestore --drop --db rodngun dump/rodngun_backup/
    
    # Restart API
    sudo systemctl start rodngun-api 2>/dev/null || true
    
    # Clean up
    rm -rf dump/ rodngun_mongodb_backup.tar.gz
    
    echo "Backup restored successfully!"
ENDSSH
DEPLOY_SCRIPT

chmod +x "$BACKUP_DIR/deploy_to_lightsail.sh"

# Step 7: Clean up temporary MongoDB database (optional)
echo ""
echo -e "${CYAN}Step 7: Cleaning up...${NC}"
echo "----------------------------------------"
echo "Dropping temporary database..."
mongo rodngun_backup --eval "db.dropDatabase()" --quiet

# Remove temporary files
rm -rf "$TEMP_DB_DIR"

# Final summary
echo ""
echo "======================================"
echo -e "${GREEN}✅ BSON Backup Created Successfully!${NC}"
echo "======================================"
echo ""
echo -e "${BLUE}Backup Location:${NC}"
echo "  Directory: $BACKUP_DIR"
echo "  BSON dump: $BACKUP_DIR/dump/"
echo "  Compressed: $BACKUP_DIR/rodngun_mongodb_backup.tar.gz"
echo ""
echo -e "${BLUE}Contents:${NC}"
echo "  - Regulations: $REGULATION_COUNT states"
echo "  - Boundaries: $BOUNDARY_COUNT states"
echo "  - Size: $BACKUP_SIZE (compressed)"
echo ""
echo -e "${BLUE}To restore locally:${NC}"
echo "  cd $BACKUP_DIR"
echo "  tar -xzf rodngun_mongodb_backup.tar.gz"
echo "  mongorestore --drop --db rodngun dump/rodngun_backup/"
echo ""
echo -e "${BLUE}To deploy to Lightsail:${NC}"
echo "  cd $BACKUP_DIR"
echo "  ./deploy_to_lightsail.sh <instance-ip> <ssh-key-path>"
echo ""
echo "Or update the main deployment with:"
echo "  $PROJECT_DIR/scripts/rodngun-cloud deploy-data"