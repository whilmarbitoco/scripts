#!/usr/bin/env bash
# ==============================================================================
# Script: monitor-alerts.sh
# Description: System resource monitoring with configurable thresholds and
#               multi-channel alerts (Telegram, email, Slack, Discord).
#               Monitors CPU, RAM, disk, network, Docker, and services.
# Usage: ./monitor-alerts.sh [--config monitor.conf] [--daemon]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/monitor.conf"
LOG_FILE="/var/log/monitor.log"
PID_FILE="/var/run/monitor-alerts.pid"
DAEMON_MODE=false
CHECK_INTERVAL=60

# Default thresholds
CPU_THRESHOLD=85
RAM_THRESHOLD=90
DISK_THRESHOLD=85
SWAP_THRESHOLD=50
LOAD_THRESHOLD=$(nproc)
DOCKER_HEALTH=true
NETWORK_CHECK=true
PROCESS_MONITOR=""

# Alert channels
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
SLACK_WEBHOOK=""
DISCORD_WEBHOOK=""
EMAIL_TO=""
EMAIL_FROM="monitor@localhost"

# Alert cooldown (seconds) to prevent spam
ALERT_COOLDOWN=300
declare -A LAST_ALERT_TIME

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
    [[ "$DAEMON_MODE" == false ]] && {
        case "$level" in
            INFO)  echo -e "${GREEN}${msg}${NC}" ;;
            WARN)  echo -e "${YELLOW}${msg}${NC}" ;;
            ERROR) echo -e "${RED}${msg}${NC}" ;;
            *)     echo "$msg" ;;
        esac
    }
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

System monitoring with multi-channel alerts.

Options:
  --config FILE     Configuration file path
  --daemon          Run as background daemon
  --interval N      Check interval in seconds (default: 60)
  --stop            Stop running daemon
  --status          Show daemon status
  --test-alerts     Send test alert to all configured channels
  --help            Show this help

Config format (monitor.conf):
  CPU_THRESHOLD=85
  RAM_THRESHOLD=90
  DISK_THRESHOLD=85
  TELEGRAM_BOT_TOKEN=xxx
  TELEGRAM_CHAT_ID=xxx
  SLACK_WEBHOOK=https://hooks.slack.com/...
  DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
  EMAIL_TO=admin@example.com
  PROCESS_MONITOR="nginx:80 postgres:5432 redis:6379"
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)       CONFIG_FILE="$2"; shift 2 ;;
            --daemon)       DAEMON_MODE=true; shift ;;
            --interval)     CHECK_INTERVAL="$2"; shift 2 ;;
            --stop)         stop_daemon; exit 0 ;;
            --status)       show_status; exit 0 ;;
            --test-alerts)  test_alerts; exit 0 ;;
            --help)         usage ;;
            *)              log ERROR "Unknown option: $1"; usage ;;
        esac
    done
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log INFO "Configuration loaded from $CONFIG_FILE"
    fi
}

send_telegram() {
    local message="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" &>/dev/null || true
}

send_slack() {
    local message="$1"
    [[ -z "$SLACK_WEBHOOK" ]] && return 0

    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"${message}\"}" \
        "$SLACK_WEBHOOK" &>/dev/null || true
}

send_discord() {
    local message="$1"
    [[ -z "$DISCORD_WEBHOOK" ]] && return 0

    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"content\":\"${message}\"}" \
        "$DISCORD_WEBHOOK" &>/dev/null || true
}

send_email() {
    local subject="$1"
    local body="$2"
    [[ -z "$EMAIL_TO" ]] && return 0

    echo "$body" | mail -s "$subject" -r "$EMAIL_FROM" "$EMAIL_TO" 2>/dev/null || true
}

