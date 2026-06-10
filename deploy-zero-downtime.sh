#!/usr/bin/env bash
# ==============================================================================
# Script: deploy-zero-downtime.sh
# Description: Zero-downtime deployment with health checks, rollback, and
#               blue-green or rolling strategy. Supports Docker, PM2, and
#               systemd services.
# Usage: ./deploy-zero-downtime.sh --strategy blue-green|rolling|docker
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="/opt/deployments"
HEALTH_CHECK_RETRIES=30
HEALTH_CHECK_INTERVAL=2
ROLLBACK_ON_FAILURE=true
STRATEGY="docker"
SERVICE_NAME=""
IMAGE_NAME=""
IMAGE_TAG="latest"
PORT=3000
HEALTH_URL="http://localhost:${PORT}/health"
DOCKER_COMPOSE_FILE="docker-compose.yml"
PM2_APP_NAME=""
SYSTEMD_SERVICE=""
MAX_PARALLEL=1
NOTIFY_WEBHOOK=""
NOTIFY_EMAIL=""
LOG_FILE="/var/log/deploy.log"
DRY_RUN=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DEPLOY_ID=$(date +"%Y%m%d_%H%M%S")
DEPLOY_LOG=""

log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "$msg" >> "$LOG_FILE"
    case "$level" in
        INFO)    echo -e "${GREEN}${msg}${NC}" ;;
        WARN)    echo -e "${YELLOW}${msg}${NC}" ;;
        ERROR)   echo -e "${RED}${msg}${NC}" ;;
        STEP)    echo -e "${CYAN}${msg}${NC}" ;;
        DEBUG)   [[ "$VERBOSE" == true ]] && echo -e "${BLUE}${msg}${NC}" ;;
        *)       echo "$msg" ;;
    esac
    DEPLOY_LOG+="${msg}\n"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Zero-downtime deployment with health checks and automatic rollback.

Options:
  --strategy STRATEGY     Deployment strategy: blue-green, rolling, docker (default: docker)
  --service NAME          Service name (PM2 app or systemd service)
  --image NAME            Docker image name
  --tag TAG               Docker image tag (default: latest)
  --port PORT             Health check port (default: 3000)
  --health-url URL        Health check endpoint (default: http://localhost:PORT/health)
  --compose FILE          Docker Compose file (default: docker-compose.yml)
  --pm2-app NAME          PM2 application name
  --systemd-service NAME  systemd service name
  --no-rollback           Disable automatic rollback on failure
  --webhook URL           Slack/Discord webhook for notifications
  --email EMAIL           Email for notifications
  --dry-run               Show what would be done without executing
  --verbose               Enable verbose output
  --help                  Show this help message

Examples:
  # Docker Compose deployment
  $(basename "$0") --strategy docker --image myapp --tag v1.2.0

  # Blue-green with PM2
  $(basename "$0") --strategy blue-green --pm2-app myapp --port 3000

  # Rolling systemd deployment
  $(basename "$0") --strategy rolling --systemd-service myapp
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strategy)         STRATEGY="$2"; shift 2 ;;
            --service)          SERVICE_NAME="$2"; shift 2 ;;
            --image)            IMAGE_NAME="$2"; shift 2 ;;
            --tag)              IMAGE_TAG="$2"; shift 2 ;;
            --port)             PORT="$2"; shift 2 ;;
            --health-url)       HEALTH_URL="$2"; shift 2 ;;
            --compose)          DOCKER_COMPOSE_FILE="$2"; shift 2 ;;
            --pm2-app)          PM2_APP_NAME="$2"; shift 2 ;;
            --systemd-service)  SYSTEMD_SERVICE="$2"; shift 2 ;;
            --no-rollback)      ROLLBACK_ON_FAILURE=false; shift ;;
            --webhook)          NOTIFY_WEBHOOK="$2"; shift 2 ;;
            --email)            NOTIFY_EMAIL="$2"; shift 2 ;;
            --dry-run)          DRY_RUN=true; shift ;;
            --verbose)          VERBOSE=true; shift ;;
            --help)             usage ;;
            *)                  log ERROR "Unknown option: $1"; usage ;;
        esac
    done
}

