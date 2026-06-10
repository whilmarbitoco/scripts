#!/usr/bin/env bash
# ==============================================================================
# Script: backup-automated.sh
# Description: Automated database + file backups with rotation and remote sync.
#               Supports PostgreSQL, MySQL, MongoDB, and file directories.
#               Configurable retention, compression, and remote upload (S3/SFTP).
# Usage: ./backup-automated.sh [--config /path/to/backup.conf]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"
BACKUP_BASE="/opt/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/var/log/backup.log"
RETENTION_DAYS=30
COMPRESS=true
REMOTE_SYNC=false
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "$msg" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "${GREEN}${msg}${NC}" ;;
        WARN)  echo -e "${YELLOW}${msg}${NC}" ;;
        ERROR) echo -e "${RED}${msg}${NC}" ;;
        *)     echo "$msg" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --config FILE     Path to backup configuration file
  --dry-run         Show what would be backed up without executing
  --retention N     Override retention days (default: 30)
  --no-compress     Disable compression
  --remote          Enable remote sync (S3/SFTP)
  --help            Show this help message

Configuration file format (backup.conf):
  BACKUP_BASE=/opt/backups
  RETENTION_DAYS=30
  COMPRESS=true
  REMOTE_SYNC=false
  REMOTE_TYPE=s3          # s3 or sftp
  S3_BUCKET=my-backups
  S3_REGION=us-east-1
  SFTP_HOST=backup.example.com
  SFTP_USER=backup
  SFTP_PATH=/backups

  # PostgreSQL databases (space-separated)
  PG_DATABASES="db1 db2 db3"

  # MySQL databases
  MYSQL_DATABASES="db1 db2"
  MYSQL_USER=root
  MYSQL_PASS=secret

  # MongoDB databases
  MONGO_DATABASES="db1 db2"

  # File directories to backup
  FILE_DIRS="/opt/data /workspace /etc/nginx"

  # Docker volumes to backup
  DOCKER_VOLUMES="app_data db_data"
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)     CONFIG_FILE="$2"; shift 2 ;;
            --dry-run)    DRY_RUN=true; shift ;;
            --retention)  RETENTION_DAYS="$2"; shift 2 ;;
            --no-compress) COMPRESS=false; shift ;;
            --remote)     REMOTE_SYNC=true; shift ;;
            --help)       usage ;;
            *)            log ERROR "Unknown option: $1"; usage ;;
        esac
    done
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log INFO "Loading configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log WARN "No config file found at $CONFIG_FILE, using defaults"
    fi

    # Apply overrides
    BACKUP_BASE="${BACKUP_BASE:-$BACKUP_BASE}"
    RETENTION_DAYS="${RETENTION_DAYS:-30}"
    COMPRESS="${COMPRESS:-true}"
    REMOTE_SYNC="${REMOTE_SYNC:-false}"
}

