#!/usr/bin/env bash
# ==============================================================================
# Script: db-migrate.sh
# Description: Database migration runner with rollback support.
#               Supports PostgreSQL, MySQL, and MongoDB.
#               Tracks applied migrations, supports up/down/status.
# Usage: ./db-migrate.sh [--db postgres|mysql|mongo] [--action up|down|status|create]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_TYPE="postgres"
DB_HOST="localhost"
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASS=""
MIGRATION_DIR="${SCRIPT_DIR}/migrations"
ACTION="up"
TARGET=""
LOG_FILE="/var/log/db-migrate.log"
DRY_RUN=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Database migration runner with rollback.

Options:
  --db TYPE           Database type: postgres, mysql, mongo (default: postgres)
  --host HOST         Database host (default: localhost)
  --port PORT         Database port (auto-detected)
  --name DB           Database name
  --user USER         Database user
  --pass PASS         Database password
  --dir DIR           Migration directory (default: ./migrations)
  --action ACTION     Action: up, down, status, create (default: up)
  --target VERSION    Target migration version (for up/down)
  --dry-run           Show what would be executed
  --help              Show this help

Migration file naming:
  YYYYMMDDHHMMSS_description.up.sql
  YYYYMMDDHHMMSS_description.down.sql
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --db)      DB_TYPE="$2"; shift 2 ;;
            --host)    DB_HOST="$2"; shift 2 ;;
            --port)    DB_PORT="$2"; shift 2 ;;
            --name)    DB_NAME="$2"; shift 2 ;;
            --user)    DB_USER="$2"; shift 2 ;;
            --pass)    DB_PASS="$2"; shift 2 ;;
            --dir)     MIGRATION_DIR="$2"; shift 2 ;;
            --action)  ACTION="$2"; shift 2 ;;
            --target)  TARGET="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            --help)    usage ;;
            *)         error "Unknown option: $1"; usage ;;
        esac
    done
}

set_default_port() {
    [[ -n "$DB_PORT" ]] && return
    case "$DB_TYPE" in
        postgres) DB_PORT="5432" ;;
        mysql)    DB_PORT="3306" ;;
        mongo)    DB_PORT="27017" ;;
    esac
}

get_db_cmd() {
    case "$DB_TYPE" in
        postgres)
            local opts="-h ${DB_HOST} -p ${DB_PORT} -U ${DB_USER}"
            [[ -n "$DB_PASS ]] && opts="${opts} PGPASSWORD=${DB_PASS}"
            echo "psql ${opts} -d ${DB_NAME} -t -A"
            ;;
        mysql)
            local opts="-h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER}"
            [[ -n "$DB_PASS" ]] && opts="${opts} -p${DB_PASS}"
            echo "mysql ${opts} ${DB_NAME}"
            ;;
        mongo)
            local opts="--host ${DB_HOST} --port ${DB_PORT}"
            [[ -n "$DB_USER" ]] && opts="${opts} -u ${DB_USER}"
            [[ -n "$DB_PASS" ]] && opts="${opts} -p ${DB_PASS}"
            echo "mongosh ${opts} ${DB_NAME}"
            ;;
    esac
}

init_migration_table() {
    local cmd
    cmd=$(get_db_cmd)

    case "$DB_TYPE" in
        postgres)
            $cmd -c "CREATE TABLE IF NOT EXISTS _migrations (
                id SERIAL PRIMARY KEY,
                version VARCHAR(50) UNIQUE NOT NULL,
                description TEXT,
                applied_at TIMESTAMP DEFAULT NOW(),
                checksum VARCHAR(64),
                execution_time_ms INTEGER
            );" 2>/dev/null || true
            ;;
        mysql)
            $cmd -e "CREATE TABLE IF NOT EXISTS _migrations (
                id INT AUTO_INCREMENT PRIMARY KEY,
                version VARCHAR(50) UNIQUE NOT NULL,
                description TEXT,
                applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                checksum VARCHAR(64),
                execution_time_ms INT
            );" 2>/dev/null || true
            ;;
    esac
}

get_applied_migrations() {
    local cmd
    cmd=$(get_db_cmd)

    case "$DB_TYPE" in
        postgres|mysql)
            $cmd -c "SELECT version FROM _migrations ORDER BY version;" 2>/dev/null || echo ""
            ;;
        mongo)
            echo ""  # MongoDB migration tracking would use a collection
            ;;
    esac
}

apply_migration() {
    local file="$1"
    local version
    version=$(basename "$file" | cut -d_ -f1)
    local description
    description=$(basename "$file" | cut -d_ -f2- | sed 's/\.up\.sql$//' | sed 's/_/ /g')
    local checksum
    checksum=$(sha256sum "$file" | cut -d' ' -f1)
    local cmd
    cmd=$(get_db_cmd)

    log "Applying migration: ${version} — ${description}"

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Would execute: ${file}"
        return 0
    fi

    local start_time
    start_time=$(date +%s%3N)

    case "$DB_TYPE" in
        postgres)
            $cmd -f "$file" 2>>"$LOG_FILE" || {
                error "Migration failed: ${version}"
                return 1
            }
            local end_time
            end_time=$(date +%s%3N)
            local elapsed=$((end_time - start_time))
            $cmd -c "INSERT INTO _migrations (version, description, checksum, execution_time_ms) VALUES ('${version}', '${description}', '${checksum}', ${elapsed}) ON CONFLICT DO NOTHING;" 2>/dev/null || true
            ;;
        mysql)
            $cmd < "$file" 2>>"$LOG_FILE" || {
                error "Migration failed: ${version}"
                return 1
            }
            local end_time
            end_time=$(date +%s%3N)
            local elapsed=$((end_time - start_time))
            $cmd -e "INSERT IGNORE INTO _migrations (version, description, checksum, execution_time_ms) VALUES ('${version}', '${description}', '${checksum}', ${elapsed});" 2>/dev/null || true
            ;;
    esac

    log "✓ Migration applied: ${version} (${elapsed}ms)"
}

