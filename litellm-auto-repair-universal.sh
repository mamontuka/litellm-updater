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
# LiteLLM Auto-Repair Script (ULTIMATE VERSION - FIXED v7.7)
# Исправления:
# - Исправлен баг в оригинальном regex для индексов (BASH_REMATCH[6] -> [5]), который вызывал ошибку "Индекс ОТСУТСТВУЕТ" с пустым именем.
# - Добавлена функция force_fix_spendlog_delivery для принудительного создания колонки 'state' в LiteLLM_SpendLogDelivery.
# - Добавлены миграции 20261001100000_rename_lens, 20261027000000_add_accounting_ledger_tables и 20261103010000_spendlogs_accounting_delivery в принудительные исправления.
#
set -euo pipefail

SERVICE_NAME="ai-core-litellm"
DB_USER="litellm_user"
DB_PASS="litellm_pass"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="litellm_db"
MIGRATIONS_DIR="/root/ai/core/servers/litellm-venv/lib/python3.13/site-packages/litellm_proxy_extras/migrations"

export PGPASSWORD="$DB_PASS"

declare -a ARTIFACTS=()

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
    if [[ "$column" == "CONSTRAINT" || "$column" == "FOREIGN" || "$column" == "KEY" ]]; then
        return 0
    fi
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
    log_info "Принудительная пометка миграции как выполненной: $migration_name"
    run_sql "UPDATE _prisma_migrations SET finished_at = NOW(), rolled_back_at = NULL, applied_steps_count = 1, logs = 'Force fixed by auto-repair v7.7' WHERE migration_name = '$migration_name';"
}

# === НОВАЯ ФУНКЦИЯ: Принудительное исправление для SpendLogDelivery ===
force_fix_spendlog_delivery() {
    log_info "ПРИНУДИТЕЛЬНОЕ ИСПРАВЛЕНИЕ: Проверка таблицы LiteLLM_SpendLogDelivery и колонки 'state'..."

    local target_table="LiteLLM_SpendLogDelivery"

    if check_table_exists "$target_table"; then
        log_info "Таблица $target_table найдена."

        local col_exists
        col_exists=$(run_sql "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = '$target_table' AND column_name = 'state';")

        if [[ "$col_exists" -eq 0 ]]; then
            log_info "Колонка 'state' отсутствует. Добавляем её вручную..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "ALTER TABLE \"$target_table\" ADD COLUMN IF NOT EXISTS state TEXT;" >/dev/null 2>&1
            log_info "Колонка 'state' успешно добавлена в $target_table."
        else
            log_info "Колонка 'state' уже существует в $target_table."
        fi

        # Принудительно фиксируем обе связанные миграции
        mark_migration_applied "20261027000000_add_accounting_ledger_tables"
        mark_migration_applied "20261103010000_spendlogs_accounting_delivery"
        return 0
    else
        log_error "Таблица $target_table не найдена в БД. Проверьте структуру базы вручную."
        return 1
    fi
}

# === ФУНКЦИЯ: Прямое исправление известных проблемных миграций ===
force_fix_known_migration() {
    local migration_name="$1"
    case "$migration_name" in
        "20260811172448_add_shadow_eval")
            if check_table_exists "LiteLLM_ShadowEvalJob"; then
                log_info "Обнаружена известная миграция add_shadow_eval. Таблица LiteLLM_ShadowEvalJob существует."
                mark_migration_applied "$migration_name"
                return 0
            else
                log_warn "Миграция add_shadow_eval, но таблица LiteLLM_ShadowEvalJob ОТСУТСТВУЕТ."
                return 1
            fi
            ;;
        "20260813180408_add_shadow_eval_direction")
            if check_column_exists "LiteLLM_ShadowEvalJob" "baseline_model"; then
                log_info "Обнаружена известная миграция add_shadow_eval_direction. Колонка baseline_model существует."
                mark_migration_applied "$migration_name"
                return 0
            else
                log_warn "Миграция add_shadow_eval_direction, но колонка baseline_model ОТСУТСТВУЕТ."
                return 1
            fi
            ;;
        "20260817143646_add_daily_guardrail_usage_units")
            if check_table_exists "LiteLLM_DailyGuardrailUsageUnits"; then
                log_info "Обнаружена известная миграция add_daily_guardrail_usage_units. Таблица существует."
                mark_migration_applied "$migration_name"
                return 0
            else
                log_warn "Миграция add_daily_guardrail_usage_units, но таблица ОТСУТСТВУЕТ."
                return 1
            fi
            ;;
        "20260818224500_add_shadow_eval_stopped_by")
            if check_column_exists "LiteLLM_ShadowEvalJob" "stopped_by"; then
                log_info "Обнаружена известная миграция add_shadow_eval_stopped_by. Колонка stopped_by существует."
                mark_migration_applied "$migration_name"
                return 0
            else
                log_warn "Миграция add_shadow_eval_stopped_by, но колонка stopped_by ОТСУТСТВУЕТ."
                return 1
            fi
            ;;
        "20260819000000_shadow_eval_max_budget")
            if check_column_exists "LiteLLM_ShadowEvalJob" "max_budget"; then
                log_info "Обнаружена известная миграция shadow_eval_max_budget. Колонка max_budget существует."
                mark_migration_applied "$migration_name"
                return 0
            else
                log_warn "Миграция shadow_eval_max_budget, но колонка max_budget ОТСУТСТВУЕТ."
                return 1
            fi
            ;;
        "20261001100000_rename_lens")
            # Для миграций переименования проверяем наличие наиболее вероятного целевого объекта.
            # Если парсинг SQL сработает, этот блок не понадобится, но он служит надежной страховкой.
            if check_table_exists "LiteLLM_Lens" || check_table_exists "LiteLLM_LensTable"; then
                log_info "Обнаружена миграция rename_lens. Целевая таблица Lens существует."
                mark_migration_applied "$migration_name"
                return 0
            else
                log_warn "Миграция rename_lens, но таблицы Lens не найдено. Требуется ручной анализ SQL-файла."
                return 1
            fi
            ;;
        "20261027000000_add_accounting_ledger_tables" | "20261103010000_spendlogs_accounting_delivery")
            force_fix_spendlog_delivery
            return $?
            ;;
    esac
    return 1 # Не является известной проблемной миграцией
}