validate_config() {
    case "$STRATEGY" in
        blue-green|rolling|docker) ;;
        *) log ERROR "Invalid strategy: $STRATEGY (must be blue-green, rolling, or docker)"; exit 1 ;;
    esac

    if [[ "$STRATEGY" == "docker" && -z "$IMAGE_NAME" ]]; then
        log ERROR "Docker strategy requires --image"; exit 1
    fi

    if [[ "$STRATEGY" == "blue-green" && -z "$PM2_APP_NAME" && -z "$SYSTEMD_SERVICE" ]]; then
        log ERROR "Blue-green strategy requires --pm2-app or --systemd-service"; exit 1
    fi
}

notify() {
    local status="$1"
    local message="Deployment ${DEPLOY_ID}: ${status}\n${DEPLOY_LOG}"

    if [[ -n "$NOTIFY_WEBHOOK" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"${message}\"}" \
            "$NOTIFY_WEBHOOK" &>/dev/null || true
    fi

    if [[ -n "$NOTIFY_EMAIL" ]]; then
        echo -e "$message" | mail -s "Deployment ${status} — ${DEPLOY_ID}" "$NOTIFY_EMAIL" 2>/dev/null || true
    fi
}

health_check() {
    local url="${1:-$HEALTH_URL}"
    local max_retries="${2:-$HEALTH_CHECK_RETRIES}"
    local interval="${3:-$HEALTH_CHECK_INTERVAL}"

    log STEP "Health checking: ${url}"

    for i in $(seq 1 "$max_retries"); do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log INFO "✓ Health check passed (attempt ${i}/${max_retries})"
            return 0
        fi

        log DEBUG "Health check attempt ${i}/${max_retries}: HTTP ${http_code}"
        sleep "$interval"
    done

    log ERROR "✗ Health check failed after ${max_retries} attempts"
    return 1
}

get_current_version() {
    case "$STRATEGY" in
        docker)
            docker inspect --format='{{.Config.Image}}' "$(docker-compose ps -q 2>/dev/null | head -1)" 2>/dev/null || echo "unknown"
            ;;
        blue-green)
            if command -v pm2 &>/dev/null && [[ -n "$PM2_APP_NAME" ]]; then
                pm2 describe "$PM2_APP_NAME" 2>/dev/null | grep "exec path" | awk '{print $NF}' || echo "unknown"
            fi
            ;;
        rolling)
            systemctl show "$SYSTEMD_SERVICE" --property=ExecStart 2>/dev/null | cut -d= -f2 || echo "unknown"
            ;;
    esac
}

save_rollback_state() {
    local rollback_file="${DEPLOY_DIR}/rollback_${DEPLOY_ID}.state"
    mkdir -p "$DEPLOY_DIR"

    log STEP "Saving rollback state"

    case "$STRATEGY" in
        docker)
            docker-compose config > "$rollback_file" 2>/dev/null || true
            echo "IMAGE_TAG=${IMAGE_TAG}" >> "$rollback_file"
            echo "IMAGE_NAME=${IMAGE_NAME}" >> "$rollback_file"
            ;;
        blue-green)
            echo "PM2_APP_NAME=${PM2_APP_NAME}" >> "$rollback_file"
            echo "CURRENT_PORT=${PORT}" >> "$rollback_file"
            pm2 save 2>/dev/null || true
            ;;
        rolling)
            echo "SYSTEMD_SERVICE=${SYSTEMD_SERVICE}" >> "$rollback_file"
            systemctl show "$SYSTEMD_SERVICE" --property=ExecStart > "$rollback_file.bak" 2>/dev/null || true
            ;;
    esac

    log INFO "Rollback state saved: $rollback_file"
    echo "$rollback_file"
}

