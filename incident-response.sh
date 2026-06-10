#!/usr/bin/env bash
# ==============================================================================
# Script: incident-response.sh
# Description: Automated incident detection and response. Monitors for common
#               failure scenarios and executes predefined response playbooks.
# Usage: ./incident-response.sh [--check|--auto|--report]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INCIDENT_LOG="/var/log/incidents.log"
RESPONSE_DIR="${SCRIPT_DIR}/incidents"
CHECK_ONLY=false
AUTO_RESPOND=false
GENERATE_REPORT=false
NOTIFY_WEBHOOK=""
NOTIFY_EMAIL=""
MAX_RESPONSE_ATTEMPTS=3
COOLDOWN=300

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

declare -A INCIDENT_COUNT
declare -A LAST_RESPONSE

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[INCIDENT]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(date '+%Y-%m-%d %H:%M:%S') [OPTIONS]

Automated incident detection and response.

Options:
  --check       Check for incidents without responding
  --auto        Auto-detect and respond to incidents
  --report      Generate incident report
  --webhook URL Slack/Discord webhook for notifications
  --email EMAIL Email for notifications
  --help        Show this help

Incident types detected:
  HIGH_CPU, HIGH_RAM, HIGH_DISK, SERVICE_DOWN, DOCKER_UNHEALTHY,
  OOM_KILLED, SSH_BRUTE_FORCE, SSL_EXPIRING, BACKUP_FAILED
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)    CHECK_ONLY=true; shift ;;
            --auto)     AUTO_RESPOND=true; shift ;;
            --report)   GENERATE_REPORT=true; shift ;;
            --webhook)  NOTIFY_WEBHOOK="$2"; shift 2 ;;
            --email)    NOTIFY_EMAIL="$2"; shift 2 ;;
            --help)     usage ;;
            *)          error "Unknown option: $1"; usage ;;
        esac
    done
}

notify() {
    local severity="$1"
    local message="$2"

    local full_message="🚨 [${severity}] Incident Detected
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')

${message}"

    echo "$full_message" >> "$INCIDENT_LOG"

    if [[ -n "$NOTIFY_WEBHOOK" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"${full_message}\"}" \
            "$NOTIFY_WEBHOOK" &>/dev/null || true
    fi

    if [[ -n "$NOTIFY_EMAIL" ]]; then
        echo "$full_message" | mail -s "[${severity}] Incident — $(hostname)" "$NOTIFY_EMAIL" 2>/dev/null || true
    fi
}

check_high_cpu() {
    local threshold=90
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4)}')

    if [[ $cpu_usage -ge $threshold ]]; then
        local top_procs
        top_procs=$(ps aux --sort=-%cpu | head -4 | tail -3 | awk '{printf "  %s: %s%%\n", $11, $3}')
        echo "HIGH_CPU|CPU usage at ${cpu_usage}% (threshold: ${threshold}%)
Top processes:
${top_procs}"
    fi
}

check_high_ram() {
    local threshold=95
    local ram_pct
    ram_pct=$(free | awk '/Mem:/ {printf "%d", ($3/$2)*100}')

    if [[ $ram_pct -ge $threshold ]]; then
        local top_procs
        top_procs=$(ps aux --sort=-%mem | head -4 | tail -3 | awk '{printf "  %s: %s%%\n", $11, $4}')
        echo "HIGH_RAM|RAM usage at ${ram_pct}% (threshold: ${threshold}%)
Top memory consumers:
${top_procs}"
    fi
}

check_disk_full() {
    local threshold=95
    local result=""

    while IFS= read -r line; do
        local pct mount
        pct=$(echo "$line" | awk '{print int($5)}')
        mount=$(echo "$line" | awk '{print $6}')

        if [[ $pct -ge $threshold ]]; then
            result+="DISK_FULL|Disk ${mount} at ${pct}% (threshold: ${threshold}%)\n"
        fi
    done < <(df --output=pcent,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2 | sed 's/%//')

    echo -e "$result"
}

check_service_down() {
    local services=("nginx" "postgresql" "docker" "redis-server" "mysql")
    local result=""

    for svc in "${services[@]}"; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null && ! pgrep -x "$svc" &>/dev/null; then
            # Check if it's supposed to be running (installed)
            if command -v "$svc" &>/dev/null || systemctl list-unit-files | grep -q "$svc"; then
                result+="SERVICE_DOWN|Service ${svc} is not running\n"
            fi
        fi
    done

    echo -e "$result"
}

