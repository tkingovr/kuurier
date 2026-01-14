#!/bin/bash
# Database Migration Script for Kuurier
# Usage: ./migrate.sh [up|status|reset]

set -e

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Default database URL
DATABASE_URL="${DATABASE_URL:-postgres://kuurier:kuurier_dev_password@localhost:5432/kuurier?sslmode=disable}"

# Migration directory
MIGRATIONS_DIR="${MIGRATIONS_DIR:-./migrations}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if psql is available
check_psql() {
    if ! command -v psql &> /dev/null; then
        log_error "psql is not installed. Please install PostgreSQL client."
        exit 1
    fi
}

# Create migrations tracking table
create_migrations_table() {
    psql "$DATABASE_URL" -q <<EOF
CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(255) PRIMARY KEY,
    applied_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
EOF
}

# Get list of applied migrations
get_applied_migrations() {
    psql "$DATABASE_URL" -t -A -c "SELECT version FROM schema_migrations ORDER BY version;" 2>/dev/null || echo ""
}

# Apply a single migration
apply_migration() {
    local migration_file=$1
    local version=$(basename "$migration_file" .sql)

    log_info "Applying migration: $version"

    # Start transaction, apply migration, record in tracking table
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<EOF
BEGIN;
\i $migration_file
INSERT INTO schema_migrations (version) VALUES ('$version');
COMMIT;
EOF

    if [ $? -eq 0 ]; then
        log_info "Successfully applied: $version"
    else
        log_error "Failed to apply: $version"
        exit 1
    fi
}

# Run all pending migrations
migrate_up() {
    log_info "Starting database migration..."

    create_migrations_table

    local applied=$(get_applied_migrations)
    local pending=0

    for migration_file in "$MIGRATIONS_DIR"/*.sql; do
        if [ -f "$migration_file" ]; then
            local version=$(basename "$migration_file" .sql)

            if echo "$applied" | grep -q "^${version}$"; then
                log_info "Already applied: $version"
            else
                apply_migration "$migration_file"
                ((pending++))
            fi
        fi
    done

    if [ $pending -eq 0 ]; then
        log_info "Database is up to date. No migrations to apply."
    else
        log_info "Applied $pending migration(s) successfully."
    fi
}

# Show migration status
migrate_status() {
    log_info "Migration Status"
    echo "----------------------------------------"

    create_migrations_table

    local applied=$(get_applied_migrations)

    for migration_file in "$MIGRATIONS_DIR"/*.sql; do
        if [ -f "$migration_file" ]; then
            local version=$(basename "$migration_file" .sql)

            if echo "$applied" | grep -q "^${version}$"; then
                echo -e "${GREEN}[APPLIED]${NC} $version"
            else
                echo -e "${YELLOW}[PENDING]${NC} $version"
            fi
        fi
    done

    echo "----------------------------------------"
}

# Reset database (DANGEROUS - only for development)
migrate_reset() {
    log_warn "This will DROP ALL TABLES and re-run migrations!"
    read -p "Are you sure? Type 'yes' to confirm: " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Aborted."
        exit 0
    fi

    log_warn "Dropping all tables..."

    psql "$DATABASE_URL" <<EOF
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO public;
EOF

    log_info "Running all migrations..."
    migrate_up
}

# Main
check_psql

case "${1:-up}" in
    up)
        migrate_up
        ;;
    status)
        migrate_status
        ;;
    reset)
        migrate_reset
        ;;
    *)
        echo "Usage: $0 [up|status|reset]"
        echo "  up     - Apply pending migrations (default)"
        echo "  status - Show migration status"
        echo "  reset  - Drop all tables and re-run migrations (DANGEROUS)"
        exit 1
        ;;
esac