rollback() {
    local rollback_file="$1"

    log WARN "========================================="
    log WARn "  INITIATING ROLLBACK"
    log WARN "========================================="

    if [[ ! -f "$rollback_file" ]]; then
        log ERROR "No rollback state found at $rollback_file"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$rollback_file"

    case "$STRATEGY" in
        docker)
            log STEP "Rolling back Docker deployment"
            if [[ "$DRY_RUN" != true ]]; then
                export IMAGE_TAG
                docker-compose down --remove-orphans 2>>"$LOG_FILE" || true
                docker-compose up -d 2>>"$LOG_FILE" || true
            fi
            ;;
        blue-green)
            log STEP "Rolling back PM2 application"
            if [[ "$DRY_RUN" != true ]]; then
                pm2 stop "$PM2_APP_NAME" 2>>"$LOG_FILE" || true
                pm2 delete "$PM2_APP_NAME" 2>>"$LOG_FILE" || true
                pm2 resurrect 2>>"$LOG_FILE" || true
            fi
            ;;
        rolling)
            log STEP "Rolling back systemd service"
            if [[ "$DRY_RUN" != true ]]; then
                systemctl stop "$SYSTEMD_SERVICE" 2>>"$LOG_FILE" || true
                if [[ -f "${rollback_file}.bak" ]]; then
                    systemctl revert "$SYSTEMD_SERVICE" 2>>"$LOG_FILE" || true
                fi
                systemctl start "$SYSTEMD_SERVICE" 2>>"$LOG_FILE" || true
            fi
            ;;
    esac

    sleep 5

    if health_check "$HEALTH_URL" 10 2; then
        log INFO "✓ Rollback successful"
        notify "ROLLBACK_SUCCESS"
    else
        log ERROR "✗ Rollback failed — manual intervention required"
        notify "ROLLBACK_FAILED"
        return 1
    fi
}

deploy_docker() {
    log STEP "Deploying via Docker Compose (zero-downtime)"

    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        log ERROR "Docker Compose file not found: $DOCKER_COMPOSE_FILE"
        return 1
    fi

    export IMAGE_TAG

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would deploy: ${IMAGE_NAME}:${IMAGE_TAG}"
        docker-compose config 2>/dev/null | grep -A5 "image:" || true
        return 0
    fi

    # Pull new image
    log STEP "Pulling image: ${IMAGE_NAME}:${IMAGE_TAG}"
    docker pull "${IMAGE_NAME}:${IMAGE_TAG}" 2>>"$LOG_FILE" || {
        log ERROR "Failed to pull image: ${IMAGE_NAME}:${IMAGE_TAG}"
        return 1
    }

    # Rolling update: one container at a time
    log STEP "Performing rolling update"
    docker-compose up -d --no-deps --build 2>>"$LOG_FILE" || {
        log ERROR "Docker Compose up failed"
        return 1
    }

    # Wait for containers to stabilize
    sleep 5

    # Verify all containers are running
    local unhealthy
    unhealthy=$(docker-compose ps --format json 2>/dev/null | grep -c '"State":"exited"' || echo "0")
    if [[ "$unhealthy" -gt 0 ]]; then
        log ERROR "${unhealthy} container(s) exited unexpectedly"
        return 1
    fi

    log INFO "✓ Docker deployment complete"
}

deploy_blue_green() {
    log STEP "Deploying via Blue-Green strategy"

    local blue_port=3000
    local green_port=3001
    local current_active_port

    # Determine which port is currently active
    if curl -s "http://localhost:${blue_port}/health" -o /dev/null 2>/dev/null; then
        current_active_port=$blue_port
    else
        current_active_port=$green_port
    fi

    local new_port=$([[ "$current_active_port" == "$blue_port" ]] && echo "$green_port" || echo "$blue_port")

    log INFO "Active port: ${current_active_port}, Deploying to: ${new_port}"

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would deploy to port ${new_port}"
        return 0
    fi

    # Deploy to inactive port
    if command -v pm2 &>/dev/null && [[ -n "$PM2_APP_NAME" ]]; then
        PORT=$new_port pm2 start ecosystem.config.js --env production 2>>"$LOG_FILE" || {
            log ERROR "PM2 start failed on port ${new_port}"
            return 1
        }
    fi

    # Health check on new port
    if ! health_check "http://localhost:${new_port}/health" "$HEALTH_CHECK_RETRIES" "$HEALTH_CHECK_INTERVAL"; then
        log ERROR "Health check failed on new port ${new_port}"
        pm2 delete "$PM2_APP_NAME-green" 2>/dev/null || true
        return 1
    fi

    # Switch traffic (update nginx/haproxy upstream)
    log STEP "Switching traffic to port ${new_port}"
    if [[ -f /etc/nginx/sites-available/default ]]; then
        sed -i "s/proxy_pass http:\/\/localhost:${current_active_port}/proxy_pass http:\/\/localhost:${new_port}/" /etc/nginx/sites-available/default
        nginx -t 2>>"$LOG_FILE" && systemctl reload nginx 2>>"$LOG_FILE" || true
    fi

    # Stop old instance
    log STEP "Stopping old instance on port ${current_active_port}"
    pm2 stop "${PM2_APP_NAME}" 2>/dev/null || true

    log INFO "✓ Blue-green deployment complete (now on port ${new_port})"
}

