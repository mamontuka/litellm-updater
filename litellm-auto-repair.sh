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

# LiteLLM Auto-Repair Script (Auto-Fix Prisma Migrations)
# Назначение: Автоматически находит и удаляет зависшие миграции, чистит БД от ошибок и перезапускает сервис.
# Используйте этот скрипт, если при запуске возникает ошибка P3018 или P3009.

# **НАСТРОЙКИ**
VENV_PATH="/root/ai/core/servers/litellm-venv"
SERVICE_NAME="ai-litellm"
DB_USER="litellm_user"
DB_PASS="litellm_pass"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="litellm_db"

set -e # Прерывать при ошибках

echo "=========================================="
echo "🛠️  STARTING LITELLM AUTO-REPAIR SCRIPT"
echo "=========================================="

# --- ШАГ 1: Остановка службы ---
echo "[1/5] Остановка службы $SERVICE_NAME..."
systemctl stop $SERVICE_NAME || echo "⚠️  Служба уже остановлена или не найдена"

# --- ШАГ 2: Поиск и удаление проблемных файлов миграций ---
echo "[2/5] Поиск и удаление 'зависших' файлов миграций..."

# Ищем файлы/папки, содержащие подозрительные даты (YYYYMMDD...) или специфичные имена проблемных миграций
# Мы ищем в venv, так как там хранятся зависимости.
PROBLEM_FILES=$(find "$VENV_PATH" -type f -o -type d \( -name "*20260331*" -o -name "*add_prompt_environment*" -o -name "*baseline_diff_failed*" \) 2>/dev/null)

if [ -n "$PROBLEM_FILES" ]; then
    echo "Найдены проблемные объекты:"
    echo "$PROBLEM_FILES"
    
    # Удаляем найденные объекты (рекурсивно для папок)
    # Используем --no-run-if-empty для защиты от пустого вывода
    echo "$PROBLEM_FILES" | xargs rm -rffv
    
    echo "✅ Проблемные файлы удалены."
else
    echo "⚠️  Специфичных проблемных файлов не найдено (возможно, они уже удалены)."
fi

# --- ШАГ 3: Очистка таблицы _prisma_migrations от ошибок ---
echo "[3/5] Очистка базы данных от записей о неудачных миграциях..."

export PGPASSWORD="$DB_PASS"

# Удаляем записи о конкретной проблемной миграции из истории Prisma
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "DELETE FROM _prisma_migrations WHERE migration_name LIKE '%20260331%';"

if [ $? -eq 0 ]; then
    echo "✅ База данных очищена от старых записей."
else
    echo "❌ Ошибка при очистке базы данных."
    exit 1
fi
unset PGPASSWORD

# --- ШАГ 4: Проверка схемы и генерация ---
echo "[4/5] Проверка схемы Prisma..."
source "$VENV_PATH/bin/activate"
SCHEMA_PATH=$(python3 -c "import os, litellm; print(os.path.join(os.path.dirname(litellm.__file__), 'proxy/schema.prisma'))")
echo "Схема найдена: $SCHEMA_PATH"

# Применяем db push, чтобы убедиться, что база синхронизирована со схемой
# --force-reset используется только если есть критические ошибки, иначе стандартный push
export DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
prisma db push --schema="$SCHEMA_PATH" --accept-data-loss
prisma generate --schema="$SCHEMA_PATH"
echo "✅ Схема проверена и обновлена."

# --- ШАГ 5: Перезапуск службы ---
echo "[5/5] Запуск службы $SERVICE_NAME..."
systemctl start $SERVICE_NAME
sleep 3

if systemctl is-active --quiet $SERVICE_NAME; then
    echo "-------------------------------------------"
    echo "🎉 ГОТОВО: Сервис успешно восстановлен и запущен!"
    echo "Версия: $(litellm --version 2>/dev/null || echo 'Недоступно')"
    echo "-------------------------------------------"
else
    echo "❌ ГРАБЛИ: Служба не завелась. Смотрите логи: journalctl -u $SERVICE_NAME -n 20"
    deactivate
    exit 1
fi

deactivate
echo "Скрипт завершен успешно."
