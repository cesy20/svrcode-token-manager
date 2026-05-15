#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/svrcode-token-manager"
CONF_FILE="/etc/svrcode-token/config.env"
SERVICE="svrcode-token-api.service"
BIN_FILE="/usr/local/bin/svrtoken"
LEGACY_BIN_FILE="/usr/local/bin/svrcode-token"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta como root: sudo bash PATCH_MENU_GIT_V014.sh" >&2
  exit 1
fi

if [[ ! -d "$INSTALL_DIR" || ! -f "$CONF_FILE" ]]; then
  echo "No encontré instalación existente. Usa: sudo bash install.sh 5000" >&2
  exit 1
fi

echo "[1/5] Respaldo de archivos actuales..."
ts="$(date +%s)"
cp "$INSTALL_DIR/svrcode-token.sh" "$INSTALL_DIR/svrcode-token.sh.bak.$ts" 2>/dev/null || true
cp "$INSTALL_DIR/api_server.py" "$INSTALL_DIR/api_server.py.bak.$ts" 2>/dev/null || true

echo "[2/5] Copiando menú v0.14 y API update..."
cp ./svrcode-token.sh "$INSTALL_DIR/svrcode-token.sh"
cp ./api_server.py "$INSTALL_DIR/api_server.py"
chmod +x "$INSTALL_DIR/svrcode-token.sh" "$INSTALL_DIR/api_server.py"
ln -sf "$INSTALL_DIR/svrcode-token.sh" "$BIN_FILE"
ln -sf "$INSTALL_DIR/svrcode-token.sh" "$LEGACY_BIN_FILE"

echo "[3/5] Asegurando variables Git en config.env..."
add_if_missing() {
  local key="$1" value="$2"
  if ! grep -qE "^${key}=" "$CONF_FILE"; then
    echo "${key}=${value}" >> "$CONF_FILE"
  fi
}
add_if_missing UPDATE_ENABLED 1
add_if_missing GITHUB_TOKEN COLOCA_AQUI_TU_TOKEN_DE_GITHUB
add_if_missing GITHUB_REPO chifladito-store/SERVERMIX
add_if_missing GITHUB_BRANCH main
add_if_missing FREE_CONFIG_PATH FreeMode/Config.json
add_if_missing VIP_CONFIG_PATH VipMode/Config.mvgl.json
add_if_missing UPDATE_CACHE_DIR /var/lib/svrcode-token/update-cache
add_if_missing UPDATE_SYNC_INTERVAL 5
if ! grep -qE '^WEBHOOK_SECRET=' "$CONF_FILE"; then
  if command -v openssl >/dev/null 2>&1; then
    echo "WEBHOOK_SECRET=$(openssl rand -hex 32)" >> "$CONF_FILE"
  else
    echo "WEBHOOK_SECRET=$(date +%s%N | sha256sum | awk '{print $1}')" >> "$CONF_FILE"
  fi
fi
chmod 600 "$CONF_FILE" 2>/dev/null || true

echo "[4/5] Reiniciando API..."
systemctl daemon-reload || true
systemctl restart "$SERVICE"
sleep 1

echo "[5/5] Verificación rápida..."
systemctl is-active --quiet "$SERVICE" && echo "API activa ✅" || { echo "API no inició. Revisa: journalctl -u $SERVICE -n 80 --no-pager"; exit 1; }

echo ""
echo "Listo ✅"
echo "Abre el menú: sudo svrtoken menu"
echo "Submenú Git: sudo svrtoken git-menu"
