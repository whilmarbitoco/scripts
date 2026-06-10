#!/usr/bin/env bash
# ==============================================================================
# Script: firewall-audit.sh
# Description: Firewall rule audit, port scanning, and security analysis.
#               Supports UFW, iptables, and firewalld.
# Usage: ./firewall-audit.sh [--scan] [--audit] [--export]
# ==============================================================================

set -euo pipefail

SCAN_EXTERNAL=false
AUDIT_RULES=true
EXPORT_CONFIG=false
CHECK_PORTS="22,80,443,3306,5432,6379,8080,8443"
REPORT_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Firewall audit and port security analysis.

Options:
  --scan          Scan local ports for unexpected listeners
  --audit         Audit firewall rules (default)
  --export        Export current firewall config
  --ports LIST    Comma-separated ports to check (default: common ports)
  --report FILE   Save report to file
  --help          Show this help
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scan)    SCAN_EXTERNAL=true; shift ;;
            --audit)   AUDIT_RULES=true; shift ;;
            --export)  EXPORT_CONFIG=true; shift ;;
            --ports)   CHECK_PORTS="$2"; shift 2 ;;
            --report)  REPORT_FILE="$2"; shift 2 ;;
            --help)    usage ;;
            *)         error "Unknown option: $1"; usage ;;
        esac
    done
}

detect_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

audit_ufw() {
    echo -e "${BLUE}=== UFW Firewall Audit ===${NC}"
    echo ""

    local status
    status=$(ufw status verbose 2>/dev/null)
    echo "$status"
    echo ""

    # Check default policies
    local default_in default_out
    default_in=$(ufw status verbose | grep "Default:" | grep "incoming" | awk '{print $NF}')
    local default_out
    default_out=$(ufw status verbose | grep "Default:" | grep "outgoing" | awk '{print $NF}')

    if [[ "$default_in" != "deny" ]]; then
        warn "Default incoming policy is '${default_in}' — should be 'deny'"
    else
        log "Default incoming policy: deny ✓"
    fi

    if [[ "$default_out" != "allow" ]]; then
        warn "Default outgoing policy is '${default_out}' — typically 'allow'"
    else
        log "Default outgoing policy: allow ✓"
    fi

    # List rules
    echo -e "\n${BLUE}Active Rules:${NC}"
    ufw status numbered 2>/dev/null | grep -v "^$" | grep -v "Status" | grep -v "To"

    # Check for overly permissive rules
    echo -e "\n${BLUE}Security Checks:${NC}"
    if ufw status | grep -q "Anywhere.*ALLOW"; then
        warn "Found overly permissive ALLOW rules (Anywhere):"
        ufw status | grep "Anywhere.*ALLOW" | sed 's/^/  /'
    else
        log "No overly permissive ALLOW rules found ✓"
    fi

    # Check SSH rate limiting
    if ufw status | grep -q "22.*LIMIT"; then
        log "SSH rate limiting enabled ✓"
    elif ufw status | grep -q "22.*ALLOW"; then
        warn "SSH allowed without rate limiting"
    fi
}

audit_iptables() {
    echo -e "${BLUE}=== iptables Audit ===${NC}"
    echo ""

    # Default policies
    echo -e "${BLUE}Default Policies:${NC}"
    iptables -L -n 2>/dev/null | grep "Chain" | while read -r line; do
        local chain policy
        chain=$(echo "$line" | awk '{print $2}')
        policy=$(echo "$line" | awk '{print $4}' | tr -d ')')
        if [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]; then
            log "  ${chain}: ${policy} ✓"
        else
            warn "  ${chain}: ${policy} (consider DROP/REJECT)"
        fi
    done

    # Rule count
    echo -e "\n${BLUE}Rule Counts:${NC}"
    for chain in INPUT OUTPUT FORWARD; do
        local count
        count=$(iptables -L "$chain" -n 2>/dev/null | grep -c "^ACCEPT\|^DROP\|^REJECT" || echo "0")
        echo "  ${chain}: ${count} rules"
    done

    # Check for common issues
    echo -e "\n${BLUE}Security Checks:${NC}"

    # Loopback
    if iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT.*lo"; then
        log "Loopback allowed ✓"
    else
        warn "Loopback not explicitly allowed"
    fi

    # Established connections
    if iptables -L INPUT -n 2>/dev/null | grep -q "ESTABLISHED,RELATED"; then
        log "Established connections allowed ✓"
    else
        warn "Established connections not explicitly allowed"
    fi

    # ICMP
    if iptables -L INPUT -n 2>/dev/null | grep -q "icmp"; then
        log "ICMP rules present ✓"
    else
        warn "No ICMP rules — may affect network diagnostics"
    fi
}