check_dependencies() {
    local missing=()
    command -v pg_dump &>/dev/null || true  # optional
    command -v mysqldump &>/dev/null || true
    command -v mongodump &>/dev/null || true
    command -v tar &>/dev/null || missing+=("tar")
    command -v gzip &>/dev/null || missing+=("gzip")
    command -v find &>/dev/null || missing+=("find")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

backup_postgresql() {
    local databases="${PG_DATABASES:-}"
    if [[ -z "$databases" ]]; then
        log INFO "No PostgreSQL databases configured, skipping"
        return 0
    fi

    if ! command -v pg_dump &>/dev/null; then
        log WARN "pg_dump not found, skipping PostgreSQL backups"
        return 0
    fi

    local pg_dir="${BACKUP_BASE}/postgresql/${TIMESTAMP}"
    mkdir -p "$pg_dir"

    for db in $databases; do
        local outfile="${pg_dir}/${db}.sql"
        log INFO "Backing up PostgreSQL database: $db"

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "[DRY RUN] Would backup PostgreSQL DB: $db → $outfile"
            continue
        fi

        if pg_dump --no-owner --no-acl "$db" > "$outfile" 2>>"$LOG_FILE"; then
            if [[ "$COMPRESS" == true ]]; then
                gzip "$outfile"
                outfile="${outfile}.gz"
            fi
            local size
            size=$(du -h "$outfile" | cut -f1)
            log INFO "✓ PostgreSQL backup complete: $db ($size)"
        else
            log ERROR "✗ PostgreSQL backup failed: $db"
        fi
    done
}

backup_mysql() {
    local databases="${MYSQL_DATABASES:-}"
    if [[ -z "$databases" ]]; then
        log INFO "No MySQL databases configured, skipping"
        return 0
    fi

    if ! command -v mysqldump &>/dev/null; then
        log WARN "mysqldump not found, skipping MySQL backups"
        return 0
    fi

    local mysql_dir="${BACKUP_BASE}/mysql/${TIMESTAMP}"
    mkdir -p "$mysql_dir"

    local mysql_opts="--single-transaction --routines --triggers"
    [[ -n "${MYSQL_USER:-}" ]] && mysql_opts="$mysql_opts -u${MYSQL_USER}"
    [[ -n "${MYSQL_PASS:-}" ]] && mysql_opts="$mysql_opts -p${MYSQL_PASS}"

    for db in $databases; do
        local outfile="${mysql_dir}/${db}.sql"
        log INFO "Backing up MySQL database: $db"

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "[DRY RUN] Would backup MySQL DB: $db → $outfile"
            continue
        fi

        if mysqldump $mysql_opts "$db" > "$outfile" 2>>"$LOG_FILE"; then
            if [[ "$COMPRESS" == true ]]; then
                gzip "$outfile"
                outfile="${outfile}.gz"
            fi
            local size
            size=$(du -h "$outfile" | cut -f1)
            log INFO "✓ MySQL backup complete: $db ($size)"
        else
            log ERROR "✗ MySQL backup failed: $db"
        fi
    done
}

backup_mongodb() {
    local databases="${MONGO_DATABASES:-}"
    if [[ -z "$databases" ]]; then
        log INFO "No MongoDB databases configured, skipping"
        return 0
    fi

    if ! command -v mongodump &>/dev/null; then
        log WARN "mongodump not found, skipping MongoDB backups"
        return 0
    fi

    local mongo_dir="${BACKUP_BASE}/mongodb/${TIMESTAMP}"
    mkdir -p "$mongo_dir"

    for db in $databases; do
        local outpath="${mongo_dir}/${db}"
        log INFO "Backing up MongoDB database: $db"

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "[DRY RUN] Would backup MongoDB DB: $db → $outpath"
            continue
        fi

        if mongodump --db "$db" --out "$outpath" 2>>"$LOG_FILE"; then
            if [[ "$COMPRESS" == true ]]; then
                tar -czf "${outpath}.tar.gz" -C "$mongo_dir" "$db"
                rm -rf "$outpath"
                outpath="${outpath}.tar.gz"
            fi
            local size
            size=$(du -h "$outpath" | cut -f1)
            log INFO "✓ MongoDB backup complete: $db ($size)"
        else
            log ERROR "✗ MongoDB backup failed: $db"
        fi
    done
}

backup_files() {
    local dirs="${FILE_DIRS:-}"
    if [[ -z "$dirs" ]]; then
        log INFO "No file directories configured, skipping"
        return 0
    fi

    local files_dir="${BACKUP_BASE}/files/${TIMESTAMP}"
    mkdir -p "$files_dir"

    for dir in $dirs; do
        if [[ ! -d "$dir" ]]; then
            log WARN "Directory not found, skipping: $dir"
            continue
        fi

        local dirname
        dirname=$(echo "$dir" | tr '/' '_')
        local outfile="${files_dir}${dirname}.tar.gz"

        log INFO "Backing up directory: $dir"

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "[DRY RUN] Would backup: $dir → $outfile"
            continue
        fi

        if tar -czf "$outfile" -C "$(dirname "$dir")" "$(basename "$dir")" 2>>"$LOG_FILE"; then
            local size
            size=$(du -h "$outfile" | cut -f1)
            log INFO "✓ File backup complete: $dir ($size)"
        else
            log ERROR "✗ File backup failed: $dir"
        fi
    done
}

backup_docker_volumes() {
    local volumes="${DOCKER_VOLUMES:-}"
    if [[ -z "$volumes" ]]; then
        log INFO "No Docker volumes configured, skipping"
        return 0
    fi

    if ! command -v docker &>/dev/null; then
        log WARN "Docker not found, skipping volume backups"
        return 0
    fi

    local vol_dir="${BACKUP_BASE}/docker-volumes/${TIMESTAMP}"
    mkdir -p "$vol_dir"

    for vol in $volumes; do
        local outfile="${vol_dir}/${vol}.tar.gz"
        log INFO "Backing up Docker volume: $vol"

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "[DRY RUN] Would backup volume: $vol → $outfile"
            continue
        fi

        if docker run --rm \
            -v "${vol}:/source:ro" \
            -v "${vol_dir}:/backup" \
            alpine tar -czf "/backup/${vol}.tar.gz" -C /source . 2>>"$LOG_FILE"; then
            local size
            size=$(du -h "$outfile" | cut -f1)
            log INFO "✓ Docker volume backup complete: $vol ($size)"
        else
            log ERROR "✗ Docker volume backup failed: $vol"
        fi
    done
}

cleanup_old_backups() {
    log INFO "Cleaning up backups older than ${RETENTION_DAYS} days"

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would remove backups older than ${RETENTION_DAYS} days from ${BACKUP_BASE}"
        return 0
    fi

    local count
    count=$(find "$BACKUP_BASE" -type f -mtime "+${RETENTION_DAYS}" 2>/dev/null | wc -l)

    if [[ $count -gt 0 ]]; then
        find "$BACKUP_BASE" -type f -mtime "+${RETENTION_DAYS}" -delete 2>>"$LOG_FILE"
        find "$BACKUP_BASE" -type d -empty -delete 2>>"$LOG_FILE"
        log INFO "Cleaned up $count old backup files"
    else
        log INFO "No old backups to clean up"
    fi
}

sync_remote() {
    if [[ "$REMOTE_SYNC" != true ]]; then
        return 0
    fi

    local remote_type="${REMOTE_TYPE:-s3}"

    case "$remote_type" in
        s3)
            if ! command -v aws &>/dev/null; then
                log ERROR "AWS CLI not found, cannot sync to S3"
                return 1
            fi
            local bucket="${S3_BUCKET:?S3_BUCKET not configured}"
            local region="${S3_REGION:-us-east-1}"
            log INFO "Syncing backups to S3: s3://${bucket}/"

            if [[ "$DRY_RUN" == true ]]; then
                log INFO "[DRY RUN] Would sync ${BACKUP_BASE}/ to s3://${bucket}/"
                return 0
            fi

            if aws s3 sync "${BACKUP_BASE}/" "s3://${bucket}/" --region "$region" --storage-class STANDARD_IA 2>>"$LOG_FILE"; then
                log INFO "✓ S3 sync complete"
            else
                log ERROR "✗ S3 sync failed"
            fi
            ;;
        sftp)
            local host="${SFTP_HOST:?SFTP_HOST not configured}"
            local user="${SFTP_USER:?SFTP_USER not configured}"
            local path="${SFTP_PATH:-/backups}"
            log INFO "Syncing backups to SFTP: ${user}@${host}:${path}/"

            if [[ "$DRY_RUN" == true ]]; then
                log INFO "[DRY RUN] Would sync ${BACKUP_BASE}/ to ${user}@${host}:${path}/"
                return 0
            fi

            if rsync -avz --delete "${BACKUP_BASE}/" "${user}@${host}:${path}/" 2>>"$LOG_FILE"; then
                log INFO "✓ SFTP sync complete"
            else
                log ERROR "✗ SFTP sync failed"
            fi
            ;;
        *)
            log ERROR "Unknown remote type: $remote_type"
            return 1
            ;;
    esac
}

