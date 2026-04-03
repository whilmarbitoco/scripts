#!/usr/bin/env bash

set -e  # Exit immediately if any command fails (safer for setup scripts)

echo "GitHub + Git Setup"

# -----------------------------
# OS Detection
# -----------------------------
# Git behaves differently on Windows vs Unix systems regarding line endings.
# On Linux/macOS, "input" prevents CRLF issues when committing.
OS="$(uname)"
if [[ "$OS" == "Linux" || "$OS" == "Darwin" ]]; then
  AUTOCRLF="input"
else
  AUTOCRLF="true"
fi

echo "Detected OS: $OS"
echo "Default core.autocrlf: $AUTOCRLF"

# -----------------------------
# User Input
# -----------------------------
echo ""
read -p "Enter your Git name: " NAME
read -p "Enter your Git email: " EMAIL
read -p "Enter preferred editor (optional): " EDITOR
read -p "Enter SSH key name (default: id_ed25519): " KEY_NAME

# Default key name if user leaves it empty
KEY_NAME=${KEY_NAME:-id_ed25519}
SSH_KEY_PATH="$HOME/.ssh/$KEY_NAME"

# -----------------------------
# Confirmation Step
# -----------------------------
echo ""
echo "Summary:"
echo "Name: $NAME"
echo "Email: $EMAIL"
echo "Editor: ${EDITOR:-none}"
echo "SSH Key: $SSH_KEY_PATH"
echo "autocrlf: $AUTOCRLF"

read -p "Proceed? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 1

# -----------------------------
# Git Configuration
# -----------------------------
# Sets global identity (fine for single-account VPS usage).
# For multi-account setups, prefer per-repo config instead.
echo ""
echo "🔧 Configuring Git..."

git config --global user.name "$NAME"
git config --global user.email "$EMAIL"
git config --global core.autocrlf "$AUTOCRLF"

# Optional editor (useful for commit messages, rebase, etc.)
if [[ -n "$EDITOR" ]]; then
  git config --global core.editor "$EDITOR"
fi

echo "Git configured"

# -----------------------------
# SSH Key Setup for GitHub
# -----------------------------
# Assumes SSH is installed but no GitHub key exists yet.
echo ""
echo "Setting up GitHub SSH key..."

mkdir -p ~/.ssh
chmod 700 ~/.ssh  # Required for SSH to trust this directory

# Generate key only if it doesn't already exist
if [[ -f "$SSH_KEY_PATH" ]]; then
  echo "SSH key already exists: $SSH_KEY_PATH"
else
  # ed25519 is modern, secure, and fast
  ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY_PATH" -N ""
  echo "SSH key generated"
fi

# -----------------------------
# SSH Agent Setup
# -----------------------------
# Ensures key is loaded into memory for authentication
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
  echo "Starting ssh-agent..."
  eval "$(ssh-agent -s)"
fi

ssh-add "$SSH_KEY_PATH"

# -----------------------------
# SSH Config Update
# -----------------------------
# Ensures Git uses the correct key for GitHub
SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Only append if not already configured (idempotent)
if ! grep -q "Host github.com" "$SSH_CONFIG"; then
cat >> "$SSH_CONFIG" <<EOF

# GitHub SSH configuration
Host github.com
  HostName github.com
  User git
  IdentityFile $SSH_KEY_PATH
  IdentitiesOnly yes
EOF
fi

echo "SSH config updated"

# -----------------------------
# Output Public Key
# -----------------------------
# User must manually add this to GitHub
echo ""
echo "Copy this SSH key to GitHub:"
echo "----------------------------------------"
cat "${SSH_KEY_PATH}.pub"
echo "----------------------------------------"

echo ""
echo "Go to:"
echo "GitHub → Settings → SSH and GPG keys → New SSH key"

# -----------------------------
# Connection Test
# -----------------------------
# This verifies that GitHub recognizes the key
echo ""
read -p "Press Enter after adding the key to GitHub to test..."

# Will return a message like:
# "Hi username! You've successfully authenticated..."
ssh -T git@github.com || true

# -----------------------------
# Final Notes
# -----------------------------
echo ""
echo "Setup complete!"

echo ""
echo "Notes:"
echo "- If SSH key is not remembered after reboot, add ssh-agent to your shell profile."
echo "- For multiple GitHub accounts, use SSH host aliases (github-acc1, github-acc2)."
echo "- Prefer per-repo git config if working with multiple identities."