check_docker_issues() {
    ! command -v docker &>/dev/null && return

    local result=""

    # Unhealthy containers
    local unhealthy
    unhealthy=$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -c -i "unhealthy" || echo "0")
    if [[ $unhealthy -gt 0 ]]; then
        local details
        details=$(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | grep -i "unhealthy" | sed 's/^/  /')
        result+="DOCKER_UNHEALTHY|${unhealthy} unhealthy container(s):\n${details}\n"
    fi

    # OOM-killed
    local oom
    oom=$(docker ps -a --filter "status=exited" --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -c -i "oom\|killed" || echo "0")
    if [[ $oom -gt 0 ]]; then
        result+="OOM_KILLED|${oom} container(s) OOM-killed\n"
    fi

    echo -e "$result"
}

check_ssh_brute_force() {
    local threshold=10
    local attempts

    if [[ -f /var/log/auth.log ]]; then
        attempts=$(grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo "0")
    elif [[ -f /var/log/secure ]]; then
        attempts=$(grep -c "Failed password" /var/log/secure 2>/dev/null || echo "0")
    else
        attempts=0
    fi

    if [[ $attempts -ge $threshold ]]; then
        local top_ips
        top_ips=$(grep "Failed password" /var/log/auth.log /var/log/secure 2>/dev/null | \
            grep -oP 'from \K[0-9.]+' | sort | uniq -c | sort -rn | head -5 | \
            awk '{printf "  %s: %s attempts\n", $2, $1}')
        echo "SSH_BRUTE_FORCE|${attempts} failed SSH attempts detected
Top source IPs:
${top_ips}"
    fi
}

check_ssl_expiry() {
    local result=""
    local domains=""

    # Auto-discover from nginx
    if [[ -d /etc/nginx/sites-available ]]; then
        domains=$(grep -rh "server_name" /etc/nginx/sites-available/ 2>/dev/null | \
            sed 's/server_name//;s/;//' | tr ' ' '\n' | sort -u | grep -v '^$' | grep -v '_')
    fi

    [[ -z "$domains" ]] && return

    for domain in $domains; do
        local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
        if [[ -f "$cert_path" ]]; then
            local expiry_date
            expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
            local expiry_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
            local now_epoch
            now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [[ $days_left -le 7 ]]; then
                result+="SSL_EXPIRING|SSL for ${domain} expires in ${days_left} days\n"
            fi
        fi
    done

    echo -e "$result"
}

# Response handlers
respond_high_cpu() {
    log "Responding to HIGH_CPU incident"

    # Kill top CPU-consuming non-essential processes
    local top_pid
    top_pid=$(ps aux --sort=-%cpu | awk 'NR==2 {print $2}')
    local top_proc
    top_proc=$(ps aux --sort=-%cpu | awk 'NR==2 {print $11}')

    # Don't kill system processes
    case "$top_proc" in
        *systemd*|*kernel*|*sshd*|*nginx*)
            warn "Top CPU process is system-critical (${top_proc}), not killing"
            ;;
        *)
            log "Killing high-CPU process: ${top_proc} (PID: ${top_pid})"
            kill -TERM "$top_pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$top_pid" 2>/dev/null || true
            ;;
    esac
}

respond_high_ram() {
    log "Responding to HIGH_RAM incident"

    # Clear caches
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    log "Cleared system caches"

    # Kill top memory-consuming non-essential processes
    local top_pid
    top_pid=$(ps aux --sort=-%mem | awk 'NR==2 {print $2}')
    local top_proc
    top_proc=$(ps aux --sort=-%mem | awk 'NR==2 {print $11}')

    case "$top_proc" in
        *systemd*|*kernel*|*sshd*|*postgres*|*mysql*)
            warn "Top RAM process is system-critical (${top_proc}), not killing"
            ;;
        *)
            log "Killing high-RAM process: ${top_proc} (PID: ${top_pid})"
            kill -TERM "$top_pid" 2>/dev/null || true
            ;;
    esac
}

respond_service_down() {
    local service="$1"
    log "Attempting to restart service: ${service}"

    if systemctl restart "$service" 2>/dev/null; then
        sleep 3
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "✓ Service ${service} restarted successfully"
        else
            error "✗ Service ${service} failed to start"
        fi
    else
        error "✗ Failed to restart ${service}"
    fi
}

respond_docker_unhealthy() {
    log "Responding to unhealthy Docker containers"

    docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -i "unhealthy" | while IFS=$'\t' read -r name status; do
        log "Restarting unhealthy container: ${name}"
        docker restart "$name" 2>/dev/null || true
    done
}

