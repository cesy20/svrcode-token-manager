#!/usr/bin/env bash
# Desinstalador SVRCODE Token Manager v0.8 - comando svrtoken
# Uso:
#   sudo bash uninstall.sh          -> elimina servicio/binarios, conserva tokens y APP_KEY
#   sudo bash uninstall.sh --purge  -> elimina servicio/binarios/configuracion/tokens/online/log

set -euo pipefail

APP_NAME="svrcode-token-manager"
INSTALL_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/svrcode-token"
DATA_DIR="/var/lib/svrcode-token"
LOG_FILE="/var/log/svrcode-token-api.log"
SERVICE_FILE="/etc/systemd/system/svrcode-token-api.service"
BIN_FILE="/usr/local/bin/svrtoken"
LEGACY_BIN_FILE="/usr/local/bin/svrcode-token"
PURGE="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta como root: sudo bash uninstall.sh" >&2
  exit 1
fi

echo "Deteniendo servicio SVRCODE Token API..."
systemctl stop svrcode-token-api.service 2>/dev/null || true
systemctl disable svrcode-token-api.service 2>/dev/null || true

rm -f "$SERVICE_FILE"
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed svrcode-token-api.service 2>/dev/null || true

rm -f "$BIN_FILE" "$LEGACY_BIN_FILE"
rm -rf "$INSTALL_DIR"

echo "Binarios y servicio eliminados."

if [[ "$PURGE" == "--purge" ]]; then
  rm -rf "$CONF_DIR" "$DATA_DIR"
  rm -f "$LOG_FILE"
  echo "PURGE completado: tambien se eliminaron configuracion, tokens, online y log."
else
  echo "No se eliminaron datos ni configuracion:"
  echo "  $CONF_DIR"
  echo "  $DATA_DIR"
  echo "  $LOG_FILE"
  echo "Para borrar todo ejecuta: sudo bash uninstall.sh --purge"
fi
