-- PostgreSQL Database Schema for RodNGun Data Management
-- This database stores all data sources, PDFs, and boundary files for quarterly updates

-- Create database if not exists (run as superuser)
-- CREATE DATABASE rodngun_sources;

-- Connect to rodngun_sources database
-- \c rodngun_sources;

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Drop existing tables if they exist (for clean setup)
DROP TABLE IF EXISTS update_logs CASCADE;
DROP TABLE IF EXISTS boundary_data CASCADE;
DROP TABLE IF EXISTS regulation_data CASCADE;
DROP TABLE IF EXISTS data_sources CASCADE;
DROP TABLE IF EXISTS states CASCADE;

-- States table
CREATE TABLE states (
    state_code VARCHAR(2) PRIMARY KEY,
    state_name VARCHAR(50) NOT NULL,
    fips_code VARCHAR(2),
    has_fishing BOOLEAN DEFAULT true,
    has_hunting BOOLEAN DEFAULT true,
    timezone VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Data sources table (master reference for all data sources)
CREATE TABLE data_sources (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_code VARCHAR(2) REFERENCES states(state_code),
    data_type VARCHAR(20) CHECK (data_type IN ('regulation', 'boundary')),
    source_type VARCHAR(20) CHECK (source_type IN ('web_scrape', 'pdf', 'shapefile', 'geojson', 'kml', 'api')),
    source_name VARCHAR(255) NOT NULL,
    source_url TEXT,
    api_endpoint TEXT,
    api_key_required BOOLEAN DEFAULT false,
    scrape_selector TEXT, -- CSS selector or XPath for web scraping
    update_frequency VARCHAR(20) CHECK (update_frequency IN ('quarterly', 'annually', 'monthly', 'as_needed')),
    last_checked TIMESTAMP,
    last_updated TIMESTAMP,
    is_active BOOLEAN DEFAULT true,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(state_code, data_type, source_type, source_name)
);

-- Regulation data table
CREATE TABLE regulation_data (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_id UUID REFERENCES data_sources(id) ON DELETE CASCADE,
    state_code VARCHAR(2) REFERENCES states(state_code),
    regulation_year INTEGER NOT NULL,
    regulation_type VARCHAR(50) CHECK (regulation_type IN ('hunting', 'fishing', 'combined')),
    species_category VARCHAR(50), -- big_game, small_game, waterfowl, fish, etc.
    
    -- URLs and references
    web_url TEXT,
    pdf_url TEXT,
    
    -- Stored documents (BLOBs)
    pdf_document BYTEA, -- PDF stored as binary
    pdf_size_mb NUMERIC(10, 2),
    pdf_pages INTEGER,
    pdf_hash VARCHAR(64), -- SHA256 hash for deduplication
    
    -- Parsed JSON data
    regulations_json JSONB, -- Parsed regulation data
    
    -- Metadata
    effective_date DATE,
    expiration_date DATE,
    version VARCHAR(20),
    last_fetched TIMESTAMP,
    fetch_status VARCHAR(20) CHECK (fetch_status IN ('success', 'failed', 'pending', 'processing')),
    fetch_error TEXT,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Boundary data table
CREATE TABLE boundary_data (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_id UUID REFERENCES data_sources(id) ON DELETE CASCADE,
    state_code VARCHAR(2) REFERENCES states(state_code),
    boundary_type VARCHAR(50) CHECK (boundary_type IN ('county', 'wmu', 'wma', 'state', 'federal_land', 'hunt_unit')),
    boundary_name VARCHAR(255),
    
    -- URLs and references
    web_url TEXT,
    shapefile_url TEXT,
    geojson_url TEXT,
    kml_url TEXT,
    
    -- Stored geographic data (BLOBs)
    shapefile_data BYTEA, -- Shapefile stored as binary (usually zipped)
    geojson_data BYTEA, -- GeoJSON stored as binary
    kml_data BYTEA, -- KML stored as binary
    file_size_mb NUMERIC(10, 2),
    file_hash VARCHAR(64), -- SHA256 hash for deduplication
    
    -- Parsed geographic data
    geometry_json JSONB, -- Simplified geometry for quick access
    properties_json JSONB, -- Properties/attributes
    
    -- Spatial metadata
    bbox_min_lat NUMERIC(10, 6),
    bbox_min_lon NUMERIC(10, 6),
    bbox_max_lat NUMERIC(10, 6),
    bbox_max_lon NUMERIC(10, 6),
    area_sq_km NUMERIC(15, 2),
    perimeter_km NUMERIC(15, 2),
    
    -- Processing metadata
    last_fetched TIMESTAMP,
    fetch_status VARCHAR(20) CHECK (fetch_status IN ('success', 'failed', 'pending', 'processing')),
    fetch_error TEXT,
    simplification_level VARCHAR(20), -- original, medium, high
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Update logs table (track all update operations)
CREATE TABLE update_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_code VARCHAR(2) REFERENCES states(state_code),
    data_type VARCHAR(20) CHECK (data_type IN ('regulation', 'boundary', 'both')),
    update_type VARCHAR(20) CHECK (update_type IN ('manual', 'scheduled', 'api_triggered')),
    started_at TIMESTAMP NOT NULL,
    completed_at TIMESTAMP,
    status VARCHAR(20) CHECK (status IN ('running', 'success', 'partial', 'failed')),
    
    -- Statistics
    records_processed INTEGER DEFAULT 0,
    records_added INTEGER DEFAULT 0,
    records_updated INTEGER DEFAULT 0,
    records_failed INTEGER DEFAULT 0,
    
    -- File statistics
    total_size_mb NUMERIC(10, 2),
    pdfs_downloaded INTEGER DEFAULT 0,
    shapefiles_downloaded INTEGER DEFAULT 0,
    
    -- Error tracking
    error_messages TEXT[],
    warnings TEXT[],
    
    -- Metadata
    initiated_by VARCHAR(100), -- username or system
    notes TEXT,
    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for better performance
CREATE INDEX idx_data_sources_state_type ON data_sources(state_code, data_type);
CREATE INDEX idx_data_sources_active ON data_sources(is_active) WHERE is_active = true;
CREATE INDEX idx_regulation_data_state_year ON regulation_data(state_code, regulation_year);
CREATE INDEX idx_regulation_data_source ON regulation_data(source_id);
CREATE INDEX idx_regulation_data_hash ON regulation_data(pdf_hash);
CREATE INDEX idx_boundary_data_state_type ON boundary_data(state_code, boundary_type);
CREATE INDEX idx_boundary_data_source ON boundary_data(source_id);
CREATE INDEX idx_boundary_data_hash ON boundary_data(file_hash);
CREATE INDEX idx_update_logs_state_date ON update_logs(state_code, started_at DESC);

-- Create update triggers
CREATE OR REPLACE FUNCTION update_modified_time()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_states_modtime BEFORE UPDATE ON states
    FOR EACH ROW EXECUTE FUNCTION update_modified_time();

CREATE TRIGGER update_data_sources_modtime BEFORE UPDATE ON data_sources
    FOR EACH ROW EXECUTE FUNCTION update_modified_time();

CREATE TRIGGER update_regulation_data_modtime BEFORE UPDATE ON regulation_data
    FOR EACH ROW EXECUTE FUNCTION update_modified_time();

CREATE TRIGGER update_boundary_data_modtime BEFORE UPDATE ON boundary_data
    FOR EACH ROW EXECUTE FUNCTION update_modified_time();

-- Insert states data
INSERT INTO states (state_code, state_name, fips_code) VALUES
('AL', 'Alabama', '01'),
('AK', 'Alaska', '02'),
('AZ', 'Arizona', '04'),
('AR', 'Arkansas', '05'),
('CA', 'California', '06'),
('CO', 'Colorado', '08'),
('CT', 'Connecticut', '09'),
('DE', 'Delaware', '10'),
('FL', 'Florida', '12'),
('GA', 'Georgia', '13'),
('HI', 'Hawaii', '15'),
('ID', 'Idaho', '16'),
('IL', 'Illinois', '17'),
('IN', 'Indiana', '18'),
('IA', 'Iowa', '19'),
('KS', 'Kansas', '20'),
('KY', 'Kentucky', '21'),
('LA', 'Louisiana', '22'),
('ME', 'Maine', '23'),
('MD', 'Maryland', '24'),
('MA', 'Massachusetts', '25'),
('MI', 'Michigan', '26'),
('MN', 'Minnesota', '27'),
('MS', 'Mississippi', '28'),
('MO', 'Missouri', '29'),
('MT', 'Montana', '30'),
('NE', 'Nebraska', '31'),
('NV', 'Nevada', '32'),
('NH', 'New Hampshire', '33'),
('NJ', 'New Jersey', '34'),
('NM', 'New Mexico', '35'),
('NY', 'New York', '36'),
('NC', 'North Carolina', '37'),
('ND', 'North Dakota', '38'),
('OH', 'Ohio', '39'),
('OK', 'Oklahoma', '40'),
('OR', 'Oregon', '41'),
('PA', 'Pennsylvania', '42'),
('RI', 'Rhode Island', '44'),
('SC', 'South Carolina', '45'),
('SD', 'South Dakota', '46'),
('TN', 'Tennessee', '47'),
('TX', 'Texas', '48'),
('UT', 'Utah', '49'),
('VT', 'Vermont', '50'),
('VA', 'Virginia', '51'),
('WA', 'Washington', '53'),
('WV', 'West Virginia', '54'),
('WI', 'Wisconsin', '55'),
('WY', 'Wyoming', '56'),
('DC', 'District of Columbia', '11');

-- Create views for easy access
CREATE VIEW v_latest_regulations AS
SELECT DISTINCT ON (state_code)
    state_code,
    regulation_year,
    regulation_type,
    pdf_url,
    regulations_json,
    last_fetched
FROM regulation_data
WHERE fetch_status = 'success'
ORDER BY state_code, regulation_year DESC, last_fetched DESC;

CREATE VIEW v_latest_boundaries AS
SELECT DISTINCT ON (state_code, boundary_type)
    state_code,
    boundary_type,
    boundary_name,
    geometry_json,
    last_fetched
FROM boundary_data
WHERE fetch_status = 'success'
ORDER BY state_code, boundary_type, last_fetched DESC;

-- Grant permissions (adjust as needed)
-- GRANT ALL ON ALL TABLES IN SCHEMA public TO rodngun_user;
-- GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO rodngun_user;

-- Sample comment
COMMENT ON TABLE data_sources IS 'Master reference table for all regulation and boundary data sources';
COMMENT ON TABLE regulation_data IS 'Stores hunting and fishing regulation PDFs and parsed data';
COMMENT ON TABLE boundary_data IS 'Stores geographic boundary files (shapefiles, GeoJSON, KML) and parsed geometries';
COMMENT ON TABLE update_logs IS 'Tracks all data update operations for audit and monitoring';