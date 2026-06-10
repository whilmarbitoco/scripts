#!/usr/bin/env bash
# ==============================================================================
# Script: health-dashboard.sh
# Description: Server health summary dashboard — displays CPU, RAM, disk,
#               network, Docker, services, and recent alerts in a single view.
# Usage: ./health-dashboard.sh [--json] [--refresh N]
# ==============================================================================

set -euo pipefail

OUTPUT_FORMAT="text"
REFRESH_INTERVAL=0
LOG_FILE="/var/log/health-dashboard.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Server health dashboard.

Options:
  --json          Output as JSON
  --refresh N     Auto-refresh every N seconds
  --help          Show this help
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)     OUTPUT_FORMAT="json"; shift ;;
            --refresh)  REFRESH_INTERVAL="$2"; shift 2 ;;
            --help)     usage ;;
            *)          echo "Unknown option: $1"; usage ;;
        esac
    done
}

get_cpu_info() {
    local usage
    usage=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f", $2 + $4}')
    local cores
    cores=$(nproc)
    local load
    load=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    echo "${usage}|${cores}|${load}"
}

get_ram_info() {
    local info
    info=$(free -m | grep Mem)
    local total used available pct
    total=$(echo "$info" | awk '{print $2}')
    used=$(echo "$info" | awk '{print $3}')
    available=$(echo "$info" | awk '{print $7}')
    pct=0
    [[ $total -gt 0 ]] && pct=$(( (used * 100) / total ))
    echo "${pct}|${used}|${total}|${available}"
}

get_disk_info() {
    local result=""
    while IFS= read -r line; do
        local usage_pct mount total used
        usage_pct=$(echo "$line" | awk '{print int($5)}')
        mount=$(echo "$line" | awk '{print $6}')
        total=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        result+="${mount}|${usage_pct}|${used}|${total}\n"
    done < <(df -h --output=source,pcent,used,size,target -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2 | head -10)
    echo -e "$result"
}

get_network_info() {
    local interfaces=""
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        local rx_bytes tx_bytes rx_human tx_human
        rx_bytes=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo "0")
        tx_bytes=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo "0")
        rx_human=$(numfmt --to=iec "$rx_bytes" 2>/dev/null || echo "${rx_bytes}B")
        tx_human=$(numfmt --to=iec "$tx_bytes" 2>/dev/null || echo "${tx_bytes}B")
        local state
        state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
        interfaces+="${iface}|${state}|${rx_human}|${tx_human}\n"
    done
    echo -e "$interfaces"
}

get_docker_info() {
    if ! command -v docker &>/dev/null; then
        echo "Docker not installed"
        return
    fi

    local running total unhealthy
    running=$(docker ps -q 2>/dev/null | wc -l)
    total=$(docker ps -aq 2>/dev/null | wc -l)
    unhealthy=$(docker ps --format '{{.Status}}' 2>/dev/null | grep -c -i "unhealthy" || echo "0")
    local images
    images=$(docker images -q 2>/dev/null | wc -l)

    echo "${running}|${total}|${unhealthy}|${images}"
}

get_service_status() {
    local services=("nginx" "postgresql" "mysql" "redis-server" "docker" "ssh" "fail2ban" "ufw")
    local result=""

    for svc in "${services[@]}"; do
        local status="stopped"
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="running"
        elif pgrep -x "$svc" &>/dev/null; then
            status="running"
        fi
        result+="${svc}|${status}\n"
    done

    echo -e "$result"
}

get_uptime() {
    uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}'
}

get_last_alerts() {
    if [[ -f /var/log/monitor.log ]]; then
        grep "ALERT" /var/log/monitor.log 2>/dev/null | tail -5 || echo "No alerts"
    else
        echo "No alerts"
    fi
}

print_bar() {
    local pct="$1"
    local width=30
    local filled=$(( (pct * width) / 100 ))
    local empty=$(( width - filled ))

    local color="$GREEN"
    [[ $pct -ge 70 ]] && color="$YELLOW"
    [[ $pct -ge 90 ]] && color="$RED"

    printf "${color}"
    printf '%*s' "$filled" '' | tr '█' '█'
    printf "${NC}"
    printf '%*s' "$empty" '' | tr '░' '░'
    printf " %3s%%" "$pct"
}