respond_ssh_brute_force() {
    log "Responding to SSH brute force"

    # Block top offending IPs with UFW
    if command -v ufw &>/dev/null; then
        grep "Failed password" /var/log/auth.log /var/log/secure 2>/dev/null | \
            grep -oP 'from \K[0-9.]+' | sort | uniq -c | sort -rn | head -5 | \
            while read -r count ip; do
                if [[ $count -ge 10 ]]; then
                    ufw deny from "$ip" 2>/dev/null || true
                    log "Blocked IP: ${ip} (${count} attempts)"
                fi
            done
    fi
}

run_checks() {
    local incidents=""

    incidents+=$(check_high_cpu)
    incidents+=$(check_high_ram)
    incidents+=$(check_disk_full)
    incidents+=$(check_service_down)
    incidents+=$(check_docker_issues)
    incidents+=$(check_ssh_brute_force)
    incidents+=$(check_ssl_expiry)

    echo -e "$incidents"
}

handle_incident() {
    local incident_type="$1"
    local details="$2"

    # Check cooldown
    local now
    now=$(date +%s)
    local last="${LAST_RESPONSE[$incident_type]:-0}"
    local elapsed=$((now - last))

    if [[ $elapsed -lt $COOLDOWN ]]; then
        log "Cooldown active for ${incident_type} (${elapsed}s < ${COOLDOWN}s)"
        return
    fi

    LAST_RESPONSE[$incident_type]=$now
    INCIDENT_COUNT[$incident_type]=$(( ${INCIDENT_COUNT[$incident_type]:-0} + 1 ))

    local count=${INCIDENT_COUNT[$incident_type]}
    if [[ $count -ge $MAX_RESPONSE_ATTEMPTS ]]; then
        error "Max response attempts (${MAX_RESPONSE_ATTEMPTS}) reached for ${incident_type} — manual intervention required"
        notify "CRITICAL" "${incident_type}: Max auto-responses reached\n${details}"
        return
    fi

    error "INCIDENT [${incident_type}]: ${details}"

    case "$incident_type" in
        HIGH_CPU)         respond_high_cpu ;;
        HIGH_RAM)         respond_high_ram ;;
        DISK_FULL)        warn "Disk full — manual cleanup required" ;;
        SERVICE_DOWN)
            local svc
            svc=$(echo "$details" | grep -oP 'Service \K\S+')
            respond_service_down "$svc"
            ;;
        DOCKER_UNHEALTHY) respond_docker_unhealthy ;;
        OOM_KILLED)       warn "OOM killed containers — investigate memory limits" ;;
        SSH_BRUTE_FORCE)  respond_ssh_brute_force ;;
        SSL_EXPIRING)     warn "SSL expiring — run ssl-manager.sh --renew" ;;
        *)                warn "No automated response for: ${incident_type}" ;;
    esac

    notify "WARNING" "${incident_type}: ${details}"
}

generate_report() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Incident Response Report       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "Host:     $(hostname)"
    echo "Time:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""

    if [[ ${#INCIDENT_COUNT[@]} -eq 0 ]]; then
        echo -e "${GREEN}No incidents detected in this session${NC}"
    else
        echo -e "${BLUE}Incident Counts:${NC}"
        for type in "${!INCIDENT_COUNT[@]}"; do
            local color="$YELLOW"
            [[ ${INCIDENT_COUNT[$type]} -ge 3 ]] && color="$RED"
            printf "  ${color}%-20s: %s${NC}\n" "$type" "${INCIDENT_COUNT[$type]}"
        done
    fi

    echo ""
    echo -e "${BLUE}Recent Incident Log:${NC}"
    if [[ -f "$INCIDENT_LOG" ]]; then
        tail -20 "$INCIDENT_LOG" 2>/dev/null | sed 's/^/  /'
    else
        echo "  No incidents logged"
    fi
    echo ""
}

main() {
    parse_args "$@"

    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Incident Response System       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$GENERATE_REPORT" == true ]]; then
        generate_report
        exit 0
    fi

    log "Running incident checks..."
    echo ""

    local incidents
    incidents=$(run_checks)

    if [[ -z "$incidents" ]]; then
        log "✓ No incidents detected"
    else
        # Process each incident
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local type details
            type=$(echo "$line" | cut -d'|' -f1)
            details=$(echo "$line" | cut -d'|' -f2-)

            if [[ "$AUTO_RESPOND" == true ]]; then
                handle_incident "$type" "$details"
            else
                warn "INCIDENT [${type}]: ${details}"
            fi
        done <<< "$incidents"
    fi

    if [[ "$CHECK_ONLY" == true ]]; then
        echo ""
        log "Check complete (no actions taken)"
    fi

    echo ""
}

main "$@"
