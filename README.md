# LiteLLM Auto-Updater (Systemd + Venv)

Updating **LiteLLM Proxy** can be a headache due to frequent breaking changes in the database schema and Prisma client requirements. This script automates the entire process: stopping the service, upgrading packages, applying database migrations, and restarting the proxy.

## 🚀 What this script does
1. **Safely stops** your `systemd` LiteLLM service.
2. **Upgrades** `litellm` and `prisma` to the latest versions within your virtual environment.
3. **Locates the hidden Prisma schema** automatically (no more searching through `site-packages`).
4. **Applies migrations** via `prisma db push` (updates tables without wiping your data).
5. **Generates the Prisma Client** to match the new code version.
6. **Restarts the service** and performs a health check.

## 🛠 Setup

1. **Clone or copy** the script to your server:
   ```bash
   nano litellm-updater.sh
   chmod +x litellm-updater.sh

Edit the configuration inside the script:
VENV_PATH: Path to your python virtual environment.
SERVICE_NAME: The name of your systemd service (e.g., ai-litellm).
DATABASE_URL: Your database connection string.
Run it:
bash
sudo ./litellm_updater.sh

⚠️ Requirements
Linux server (Debian/Ubuntu recommended).
LiteLLM installed in a venv.
PostgreSQL or SQLite database.
systemd service managing the proxy.


**Why use this instead of just pip install --upgrade?
LiteLLM relies on a generated Prisma client. If you update the package but don't run prisma generate against the internal schema file, the proxy will likely crash with "Table not found" or "Field missing" errors. This script handles the dirty work for you.**