send_alert() {
    local alert_type="$1"
    local message="$2"
    local severity="${3:-WARNING}"

    # Check cooldown
    local now
    now=$(date +%s)
    local last="${LAST_ALERT_TIME[$alert_type]:-0}"
    local elapsed=$((now - last))

    if [[ $elapsed -lt $ALERT_COOLDOWN ]]; then
        log DEBUG "Alert cooldown active for ${alert_type} (${elapsed}s < ${ALERT_COOLDOWN}s)"
        return 0
    fi

    LAST_ALERT_TIME[$alert_type]=$now

    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    local full_message="🚨 <b>[${severity}] ${alert_type}</b>
📍 Host: <code>${hostname}</code>
🕐 Time: ${timestamp}

${message}

— Server Monitor"

    local plain_message="[${severity}] ${alert_type}
Host: ${hostname}
Time: ${timestamp}

${message}"

    log WARN "ALERT [${alert_type}]: ${message}"

    send_telegram "$full_message"
    send_slack "$plain_message"
    send_discord "$plain_message"
    send_email "[${severity}] ${alert_type} — ${hostname}" "$plain_message"
}

check_cpu() {
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4)}')

    if [[ $cpu_usage -ge $CPU_THRESHOLD ]]; then
        local top_procs
        top_procs=$(ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "  %s: %s%% (PID %s)\n", $11, $3, $2}')
        send_alert "HIGH_CPU" "CPU usage: ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%)

Top processes:
${top_procs}" "WARNING"
    fi

    echo "$cpu_usage"
}

check_ram() {
    local ram_info
    ram_info=$(free | grep Mem)
    local total used available
    total=$(echo "$ram_info" | awk '{print $2}')
    used=$(echo "$ram_info" | awk '{print $3}')
    available=$(echo "$ram_info" | awk '{print $7}')

    local ram_pct=0
    [[ $total -gt 0 ]] && ram_pct=$(( (used * 100) / total ))

    if [[ $ram_pct -ge $RAM_THRESHOLD ]]; then
        local top_procs
        top_procs=$(ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "  %s: %s%% (PID %s)\n", $11, $4, $2}')
        send_alert "HIGH_RAM" "RAM usage: ${ram_pct}% (${used}K / ${total}K)

Top memory consumers:
${top_procs}" "WARNING"
    fi

    # Check swap
    local swap_info
    swap_info=$(free | grep Swap)
    local swap_total swap_used
    swap_total=$(echo "$swap_info" | awk '{print $2}')
    swap_used=$(echo "$swap_info" | awk '{print $3}')

    if [[ $swap_total -gt 0 ]]; then
        local swap_pct=$(( (swap_used * 100) / swap_total ))
        if [[ $swap_pct -ge $SWAP_THRESHOLD ]]; then
            send_alert "HIGH_SWAP" "Swap usage: ${swap_pct}% (${swap_used}K / ${swap_total}K)" "CRITICAL"
        fi
    fi

    echo "$ram_pct"
}

check_disk() {
    local alert_msg=""
    local triggered=false

    while IFS= read -r line; do
        local usage_pct mount_point
        usage_pct=$(echo "$line" | awk '{print int($5)}')
        mount_point=$(echo "$line" | awk '{print $6}')

        if [[ $usage_pct -ge $DISK_THRESHOLD ]]; then
            local disk_info
            disk_info=$(df -h "$mount_point" | tail -1 | awk '{printf "Used: %s / %s (%s)", $3, $2, $5}')
            alert_msg+="📁 ${mount_point}: ${usage_pct}% (${disk_info})"$'\n'
            triggered=true
        fi
    done < <(df --output=pcent,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2 | sed 's/%//')

    if [[ "$triggered" == true ]]; then
        send_alert "HIGH_DISK" "Disk usage exceeds ${DISK_THRESHOLD}%:${'\n'}${alert_msg}" "WARNING"
    fi
}

check_load() {
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print int($1)}')

    if [[ $load_avg -ge $LOAD_THRESHOLD ]]; then
        send_alert "HIGH_LOAD" "Load average: ${load_avg} (threshold: ${LOAD_THRESHOLD}, cores: $(nproc))" "WARNING"
    fi

    echo "$load_avg"
}

check_docker() {
    [[ "$DOCKER_HEALTH" != true ]] && return 0
    ! command -v docker &>/dev/null && return 0

    local unhealthy
    unhealthy=$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -c -i "unhealthy\|restarting" || echo "0")

    if [[ $unhealthy -gt 0 ]]; then
        local details
        details=$(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | grep -i "unhealthy\|restarting" | sed 's/^/  /')
        send_alert "DOCKER_UNHEALTHY" "${unhealthy} container(s) unhealthy:
