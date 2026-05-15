#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="/opt/svrcode-token-manager"
SERVICE="svrcode-token-api.service"
CONF_FILE="/etc/svrcode-token/config.env"
if [[ "${EUID}" -ne 0 ]]; then echo "Ejecuta como root" >&2; exit 1; fi
if [[ ! -d "$INSTALL_DIR" ]]; then echo "No encontré $INSTALL_DIR" >&2; exit 1; fi
cp "$INSTALL_DIR/api_server.py" "$INSTALL_DIR/api_server.py.bak.$(date +%s)" 2>/dev/null || true
cp ./api_server.py "$INSTALL_DIR/api_server.py"
chmod +x "$INSTALL_DIR/api_server.py" 2>/dev/null || true
# asegurar intervalo rápido
if [[ -f "$CONF_FILE" ]]; then
  if grep -qE '^UPDATE_SYNC_INTERVAL=' "$CONF_FILE"; then
    sed -i 's/^UPDATE_SYNC_INTERVAL=.*/UPDATE_SYNC_INTERVAL=3/' "$CONF_FILE"
  else
    echo 'UPDATE_SYNC_INTERVAL=3' >> "$CONF_FILE"
  fi
fi
systemctl daemon-reload || true
systemctl restart "$SERVICE"
sleep 1
echo "Patch v0.15 aplicado. Prueba:"
echo "curl http://127.0.0.1:5000/api/update/free"
echo "curl http://127.0.0.1:5000/config/free.json"
