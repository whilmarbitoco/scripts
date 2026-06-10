#!/usr/bin/env bash
# ==============================================================================
# Script: log-analyzer.sh
# Description: Log parsing, error detection, pattern matching, and reporting.
#               Supports nginx, Apache, syslog, Docker, PM2, and custom logs.
# Usage: ./log-analyzer.sh [--log /var/log/nginx/error.log] [--since 1h]
# ==============================================================================

set -euo pipefail

LOG_FILE=""
SINCE="1h"
TOP_N=20
OUTPUT_FORMAT="text"
REPORT_FILE=""
ALERT_ON_ERRORS=false
ERROR_THRESHOLD=50
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Log analysis with error detection and pattern matching.

Options:
  --log FILE          Log file to analyze (auto-detects type)
  --since TIME        Time range: 1h, 24h, 7d (default: 1h)
  --top N             Show top N entries (default: 20)
  --format FORMAT     Output: text, json, csv (default: text)
  --report FILE       Save report to file
  --alert             Send alert if errors exceed threshold
  --threshold N       Error count threshold for alerts (default: 50)
  --help              Show this help

Auto-detected log types:
  nginx, apache, syslog, docker, pm2, postgresql, mysql, auth, kern
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log)        LOG_FILE="$2"; shift 2 ;;
            --since)      SINCE="$2"; shift 2 ;;
            --top)        TOP_N="$2"; shift 2 ;;
            --format)     OUTPUT_FORMAT="$2"; shift 2 ;;
            --report)     REPORT_FILE="$2"; shift 2 ;;
            --alert)      ALERT_ON_ERRORS=true; shift ;;
            --threshold)  ERROR_THRESHOLD="$2"; shift 2 ;;
            --help)       usage ;;
            *)            echo "Unknown option: $1"; usage ;;
        esac
    done
}

detect_log_type() {
    local file="$1"
    local basename
    basename=$(basename "$file")

    case "$basename" in
        *nginx*|*access*|*httpd*) echo "nginx" ;;
        *apache*)                 echo "apache" ;;
        *syslog*)                 echo "syslog" ;;
        *docker*|*container*)     echo "docker" ;;
        *pm2*)                    echo "pm2" ;;
        *postgres*|*pg*)          echo "postgresql" ;;
        *mysql*)                  echo "mysql" ;;
        *auth*|*secure*)          echo "auth" ;;
        *kern*)                   echo "kern" ;;
        *)                        echo "generic" ;;
    esac
}

parse_time_range() {
    local since="$1"
    case "$since" in
        *h)  date -d "-${since%h} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-"${since%h}H" '+%Y-%m-%d %H:%M:%S' ;;
        *d)  date -d "-${since%d} days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-"${since%d}d" '+%Y-%m-%d %H:%M:%S' ;;
        *m)  date -d "-${since%m} minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-"${since%m}M" '+%Y-%m-%d %H:%M:%S' ;;
        *)   date '-1 hour' '+%Y-%m-%d %H:%M:%S' ;;
    esac
}

analyze_nginx() {
    local log="$1"
    local since_time
    since_time=$(parse_time_range "$SINCE")

    echo -e "${CYAN}=== Nginx Log Analysis ===${NC}"
    echo ""

    # Total requests
    local total
    total=$(wc -l < "$log" 2>/dev/null || echo "0")
    echo -e "${BLUE}Total lines:${NC} $total"

    # HTTP status code distribution
    echo -e "\n${BLUE}HTTP Status Codes:${NC}"
    grep -oP '" \K\d{3}(?= )' "$log" 2>/dev/null | sort | uniq -c | sort -rn | head -10 | while read -r count code; do
        local color="$GREEN"
        [[ "$code" == 4* ]] && color="$YELLOW"
        [[ "$code" == 5* ]] && color="$RED"
        printf "  ${color}%s${NC}: %s\n" "$code" "$count"
    done

    # Top URLs
    echo -e "\n${BLUE}Top ${TOP_N} URLs:${NC}"
    awk '{print $7}' "$log" 2>/dev/null | sort | uniq -c | sort -rn | head -"$TOP_N" | while read -r count url; do
        printf "  %6s  %s\n" "$count" "$url"
    done

    # Top IPs
    echo -e "\n${BLUE}Top ${TOP_N} IPs:${NC}"
    awk '{print $1}' "$log" 2>/dev/null | sort | uniq -c | sort -rn | head -"$TOP_N" | while read -r count ip; do
        printf "  %6s  %s\n" "$count" "$ip"
    done

    # Error rate
    local errors_4xx errors_5xx
    errors_4xx=$(grep -c '" 4' "$log" 2>/dev/null || echo "0")
    errors_5xx=$(grep -c '" 5' "$log" 2>/dev/null || echo "0")
    echo -e "\n${BLUE}Error Summary:${NC}"
    echo -e "  4xx errors: ${YELLOW}${errors_4xx}${NC}"
    echo -e "  5xx errors: ${RED}${errors_5xx}${NC}"

    # Response time analysis (if available)
    if grep -q 'rt=' "$log" 2>/dev/null; then
        echo -e "\n${BLUE}Response Times:${NC}"
        local avg_time max_time
        avg_time=$(grep -oP 'rt=\K[0-9.]+' "$log" 2>/dev/null | awk '{s+=$1; c++} END {printf "%.3f", s/c}')
        max_time=$(grep -oP 'rt=\K[0-9.]+' "$log" 2>/dev/null | sort -rn | head -1)
        echo -e "  Average: ${avg_time}s"
        echo -e "  Max:     ${max_time}s"
    fi

    echo "$((errors_4xx + errors_5xx))"
}