generate_report() {
    local report_file="${BACKUP_BASE}/reports/backup_${TIMESTAMP}.txt"
    mkdir -p "$(dirname "$report_file")"

    {
        echo "========================================"
        echo "  Backup Report — ${TIMESTAMP}"
        echo "========================================"
        echo ""
        echo "Backup Base: ${BACKUP_BASE}"
        echo "Retention:   ${RETENTION_DAYS} days"
        echo "Compression: ${COMPRESS}"
        echo "Remote Sync: ${REMOTE_SYNC}"
        echo ""
        echo "--- Disk Usage ---"
        du -sh "${BACKUP_BASE}"/* 2>/dev/null || echo "No backups found"
        echo ""
        echo "--- Backup Sizes ---"
        if [[ -d "${BACKUP_BASE}" ]]; then
            find "${BACKUP_BASE}" -name "*.gz" -o -name "*.sql" -o -name "*.tar.gz" | head -20 | while read -r f; do
                echo "  $(du -h "$f" | cut -f1)  $f"
            done
        fi
        echo ""
        echo "--- Recent Log Entries ---"
        tail -20 "$LOG_FILE" 2>/dev/null || echo "No log entries"
        echo ""
        echo "========================================"
    } > "$report_file"

    log INFO "Backup report saved: $report_file"
}

main() {
    parse_args "$@"
    load_config
    check_dependencies

    echo ""
    log INFO "========================================="
    log INFO "  Automated Backup — ${TIMESTAMP}"
    log INFO "========================================="
    log INFO "Backup Base:   ${BACKUP_BASE}"
    log INFO "Retention:     ${RETENTION_DAYS} days"
    log INFO "Compression:   ${COMPRESS}"
    log INFO "Remote Sync:   ${REMOTE_SYNC}"
    [[ "$DRY_RUN" == true ]] && log WARN "DRY RUN MODE — no changes will be made"
    echo ""

    mkdir -p "$BACKUP_BASE"

    backup_postgresql
    backup_mysql
    backup_mongodb
    backup_files
    backup_docker_volumes
    cleanup_old_backups
    sync_remote
    generate_report

    echo ""
    log INFO "========================================="
    log INFO "  Backup Complete — ${TIMESTAMP}"
    log INFO "========================================="
    echo ""
}

main "$@"