${details}" "CRITICAL"
    fi

    # Check for OOM-killed containers
    local oom
    oom=$(docker ps -a --filter "status=exited" --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -c -i "oom\|killed" || echo "0")

    if [[ $oom -gt 0 ]]; then
        local details
        details=$(docker ps -a --filter "status=exited" --format '{{.Names}}: {{.Status}}' 2>/dev/null | grep -i "oom\|killed" | sed 's/^/  /')
        send_alert "DOCKER_OOM" "${oom} container(s) OOM-killed:
${details}" "CRITICAL"
    fi
}

check_processes() {
    [[ -z "$PROCESS_MONITOR" ]] && return 0

    for proc_entry in $PROCESS_MONITOR; do
        local proc_name="${proc_entry%%:*}"
        local proc_port="${proc_entry##*:}"

        # Check by port
        if [[ "$proc_port" =~ ^[0-9]+$ ]]; then
            if ! ss -tlnp | grep -q ":${proc_port} "; then
                send_alert "PROCESS_DOWN" "Service ${proc_name} is not listening on port ${proc_port}" "CRITICAL"
            fi
        # Check by process name
        elif ! pgrep -x "$proc_name" &>/dev/null; then
            send_alert "PROCESS_DOWN" "Process ${proc_name} is not running" "CRITICAL"
        fi
    done
}

check_network() {
    [[ "$NETWORK_CHECK" != true ]] && return 0

    # Check internet connectivity
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        send_alert "NETWORK_DOWN" "Internet connectivity check failed (8.8.8.8 unreachable)" "CRITICAL"
    fi

    # Check DNS resolution
    if ! nslookup google.com &>/dev/null; then
        send_alert "DNS_FAILURE" "DNS resolution failed for google.com" "WARNING"
    fi
}

check_ssl_expiry() {
    local domains="${SSL_DOMAINS:-}"
    [[ -z "$domains" ]] && return 0

    local alert_msg=""
    local triggered=false

    for domain in $domains; do
        local expiry_date
        expiry_date=$(echo | openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

        if [[ -n "$expiry_date" ]]; then
            local expiry_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
            local now_epoch
            now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [[ $days_left -le 14 ]]; then
                alert_msg+="🔒 ${domain}: ${days_left} days remaining (expires: ${expiry_date})"$'\n'
                triggered=true
            fi
        fi
    done

    if [[ "$triggered" == true ]]; then
        send_alert "SSL_EXPIRING" "SSL certificates expiring soon:${'\n'}${alert_msg}" "WARNING"
    fi
}

run_checks() {
    log DEBUG "Running system checks..."

    local cpu ram load
    cpu=$(check_cpu)
    ram=$(check_ram)
    load=$(check_load)
    check_disk
    check_docker
    check_processes
    check_network
    check_ssl_expiry

    log DEBUG "CPU: ${cpu}% | RAM: ${ram}% | Load: ${load}"
}

daemon_loop() {
    log INFO "Starting monitor daemon (interval: ${CHECK_INTERVAL}s, PID: $$)"
    echo $$ > "$PID_FILE"

    trap 'log INFO "Monitor daemon stopping"; rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT

    while true; do
        run_checks
        sleep "$CHECK_INTERVAL"
    done
}

stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" && echo "Monitor daemon stopped (PID: $pid)"
        else
            echo "Daemon not running (stale PID file)"
            rm -f "$PID_FILE"
        fi
    else
        echo "No monitor daemon running"
    fi
}

show_status() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Monitor daemon is running (PID: $(cat "$PID_FILE"))"
    else
        echo "Monitor daemon is not running"
    fi
}

test_alerts() {
    log INFO "Sending test alerts to all configured channels..."
    send_alert "TEST" "This is a test alert from the server monitoring system. If you receive this, your alert channels are configured correctly." "INFO"
    log INFO "Test alerts sent"
}

main() {
    parse_args "$@"
    load_config

    if [[ "$DAEMON_MODE" == true ]]; then
        daemon_loop
    else
        run_checks
        log INFO "System check complete"
    fi
}

main "$@"
