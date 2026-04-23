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

#
# LiteLLM Auto-Repair Script (ULTIMATE VERSION - FIXED)
# Назначение: Полностью автоматическое восстановление failed-миграций Prisma.
# Исправление: Убраны nameref для избежания circular reference errors.
# Поддержка: CREATE TABLE, ADD COLUMN, CREATE INDEX, FOREIGN KEY.
#
set -euo pipefail

# === КОНФИГУРАЦИЯ ===
SERVICE_NAME="ai-litellm"
DB_USER="litellm_user"
DB_PASS="litellm_pass"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="litellm_db"
MIGRATIONS_DIR="/root/ai/core/servers/litellm-venv/lib/python3.11/site-packages/litellm_proxy_extras/migrations"

export PGPASSWORD="$DB_PASS"

# Глобальный массив артефактов
declare -a ARTIFACTS=()

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

run_sql() {
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

check_table_exists() {
    local table="$1"
    local count
    count=$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table';")
    [[ "$count" -gt 0 ]]
}

check_column_exists() {
    local table="$1"
    local column="$2"
    local count
    count=$(run_sql "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = '$table' AND column_name = '$column';")
    [[ "$count" -gt 0 ]]
}

check_index_exists() {
    local index="$1"
    local count
    count=$(run_sql "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = '$index';")
    [[ "$count" -gt 0 ]]
}

check_constraint_exists() {
    local constraint="$1"
    local count
    count=$(run_sql "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema = 'public' AND constraint_name = '$constraint';")
    [[ "$count" -gt 0 ]]
}

mark_migration_applied() {
    local migration_name="$1"
    log_info "Pomechayu migraciyu kak primenyonnuyu: $migration_name"
    run_sql "UPDATE _prisma_migrations SET finished_at = NOW(), rolled_back_at = NULL, applied_steps_count = 1 WHERE migration_name = '$migration_name' AND finished_at IS NULL;"
}

parse_sql_file() {
    local sql_file="$1"
    while IFS= read -r line; do
        if [[ "$line" =~ CREATE[[:space:]]+TABLE[[:space:]]+[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']? ]]; then
            ARTIFACTS+=("table:${BASH_REMATCH[1]}")
        fi
        if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+[\"']?([A-Za-z_]+)[\"']?[[:space:]]+ADD[[:space:]]+(COLUMN[[:space:]]+)?[\"']?([A-Za-z_]+)[\"']? ]]; then
            ARTIFACTS+=("column:${BASH_REMATCH[1]}:${BASH_REMATCH[3]}")
        fi
        if [[ "$line" =~ CREATE[[:space:]]+(UNIQUE[[:space:]]+)?INDEX[[:space:]]+(CONCURRENTLY[[:space:]]+)?[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']? ]]; then
            ARTIFACTS+=("index:${BASH_REMATCH[3]}")
        fi
        if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+[\"']?([A-Za-z_]+)[\"']?[[:space:]]+ADD[[:space:]]+CONSTRAINT[[:space:]]+[\"']?([A-Za-z_]+)[\"']?[[:space:]]+FOREIGN[[:space:]]+KEY ]]; then
            ARTIFACTS+=("constraint:${BASH_REMATCH[2]}")
        fi
    done < "$sql_file"
}

parse_migration_name() {
    local name="$1"
    if [[ "$name" =~ add_([a-z_]+)_([a-z_]+)$ ]]; then
        local tbl_raw="${BASH_REMATCH[1]}"
        local col="${BASH_REMATCH[2]}"
        local tbl=$(echo "$tbl_raw" | awk -F'_' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' OFS='')
        ARTIFACTS+=("column:LiteLLM_${tbl}:${col}")
        return 0
    fi
    if [[ "$name" =~ add_([a-z_]+)_tables$ ]]; then
        local tbl_raw="${BASH_REMATCH[1]}"
        local tbl=$(echo "$tbl_raw" | awk -F'_' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' OFS='')
        ARTIFACTS+=("table:LiteLLM_${tbl}")
        return 0
    fi
    return 1
}

verify_artifacts() {
    local all_ok=true
    for art in "${ARTIFACTS[@]}"; do
        IFS=':' read -r type arg1 arg2 <<< "$art"
        case "$type" in
            table)
                if check_table_exists "$arg1"; then
                    log_info "Tablica $arg1 suschestvuet."
                else
                    log_error "Tablica $arg1 OTSUTSTVUET."
                    all_ok=false
                fi
                ;;
            column)
                if check_column_exists "$arg1" "$arg2"; then
                    log_info "Kolonna $arg1.$arg2 suschestvuet."
                else
                    log_error "Kolonna $arg1.$arg2 OTSUTSTVUET."
                    all_ok=false
                fi
                ;;
            index)
                if check_index_exists "$arg1"; then
                    log_info "Indeks $arg1 suschestvuet."
                else
                    log_error "Indeks $arg1 OTSUTSTVUET."
                    all_ok=false
                fi
                ;;
            constraint)
                if check_constraint_exists "$arg1"; then
                    log_info "Ogranichenie $arg1 suschestvuet."
                else
                    log_error "Ogranichenie $arg1 OTSUTSTVUET."
                    all_ok=false
                fi
                ;;
        esac
    done
    $all_ok
}

process_migration() {
    local migration_name="$1"
    local migration_dir="$MIGRATIONS_DIR/$migration_name"
    local sql_file="$migration_dir/migration.sql"
    log_info "Analiz migracii: $migration_name"
    ARTIFACTS=()
    if [[ -f "$sql_file" ]]; then
        log_info "Parsing SQL file..."
        parse_sql_file "$sql_file"
    else
        log_warn "SQL fail ne nayden, ispolzuyu evristiku."
        parse_migration_name "$migration_name" || true
    fi
    if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
        log_warn "Ne udalos opredelit artefakty. Propusk."
        return 1
    fi
    log_info "Naydeno artefaktov: ${#ARTIFACTS[@]}"
    if verify_artifacts; then
        mark_migration_applied "$migration_name"
        return 0
    else
        log_warn "Shema BD nepolnaya, migraciya ne pomechena."
        return 1
    fi
}

main() {
    echo "LITELLM AUTO-REPAIR (ULTIMATE)"
    if [[ ! -d "$MIGRATIONS_DIR" ]]; then
        log_warn "Papka migraciy ne naydena: $MIGRATIONS_DIR"
    fi
    log_info "Poisk failed-migraciy..."
    local migrations
    migrations=$(run_sql "SELECT DISTINCT migration_name FROM _prisma_migrations WHERE rolled_back_at IS NOT NULL OR finished_at IS NULL;")
    if [[ -z "$migrations" ]]; then
        log_info "Net failed-migraciy. Sostoyanie korrektno."
        exit 0
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Ostanovka $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
        sleep 2
    fi
    local resolved=0
    local skipped=0
    while IFS= read -r migration; do
        [[ -z "$migration" ]] && continue
        echo "-------------------------------------------"
        if process_migration "$migration"; then
            resolved=$((resolved + 1))
        else
            skipped=$((skipped + 1))
        fi
    done <<< "$migrations"
    echo "-------------------------------------------"
    log_info "Itog: $resolved ispravleno, $skipped propuscheno."
    log_info "Zapusk $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    echo "SKRIPT ZAVYORSHEN"
    unset PGPASSWORD
}

main "$@"