analyze_generic() {
    local log="$1"

    echo -e "${CYAN}=== Generic Log Analysis ===${NC}"
    echo ""

    local total
    total=$(wc -l < "$log" 2>/dev/null || echo "0")
    echo -e "${BLUE}Total lines:${NC} $total"

    # Error patterns
    echo -e "\n${BLUE}Error Patterns:${NC}"
    local error_count=0
    for pattern in "ERROR" "FATAL" "CRITICAL" "Exception" "panic" "OOM" "segfault" "denied" "refused"; do
        local count
        count=$(grep -ci "$pattern" "$log" 2>/dev/null || echo "0")
        if [[ $count -gt 0 ]]; then
            local color="$YELLOW"
            [[ "$pattern" == "FATAL" || "$pattern" == "CRITICAL" || "$pattern" == "panic" ]] && color="$RED"
            printf "  ${color}%-15s${NC}: %s\n" "$pattern" "$count"
            error_count=$((error_count + count))
        fi
    done

    # Top error messages
    echo -e "\n${BLUE}Top Error Messages:${NC}"
    grep -iE "error|fatal|exception|panic" "$log" 2>/dev/null | \
        sed 's/.*\(ERROR\|FATAL\|Exception\|panic\)/\1/' | \
        sort | uniq -c | sort -rn | head -10 | while read -r count msg; do
        printf "  %6s  %s\n" "$count" "$msg"
    done

    # Time distribution (by hour)
    echo -e "\n${BLUE}Activity by Hour:${NC}"
    awk '{print $2}' "$log" 2>/dev/null | cut -d: -f1 | sort | uniq -c | sort -rn | head -12 | while read -r count hour; do
        printf "  %s:00  %s\n" "$hour" "$(printf '%*s' "$count" '' | tr ' ' '█')"
    done

    echo "$error_count"
}

main() {
    parse_args "$@"

    if [[ -z "$LOG_FILE" ]]; then
        # Auto-detect common log files
        for candidate in /var/log/nginx/error.log /var/log/syslog /var/log/messages; do
            if [[ -f "$candidate" ]]; then
                LOG_FILE="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
        echo -e "${RED}Error: No log file found or specified${NC}"
        echo "Use --log FILE to specify a log file"
        exit 1
    fi

    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Log Analyzer Report            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Log File:${NC}  $LOG_FILE"
    echo -e "${BLUE}Log Size:${NC}  $(du -h "$LOG_FILE" | cut -f1)"
    echo -e "${BLUE}Since:${NC}     $SINCE"
    echo -e "${BLUE}Type:${NC}      $(detect_log_type "$LOG_FILE")"
    echo ""

    local log_type
    log_type=$(detect_log_type "$LOG_FILE")
    local error_count=0

    case "$log_type" in
        nginx|apache)
            error_count=$(analyze_nginx "$LOG_FILE")
            ;;
        *)
            error_count=$(analyze_generic "$LOG_FILE")
            ;;
    esac

    # Alert on high error count
    if [[ "$ALERT_ON_ERRORS" == true && "$error_count" -ge "$ERROR_THRESHOLD" ]]; then
        local msg="Log analyzer detected ${error_count} errors in ${LOG_FILE} (threshold: ${ERROR_THRESHOLD})"
        echo -e "\n${RED}⚠ ALERT: ${msg}${NC}"

        if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_CHAT_ID}" \
                -d "text=🚨 ${msg}" &>/dev/null || true
        fi
    fi

    # Save report
    if [[ -n "$REPORT_FILE" ]]; then
        {
            echo "Log Analysis Report — $(date)"
            echo "Log: $LOG_FILE | Type: $log_type | Since: $SINCE"
            echo "Errors detected: $error_count"
        } > "$REPORT_FILE"
        echo -e "\n${GREEN}Report saved: ${REPORT_FILE}${NC}"
    fi
}

main "$@"
