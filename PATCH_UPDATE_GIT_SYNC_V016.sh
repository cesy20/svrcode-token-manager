#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="/opt/svrcode-token-manager"
CONF_FILE="/etc/svrcode-token/config.env"
SERVICE="svrcode-token-api.service"
if [[ "${EUID}" -ne 0 ]]; then echo "Ejecuta como root" >&2; exit 1; fi
apt update -y >/dev/null 2>&1 || true
apt install -y git python3 curl openssl >/dev/null 2>&1 || true
if [[ ! -d "$INSTALL_DIR" || ! -f "$CONF_FILE" ]]; then echo "No encontré instalación existente" >&2; exit 1; fi
cp "$INSTALL_DIR/api_server.py" "$INSTALL_DIR/api_server.py.bak.$(date +%s)" 2>/dev/null || true
cp ./api_server.py "$INSTALL_DIR/api_server.py"
chmod +x "$INSTALL_DIR/api_server.py"
add_env(){ local k="$1" v="$2"; grep -qE "^${k}=" "$CONF_FILE" || echo "${k}=${v}" >> "$CONF_FILE"; }
add_env UPDATE_ENABLED 1
add_env GIT_SYNC_ENABLED 1
add_env GIT_CACHE_DIR /var/lib/svrcode-token/git-cache
add_env GITHUB_REPO chifladito-store/SERVERMIX
add_env GITHUB_BRANCH main
add_env FREE_CONFIG_PATH FreeMode/Config.json
add_env VIP_CONFIG_PATH VipMode/Config.mvgl.json
add_env UPDATE_CACHE_DIR /var/lib/svrcode-token/update-cache
add_env UPDATE_SYNC_INTERVAL 5
mkdir -p /var/lib/svrcode-token/git-cache /var/lib/svrcode-token/update-cache
chmod 700 /var/lib/svrcode-token/git-cache /var/lib/svrcode-token/update-cache || true
systemctl daemon-reload || true
systemctl restart "$SERVICE"
sleep 1
PORT=$(grep -E '^API_PORT=' "$CONF_FILE" | head -n1 | cut -d= -f2-)
APP_KEY=$(grep -E '^APP_KEY=' "$CONF_FILE" | head -n1 | cut -d= -f2-)
echo "✅ PATCH v0.16 aplicado con git sync"
echo "Prueba: curl http://127.0.0.1:${PORT}/api/update/vip?force=1"
echo "Prueba: curl http://127.0.0.1:${PORT}/config/vip.json?force=1 | head"
echo "Online: curl -H \"X-App-Key: ${APP_KEY}\" http://127.0.0.1:${PORT}/online"