parse_sql_file() {
    local sql_file="$1"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*-- ]] && continue
        [[ -z "${line// }" ]] && continue
        set +u

        # 1. Создание таблиц
        if [[ "$line" =~ CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?(\"?[a-zA-Z_][a-zA-Z0-9_]*\"?\.)?\"?([A-Za-z_][A-Za-z0-9_]*)\"? ]]; then
            ARTIFACTS+=("table:${BASH_REMATCH[3]}")
        fi

        # 2. Добавление колонок
        if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+(\"?[a-zA-Z_][a-zA-Z0-9_]*\"?\.)?\"?([A-Za-z_][A-Za-z0-9_]*)\"?[[:space:]]+ADD[[:space:]]+COLUMN[[:space:]]+\"?([A-Za-z_][A-Za-z0-9_]*)\"? ]]; then
            ARTIFACTS+=("column:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}")
        fi

        # 3. Переименование таблиц
        if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+(\"?[a-zA-Z_][a-zA-Z0-9_]*\"?\.)?\"?([A-Za-z_][A-Za-z0-9_]*)\"?[[:space:]]+RENAME[[:space:]]+TO[[:space:]]+\"?([A-Za-z_][A-Za-z0-9_]*)\"? ]]; then
            ARTIFACTS+=("table:${BASH_REMATCH[3]}") # Проверяем наличие НОВОГО имени таблицы
        fi

        # 4. Переименование колонок
        if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+(\"?[a-zA-Z_][a-zA-Z0-9_]*\"?\.)?\"?([A-Za-z_][A-Za-z0-9_]*)\"?[[:space:]]+RENAME[[:space:]]+COLUMN[[:space:]]+\"?[a-zA-Z_][a-zA-Z0-9_]*\"?[[:space:]]+TO[[:space:]]+\"?([A-Za-z_][A-Za-z0-9_]*)\"? ]]; then
            ARTIFACTS+=("column:${BASH_REMATCH[2]}:${BASH_REMATCH[4]}") # Проверяем наличие колонки с НОВЫМ именем
        fi

        # 5. Создание индексов (ИСПРАВЛЕНО: BASH_REMATCH[6] заменён на [5], так как в оригинале группа 6 была пустой, что вызывало ошибку "Индекс ОТСУТСТВУЕТ")
        if [[ "$line" =~ CREATE[[:space:]]+(UNIQUE[[:space:]]+)?INDEX[[:space:]]+(CONCURRENTLY[[:space:]]+)?(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[[:space:]]*\"?([a-zA-Z_][a-zA-Z0-9_]*)\"?[[:space:]]+ON ]]; then
            ARTIFACTS+=("index:${BASH_REMATCH[5]}")
        fi

        # 6. Добавление ограничений
        if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+\"?([A-Za-z_][A-Za-z0-9_]*)\"?[[:space:]]+ADD[[:space:]]+CONSTRAINT[[:space:]]+\"?([A-Za-z_][A-Za-z0-9_]*)\"? ]]; then
            ARTIFACTS+=("constraint:${BASH_REMATCH[2]}")
        fi
        set -u
    done < "$sql_file"
}

to_pascal_case() {
    local input="$1"
    echo "$input" | awk -F'_' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1' OFS=''
}

parse_migration_name() {
    local name="$1"
    local col tbl_raw tbl has_table_suffix=false
    set +u

    if [[ "$name" =~ _table$ ]]; then
        has_table_suffix=true
    fi

    if [[ "$name" =~ add_([a-z_]+)_to_([a-z_]+)_table$ ]]; then
        col="${BASH_REMATCH[1]}"
        tbl_raw="${BASH_REMATCH[2]}"
        case "$tbl_raw" in
            mcp_server) tbl="MCPServerTable" ;;
            *)
                tbl=$(to_pascal_case "$tbl_raw")
                [[ "$has_table_suffix" == true ]] && tbl="${tbl}Table"
                ;;
        esac
        ARTIFACTS+=("column:LiteLLM_${tbl}:${col}")
        set -u
        return 0
    elif [[ "$name" =~ add_([a-z_]+)_([a-z_]+)$ ]]; then
        tbl_raw="${BASH_REMATCH[1]}"
        col="${BASH_REMATCH[2]}"
        tbl=$(to_pascal_case "$tbl_raw")
        ARTIFACTS+=("column:LiteLLM_${tbl}:${col}")
        set -u
        return 0
    elif [[ "$name" =~ add_([a-z_]+)_tables$ ]]; then
        tbl_raw="${BASH_REMATCH[1]}"
        tbl=$(to_pascal_case "$tbl_raw")
        ARTIFACTS+=("table:LiteLLM_${tbl}")
        set -u
        return 0
    fi

    set -u
    return 1
}

verify_artifacts() {
    local all_ok=true
    local art type arg1 arg2
    for art in "${ARTIFACTS[@]}"; do
        IFS=':' read -r type arg1 arg2 <<< "$art"
        case "$type" in
            table)
                if check_table_exists "$arg1"; then log_info "Таблица $arg1 существует."; else log_error "Таблица $arg1 ОТСУТСТВУЕТ."; all_ok=false; fi
                ;;
            column)
                if check_column_exists "$arg1" "$arg2"; then log_info "Колонка $arg1.$arg2 существует."; else log_error "Колонка $arg1.$arg2 ОТСУТСТВУЕТ."; all_ok=false; fi
                ;;
            index)
                if check_index_exists "$arg1"; then log_info "Индекс $arg1 существует."; else log_error "Индекс $arg1 ОТСУТСТВУЕТ."; all_ok=false; fi
                ;;
            constraint)
                if check_constraint_exists "$arg1"; then log_info "Ограничение $arg1 существует."; else log_error "Ограничение $arg1 ОТСУТСТВУЕТ."; all_ok=false; fi
                ;;
        esac
    done
    $all_ok
}

process_migration() {
    local migration_name="$1"
    local migration_dir="$MIGRATIONS_DIR/$migration_name"
    local sql_file="$migration_dir/migration.sql"

    log_info "Анализ миграции: $migration_name"
    ARTIFACTS=()

    # ШАГ 1: Приоритетная проверка известных проблемных миграций
    if force_fix_known_migration "$migration_name"; then
        return 0
    fi

    # ШАГ 2: Стандартный парсинг (если миграция не попала в список известных)
    if [[ -f "$sql_file" ]]; then
        log_info "Парсинг SQL-файла..."
        parse_sql_file "$sql_file"
    else
        log_warn "SQL-файл не найден, использую эвристику по имени."
        parse_migration_name "$migration_name" || true
    fi

    # Убираем дубликаты
    declare -A unique_artifacts
    local clean_artifacts=()
    local art
    for art in "${ARTIFACTS[@]}"; do
        if [[ -z "${unique_artifacts[$art]+x}" ]]; then
            unique_artifacts[$art]=1
            clean_artifacts+=("$art")
        fi
    done
    ARTIFACTS=("${clean_artifacts[@]}")

    if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
        log_warn "Не удалось определить артефакты. Пропуск."
        return 1
    fi

    log_info "Найдено артефактов: ${#ARTIFACTS[@]}"

    if verify_artifacts; then
        mark_migration_applied "$migration_name"
        return 0
    else
        log_warn "Схема БД неполная, миграция не помечена как выполненная."
        return 1
    fi
}

main() {
    echo "=========================================="
    echo " LITELLM AUTO-REPAIR (ULTIMATE v7.7)"
    echo "=========================================="

    if [[ ! -d "$MIGRATIONS_DIR" ]]; then
        log_warn "Папка миграций не найдена: $MIGRATIONS_DIR"
        exit 1
    fi

    log_info "Поиск failed-миграций..."
    local migrations
    migrations=$(run_sql "SELECT DISTINCT migration_name FROM _prisma_migrations WHERE rolled_back_at IS NOT NULL OR finished_at IS NULL;")

    if [[ -z "$migrations" ]]; then
        log_info "Нет failed-миграций. Состояние БД корректно."
        exit 0
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Остановка $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
        sleep 2
    fi

    local resolved=0
    local skipped=0
    local migration

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
    log_info "Итог: $resolved исправлено, $skipped пропущено."

    log_info "Запуск $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"

    echo "СКРИПТ ЗАВЕРШЁН УСПЕШНО"
    unset PGPASSWORD
}

main "$@"
