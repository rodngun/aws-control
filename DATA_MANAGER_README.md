# RodNGun Data Manager

## Overview

The RodNGun Data Manager is a comprehensive system for fetching, storing, and updating hunting/fishing regulation and boundary data for all US states. It uses PostgreSQL to store source URLs and BLOB data (PDFs, shapefiles), and automatically updates MongoDB for API serving.

## Features

- **Regulation Data Management**: Downloads and stores hunting/fishing regulation PDFs with metadata
- **Boundary Data Management**: Downloads and stores county/WMU/WMA boundary files (shapefiles, GeoJSON)
- **PostgreSQL Storage**: All source files stored as BLOBs with deduplication via SHA256 hashing
- **MongoDB Integration**: Automatically updates MongoDB with parsed data for API serving
- **Automated Backups**: Creates BSON backups after each update
- **Update Logging**: Complete audit trail of all data updates
- **Batch Processing**: Update single states or all 51 states at once

## Installation

### Prerequisites

- Python 3.8+
- PostgreSQL 12+
- MongoDB 4.4+
- Git

### Quick Setup

```bash
# Run the setup script
cd /Users/davisj77/Projects/rodngun-ai/scripts
./setup_data_manager.sh
```

This will:
1. Install PostgreSQL (if not present)
2. Create database and user
3. Initialize database schema
4. Install Python dependencies
5. Create environment configuration
6. Load initial data sources

### Environment Variables

The following environment variables control the data manager:

| Variable | Default | Description |
|----------|---------|-------------|
| `RODNGUN` | (unset) | Set to `1` to enable API updates. Leave unset or any other value to disable |
| `POSTGRES_HOST` | localhost | PostgreSQL host |
| `POSTGRES_PORT` | 5432 | PostgreSQL port |
| `POSTGRES_DB` | rodngun_sources | PostgreSQL database name |
| `POSTGRES_USER` | rodngun_user | PostgreSQL username |
| `POSTGRES_PASSWORD` | rodngun_pass | PostgreSQL password |
| `API_BASE_URL` | http://api.rodngun.us | Backend API URL (only used when RODNGUN=1) |
| `ADMIN_API_KEY` | (required) | Admin API key for PATCH endpoints (only used when RODNGUN=1) |
| `ADMIN_API_SECRET` | (required) | Admin API secret for HMAC signing (only used when RODNGUN=1) |

Copy `.env.template` to `.env` and configure as needed.

### Manual Setup

1. **Install PostgreSQL**:
```bash
# macOS
brew install postgresql@15
brew services start postgresql@15

# Ubuntu/Debian
sudo apt-get install postgresql postgresql-contrib
sudo systemctl start postgresql
```

2. **Create Database**:
```sql
CREATE USER rodngun_user WITH PASSWORD 'rodngun_pass';
CREATE DATABASE rodngun_sources OWNER rodngun_user;
```

3. **Initialize Schema**:
```bash
psql -U rodngun_user -d rodngun_sources -f scripts/database/init_postgres.sql
```

4. **Install Python Dependencies**:
```bash
pip install psycopg2-binary aiohttp requests beautifulsoup4 geopandas shapely pymongo
```

## Usage

### Basic Commands

```bash
# Fetch regulation data for a single state
./scripts/rodngun-data colorado regulation

# Fetch boundary data for a single state
./scripts/rodngun-data texas boundary

# Fetch both regulation and boundary data
./scripts/rodngun-data wyoming both

# Update all 51 states
./scripts/rodngun-data all regulation
./scripts/rodngun-data all boundary
./scripts/rodngun-data all both

# Fetch data and update API via PATCH endpoints
./scripts/rodngun-data colorado regulation --update-api

# Update API from existing PostgreSQL data (no fetching)
./scripts/rodngun-data all both --api-only
```

### Command Options

```bash
./scripts/rodngun-data <state> <command> [options]

Arguments:
  state     State name, abbreviation, or "all" for all states
  command   Type of data: regulation, boundary, or both

Options:
  --init-db         Initialize database schema
  --skip-mongodb    Skip MongoDB update
  --skip-backup     Skip MongoDB backup creation
  --update-api      Update API via PATCH endpoints after fetching
  --api-only        Only update API from existing PostgreSQL data (skip fetching)
```

### API Integration

The data manager can integrate with the backend API PATCH endpoints when enabled:

#### Security Control

API updates are **disabled by default** for safety. To enable API updates, you must set the `RODNGUN` environment variable to `1`:

```bash
# Enable API updates (required for --update-api and --api-only flags)
export RODNGUN=1

# Set API credentials
export API_BASE_URL="http://api.rodngun.us"
export ADMIN_API_KEY="your-secure-admin-key-here"

# Update API after fetching new data
./scripts/rodngun-data colorado both --update-api

# Update API for all states from existing data
./scripts/rodngun-data all both --api-only
```

