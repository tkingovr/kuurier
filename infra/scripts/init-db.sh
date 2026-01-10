#!/bin/bash
set -e

# This script runs when the PostgreSQL container is first initialized

echo "Initializing Kuurier database..."

# Run the migration file
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" < /docker-entrypoint-initdb.d/001_initial_schema.sql 2>/dev/null || {
    echo "Migration file not found at startup, will be applied manually"
}

echo "Database initialization complete."