scan_ports() {
    echo -e "${BLUE}=== Port Scan ===${NC}"
    echo ""

    log "Scanning local listening ports..."
    echo ""

    printf "%-8s %-12s %-20s %-s\n" "PORT" "STATE" "SERVICE" "PROCESS"
    printf "%-8s %-12s %-20s %-s\n" "────" "─────" "───────" "───────"

    ss -tlnp 2>/dev/null | tail -n +2 | while read -r line; do
        local port state process
        port=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
        state=$(echo "$line" | awk '{print $2}')
        process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")

        local color="$GREEN"
        if [[ "$port" == "22" || "$port" == "80" || "$port" == "443" ]]; then
            color="$GREEN"
        elif [[ "$port" == "3306" || "$port" == "5432" || "$port" == "6379" || "$port" == "27017" ]]; then
            color="$YELLOW"
        fi

        printf "${color}%-8s %-12s %-20s %-s${NC}\n" "$port" "$state" "$(get_service_name "$port")" "$process"
    done

    # Check for unexpected listeners
    echo -e "\n${BLUE}Unexpected Listeners:${NC}"
    local unexpected=false
    IFS=',' read -ra SAFE_PORTS <<< "$CHECK_PORTS"
    while IFS= read -r line; do
        local port
        port=$(echo "$line" | awk '{print $4}' | rev | cut -d: -f1 | rev)
        local found=false
        for safe in "${SAFE_PORTS[@]}"; do
            [[ "$port" == "$(echo "$safe" | xargs)" ]] && found=true && break
        done
        if [[ "$found" == false ]]; then
            warn "  Unexpected listener on port ${port}"
            unexpected=true
        fi
    done < <(ss -tlnp 2>/dev/null | tail -n +2)

    [[ "$unexpected" == false ]] && log "No unexpected listeners found ✓"
}

get_service_name() {
    local port="$1"
    case "$port" in
        22)   echo "SSH" ;;
        80)   echo "HTTP" ;;
        443)  echo "HTTPS" ;;
        3306) echo "MySQL" ;;
        5432) echo "PostgreSQL" ;;
        6379) echo "Redis" ;;
        27017) echo "MongoDB" ;;
        8080) echo "HTTP-Alt" ;;
        8443) echo "HTTPS-Alt" ;;
        3000) echo "Node.js" ;;
        5000) echo "Flask" ;;
        8000) echo "Django" ;;
        9000) echo "PHP-FPM" ;;
        *)    echo "unknown" ;;
    esac
}

export_config() {
    local fw_type
    fw_type=$(detect_firewall)
    local export_file="/opt/backups/firewall_$(date +%Y%m%d_%H%M%S).conf"

    mkdir -p "$(dirname "$export_file")"

    case "$fw_type" in
        ufw)
            { echo "# UFW Configuration Export — $(date)"; echo ""; ufw status verbose 2>/dev/null; } > "$export_file"
            ;;
        iptables)
            { echo "# iptables Configuration Export — $(date)"; echo ""; iptables-save 2>/dev/null; } > "$export_file"
            ;;
        firewalld)
            { echo "# firewalld Configuration Export — $(date)"; echo ""; firewall-cmd --list-all 2>/dev/null; } > "$export_file"
            ;;
        *)
            warn "No firewall detected to export"
            return
            ;;
    esac

    log "Firewall config exported: $export_file"
}

main() {
    parse_args "$@"

    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Firewall Audit Report          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    local fw_type
    fw_type=$(detect_firewall)
    log "Detected firewall: ${fw_type}"
    echo ""

    if [[ "$SCAN_EXTERNAL" == true ]]; then
        scan_ports
    fi

    if [[ "$AUDIT_RULES" == true ]]; then
        case "$fw_type" in
            ufw)       audit_ufw ;;
            iptables)  audit_iptables ;;
            firewalld) audit_ufw ;;  # Simplified
            none)      warn "No firewall detected — system may be unprotected!" ;;
        esac
    fi

    if [[ "$EXPORT_CONFIG" == true ]]; then
        export_config
    fi

    if [[ -n "$REPORT_FILE" ]]; then
        log "Report saved: $REPORT_FILE"
    fi

    echo ""
    log "✓ Firewall audit complete"
}

main "$@"
