#!/usr/bin/env bash
# Instalador SVRCODE Token Manager v0.14 - comando svrtoken
# Puerto por defecto: 5000. Si otro servicio ocupa el puerto, no lo reemplaza.

set -euo pipefail

APP_NAME="svrcode-token-manager"
INSTALL_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/svrcode-token"
DATA_DIR="/var/lib/svrcode-token"
LOG_FILE="/var/log/svrcode-token-api.log"
CONF_FILE="${CONF_DIR}/config.env"
SERVICE_FILE="/etc/systemd/system/svrcode-token-api.service"
BIN_FILE="/usr/local/bin/svrtoken"
LEGACY_BIN_FILE="/usr/local/bin/svrcode-token"
DEFAULT_PORT="5000"
API_HOST="0.0.0.0"
VERSION="0.16"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta como root: sudo bash install.sh" >&2
  exit 1
fi

PORT="${1:-$DEFAULT_PORT}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Puerto invalido: $PORT" >&2
  exit 1
fi

check_port_free() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then
      return 1
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -ltnup 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
      return 1
    fi
  else
    echo "Aviso: no encontre ss/netstat para verificar el puerto. Instala iproute2." >&2
  fi
  return 0
}

show_port_owner() {
  local port="$1"
  echo "Detalle del puerto ocupado:" >&2
  if command -v ss >/dev/null 2>&1; then
    ss -ltnup 2>/dev/null | grep -E "(^|:)${port}\b" || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnup 2>/dev/null | grep -E "(^|:)${port}\b" || true
  fi
}

install_deps() {
  echo "[1/7] Verificando dependencias..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null || true
    apt-get install -y python3 curl ca-certificates iproute2 openssl >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 curl ca-certificates iproute openssl >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 curl ca-certificates iproute openssl >/dev/null
  else
    echo "No reconozco el gestor de paquetes. Instala manualmente: python3 curl iproute2 openssl" >&2
  fi
}

generate_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 64
    echo
  fi
}

public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 4 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -z "$ip" ]] && ip="IP_DE_TU_VPS"
  echo "$ip"
}

stop_old_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^svrcode-token-api.service'; then
    systemctl stop svrcode-token-api.service 2>/dev/null || true
  fi
}