print_text_dashboard() {
    local hostname
    hostname=$(hostname)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local uptime_str
    uptime_str=$(get_uptime)

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${BOLD}           🖥  SERVER HEALTH DASHBOARD${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Host:${NC}     ${hostname}"
    echo -e "  ${BLUE}Uptime:${NC}   ${uptime_str}"
    echo -e "  ${BLUE}Time:${NC}     ${timestamp}"
    echo ""

    # CPU
    echo -e "  ${BOLD}━━━ CPU ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    IFS='|' read -ra CPU <<< "$(get_cpu_info)"
    printf "  Usage:    "; print_bar "${CPU[0]%.*}"
    echo ""
    echo -e "  Cores:    ${CPU[1]}"
    echo -e "  Load:     ${CPU[2]}"
    echo ""

    # RAM
    echo -e "  ${BOLD}━━━ Memory ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    IFS='|' read -ra RAM <<< "$(get_ram_info)"
    printf "  Usage:    "; print_bar "${RAM[0]}"
    echo ""
    echo -e "  Used:     ${RAM[1]}MB / ${RAM[2]}MB"
    echo -e "  Available: ${RAM[3]}MB"
    echo ""

    # Disk
    echo -e "  ${BOLD}━━━ Disk ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -ra DISK <<< "$line"
        local mount="${DISK[0]}"
        local pct="${DISK[1]}"
        local used="${DISK[2]}"
        local total="${DISK[3]}"
        printf "  %-15s" "$mount"
        print_bar "$pct"
        echo "  (${used}/${total})"
    done < <(get_disk_info)
    echo ""

    # Network
    echo -e "  ${BOLD}━━━ Network ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -ra NET <<< "$line"
        local state_color="$GREEN"
        [[ "${NET[1]}" != "up" ]] && state_color="$RED"
        printf "  %-10s ${state_color}%-6s${NC}  RX: %-10s  TX: %s\n" "${NET[0]}" "${NET[1]}" "${NET[2]}" "${NET[3]}"
    done < <(get_network_info)
    echo ""

    # Docker
    echo -e "  ${BOLD}━━━ Docker ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local docker_info
    docker_info=$(get_docker_info)
    if [[ "$docker_info" == "Docker not installed" ]]; then
        echo -e "  ${YELLOW}Docker not installed${NC}"
    else
        IFS='|' read -ra DOCKER <<< "$docker_info"
        echo -e "  Running:  ${GREEN}${DOCKER[0]}${NC} / ${DOCKER[1]} total"
        echo -e "  Unhealthy: ${RED}${DOCKER[2]}${NC}"
        echo -e "  Images:   ${DOCKER[3]}"
    fi
    echo ""

    # Services
    echo -e "  ${BOLD}━━━ Services ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -ra SVC <<< "$line"
        local status_color="$RED"
        [[ "${SVC[1]}" == "running" ]] && status_color="$GREEN"
        printf "  %-18s ${status_color}● %s${NC}\n" "${SVC[0]}" "${SVC[1]}"
    done < <(get_service_status)
    echo ""

    # Recent Alerts
    echo -e "  ${BOLD}━━━ Recent Alerts ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    local alerts
    alerts=$(get_last_alerts)
    if [[ "$alerts" == "No alerts" ]]; then
        echo -e "  ${GREEN}No recent alerts${NC}"
    else
        echo "$alerts" | while IFS= read -r alert; do
            echo -e "  ${YELLOW}⚠${NC} $alert"
        done
    fi
    echo ""

    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_json_dashboard() {
    local hostname
    hostname=$(hostname)
    local timestamp
    date -u +"%Y-%m-%dT%H:%M:%SZ"

    IFS='|' read -ra CPU <<< "$(get_cpu_info)"
    IFS='|' read -ra RAM <<< "$(get_ram_info)"

    cat <<EOF
{
  "host": "${hostname}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "uptime": "$(get_uptime)",
  "cpu": {
    "usage_percent": ${CPU[0]},
    "cores": ${CPU[1]},
    "load_avg": "${CPU[2]}"
  },
  "memory": {
    "usage_percent": ${RAM[0]},
    "used_mb": ${RAM[1]},
    "total_mb": ${RAM[2]},
    "available_mb": ${RAM[3]}
  },
  "disk": [
$(get_disk_info | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS='|' read -ra D <<< "$line"
    echo "    {\"mount\": \"${D[0]}\", \"usage_percent\": ${D[1]}, \"used\": \"${D[2]}\", \"total\": \"${D[3]}\"},"
done | sed '$ s/,$//')
  ],
  "docker": {
    "running": $(docker ps -q 2>/dev/null | wc -l),
    "total": $(docker ps -aq 2>/dev/null | wc -l),
    "unhealthy": $(docker ps --format '{{.Status}}' 2>/dev/null | grep -c -i "unhealthy" || echo "0")
  }
}
EOF
}

main() {
    parse_args "$@"

    if [[ "$REFRESH_INTERVAL" -gt 0 ]]; then
        while true; do
            clear
            print_text_dashboard
            sleep "$REFRESH_INTERVAL"
        done
    elif [[ "$OUTPUT_FORMAT" == "json" ]]; then
        print_json_dashboard
    else
        print_text_dashboard
    fi
}

main "$@"
