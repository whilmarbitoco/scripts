#!/bin/bash
# Bootstrap a new VPS with dependencies, Docker, Dokploy, SSH keys, firewall

# Update packages
apt update && apt upgrade -y

# Install essentials
apt install -y git curl docker.io docker-compose ufw

# Add non-root user
read -p "New username: " user
adduser $user
usermod -aG sudo,docker $user

# Setup firewall
ufw allow OpenSSH
ufw enable

# Dokploy setup placeholder
echo "Set up Dokploy manually or automate here"

# SSH key setup
echo "Copy your public key to ~/.ssh/authorized_keys"

echo "Bootstrap complete!"