main() {
  echo "=========================================="
  echo " Instalador SVRCODE Token Manager v${VERSION}"
  echo " Puerto API solicitado: ${PORT}"
  echo "=========================================="

  # En reinstalacion primero detenemos nuestro servicio para que no bloquee su propio puerto.
  stop_old_service

  if ! check_port_free "$PORT"; then
    echo "ERROR: El puerto ${PORT} ya esta ocupado por otro servicio. No se reemplazara." >&2
    show_port_owner "$PORT"
    echo "Solucion: libera el puerto o instala con otro puerto, ejemplo:" >&2
    echo "  sudo bash install.sh 5050" >&2
    exit 1
  fi

  install_deps

  echo "[2/7] Creando directorios..."
  mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$DATA_DIR"
  chmod 700 "$CONF_DIR" "$DATA_DIR"

  echo "[3/7] Copiando archivos..."
  cp ./svrcode-token.sh "$INSTALL_DIR/svrcode-token.sh"
  cp ./api_server.py "$INSTALL_DIR/api_server.py"
  cp ./uninstall.sh "$INSTALL_DIR/uninstall.sh"
  chmod +x "$INSTALL_DIR/svrcode-token.sh" "$INSTALL_DIR/api_server.py" "$INSTALL_DIR/uninstall.sh"
  ln -sf "$INSTALL_DIR/svrcode-token.sh" "$BIN_FILE"
  # Alias opcional para compatibilidad con versiones anteriores.
  ln -sf "$INSTALL_DIR/svrcode-token.sh" "$LEGACY_BIN_FILE"

  echo "[4/7] Preparando configuracion..."
  if [[ -f "$CONF_FILE" ]]; then
    EXISTING_KEY="$(grep -E '^APP_KEY=' "$CONF_FILE" | head -n1 | cut -d= -f2- || true)"
    EXISTING_DB="$(grep -E '^TOKEN_DB=' "$CONF_FILE" | head -n1 | cut -d= -f2- || true)"
    EXISTING_ONLINE_DB="$(grep -E '^ONLINE_DB=' "$CONF_FILE" | head -n1 | cut -d= -f2- || true)"
    EXISTING_ONLINE_TTL="$(grep -E '^ONLINE_TTL=' "$CONF_FILE" | head -n1 | cut -d= -f2- || true)"
    APP_KEY="${EXISTING_KEY:-$(generate_key)}"
    TOKEN_DB_PATH="${EXISTING_DB:-${DATA_DIR}/tokens.db}"
    ONLINE_DB_PATH="${EXISTING_ONLINE_DB:-${DATA_DIR}/online.db}"
    ONLINE_TTL_VALUE="${EXISTING_ONLINE_TTL:-300}"
  else
    APP_KEY="$(generate_key)"
    TOKEN_DB_PATH="${DATA_DIR}/tokens.db"
    ONLINE_DB_PATH="${DATA_DIR}/online.db"
    ONLINE_TTL_VALUE="300"
  fi

  EXISTING_UPDATE_ENABLED="$(grep -E '^UPDATE_ENABLED=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_GITHUB_TOKEN="$(grep -E '^GITHUB_TOKEN=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_GITHUB_REPO="$(grep -E '^GITHUB_REPO=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_GITHUB_BRANCH="$(grep -E '^GITHUB_BRANCH=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_FREE_CONFIG_PATH="$(grep -E '^FREE_CONFIG_PATH=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_VIP_CONFIG_PATH="$(grep -E '^VIP_CONFIG_PATH=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_UPDATE_CACHE_DIR="$(grep -E '^UPDATE_CACHE_DIR=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_UPDATE_SYNC_INTERVAL="$(grep -E '^UPDATE_SYNC_INTERVAL=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  EXISTING_WEBHOOK_SECRET="$(grep -E '^WEBHOOK_SECRET=' "$CONF_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"

  UPDATE_ENABLED_VALUE="${EXISTING_UPDATE_ENABLED:-1}"
  GITHUB_TOKEN_VALUE="${EXISTING_GITHUB_TOKEN:-COLOCA_AQUI_TU_TOKEN_DE_GITHUB}"
  GITHUB_REPO_VALUE="${EXISTING_GITHUB_REPO:-chifladito-store/SERVERMIX}"
  GITHUB_BRANCH_VALUE="${EXISTING_GITHUB_BRANCH:-main}"
  FREE_CONFIG_PATH_VALUE="${EXISTING_FREE_CONFIG_PATH:-FreeMode/Config.json}"
  VIP_CONFIG_PATH_VALUE="${EXISTING_VIP_CONFIG_PATH:-VipMode/Config.mvgl.json}"
  UPDATE_CACHE_DIR_VALUE="${EXISTING_UPDATE_CACHE_DIR:-${DATA_DIR}/update-cache}"
  UPDATE_SYNC_INTERVAL_VALUE="${EXISTING_UPDATE_SYNC_INTERVAL:-5}"
  WEBHOOK_SECRET_VALUE="${EXISTING_WEBHOOK_SECRET:-$(generate_key)}"

  cat > "$CONF_FILE" <<CONF
API_HOST=${API_HOST}
API_PORT=${PORT}
APP_KEY=${APP_KEY}
TOKEN_DB=${TOKEN_DB_PATH}
ONLINE_DB=${ONLINE_DB_PATH}
ONLINE_TTL=${ONLINE_TTL_VALUE}
UPDATE_ENABLED=${UPDATE_ENABLED_VALUE}
GIT_SYNC_ENABLED=1
GIT_CACHE_DIR=${DATA_DIR}/git-cache
GITHUB_TOKEN=${GITHUB_TOKEN_VALUE}
GITHUB_REPO=${GITHUB_REPO_VALUE}
GITHUB_BRANCH=${GITHUB_BRANCH_VALUE}
FREE_CONFIG_PATH=${FREE_CONFIG_PATH_VALUE}
VIP_CONFIG_PATH=${VIP_CONFIG_PATH_VALUE}
UPDATE_CACHE_DIR=${UPDATE_CACHE_DIR_VALUE}
UPDATE_SYNC_INTERVAL=${UPDATE_SYNC_INTERVAL_VALUE}
WEBHOOK_SECRET=${WEBHOOK_SECRET_VALUE}
CONF
  chmod 600 "$CONF_FILE"
  touch "$TOKEN_DB_PATH" "$ONLINE_DB_PATH" "$LOG_FILE"
  chmod 600 "$TOKEN_DB_PATH" "$ONLINE_DB_PATH" 2>/dev/null || true

  echo "[5/7] Creando servicio systemd..."
  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=SVRCODE Token API
After=network.target

[Service]
Type=simple
EnvironmentFile=${CONF_FILE}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/api_server.py
Restart=always
RestartSec=3
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
SERVICE

  echo "[6/7] Activando API..."
  systemctl daemon-reload
  systemctl enable svrcode-token-api.service >/dev/null
  systemctl restart svrcode-token-api.service

  sleep 1
  if ! systemctl is-active --quiet svrcode-token-api.service; then
    echo "ERROR: La API no inicio correctamente." >&2
    echo "Verifica con:" >&2
    echo "  journalctl -u svrcode-token-api.service -n 80 --no-pager" >&2
    exit 1
  fi

  echo "[7/7] Prueba local..."
  curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null || {
    echo "ERROR: La API inicio, pero no responde en /health." >&2
    exit 1
  }

  VPS_IP="$(public_ip)"
  echo
  echo "=========================================="
  echo " INSTALACION COMPLETADA"
  echo "=========================================="
  echo "Version    : ${VERSION}"
  echo "Puerto API : ${PORT}/tcp"
  echo "IP VPS     : ${VPS_IP}"
  echo "URL App    : http://${VPS_IP}:${PORT}/validate"
  echo "Check user : http://${VPS_IP}:${PORT}/check-user"
  echo "Heartbeat  : http://${VPS_IP}:${PORT}/heartbeat"
  echo "Online list: http://${VPS_IP}:${PORT}/online"
  echo "APP_KEY    : ${APP_KEY}"
  echo "------------------------------------------"
  echo "Abrir menu bonito:"
  echo "  sudo svrtoken"
  echo "  sudo svrtoken menu"
  echo
  echo "Crear usuario/token rapido:"
  echo "  sudo svrtoken add cliente1 all 30 1"
  echo "  sudo svrtoken add cliente2 xray 30 1"
  echo "  sudo svrtoken add cliente3 slowdns 7 1"
  echo
  echo "Ver JSON completo para la app:"
  echo "  sudo svrtoken api-config json"
  echo
  echo "Check user online:"
  echo "  sudo svrtoken online"
  echo "  sudo svrtoken check-user TOKEN_ID"
  echo
  echo "Desinstalar sin menu:"
  echo "  sudo bash ${INSTALL_DIR}/uninstall.sh"
  echo "  sudo bash ${INSTALL_DIR}/uninstall.sh --purge   # borra tambien datos"
  echo "=========================================="
}

main "$@"
