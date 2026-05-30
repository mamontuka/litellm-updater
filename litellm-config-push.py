#!/usr/bin/env python3
#
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

import yaml
import re
import sys
import psycopg2
from psycopg2.extras import Json
import requests
import time

# --- CONFIGURATION ---
CONFIG_FILE = "/root/ai/tools/litellm-config.yaml"
DB_URL = "postgresql://litellm_user:litellm_pass@localhost:5432/litellm_db"
BASE_URL = "http://127.0.0.1:4000"
MASTER_KEY = "sk-xxxxxxxxxxxx"
HEADERS = {"Authorization": f"Bearer {MASTER_KEY}", "Content-Type": "application/json"}

# 👤 Author tag for DB records
DB_USER_TAG = "Admin"

def extract_port(api_base: str) -> str:
    match = re.search(r":(\d+)(?:/|$)", str(api_base))
    return match.group(1) if match else "0000"

def force_terminate_connections():
    """🔪 [0/3] FORCE TERMINATE: Kill all connections to the database"""
    print("🔪 [0/3] === TERMINATING ACTIVE CONNECTIONS ===")
    try:
        print("   🔌 Connecting to PostgreSQL (system db)...")
        # Connect to 'postgres' db to safely terminate connections to 'litellm_db'
        conn = psycopg2.connect(DB_URL.replace("/litellm_db", "/postgres"))
        conn.autocommit = True
        cur = conn.cursor()
        print("   ✅ Connection established.")

        print("   🚫 Terminating all backends connected to 'litellm_db'...")
        cur.execute('''
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname = 'litellm_db'
            AND pid <> pg_backend_pid();
        ''')
        terminated = cur.rowcount
        print(f"   💀 Terminated {terminated} active connection(s).")

        cur.close()
        conn.close()
        print("   🔌 Connection closed.")
        print(f"✅ [0/3] Connections terminated. Ready for cleanup.")
    except Exception as e:
        print(f"⚠️ [0/3] WARNING: Could not terminate connections: {e}")
        print("   Proceeding anyway, but TRUNCATE may fail if locks exist.")

def hard_reset_db():
    """🧨 [1/3] RADICAL CLEANUP: Clear table"""
    print("🧨 [1/3] === STARTING DATABASE CLEANUP ===")
    try:
        print("   🔌 Connecting to PostgreSQL...")
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        print("   ✅ Connection established.")

        # Check before cleanup
        print("   🔍 Checking current record count...")
        cur.execute('SELECT COUNT(*) FROM "LiteLLM_ProxyModelTable";')
        count_before = cur.fetchone()[0]
        print(f"   📊 Before cleanup: {count_before} records.")

        print("   🧹 Executing TRUNCATE TABLE ... RESTART IDENTITY CASCADE...")
        cur.execute('TRUNCATE TABLE "LiteLLM_ProxyModelTable" RESTART IDENTITY CASCADE;')

        print("   💾 Committing transaction (COMMIT)...")
        conn.commit()

        # Check after cleanup
        print("   🔍 Verifying cleanup result...")
        cur.execute('SELECT COUNT(*) FROM "LiteLLM_ProxyModelTable";')
        count_after = cur.fetchone()[0]

        cur.close()
        conn.close()
        print("   🔌 Connection closed.")

        if count_after == 0:
            print(f"✅ [1/3] Database successfully cleaned. Removed {count_before} records. Remaining: 0.")
        else:
            print(f"❌ [1/3] CRITICAL ERROR: After cleanup, {count_after} records remain in the table!")
            sys.exit(1)
    except Exception as e:
        print(f"❌ [1/3] CLEANUP ERROR: {e}")
        sys.exit(1)

