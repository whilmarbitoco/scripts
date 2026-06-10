#!/usr/bin/env bash
# ==============================================================================
# Script: docker-cleanup.sh
# Description: Docker resource cleanup — removes unused images, containers,
#               volumes, networks, and build cache. Shows space reclaimed.
# Usage: ./docker-cleanup.sh [--all] [--volumes] [--images] [--dry-run]
# ==============================================================================

set -euo pipefail

DRY_RUN=false
CLEAN_CONTAINERS=true
CLEAN_IMAGES=true
CLEAN_VOLUMES=false
CLEAN_NETWORKS=true
CLEAN_BUILD_CACHE=true
FORCE=false

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

Docker resource cleanup and maintenance.

Options:
  --all           Clean everything including volumes
  --volumes       Also remove unused volumes (DANGEROUS)
  --images        Only clean images
  --containers    Only clean stopped containers
  --dry-run       Show what would be removed
  --force         Skip confirmation prompts
  --help          Show this help
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)         CLEAN_VOLUMES=true; shift ;;
            --volumes)     CLEAN_VOLUMES=true; shift ;;
            --images)      CLEAN_CONTAINERS=false; CLEAN_NETWORKS=false; CLEAN_BUILD_CACHE=false; shift ;;
            --containers)  CLEAN_IMAGES=false; CLEAN_NETWORKS=false; CLEAN_BUILD_CACHE=false; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --force)       FORCE=true; shift ;;
            --help)         usage ;;
            *)             error "Unknown option: $1"; usage ;;
        esac
    done
}

get_docker_disk_usage() {
    docker system df 2>/dev/null | tail -1 | awk '{print $1}' || echo "unknown"
}

format_bytes() {
    local bytes="$1"
    if [[ $bytes -gt 1073741824 ]]; then
        echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    elif [[ $bytes -gt 1048576 ]]; then
        echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $bytes / 1024" | bc) KB"
    fi
}

main() {
    parse_args "$@"

    if ! command -v docker &>/dev/null; then
        error "Docker is not installed"
        exit 1
    fi

    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Docker Cleanup Report          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    # Show current disk usage
    log "Current Docker disk usage:"
    docker system df 2>/dev/null || true
    echo ""

    local before_space
    before_space=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "unknown")
    log "Space before cleanup: $before_space"

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY RUN MODE — no changes will be made"
        echo ""
    fi

    # Stopped containers
    if [[ "$CLEAN_CONTAINERS" == true ]]; then
        local stopped
        stopped=$(docker ps -a --filter "status=exited" --filter "status=dead" -q 2>/dev/null | wc -l)
        if [[ $stopped -gt 0 ]]; then
            log "Removing $stopped stopped/dead containers..."
            if [[ "$DRY_RUN" != true ]]; then
                docker container prune -f 2>/dev/null | tail -5
            fi
        else
            log "No stopped containers to clean"
        fi
    fi

    # Dangling images
    if [[ "$CLEAN_IMAGES" == true ]]; then
        local dangling
        dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
        if [[ $dangling -gt 0 ]]; then
            log "Removing $dangling dangling images..."
            if [[ "$DRY_RUN" != true ]]; then
                docker image prune -f 2>/dev/null | tail -5
            fi
        else
            log "No dangling images to clean"
        fi

        # Unused images (not referenced by any container)
        local unused
        unused=$(docker images -q 2>/dev/null | wc -l)
        local used
        used=$(docker ps -a --format '{{.Image}}' 2>/dev/null | sort -u | wc -l)
        local diff=$((unused - used))
        if [[ $diff -gt 5 ]]; then
            log "Found ~$diff potentially unused images"
            if [[ "$FORCE" == true || "$DRY_RUN" == true ]]; then
                if [[ "$DRY_RUN" != true ]]; then
                    docker image prune -a -f 2>/dev/null | tail -5
                fi
            else
                warn "Use --force to remove all unused images (keeps images used by running containers)"
            fi
        fi
    fi

    # Unused volumes
    if [[ "$CLEAN_VOLUMES" == true ]]; then
        local unused_vols
        unused_vols=$(docker volume ls -f "dangling=true" -q 2>/dev/null | wc -l)
        if [[ $unused_vols -gt 0 ]]; then
            warn "Found $unused_vols unused volumes"
            if [[ "$FORCE" == true ]]; then
                if [[ "$DRY_RUN" != true ]]; then
                    docker volume prune -f 2>/dev/null | tail -5
                fi
            else
                warn "Use --force to remove unused volumes (DATA LOSS RISK)"
            fi
        else
            log "No unused volumes to clean"
        fi
    fi

    # Unused networks
    if [[ "$CLEAN_NETWORKS" == true ]]; then
        local unused_nets
        unused_nets=$(docker network ls --filter "type=custom" -q 2>/dev/null | wc -l)
        if [[ $unused_nets -gt 0 ]]; then
            if [[ "$DRY_RUN" != true ]]; then
                docker network prune -f 2>/dev/null | tail -3
            fi
            log "Cleaned unused networks"
        fi
    fi

    # Build cache
    if [[ "$CLEAN_BUILD_CACHE" == true ]]; then
        local cache_size
        cache_size=$(docker builder df 2>/dev/null | grep "CACHE" | awk '{print $2}' || echo "unknown")
        log "Build cache size: $cache_size"
        if [[ "$DRY_RUN" != true ]]; then
            docker builder prune -f 2>/dev/null | tail -3
            log "Build cache cleaned"
        fi
    fi

    echo ""
    log "Docker disk usage after cleanup:"
    docker system df 2>/dev/null || true
    echo ""
    log "✓ Cleanup complete"
}

main "$@"
