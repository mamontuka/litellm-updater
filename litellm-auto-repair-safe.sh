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
# LiteLLM Auto-Repair Script (SQL Direct Version)
# Назначение: Восстановление миграций Prisma через прямое редактирование БД.
# Используется, когда файлы миграций удалены или повреждены (ошибка P3017).
# Помечает failed-миграции как успешные, если схема базы данных актуальна.
#
# Использование: ./litellm-auto-repair-sql.sh
#

set -euo pipefail

# === КОНФИГУРАЦИЯ ===
SERVICE_NAME="ai-litellm"
DB_USER="litellm_user"
DB_PASS="litellm_pass"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="litellm_db"

export PGPASSWORD="$DB_PASS"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# === ФУНКЦИИ ===

run_sql() {
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

stop_service() {
    log_info "Остановка службы $SERVICE_NAME..."
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        sleep 2
        log_info "Служба остановлена."
    else
        log_warn "Служба уже остановлена."
    fi
}

start_service() {
    log_info "Запуск службы $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Служба успешно запущена."
    else
        log_error "Служба не запустилась. Проверьте логи: journalctl -u $SERVICE_NAME -n 30"
        exit 1
    fi
}

mark_migration_applied() {
    local migration_name="$1"
    log_info "Помечаю миграцию как применённую: $migration_name"
    
    run_sql "UPDATE _prisma_migrations 
             SET finished_at = NOW(), rolled_back_at = NULL, applied_steps_count = 1 
             WHERE migration_name = '$migration_name' AND finished_at IS NULL;"
    
    log_info "Миграция $migration_name обновлена."
}

check_column_exists() {
    local table="$1"
    local column="$2"
    local count
    count=$(run_sql "SELECT COUNT(*) FROM information_schema.columns 
                     WHERE table_name = '$table' AND column_name = '$column';")
    [[ "$count" -gt 0 ]]
}

# === ОСНОВНОЙ СЦЕНАРИЙ ===

main() {
    echo "=========================================="
    echo "🛠️  LITELLM AUTO-REPAIR SQL SCRIPT"
    echo "=========================================="
    
    # Получаем уникальные failed-миграции
    log_info "Поиск failed-миграций..."
    local migrations
    migrations=$(run_sql "SELECT DISTINCT migration_name FROM _prisma_migrations 
                          WHERE rolled_back_at IS NOT NULL OR finished_at IS NULL;")
    
    if [[ -z "$migrations" ]]; then
        log_info "В базе нет failed-миграций. Состояние корректно."
        exit 0
    fi
    
    stop_service
    
    local resolved=0
    local skipped=0
    
    while IFS= read -r migration; do
        [[ -z "$migration" ]] && continue
        
        case "$migration" in
            *add_prompt_environment_and_created_by)
                if check_column_exists "LiteLLM_PromptTable" "environment"; then
                    mark_migration_applied "$migration"
                    resolved=$((resolved + 1))
                else
                    log_warn "Столбец environment отсутствует. Миграция $migration пропущена."
                    skipped=$((skipped + 1))
                fi
                ;;
            *baseline_diff)
                # Baseline миграции обычно безопасны для отметки
                mark_migration_applied "$migration"
                resolved=$((resolved + 1))
                ;;
            *)
                log_warn "Неизвестная миграция $migration. Требуется ручной анализ."
                skipped=$((skipped + 1))
                ;;
        esac
    done <<< "$migrations"
    
    log_info "Результат: $resolved миграций исправлено, $skipped пропущено."
    
    start_service
    
    echo "-------------------------------------------"
    echo "🎉 СКРИПТ ЗАВЕРШЁН"
    echo "-------------------------------------------"
    
    unset PGPASSWORD
}

main "$@"
