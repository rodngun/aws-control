#!/bin/bash

# Setup script for RodNGun Data Manager
# Installs PostgreSQL, creates database, and installs Python dependencies

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================"
echo -e "${BLUE}RodNGun Data Manager Setup${NC}"
echo "======================================"

# Step 1: Check for PostgreSQL
echo -e "${YELLOW}Checking PostgreSQL installation...${NC}"

if ! command -v psql &> /dev/null; then
    echo -e "${YELLOW}PostgreSQL not found. Installing...${NC}"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install postgresql@15
            brew services start postgresql@15
        else
            echo -e "${RED}Homebrew not found. Please install PostgreSQL manually.${NC}"
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        sudo apt-get update
        sudo apt-get install -y postgresql postgresql-contrib
        sudo systemctl start postgresql
        sudo systemctl enable postgresql
    else
        echo -e "${RED}Unsupported OS. Please install PostgreSQL manually.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}PostgreSQL is installed${NC}"
    
    # Start PostgreSQL if not running
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew services start postgresql@15 2>/dev/null || true
    else
        sudo systemctl start postgresql 2>/dev/null || true
    fi
fi

# Step 2: Create database and user
echo -e "${YELLOW}Setting up PostgreSQL database...${NC}"

# Set database credentials
DB_NAME="rodngun_sources"
DB_USER="rodngun_user"
DB_PASS="rodngun_pass"

# Create user and database
sudo -u postgres psql << EOF 2>/dev/null || psql << EOF
-- Create user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$DB_USER') THEN
        CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
    END IF;
END
\$\$;

-- Create database if not exists
SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

echo -e "${GREEN}Database '$DB_NAME' configured${NC}"

# Step 3: Initialize database schema
echo -e "${YELLOW}Initializing database schema...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/database/init_postgres.sql"

if [ -f "$SQL_FILE" ]; then
    PGPASSWORD=$DB_PASS psql -U $DB_USER -d $DB_NAME -f "$SQL_FILE" 2>/dev/null || {
        echo -e "${YELLOW}Schema may already exist, continuing...${NC}"
    }
    echo -e "${GREEN}Database schema initialized${NC}"
else
    echo -e "${RED}SQL schema file not found at $SQL_FILE${NC}"
fi

# Step 4: Install Python dependencies
echo -e "${YELLOW}Installing Python dependencies...${NC}"

# Check Python version
if command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
else
    echo -e "${RED}Python not found. Please install Python 3.8+${NC}"
    exit 1
fi

# Install pip if not available
if ! $PYTHON_CMD -m pip --version &> /dev/null; then
    echo "Installing pip..."
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    $PYTHON_CMD get-pip.py
    rm get-pip.py
fi

# Create virtual environment (optional but recommended)
if [ ! -d "$SCRIPT_DIR/venv" ]; then
    echo "Creating virtual environment..."
    $PYTHON_CMD -m venv "$SCRIPT_DIR/venv"
fi

# Activate virtual environment
source "$SCRIPT_DIR/venv/bin/activate" 2>/dev/null || . "$SCRIPT_DIR/venv/bin/activate"

# Install required packages
echo "Installing Python packages..."
pip install --upgrade pip
pip install \
    psycopg2-binary \
    aiohttp \
    requests \
    beautifulsoup4 \
    geopandas \
    shapely \
    pymongo \
    pandas \
    lxml

echo -e "${GREEN}Python dependencies installed${NC}"

# Step 5: Create environment file
echo -e "${YELLOW}Creating environment configuration...${NC}"

ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" << EOL
# API Update Control
# Set RODNGUN=1 to enable API updates via PATCH endpoints
# Leave unset or set to any other value to disable API updates
RODNGUN=

# PostgreSQL Configuration
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=$DB_NAME
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS

# MongoDB Configuration (local)
MONGO_HOST=localhost
MONGO_PORT=27017
MONGO_DB=rodngun

# API Configuration for PATCH Endpoints
# Only used when RODNGUN=1
API_BASE_URL=http://api.rodngun.us
ADMIN_API_KEY=your-secure-admin-key-here
ADMIN_API_SECRET=your-secure-admin-secret-here

# API Keys (add as needed)
# GOOGLE_MAPS_API_KEY=
# CENSUS_API_KEY=

# Environment
ENVIRONMENT=production
EOL
    echo -e "${GREEN}Environment file created at $ENV_FILE${NC}"
    echo -e "${YELLOW}⚠️  API updates are disabled by default. Set RODNGUN=1 to enable.${NC}"
    echo -e "${YELLOW}⚠️  Please update API credentials in $ENV_FILE if needed${NC}"
else
    echo -e "${YELLOW}Environment file already exists${NC}"
fi

# Step 6: Make scripts executable
chmod +x "$SCRIPT_DIR/rodngun-cloud"
chmod +x "$SCRIPT_DIR/create_local_mongodb_backup.sh"

# Step 7: Load initial data sources
echo -e "${YELLOW}Loading initial data sources into database...${NC}"

$PYTHON_CMD << EOF
import json
import psycopg2
from psycopg2.extras import Json

# Load configuration
with open('$SCRIPT_DIR/database/data_sources.json', 'r') as f:
    sources = json.load(f)

# Connect to database
conn = psycopg2.connect(
    host='localhost',
    database='$DB_NAME',
    user='$DB_USER',
    password='$DB_PASS'
)
cur = conn.cursor()

# Insert regulation sources
for state, source in sources['regulation_sources'].items():
    try:
        cur.execute("""
            INSERT INTO data_sources (
                state_code, data_type, source_type, source_name,
                source_url, update_frequency, is_active
            ) VALUES (%s, %s, %s, %s, %s, %s, true)
            ON CONFLICT (state_code, data_type, source_type, source_name) 
            DO UPDATE SET source_url = EXCLUDED.source_url
        """, (
            state, 'regulation', 'pdf', source['name'],
            source['pdf_url'], source['update_frequency']
        ))
    except Exception as e:
        print(f"Warning: {e}")

# Insert boundary sources
for state, source in sources.get('boundary_sources', {}).get('states', {}).items():
    try:
        cur.execute("""
            INSERT INTO data_sources (
                state_code, data_type, source_type, source_name,
                source_url, update_frequency, is_active
            ) VALUES (%s, %s, %s, %s, %s, %s, true)
            ON CONFLICT (state_code, data_type, source_type, source_name)
            DO UPDATE SET source_url = EXCLUDED.source_url
        """, (
            state, 'boundary', source.get('format', 'shapefile'),
            source.get('wmu_source', 'State GIS'),
            source.get('shapefile_url'), 'annually'
        ))
    except Exception as e:
        print(f"Warning: {e}")

conn.commit()
cur.close()
conn.close()
print("Data sources loaded into database")
EOF

echo -e "${GREEN}Initial data sources loaded${NC}"

# Final summary
echo ""
echo "======================================"
echo -e "${GREEN}✅ Setup Complete!${NC}"
echo "======================================"
echo ""
echo "Database Details:"
echo "  Host: localhost"
echo "  Port: 5432"
echo "  Database: $DB_NAME"
echo "  User: $DB_USER"
echo "  Password: $DB_PASS"
echo ""
echo "To use the data manager:"
echo ""
echo "  # Activate virtual environment"
echo "  source $SCRIPT_DIR/venv/bin/activate"
echo ""
echo "To connect to PostgreSQL:"
echo "  psql -U $DB_USER -d $DB_NAME"
echo ""
echo "======================================"