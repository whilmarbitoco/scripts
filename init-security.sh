#!/bin/bash

# ==============================================================================
# Script: init-security.sh
# Description: Production-ready Linux hardening for Debian/Ubuntu environments.
# Features: SSH Hardening, UFW Firewall, Fail2Ban, Sysctl Hardening, Auto-updates.
# ==============================================================================

# Strict Error Handling
set -euo pipefail
IFS=$'\n\t'

# Constants
SSH_PORT=2222
LOG_FILE="/var/log/init-security.log"
BACKUP_DIR="/var/backups/security-init-$(date +%F_%H-%M-%S)"

# --- Helper Functions ---

log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1" >&2
    exit 1
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error_exit "This script must be run as root."
    fi
}

backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$BACKUP_DIR/$(basename "$file").bak"
        log "Backup created for $file"
    fi
}

# --- Core Tasks ---

install_dependencies() {
    log "Updating package lists and installing core security tools..."
    apt-get update -y
    apt-get install -y ufw fail2ban unattended-upgrades curl sed grep procps auditd
}

harden_ssh() {
    log "Hardening SSH on port $SSH_PORT..."
    local ssh_config="/etc/ssh/sshd_config"
    backup_config "$ssh_config"

    # Apply hardened settings
    sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$ssh_config"
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$ssh_config"
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$ssh_config"
    sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries 3/" "$ssh_config"
    
    systemctl restart ssh
}

setup_firewall() {
    log "Configuring UFW Firewall..."
    # Reset firewall and set defaults
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Allow essential services
    ufw allow "$SSH_PORT"/tcp comment 'Custom SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # Enable UFW
    ufw --force enable
}

configure_fail2ban() {
    log "Configuring Fail2Ban..."
    local jail_config="/etc/fail2ban/jail.local"
    
    cat <<EOF > "$jail_config"
[DEFAULT]
bantime  = 24h
findtime = 1h
maxretry = 3

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
}

harden_sysctl() {
    log "Applying Kernel security parameters..."
    local sysctl_file="/etc/sysctl.d/99-security.conf"
    
    cat <<EOF > "$sysctl_file"
# Network Hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
# Prevent ICMP Redirects
net.ipv6.conf.all.accept_redirects = 0
# Memory Protection
kernel.randomize_va_space = 2
EOF

    sysctl --system > /dev/null
}

setup_auto_updates() {
    log "Configuring Unattended Security Upgrades..."
    cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

# --- Main Execution ---

main() {
    clear
    log "Starting Production-Ready Security Hardening..."
    
    check_root
    install_dependencies
    harden_ssh
    setup_firewall
    configure_fail2ban
    harden_sysctl
    setup_auto_updates
    
    log "--------------------------------------------------------"
    log "SUCCESS: System Hardening Complete."
    log "SSH Port: $SSH_PORT (Ensure your key is in ~/.ssh/authorized_keys)"
    log "Firewall: ACTIVE (80, 443, $SSH_PORT allowed)"
    log "Backups stored in: $BACKUP_DIR"
    log "--------------------------------------------------------"
}

main "$@"