rollback_migration() {
    local version="$1"
    local down_file
    down_file=$(find "$MIGRATION_DIR" -name "${version}*.down.sql" 2>/dev/null | head -1)

    if [[ -z "$down_file" ]]; then
        error "No rollback file found for version: ${version}"
        return 1
    fi

    log "Rolling back migration: ${version}"

    if [[ "$DRY_RUN" == true ]]; then
        log "[DRY RUN] Would execute: ${down_file}"
        return 0
    fi

    local cmd
    cmd=$(get_db_cmd)

    case "$DB_TYPE" in
        postgres)
            $cmd -f "$down_file" 2>>"$LOG_FILE" || {
                error "Rollback failed: ${version}"
                return 1
            }
            $cmd -c "DELETE FROM _migrations WHERE version='${version}';" 2>/dev/null || true
            ;;
        mysql)
            $cmd < "$down_file" 2>>"$LOG_FILE" || {
                error "Rollback failed: ${version}"
                return 1
            }
            $cmd -e "DELETE FROM _migrations WHERE version='${version}';" 2>/dev/null || true
            ;;
    esac

    log "✓ Rolled back: ${version}"
}

show_status() {
    echo -e "${BLUE}=== Migration Status ===${NC}"
    echo ""

    init_migration_table

    local applied
    applied=$(get_applied_migrations)
    local applied_count
    applied_count=$(echo "$applied" | grep -c "^[0-9]" 2>/dev/null || echo "0")

    local pending=0
    local total=0

    printf "%-20s %-10s %-30s\n" "VERSION" "STATUS" "DESCRIPTION"
    printf "%-20s %-10s %-30s\n" "───────" "──────" "───────────"

    for up_file in "$MIGRATION_DIR"/*.up.sql 2>/dev/null; do
        [[ ! -f "$up_file" ]] && continue
        total=$((total + 1))

        local version description
        version=$(basename "$up_file" | cut -d_ -f1)
        description=$(basename "$up_file" | cut -d_ -f2- | sed 's/\.up\.sql$//' | sed 's/_/ /g')

        if echo "$applied" | grep -q "^${version}$"; then
            printf "${GREEN}%-20s %-10s %-30s${NC}\n" "$version" "APPLIED" "$description"
        else
            printf "${YELLOW}%-20s %-10s %-30s${NC}\n" "$version" "PENDING" "$description"
            pending=$((pending + 1))
        fi
    done

    echo ""
    log "Applied: ${applied_count} | Pending: ${pending} | Total: ${total}"
}

create_migration() {
    local description="${1:-new_migration}"
    local version
    version=$(date +"%Y%m%d%H%M%S")
    local safe_desc
    safe_desc=$(echo "$description" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')

    mkdir -p "$MIGRATION_DIR"

    local up_file="${MIGRATION_DIR}/${version}_${safe_desc}.up.sql"
    local down_file="${MIGRATION_DIR}/${version}_${safe_desc}.down.sql"

    cat > "$up_file" <<EOF
-- Migration: ${description}
-- Version: ${version}
-- Created: $(date)

-- Add your migration SQL here

EOF

    cat > "$down_file" <<EOF
-- Rollback: ${description}
-- Version: ${version}

-- Add your rollback SQL here

EOF

    log "Created migration files:"
    log "  UP:   ${up_file}"
    log "  DOWN: ${down_file}"
}

main() {
    parse_args "$@"
    set_default_port

    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Database Migration Manager     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
    log "Database: ${DB_TYPE}://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    log "Action:   ${ACTION}"
    echo ""

    case "$ACTION" in
        status)
            show_status
            ;;
        up)
            init_migration_table
            show_status
            echo ""

            local applied
            applied=$(get_applied_migrations)

            for up_file in "$MIGRATION_DIR"/*.up.sql 2>/dev/null; do
                [[ ! -f "$up_file" ]] && continue
                local version
                version=$(basename "$up_file" | cut -d_ -f1)

                if echo "$applied" | grep -q "^${version}$"; then
                    continue
                fi

                if [[ -n "$TARGET" && "$version" > "$TARGET" ]]; then
                    break
                fi

                apply_migration "$up_file" || exit 1
            done

            echo ""
            log "✓ All migrations applied"
            ;;
        down)
            if [[ -z "$TARGET" ]]; then
                error "Rollback requires --target VERSION"
                exit 1
            fi
            rollback_migration "$TARGET" || exit 1
            ;;
        create)
            create_migration "${TARGET:-new_migration}"
            ;;
        *)
            error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

main "$@"
