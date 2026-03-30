#!/bin/bash

# Copyright (C) 2026 Oleh Mamont
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org>.

# LiteLLM Auto-Update Script
# Environment: Linux (Debian/Ubuntu), venv, systemd service

set -e  # Exit on error

# ================= SETTINGS =================
VENV_PATH="/root/ai/core/servers/litellm-venv"
SERVICE_NAME="ai-litellm"

# INSERT YOUR DATABASE_URL HERE
# Example: postgresql://user:password@localhost:5432/litellm_db
export DATABASE_URL="postgresql://user:pass@localhost:5432/db_name"
# ============================================

echo "=== [1/5] Stopping service: $SERVICE_NAME ==="
systemctl stop $SERVICE_NAME || echo "Service already stopped"

echo "=== [2/5] Updating packages in venv ==="
source "$VENV_PATH/bin/activate"
pip install --upgrade pip
pip install --upgrade 'litellm[proxy]' prisma

echo "=== [3/5] Locating Prisma schema ==="
# Dynamically find the schema path inside the installed package
SCHEMA_PATH=$(python3 -c "import os, litellm; print(os.path.join(os.path.dirname(litellm.__file__), 'proxy/schema.prisma'))")
echo "Schema found at: $SCHEMA_PATH"

echo "=== [4/5] Database migration and client generation ==="
# Sync database structure without data loss
prisma db push --schema="$SCHEMA_PATH" --accept-data-loss
prisma generate --schema="$SCHEMA_PATH"

echo "=== [5/5] Starting service and health check ==="
systemctl start $SERVICE_NAME
sleep 3

if systemctl is-active --quiet $SERVICE_NAME; then
    echo "-------------------------------------------"
    echo "SUCCESS: LiteLLM updated and running!"
    litellm --version
    echo "-------------------------------------------"
else
    echo "ERROR: Service failed to start. Check logs: journalctl -u $SERVICE_NAME -n 20"
    exit 1
fi

deactivate