deploy_rolling() {
    log STEP "Deploying via Rolling strategy (systemd)"

    if [[ -z "$SYSTEMD_SERVICE" ]]; then
        log ERROR "No systemd service specified"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would restart systemd service: ${SYSTEMD_SERVICE}"
        return 0
    fi

    # Reload systemd in case unit file changed
    systemctl daemon-reload 2>>"$LOG_FILE" || true

    # Restart with zero-downtime (systemd handles socket activation)
    log STEP "Restarting service: ${SYSTEMD_SERVICE}"
    systemctl restart "$SYSTEMD_SERVICE" 2>>"$LOG_FILE" || {
        log ERROR "Service restart failed: ${SYSTEMD_SERVICE}"
        return 1
    }

    # Wait for service to be active
    local retries=0
    while ! systemctl is-active --quiet "$SYSTEMD_SERVICE"; do
        retries=$((retries + 1))
        if [[ $retries -ge 10 ]]; then
            log ERROR "Service failed to become active: ${SYSTEMD_SERVICE}"
            return 1
        fi
        sleep 2
    done

    log INFO "✓ Rolling deployment complete"
}

main() {
    parse_args "$@"
    validate_config

    echo ""
    log INFO "========================================="
    log INFO "  Zero-Downtime Deployment"
    log INFO "========================================="
    log INFO "Deploy ID:   ${DEPLOY_ID}"
    log INFO "Strategy:    ${STRATEGY}"
    log INFO "Image:       ${IMAGE_NAME:-N/A}:${IMAGE_TAG}"
    log INFO "Service:     ${SERVICE_NAME:-${PM2_APP_NAME:-${SYSTEMD_SERVICE:-N/A}}}"
    log INFO "Health URL:  ${HEALTH_URL}"
    log INFO "Rollback:    ${ROLLBACK_ON_FAILURE}"
    [[ "$DRY_RUN" == true ]] && log WARN "DRY RUN MODE"
    echo ""

    # Pre-deployment checks
    log STEP "Running pre-deployment checks"

    local current_version
    current_version=$(get_current_version)
    log INFO "Current version: ${current_version}"

    # Save rollback state
    local rollback_file
    rollback_file=$(save_rollback_state)

    # Execute deployment
    local deploy_success=false

    case "$STRATEGY" in
        docker)
            deploy_docker && deploy_success=true
            ;;
        blue-green)
            deploy_blue_green && deploy_success=true
            ;;
        rolling)
            deploy_rolling && deploy_success=true
            ;;
    esac

    # Post-deployment health check
    if [[ "$deploy_success" == true ]]; then
        log STEP "Running post-deployment health check"

        if health_check "$HEALTH_URL"; then
            log INFO "========================================="
            log INFO "  ✓ DEPLOYMENT SUCCESSFUL"
            log INFO "========================================="
            log INFO "Deploy ID:   ${DEPLOY_ID}"
            log INFO "Version:     ${IMAGE_NAME}:${IMAGE_TAG}"
            log INFO "Health:      OK"
            notify "SUCCESS"
        else
            log ERROR "Post-deployment health check failed"
            deploy_success=false
        fi
    fi

    # Rollback on failure
    if [[ "$deploy_success" == false ]]; then
        log ERROR "========================================="
        log ERROR "  ✗ DEPLOYMENT FAILED"
        log ERROR "========================================="

        if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
            rollback "$rollback_file"
        else
            log WARN "Automatic rollback disabled — manual intervention required"
            notify "FAILED_NO_ROLLBACK"
        fi

        exit 1
    fi

    echo ""
}

main "$@"