def push_models_directly():
    """🚀 [2/3] Direct model write to DB with order guarantee"""
    print("\n🚀 [2/3] === STARTING MODEL WRITE ===")
    print("   📂 Reading config...")
    with open(CONFIG_FILE, "r") as f:
        cfg = yaml.safe_load(f)

    models = cfg.get("model_list", [])
    total = len(models)
    print(f"   📋 Models found in config: {total}")
    print(f"   👤 Record author (created_by): '{DB_USER_TAG}'")

    try:
        print("   🔌 Connecting to PostgreSQL...")
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        print("   ✅ Connection established.")

        for idx, m in enumerate(models, 1):
            name = m.get("model_name")
            params = m.get("litellm_params", {})
            info_from_yaml = m.get("model_info", {})

            disable_health = info_from_yaml.get("disable_background_health_check", False)
            if disable_health:
                params["disable_background_health_check"] = True

            port = extract_port(params.get("api_base", ""))
            custom_id = f"{idx:03d}-{name}-{port}"

            final_model_info = {
                "id": custom_id,
                "base_model": name,
                "db_order_index": idx,
                "disable_background_health_check": disable_health
            }
            final_model_info.update({k: v for k, v in info_from_yaml.items() if k not in final_model_info})

            # Log insertion
            print(f"   📝 [{idx:03d}/{total}] INSERT model_id='{custom_id}' ...")
            cur.execute('''
                INSERT INTO "LiteLLM_ProxyModelTable"
                (model_id, model_name, litellm_params, model_info, created_by, updated_by)
                VALUES (%s, %s, %s, %s, %s, %s)
            ''', (custom_id, name, Json(params), Json(final_model_info), DB_USER_TAG, DB_USER_TAG))

            # Commit after each model guarantees order
            conn.commit()
            print(f"   ✅ [{idx:03d}] Committed.")

        # Final verification
        print("   🔍 Checking final record count...")
        cur.execute('SELECT COUNT(*) FROM "LiteLLM_ProxyModelTable";')
        db_count = cur.fetchone()[0]

        cur.close()
        conn.close()
        print("   🔌 Connection closed.")

        if db_count == total:
            print(f"✅ [2/3] Success! Written {db_count} models strictly in config order.")
        else:
            print(f"❌ [2/3] MISMATCH: Config has {total}, but database has {db_count} records!")
            sys.exit(1)
    except Exception as e:
        print(f"❌ [2/3] WRITE ERROR: {e}")
        sys.exit(1)

def update_settings():
    """⚙️ [3/3] System settings synchronization via API"""
    print("\n⚙️ [3/3] === SYNCHRONIZING SETTINGS ===")
    with open(CONFIG_FILE, "r") as f:
        cfg = yaml.safe_load(f)

    l_settings = cfg.get("litellm_settings", {})
    if "cache_params" in l_settings:
        l_settings["cache_params"]["host"] = "127.0.0.1"
        print("   🔄 cache_params.host set to 127.0.0.1")

    config_payload = {
        "router_settings": cfg.get("router_settings", {}),
        "litellm_settings": l_settings,
        "general_settings": cfg.get("general_settings", {})
    }

    try:
        print("   📤 Sending POST /config/update...")
        r = requests.post(f"{BASE_URL}/config/update", json=config_payload, headers=HEADERS, timeout=10)

        if r.status_code == 200:
            print("✅ [3/3] Settings successfully applied.")
        else:
            print(f"❌ [3/3] API Error: status {r.status_code}")
            print(f"   Server response: {r.text}")
            sys.exit(1)
    except Exception as e:
        print(f"❌ [3/3] API ERROR: {e}")
        sys.exit(1)

if __name__ == "__main__":
    print("=" * 60)
    print("🦌 LITELLM DB CONFIG PUSHER")
    print("=" * 60)

    force_terminate_connections()
    time.sleep(0.5)
    hard_reset_db()
    time.sleep(0.5)
    push_models_directly()
    update_settings()

    print("\n" + "=" * 60)
    print("✨ DONE! All stages completed successfully.")
    print("   • Connections terminated.")
    print("   • Database cleared and verified.")
    print("   • Models written strictly in order.")
    print(f"   • created_by = '{DB_USER_TAG}'.")
    print("   • Settings synchronized.")
    print("=" * 60)