**Important**: If `RODNGUN` is not set to `1`, the script will:
- Skip API updates even if `--update-api` or `--api-only` flags are used
- Display a warning message about API updates being disabled
- Continue with all other operations (fetching, PostgreSQL storage, MongoDB updates)

This safety mechanism prevents accidental API updates in production environments.

### Examples

```bash
# Quarterly update for all states
./scripts/rodngun-data all both

# Update specific state after regulation change
./scripts/rodngun-data colorado regulation

# Initialize and update
./scripts/rodngun-data all both --init-db
```

## Database Schema

### PostgreSQL Tables

1. **states**: State reference data
2. **data_sources**: Master list of all data sources with URLs
3. **regulation_data**: Stored regulation PDFs and parsed data
4. **boundary_data**: Stored boundary files and geometries
5. **update_logs**: Audit trail of all updates

### Key Features

- **BLOB Storage**: PDFs and shapefiles stored as binary data
- **Deduplication**: SHA256 hashing prevents duplicate storage
- **Version Tracking**: Complete history of all data updates
- **Metadata**: File sizes, fetch dates, processing status

## Data Sources

### Regulation Sources

All 51 states configured with:
- Official wildlife agency websites
- Direct PDF download URLs
- Update frequency (annual/quarterly)

### Boundary Sources

- **Counties**: US Census Bureau TIGER/Line shapefiles
- **WMUs/WMAs**: State-specific GIS portals
- **Formats**: Shapefile, GeoJSON, KML

## MongoDB Integration

After fetching data, the system:
1. Parses regulation PDFs into structured JSON
2. Converts boundary files to simplified GeoJSON
3. Updates MongoDB collections
4. Creates BSON backup
5. Optionally deploys to Lightsail instance

## Monitoring

### View Update Logs

```sql
-- Connect to PostgreSQL
psql -U rodngun_user -d rodngun_sources

-- Recent updates
SELECT state_code, data_type, status, started_at, completed_at
FROM update_logs
ORDER BY started_at DESC
LIMIT 10;

-- Check data freshness
SELECT state_code, MAX(last_fetched) as last_update
FROM regulation_data
GROUP BY state_code
ORDER BY last_update DESC;
```

### Check Storage Usage

```sql
-- Database size
SELECT pg_database_size('rodngun_sources') / 1024 / 1024 as size_mb;

-- Table sizes
SELECT relname as table_name,
       pg_size_pretty(pg_total_relation_size(relid)) as size
FROM pg_catalog.pg_stattuple_approx(relid)
JOIN pg_class ON pg_class.oid = relid
WHERE relnamespace = 'public'::regnamespace
ORDER BY pg_total_relation_size(relid) DESC;
```

## Scheduling Updates

### Cron Setup for Quarterly Updates

```bash
# Add to crontab (crontab -e)
# Run quarterly on the 1st of Jan, Apr, Jul, Oct at 2 AM
0 2 1 1,4,7,10 * /Users/davisj77/Projects/rodngun-ai/scripts/rodngun-data all both

# Run monthly boundary updates
0 3 1 * * /Users/davisj77/Projects/rodngun-ai/scripts/rodngun-data all boundary

# Run annual regulation updates (September)
0 2 1 9 * /Users/davisj77/Projects/rodngun-ai/scripts/rodngun-data all regulation
```

## Deployment

After updating data locally:

```bash
# Create MongoDB backup
./scripts/rodngun-cloud backup-data

# Deploy to Lightsail
./scripts/rodngun-cloud deploy-data
```

## Troubleshooting

### Database Connection Issues

```bash
# Check PostgreSQL status
brew services list | grep postgresql  # macOS
systemctl status postgresql           # Linux

# Test connection
psql -U rodngun_user -d rodngun_sources -c "SELECT 1"
```

### Missing Data Sources

Edit `scripts/database/data_sources.json` to add/update source URLs.

### Failed Downloads

Check logs:
```sql
SELECT state_code, fetch_status, fetch_error
FROM regulation_data
WHERE fetch_status = 'failed';
```

## Architecture

```
┌─────────────────────────────────┐
│     rodngun-data Script         │
│  (Python Async Data Fetcher)    │
└────────────┬────────────────────┘
             │
    ┌────────▼────────┐
    │   PostgreSQL    │
    │  (Source Data)  │
    │   - PDFs        │
    │   - Shapefiles  │
    │   - Metadata    │
    └────────┬────────┘
             │
    ┌────────▼────────┐
    │    MongoDB      │
    │ (Parsed Data)   │
    │   - JSON        │
    │   - GeoJSON     │
    └────────┬────────┘
             │
    ┌────────▼────────┐
    │  BSON Backup    │
    │   & Deploy      │
    └─────────────────┘
```

## License

Internal use only. Contains references to public data sources.

## Support

For issues or questions, contact the development team.