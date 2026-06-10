#!/usr/bin/env bash
# ==============================================================================
# Script: ssl-manager.sh
# Description: SSL certificate management — issue, renew, monitor, and deploy
#               Let's Encrypt certs across multiple domains and services.
# Usage: ./ssl-manager.sh [--check|--renew|--deploy|--monitor]
# ==============================================================================

set -euo pipefail

DOMAINS=""
EMAIL=""
WEBROOT="/var/www/html"
NGINX_CONF="/etc/nginx/sites-available"
RELOAD_CMD="systemctl reload nginx"
CHECK_ONLY=false
RENEW_ONLY=false
DEPLOY_ONLY=false
MONITOR_ONLY=false
FORCE_RENEW=false
NOTIFY_WEBHOOK=""

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

SSL certificate management for Let's Encrypt.

Options:
  --domains LIST    Comma-separated domain list (domain1.com,domain2.com)
  --email EMAIL     Contact email for Let's Encrypt
  --check           Check expiry status only
  --renew           Renew certificates
  --force-renew     Force renewal regardless of expiry
  --deploy          Deploy certificates to services
  --monitor         Monitor and alert on expiring certs
  --webroot PATH    Webroot path for ACME challenge (default: /var/www/html)
  --webhook URL     Slack/Discord webhook for notifications
  --help            Show this help
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domains)     DOMAINS="$2"; shift 2 ;;
            --email)       EMAIL="$2"; shift 2 ;;
            --check)       CHECK_ONLY=true; shift ;;
            --renew)       RENEW_ONLY=true; shift ;;
            --force-renew) FORCE_RENEW=true; RENEW_ONLY=true; shift ;;
            --deploy)      DEPLOY_ONLY=true; shift ;;
            --monitor)     MONITOR_ONLY=true; shift ;;
            --webroot)     WEBROOT="$2"; shift 2 ;;
            --webhook)     NOTIFY_WEBHOOK="$2"; shift 2 ;;
            --help)         usage ;;
            *)             error "Unknown option: $1"; usage ;;
        esac
    done
}

check_certbot() {
    if ! command -v certbot &>/dev/null; then
        error "certbot not found. Install with: apt install certbot python3-certbot-nginx"
        exit 1
    fi
}

check_expiry() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"

    if [[ ! -f "$cert_path" ]]; then
        echo "MISSING"
        return
    fi

    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    echo "$days_left"
}

