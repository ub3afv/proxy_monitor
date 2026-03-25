#!/bin/bash
# ============================================================================
# Multi-Protocol Proxy Monitor — ПОЛНОЕ УДАЛЕНИЕ
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/opt/proxy_monitor"
DATA_DIR="/var/www/proxy_monitor"
SERVICE_NAME="proxy-monitor"
API_SERVICE="proxy-admin-api"

echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   ⚠️  Удаление Multi-Protocol Proxy Monitor              ║"
echo "║   Все данные будут безвозвратно удалены!                 ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Вы уверены? Введите YES для подтверждения: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo -e "${YELLOW}Отменено${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}═══ Удаление ═══${NC}"

# Остановка сервисов
echo -n "🛑 Остановка сервисов... "
systemctl stop "${SERVICE_NAME}.timer" "${SERVICE_NAME}.service" "${API_SERVICE}.service" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.timer" "${SERVICE_NAME}.service" "${API_SERVICE}.service" 2>/dev/null || true
echo "✅"

# Удаление systemd файлов
echo -n "🗑️  systemd... "
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"
rm -f "/etc/systemd/system/${API_SERVICE}.service"
systemctl daemon-reload
echo "✅"

# Удаление nginx конфигурации
echo -n "🗑️  nginx... "
rm -f /etc/nginx/sites-available/proxy-monitor
rm -f /etc/nginx/sites-enabled/proxy-monitor
nginx -t && systemctl reload nginx 2>/dev/null || true
echo "✅"

# Удаление файлов данных
echo -n "🗑️  Данные ($DATA_DIR)... "
rm -rf "$DATA_DIR"
echo "✅"

# Удаление установки
echo -n "🗑️  Установка ($INSTALL_DIR)... "
rm -rf "$INSTALL_DIR"
echo "✅"

# Очистка логов
echo -n "🗑️  Логи nginx... "
rm -f /var/log/nginx/proxy-monitor-*.log
echo "✅"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ Удаление завершено!                                  ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}📝 Примечание:${NC}"
echo -e "  • Python пакеты в venv удалены вместе с $INSTALL_DIR"
echo -e "  • Для полной очистки системных пакетов выполните:"
echo -e "    ${YELLOW}sudo apt autoremove -y${NC}"
echo ""
