#!/usr/bin/env bash

set -e

echo "Enter PostgreSQL connection string (DSN):"
read -r -s DB_URL
echo

if [ -z "$DB_URL" ]; then
    echo "ERROR: Connection string cannot be empty"
    exit 1
fi

# =========================
# Ensure psql is installed
# =========================

if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found. Installing PostgreSQL client..."

    if [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y postgresql-client
    elif [ -f /etc/alpine-release ]; then
        sudo apk add --no-cache postgresql-client
    elif [ -f /etc/redhat-release ]; then
        sudo dnf install -y postgresql
    else
        echo "ERROR: Unsupported OS. Please install 'psql' manually."
        exit 2
    fi
fi

# =========================
# Test connection
# =========================

echo "-----------------------------------"
echo "Checking PostgreSQL connection..."
echo "-----------------------------------"

OUTPUT=$(psql "$DB_URL" -c "SELECT 1;" -t 2>&1)

if echo "$OUTPUT" | grep -q "1"; then
    echo "OK: Connection successful"
    exit 0
else
    echo "ERROR: Connection failed"
    echo "Details:"
    echo "$OUTPUT"
    exit 3
fi