check_all_domains() {
    log "Checking SSL certificate status..."
    echo ""
    printf "%-40s %-12s %-10s\n" "DOMAIN" "DAYS LEFT" "STATUS"
    printf "%-40s %-12s %-10s\n" "──────" "─────────" "──────"

    local alert_msg=""
    IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
    for domain in "${DOMAIN_LIST[@]}"; do
        domain=$(echo "$domain" | xargs)
        local days
        days=$(check_expiry "$domain")

        local status color
        if [[ "$days" == "MISSING" ]]; then
            status="MISSING"
            color="$RED"
            alert_msg+="🔴 ${domain}: No certificate found"$'\n'
        elif [[ $days -le 0 ]]; then
            status="EXPIRED"
            color="$RED"
            alert_msg+="🔴 ${domain}: EXPIRED (${days} days)"$'\n'
        elif [[ $days -le 7 ]]; then
            status="CRITICAL"
            color="$RED"
            alert_msg+="🟠 ${domain}: ${days} days remaining"$'\n'
        elif [[ $days -le 14 ]]; then
            status="WARNING"
            color="$YELLOW"
            alert_msg+="🟡 ${domain}: ${days} days remaining"$'\n'
        elif [[ $days -le 30 ]]; then
            status="ATTENTION"
            color="$YELLOW"
        else
            status="OK"
            color="$GREEN"
        fi

        printf "${color}%-40s %-12s %-10s${NC}\n" "$domain" "$days" "$status"
    done

    echo ""

    if [[ -n "$alert_msg" && -n "$NOTIFY_WEBHOOK" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"🔒 SSL Certificate Alert:\n${alert_msg}\"}" \
            "$NOTIFY_WEBHOOK" &>/dev/null || true
    fi
}

renew_certs() {
    log "Renewing SSL certificates..."

    local renew_opts="--non-interactive --agree-tos"
    [[ -n "$EMAIL" ]] && renew_opts="$renew_opts --email $EMAIL"
    [[ "$FORCE_RENEW" == true ]] && renew_opts="$renew_opts --force-renewal"

    IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
    for domain in "${DOMAIN_LIST[@]}"; do
        domain=$(echo "$domain" | xargs)
        local days
        days=$(check_expiry "$domain")

        if [[ "$FORCE_RENEW" != true && "$days" != "MISSING" && $days -gt 30 ]]; then
            log "Skipping ${domain} — ${days} days remaining (use --force-renew to override)"
            continue
        fi

        log "Processing: ${domain}"

        if [[ -f "${NGINX_CONF}/${domain}" ]]; then
            # Use nginx plugin
            certbot certonly --nginx $renew_opts -d "$domain" 2>&1 | tail -5
        else
            # Use webroot
            certbot certonly --webroot $renew_opts -w "$WEBROOT" -d "$domain" 2>&1 | tail -5
        fi

        if [[ $? -eq 0 ]]; then
            log "✓ Certificate renewed: ${domain}"
        else
            error "✗ Certificate renewal failed: ${domain}"
        fi
    done

    # Reload services
    log "Reloading services..."
    eval "$RELOAD_CMD" 2>/dev/null || true
    log "✓ Services reloaded"
}

deploy_certs() {
    log "Deploying certificates to services..."

    IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
    for domain in "${DOMAIN_LIST[@]}"; do
        domain=$(echo "$domain" | xargs)
        local cert_dir="/etc/letsencrypt/live/${domain}"

        if [[ ! -d "$cert_dir" ]]; then
            warn "No certificate found for ${domain}, skipping"
            continue
        fi

        log "Deploying: ${domain}"
        echo "  Certificate: ${cert_dir}/fullchain.pem"
        echo "  Private Key: ${cert_dir}/privkey.pem"

        # Copy to common locations
        local deploy_dir="/opt/ssl/${domain}"
        mkdir -p "$deploy_dir"
        cp "${cert_dir}/fullchain.pem" "${deploy_dir}/cert.pem"
        cp "${cert_dir}/privkey.pem" "${deploy_dir}/key.pem"
        chmod 600 "${deploy_dir}/key.pem"
        chmod 644 "${deploy_dir}/cert.pem"

        log "✓ Deployed to: ${deploy_dir}"
    done
}

main() {
    parse_args "$@"
    check_certbot

    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       SSL Certificate Manager        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    if [[ -z "$DOMAINS" ]]; then
        # Auto-discover from nginx configs
        if [[ -d "$NGINX_CONF" ]]; then
            DOMAINS=$(grep -rh "server_name" "$NGINX_CONF/" 2>/dev/null | \
                sed 's/server_name//;s/;//' | tr ' ' '\n' | sort -u | grep -v '^$' | grep -v '_' | \
                tr '\n' ',' | sed 's/,$//')
            log "Auto-discovered domains: $DOMAINS"
        fi
    fi

    if [[ -z "$DOMAINS" ]]; then
        error "No domains specified. Use --domains or configure nginx sites."
        exit 1
    fi

    if [[ "$CHECK_ONLY" == true ]]; then
        check_all_domains
    elif [[ "$RENEW_ONLY" == true ]]; then
        renew_certs
    elif [[ "$DEPLOY_ONLY" == true ]]; then
        deploy_certs
    elif [[ "$MONITOR_ONLY" == true ]]; then
        check_all_domains
    else
        # Default: check + renew if needed
        check_all_domains
        renew_certs
    fi

    echo ""
    log "✓ SSL management complete"
}

main "$@"
