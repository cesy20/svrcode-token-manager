#!/usr/bin/env bash
# SVRCODE Token Manager v0.10 - comando principal svrtoken
# CLI + menu visual para clientes/tokens y validacion por API.

set -euo pipefail

CONF_FILE="/etc/svrcode-token/config.env"
DEFAULT_DB_FILE="/var/lib/svrcode-token/tokens.db"
LOG_FILE="/var/log/svrcode-token-api.log"
SERVICE_NAME="svrcode-token-api.service"
VERSION="0.14"

# Protocolos aceptados por el panel. La API tambien reconoce alias.
PROTO_LIST=(all ssh ssh-ws ssl dropbear slowdns openvpn udp udp-custom hysteria hysteria2 v2ray xray singbox vless vmess trojan reality shadowsocks tuic)

load_config() {
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  fi
  API_PORT="${API_PORT:-5000}"
  API_HOST="${API_HOST:-0.0.0.0}"
  APP_KEY="${APP_KEY:-}"
  DB_FILE="${TOKEN_DB:-$DEFAULT_DB_FILE}"
  ONLINE_DB="${ONLINE_DB:-/var/lib/svrcode-token/online.db}"
  ONLINE_TTL="${ONLINE_TTL:-300}"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ejecuta como root: sudo svrtoken $*" >&2
    exit 1
  fi
}

ensure_db() {
  load_config
  mkdir -p "$(dirname "$DB_FILE")"
  touch "$DB_FILE"
  chmod 600 "$DB_FILE" 2>/dev/null || true
}

ensure_online_db() {
  load_config
  mkdir -p "$(dirname "$ONLINE_DB")"
  touch "$ONLINE_DB"
  chmod 600 "$ONLINE_DB" 2>/dev/null || true
}

mask_token() {
  local token="${1:-}"
  if (( ${#token} <= 10 )); then
    echo "$token"
  else
    printf '%s...%s\n' "${token:0:6}" "${token: -4}"
  fi
}

prune_online_db() {
  ensure_online_db
  local tmp now ttl
  now="$(now_epoch)"
  ttl="${ONLINE_TTL:-300}"
  tmp="$(mktemp)"
  awk -F'|' -v now="$now" -v ttl="$ttl" 'NF>=6 && $6 ~ /^[0-9]+$/ && (now-$6)<=ttl {print}' "$ONLINE_DB" > "$tmp" || true
  mv "$tmp" "$ONLINE_DB"
  chmod 600 "$ONLINE_DB" 2>/dev/null || true
}

now_epoch() { date +%s; }

make_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 32
    echo
  fi
}

safe_field() {
  # Evita romper el formato token|cliente|proto|...
  printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/|/-/g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

clean_token() {
  # Token ID obligatorio para la app: letras, numeros, guion, punto y guion bajo.
  printf '%s' "${1:-}" | tr -d '\r\n ' | sed 's/[^A-Za-z0-9._-]//g'
}

normalize_proto() {
  local p
  p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  case "$p" in
    todos|todo|full|any|todas) echo "all" ;;
    sinbox|sing-box|sing_box|sb) echo "singbox" ;;
    slodns|slow-dns|slow_dns|dns) echo "slowdns" ;;
    histeria|hy|hysteria1) echo "hysteria" ;;
    hy2|hysteria-2|hysteria_2) echo "hysteria2" ;;
    udpcustom|udp-custom|udp_custom) echo "udp-custom" ;;
    sshws|ssh-websocket|websocket|ws) echo "ssh-ws" ;;
    sslssh|stunnel|tls) echo "ssl" ;;
    v2|v2-ray) echo "v2ray" ;;
    x-ray) echo "xray" ;;
    ss|shadow-socks) echo "shadowsocks" ;;
    *) echo "$p" ;;
  esac
}

valid_proto() {
  local p x
  p="$(normalize_proto "${1:-}")"
  for x in "${PROTO_LIST[@]}"; do
    [[ "$p" == "$x" ]] && return 0
  done
  return 1
}

protocols_text() {
  printf '%s ' "${PROTO_LIST[@]}"
  echo
}

format_date() {
  local epoch="${1:-0}"
  date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$epoch"
}

remaining_days() {
  local expires="${1:-0}" now diff
  now="$(now_epoch)"
  diff=$(( expires - now ))
  if (( diff < 0 )); then
    echo "vencido"
  else
    echo "$(( diff / 86400 )) dias"
  fi
}

count_devices() {
  local devices="${1:-}"
  if [[ -z "$devices" ]]; then
    echo 0
  else
    awk -F',' '{print NF}' <<< "$devices"
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

api_url() {
  load_config
  echo "http://$(public_ip):${API_PORT}/validate"
}

find_token_line() {
  local token="$1"
  ensure_db
  awk -F'|' -v tok="$token" '$1==tok {print; found=1; exit} END{if(!found) exit 2}' "$DB_FILE"
}

stats_values() {
  ensure_db
  local now
  now="$(now_epoch)"
  awk -F'|' -v now="$now" '
    NF>=6 {
      total++;
      if ($6=="active" && $5>=now) active++;
      if ($6!="active") disabled++;
      if ($5<now) expired++;
      if ($6=="active" && $5>=now && $5<=now+259200) exp3++;
      if ($8!="") { n=split($8,a,","); devices+=n }
    }
    END { printf "%d|%d|%d|%d|%d|%d", total+0, active+0, disabled+0, expired+0, exp3+0, devices+0 }
  ' "$DB_FILE"
}

color_setup() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold 2>/dev/null || true)"; DIM="$(tput dim 2>/dev/null || true)"; RESET="$(tput sgr0 2>/dev/null || true)"
    RED="$(tput setaf 1 2>/dev/null || true)"; GREEN="$(tput setaf 2 2>/dev/null || true)"; YELLOW="$(tput setaf 3 2>/dev/null || true)"
    BLUE="$(tput setaf 4 2>/dev/null || true)"; MAGENTA="$(tput setaf 5 2>/dev/null || true)"; CYAN="$(tput setaf 6 2>/dev/null || true)"
  else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
  fi
}

line() { printf '%s\n' "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${RESET}"; }
top()  { printf '%s\n' "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"; }
bot()  { printf '%s\n' "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"; }
row()  { printf "${CYAN}║${RESET} %-68s ${CYAN}║${RESET}\n" "$1"; }

print_header() {
  color_setup
  local stats total active disabled expired exp3 devices
  IFS='|' read -r total active disabled expired exp3 devices <<< "$(stats_values)"
  top
  row "${BOLD}SVRCODE TOKEN MANAGER v${VERSION}${RESET}"
  row "API: $(api_url)"
  row "Puerto: ${API_PORT}/tcp   Activos: ${active}   Vencidos: ${expired}   Disp.: ${devices}"
  bot
}

cmd_add() {
  need_root "$@"
  ensure_db
  local name="${1:-}"
  local proto="${2:-all}"
  local days="${3:-30}"
  local max_devices="${4:-1}"
  local custom_token="${5:-}"

  name="$(safe_field "$name")"
  proto="$(normalize_proto "$proto")"
  custom_token="$(clean_token "$custom_token")"

  if [[ -z "$name" ]]; then
    echo "Uso: svrtoken add NOMBRE proto dias max_devices TOKEN_ID" >&2
    echo "Ejemplo: svrtoken add cliente1 all 60 1 MI_TOKEN_ID" >&2
    exit 1
  fi
  if [[ -z "$custom_token" ]]; then
    echo "ERROR: Debes ingresar Token ID. No existe modo automatico en esta version." >&2
    echo "Uso: svrtoken add NOMBRE proto dias max_devices TOKEN_ID" >&2
    exit 1
  fi
  if ! valid_proto "$proto"; then
    echo "Protocolo invalido: $proto" >&2
    echo "Permitidos: $(protocols_text)" >&2
    exit 1
  fi
  if ! [[ "$days" =~ ^[0-9]+$ ]] || (( days < 1 )); then
    echo "Dias debe ser numero entero mayor a 0." >&2
    exit 1
  fi
  if ! [[ "$max_devices" =~ ^[0-9]+$ ]] || (( max_devices < 1 )); then
    echo "max_devices debe ser numero entero mayor a 0." >&2
    exit 1
  fi

  local token created expires
  token="$custom_token"

  if [[ ${#token} -lt 4 ]]; then
    echo "Token ID invalido: minimo 4 caracteres." >&2
    exit 1
  fi

  if awk -F'|' -v tok="$token" '$1==tok {found=1; exit} END{exit !found}' "$DB_FILE"; then
    echo "ERROR: Ese Token ID ya existe. Usa otro token o elimina el anterior." >&2
    exit 1
  fi

  created="$(now_epoch)"
  expires=$(( created + days * 86400 ))

  # Formato compatible: token|cliente|proto|created|expires|status|max_devices|devices
  printf '%s|%s|%s|%s|%s|active|%s|\n' "$token" "$name" "$proto" "$created" "$expires" "$max_devices" >> "$DB_FILE"

  echo "╔════════════════════════════════════════════╗"
  echo "║              TOKEN CREADO                 ║"
  echo "╚════════════════════════════════════════════╝"
  echo "Cliente / usuario : $name"
  echo "Token ID          : $token"
  echo "Protocolo         : $proto"
  echo "Dias              : $days"
  echo "Vence             : $(format_date "$expires")"
  echo "Max dispositivos  : $max_devices"
  echo "API_URL           : $(api_url)"
}

cmd_list() {
  ensure_db
  local n=0 now
  now="$(now_epoch)"
  printf '%-4s %-20s %-12s %-10s %-17s %-11s %-8s %-18s\n' "N" "CLIENTE" "PROTO" "ESTADO" "VENCE" "RESTANTE" "DISP" "TOKEN ID"
  echo "----------------------------------------------------------------------------------------------------------------"
  while IFS='|' read -r token name proto created expires status max_devices devices; do
    [[ -z "${token:-}" ]] && continue
    n=$((n+1))
    local exp_date used rest real_status
    exp_date="$(format_date "${expires:-0}")"
    used="$(count_devices "${devices:-}")"
    rest="$(remaining_days "${expires:-0}")"
    real_status="${status:-unknown}"
    if [[ "$real_status" == "active" ]] && (( expires < now )); then
      real_status="expired"
    fi
    printf '%-4s %-20.20s %-12.12s %-10s %-17s %-11s %-8s %.18s...\n' "$n" "${name:-}" "${proto:-}" "$real_status" "$exp_date" "$rest" "$used/${max_devices:-1}" "$token"
  done < "$DB_FILE"
}

cmd_show() {
  ensure_db
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    echo "Uso: svrcode-token show TOKEN" >&2
    exit 1
  fi
  local line
  line="$(find_token_line "$token")" || { echo "Token no encontrado." >&2; exit 1; }
  IFS='|' read -r token name proto created expires status max_devices devices <<< "$line"
  echo "╔════════════════════════════════════════════╗"
  echo "║             DETALLE DEL CLIENTE           ║"
  echo "╚════════════════════════════════════════════╝"
  echo "Cliente / usuario : $name"
  echo "Token ID          : $token"
  echo "Protocolo         : $proto"
  echo "Estado            : $status"
  echo "Creado            : $(format_date "$created")"
  echo "Vence             : $(format_date "$expires")"
  echo "Tiempo restante   : $(remaining_days "$expires")"
  echo "Dispositivos      : $(count_devices "${devices:-}")/$max_devices"
  echo "Device IDs        : ${devices:-sin registros}"
  echo "API_URL           : $(api_url)"
}

cmd_search() {
  ensure_db
  local q="$(safe_field "${1:-}")"
  if [[ -z "$q" ]]; then
    echo "Uso: svrcode-token search TEXTO" >&2
    exit 1
  fi
  awk -F'|' -v q="$q" '
    BEGIN { IGNORECASE=1; printf "%-20s %-12s %-10s %-18s\n", "CLIENTE", "PROTO", "ESTADO", "TOKEN ID"; print "----------------------------------------------------------------" }
    $1 ~ q || $2 ~ q || $3 ~ q { printf "%-20.20s %-12.12s %-10s %.18s...\n", $2, $3, $6, $1; found=1 }
    END { if (!found) print "Sin resultados." }
  ' "$DB_FILE"
}

update_status() {
  need_root "$@"
  ensure_db
  local token="${1:-}"
  local new_status="${2:-}"
  if [[ -z "$token" || -z "$new_status" ]]; then
    echo "Uso: svrcode-token enable|disable TOKEN" >&2
    exit 1
  fi
  local tmp
  tmp="$(mktemp)"
  awk -F'|' -v OFS='|' -v tok="$token" -v st="$new_status" '
    $1==tok {$6=st; found=1}
    {print}
    END { if (!found) exit 2 }
  ' "$DB_FILE" > "$tmp" || {
    rm -f "$tmp"
    echo "Token no encontrado." >&2
    exit 1
  }
  mv "$tmp" "$DB_FILE"
  chmod 600 "$DB_FILE" 2>/dev/null || true
  echo "Token actualizado a: $new_status"
}

update_field() {
  need_root "$@"
  ensure_db
  local token="${1:-}" field="${2:-}" value="${3:-}"
  if [[ -z "$token" || -z "$field" ]]; then
    echo "Uso interno: update_field TOKEN CAMPO VALOR" >&2
    exit 1
  fi
  local tmp
  tmp="$(mktemp)"
  awk -F'|' -v OFS='|' -v tok="$token" -v fld="$field" -v val="$value" '
    $1==tok {$fld=val; found=1}
    {print}
    END { if (!found) exit 2 }
  ' "$DB_FILE" > "$tmp" || {
    rm -f "$tmp"
    echo "Token no encontrado." >&2
    exit 1
  }
  mv "$tmp" "$DB_FILE"
  chmod 600 "$DB_FILE" 2>/dev/null || true
}

cmd_set_name() {
  local token="${1:-}" name="$(safe_field "${2:-}")"
  [[ -z "$token" || -z "$name" ]] && { echo "Uso: svrcode-token set-name TOKEN NUEVO_NOMBRE" >&2; exit 1; }
  update_field "$token" 2 "$name"
  echo "Cliente actualizado: $name"
}

cmd_set_proto() {
  local token="${1:-}" proto="$(normalize_proto "${2:-}")"
  [[ -z "$token" || -z "$proto" ]] && { echo "Uso: svrcode-token set-proto TOKEN PROTO" >&2; exit 1; }
  valid_proto "$proto" || { echo "Protocolo invalido. Permitidos: $(protocols_text)" >&2; exit 1; }
  update_field "$token" 3 "$proto"
  echo "Protocolo actualizado: $proto"
}

cmd_set_devices() {
  local token="${1:-}" maxd="${2:-}"
  [[ -z "$token" || -z "$maxd" ]] && { echo "Uso: svrcode-token set-devices TOKEN MAX" >&2; exit 1; }
  [[ "$maxd" =~ ^[0-9]+$ ]] && (( maxd > 0 )) || { echo "MAX debe ser mayor a 0." >&2; exit 1; }
  update_field "$token" 7 "$maxd"
  echo "Max dispositivos actualizado: $maxd"
}

cmd_del() {
  need_root "$@"
  ensure_db
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    echo "Uso: svrcode-token del TOKEN" >&2
    exit 1
  fi
  local tmp before after
  before="$(grep -c '|' "$DB_FILE" 2>/dev/null || echo 0)"
  tmp="$(mktemp)"
  grep -v "^${token}|" "$DB_FILE" > "$tmp" || true
  mv "$tmp" "$DB_FILE"
  chmod 600 "$DB_FILE" 2>/dev/null || true
  after="$(grep -c '|' "$DB_FILE" 2>/dev/null || echo 0)"
  if [[ "$before" != "$after" ]]; then
    echo "Token eliminado."
  else
    echo "Token no encontrado o ya eliminado."
  fi
}

cmd_renew() {
  need_root "$@"
  ensure_db
  local token="${1:-}"
  local days="${2:-30}"
  if [[ -z "$token" ]]; then
    echo "Uso: svrcode-token renew TOKEN [dias]" >&2
    exit 1
  fi
  if ! [[ "$days" =~ ^[0-9]+$ ]] || (( days < 1 )); then
    echo "Dias debe ser numero entero mayor a 0." >&2
    exit 1
  fi

  local tmp now newexp
  tmp="$(mktemp)"
  now="$(now_epoch)"
  awk -F'|' -v OFS='|' -v tok="$token" -v now="$now" -v days="$days" -v meta="$tmp.meta" '
    $1==tok {
      base=$5;
      if (base < now) base=now;
      $5=base + (days * 86400);
      $6="active";
      found=1;
      print $5 > meta;
      print;
      next
    }
    {print}
    END { if (!found) exit 2 }
  ' "$DB_FILE" > "$tmp" || {
    rm -f "$tmp" "$tmp.meta"
    echo "Token no encontrado." >&2
    exit 1
  }
  newexp="$(cat "$tmp.meta" 2>/dev/null || true)"
  mv "$tmp" "$DB_FILE"
  rm -f "$tmp.meta"
  chmod 600 "$DB_FILE" 2>/dev/null || true
  echo "Token renovado por $days dias. Nueva fecha: $(format_date "$newexp")"
}

cmd_reset_devices() {
  need_root "$@"
  ensure_db
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    echo "Uso: svrcode-token reset-devices TOKEN" >&2
    exit 1
  fi
  update_field "$token" 8 ""
  echo "Dispositivos reiniciados para el token."
}

cmd_api_config() {
  load_config
  local mode="${1:-text}"
  if [[ "$mode" == "json" || "$mode" == "--json" ]]; then
    cat <<JSON
{
  "api_url": "$(api_url)",
  "api_host": "${API_HOST}",
  "api_port": ${API_PORT},
  "app_key": "${APP_KEY}",
  "validate_endpoint": "/validate",
  "heartbeat_endpoint": "/heartbeat",
  "check_user_endpoint": "/check-user",
  "disconnect_endpoint": "/disconnect",
  "online_endpoint": "/online",
  "online_ttl": ${ONLINE_TTL},
  "header": "X-App-Key",
  "protocols": ["all", "ssh", "slowdns", "udp", "hysteria", "hysteria2", "v2ray", "xray", "singbox", "vless", "vmess", "trojan", "reality", "shadowsocks", "tuic"],
  "body_example": {"token": "TOKEN_ID", "proto": "xray", "device_id": "UUID_APP"}
}
JSON
    return
  fi
  echo "╔════════════════════════════════════════════╗"
  echo "║          CONFIGURACION PARA LA APP        ║"
  echo "╚════════════════════════════════════════════╝"
  echo "API_HOST    : $API_HOST"
  echo "API_PORT    : $API_PORT"
  echo "IP_VPS      : $(public_ip)"
  echo "API_URL     : $(api_url)"
  echo "APP_KEY     : $APP_KEY"
  echo "TOKEN_DB    : $DB_FILE"
  echo "ONLINE_DB   : $ONLINE_DB"
  echo "ONLINE_TTL  : ${ONLINE_TTL} segundos"
  echo "HEADER      : X-App-Key: $APP_KEY"
  echo "VALIDATE    : POST /validate con {\"token\":\"TOKEN_ID\",\"proto\":\"ssh\",\"device_id\":\"UUID_APP\"}"
  echo "HEARTBEAT   : POST /heartbeat cada 60 segundos mientras este conectado"
  echo "CHECK USER  : POST /check-user con {\"token\":\"TOKEN_ID\",\"device_id\":\"UUID_APP\"}"
  echo "DISCONNECT  : POST /disconnect al cortar conexion"
}

cmd_validate_local() {
  load_config
  local token="${1:-}" proto="$(normalize_proto "${2:-ssh}")" device="${3:-test-device}"
  [[ -z "$token" ]] && { echo "Uso: svrcode-token test TOKEN [proto] [device_id]" >&2; exit 1; }
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl no esta instalado." >&2
    exit 1
  fi
  curl -sS -X POST "http://127.0.0.1:${API_PORT}/validate" \
    -H "Content-Type: application/json" \
    -H "X-App-Key: ${APP_KEY}" \
    -d "{\"token\":\"${token}\",\"proto\":\"${proto}\",\"device_id\":\"${device}\"}"
  echo
}

cmd_status() {
  load_config
  echo "╔════════════════════════════════════════════╗"
  echo "║             ESTADO DE LA API              ║"
  echo "╚════════════════════════════════════════════╝"
  echo "API_URL: $(api_url)"
  echo "Puerto : ${API_PORT}/tcp"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
  else
    ps aux | grep '[a]pi_server.py' || true
  fi
}

cmd_restart() {
  need_root "$@"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME"
    echo "API reiniciada."
  else
    echo "systemctl no disponible. Reinicia manualmente api_server.py." >&2
    exit 1
  fi
}

cmd_logs() {
  load_config
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$SERVICE_NAME" -n "${1:-80}" --no-pager || true
  elif [[ -f "$LOG_FILE" ]]; then
    tail -n "${1:-80}" "$LOG_FILE"
  else
    echo "No se encontraron logs."
  fi
}

cmd_estimate() {
  ensure_db
  local now total active disabled expired exp3 exp7 devices_sum
  now="$(now_epoch)"
  total="$(awk -F'|' 'NF>=6 {c++} END{print c+0}' "$DB_FILE")"
  active="$(awk -F'|' -v now="$now" '$6=="active" && $5>=now {c++} END{print c+0}' "$DB_FILE")"
  disabled="$(awk -F'|' '$6!="active" {c++} END{print c+0}' "$DB_FILE")"
  expired="$(awk -F'|' -v now="$now" '$5<now {c++} END{print c+0}' "$DB_FILE")"
  exp3="$(awk -F'|' -v now="$now" '$6=="active" && $5>=now && $5<=now+259200 {c++} END{print c+0}' "$DB_FILE")"
  exp7="$(awk -F'|' -v now="$now" '$6=="active" && $5>=now && $5<=now+604800 {c++} END{print c+0}' "$DB_FILE")"
  devices_sum="$(awk -F'|' '{ if($8!="") { n=split($8,a,","); c+=n } } END{print c+0}' "$DB_FILE")"

  echo "╔════════════════════════════════════════════╗"
  echo "║              RESUMEN GENERAL              ║"
  echo "╚════════════════════════════════════════════╝"
  echo "Total tokens            : $total"
  echo "Activos vigentes        : $active"
  echo "Desactivados            : $disabled"
  echo "Vencidos                : $expired"
  echo "Vencen en 3 dias        : $exp3"
  echo "Vencen en 7 dias        : $exp7"
  echo "Dispositivos registrados: $devices_sum"
  echo "API_URL                 : $(api_url)"
  echo
  echo "Por protocolo:"
  awk -F'|' 'NF>=3 {p[$3]++} END{for (k in p) printf "  %-12s : %s\n", k, p[k]}' "$DB_FILE" | sort || true
}

cmd_online() {
  ensure_db
  ensure_online_db
  prune_online_db
  local now ttl count
  now="$(now_epoch)"
  ttl="${ONLINE_TTL:-300}"
  echo "╔════════════════════════════════════════════╗"
  echo "║          USUARIOS ONLINE / ACTIVOS        ║"
  echo "╚════════════════════════════════════════════╝"
  echo "API_URL     : $(api_url)"
  echo "Check URL   : http://$(public_ip):${API_PORT}/check-user"
  echo "Heartbeat   : http://$(public_ip):${API_PORT}/heartbeat"
  echo "TTL online  : ${ttl} segundos"
  echo
  echo "=== Usuarios reportados por la APP ==="
  count="$(awk -F'|' -v now="$now" -v ttl="$ttl" 'NF>=6 && $6 ~ /^[0-9]+$/ && (now-$6)<=ttl {c++} END{print c+0}' "$ONLINE_DB")"
  if [[ "$count" == "0" ]]; then
    echo "Sin usuarios online reportados por la app."
    echo "La app debe llamar /validate al conectar, /heartbeat cada 60s y /disconnect al desconectar."
  else
    printf '%-4s %-20s %-12s %-18s %-15s %-10s %-18s\n' "N" "CLIENTE" "PROTO" "DEVICE" "IP" "HACE" "TOKEN"
    echo "---------------------------------------------------------------------------------------------------"
    awk -F'|' -v now="$now" -v ttl="$ttl" '
      NF>=6 && $6 ~ /^[0-9]+$/ && (now-$6)<=ttl {
        n++;
        token=$1; mask=substr(token,1,6) "..." substr(token,length(token)-3,4);
        age=now-$6;
        printf "%-4s %-20.20s %-12.12s %-18.18s %-15.15s %-10s %-18s\n", n, $2, $3, $4, $5, age "s", mask;
      }
    ' "$ONLINE_DB"
  fi
  echo
  echo "=== SSH logueados en la VPS ==="
  if command -v who >/dev/null 2>&1; then
    who || true
  else
    echo "Comando who no disponible."
  fi
  echo
  echo "=== Puertos/procesos relacionados ==="
  if command -v ss >/dev/null 2>&1; then
    ss -tunap 2>/dev/null | grep -Ei 'sshd|dropbear|stunnel|openvpn|xray|v2ray|sing-box|singbox|hysteria|udp|slowdns|dns|:5000' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tunap 2>/dev/null | grep -Ei 'sshd|dropbear|stunnel|openvpn|xray|v2ray|sing-box|singbox|hysteria|udp|slowdns|dns|:5000' || true
  else
    echo "Instala iproute2 o net-tools para ver conexiones."
  fi
}

cmd_check_user_online() {
  ensure_online_db
  prune_online_db
  local token="${1:-}" device="${2:-}" now ttl count
  now="$(now_epoch)"
  ttl="${ONLINE_TTL:-300}"
  if [[ -z "$token" ]]; then
    echo "Uso: svrcode-token check-user TOKEN [device_id]" >&2
    exit 1
  fi
  echo "╔════════════════════════════════════════════╗"
  echo "║             CHECK USER ONLINE             ║"
  echo "╚════════════════════════════════════════════╝"
  echo "Token ID : $(mask_token "$token")"
  [[ -n "$device" ]] && echo "Device   : $device"
  echo "TTL      : ${ttl} segundos"
  echo
  count="$(awk -F'|' -v tok="$token" -v dev="$device" -v now="$now" -v ttl="$ttl" '
    NF>=6 && $1==tok && (dev=="" || $4==dev) && $6 ~ /^[0-9]+$/ && (now-$6)<=ttl {c++}
    END{print c+0}
  ' "$ONLINE_DB")"
  if [[ "$count" == "0" ]]; then
    echo "Estado: OFFLINE o sin heartbeat vigente."
    echo "Nota  : para que sea exacto, la app debe enviar /heartbeat cada 60 segundos."
    return 1
  fi
  echo "Estado: ONLINE"
  echo
  printf '%-20s %-12s %-18s %-15s %-10s\n' "CLIENTE" "PROTO" "DEVICE" "IP" "HACE"
  echo "----------------------------------------------------------------------------"
  awk -F'|' -v tok="$token" -v dev="$device" -v now="$now" -v ttl="$ttl" '
    NF>=6 && $1==tok && (dev=="" || $4==dev) && $6 ~ /^[0-9]+$/ && (now-$6)<=ttl {
      age=now-$6;
      printf "%-20.20s %-12.12s %-18.18s %-15.15s %-10s\n", $2, $3, $4, $5, age "s";
    }
  ' "$ONLINE_DB"
}

cmd_online_api_test() {
  load_config
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl no esta instalado." >&2
    exit 1
  fi
  curl -sS -H "X-App-Key: ${APP_KEY}" "http://127.0.0.1:${API_PORT}/online"
  echo
}

read_input() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value || true
    echo "${value:-$default}"
  else
    read -r -p "$prompt: " value || true
    echo "$value"
  fi
}

read_secret_input() {
  local prompt="$1" value
  read -r -s -p "$prompt: " value || true
  echo >&2
  echo "$value"
}

set_config_value() {
  need_root "$@"
  local key="$1" value="$2" tmp
  mkdir -p "$(dirname "$CONF_FILE")"
  touch "$CONF_FILE"
  chmod 600 "$CONF_FILE" 2>/dev/null || true
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$CONF_FILE" 2>/dev/null; then
    awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$CONF_FILE" > "$tmp"
  else
    cat "$CONF_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" "$CONF_FILE"
  chmod 600 "$CONF_FILE" 2>/dev/null || true
}

bool_text() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|si|SI) echo "ACTIVO" ;;
    *) echo "INACTIVO" ;;
  esac
}

cmd_git_config_show() {
  load_config
  color_setup
  local base="http://$(public_ip):${API_PORT}"
  echo "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
  echo "${CYAN}║${RESET} ${BOLD}🚀 CANAL DE ACTUALIZACIÓN GIT / VPS${RESET}"
  echo "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${RESET}"
  printf "${CYAN}║${RESET} %-20s: %s\n" "Estado" "$(bool_text "${UPDATE_ENABLED:-1}")"
  printf "${CYAN}║${RESET} %-20s: %s\n" "Repositorio" "${GITHUB_REPO:-chifladito-store/SERVERMIX}"
  printf "${CYAN}║${RESET} %-20s: %s\n" "Rama" "${GITHUB_BRANCH:-main}"
  printf "${CYAN}║${RESET} %-20s: %s\n" "FREE JSON" "${FREE_CONFIG_PATH:-FreeMode/Config.json}"
  printf "${CYAN}║${RESET} %-20s: %s\n" "VIP JSON" "${VIP_CONFIG_PATH:-VipMode/Config.mvgl.json}"
  printf "${CYAN}║${RESET} %-20s: %s segundos\n" "Intervalo" "${UPDATE_SYNC_INTERVAL:-5}"
  printf "${CYAN}║${RESET} %-20s: %s\n" "GitHub Token" "$(mask_token "${GITHUB_TOKEN:-}")"
  echo "${CYAN}╠══════════════════════════════════════════════════════════════════════╣${RESET}"
  printf "${CYAN}║${RESET} %-20s: %s\n" "FREE check" "${base}/api/update/free"
  printf "${CYAN}║${RESET} %-20s: %s\n" "VIP check" "${base}/api/update/vip"
  printf "${CYAN}║${RESET} %-20s: %s\n" "FREE config" "${base}/config/free.json"
  printf "${CYAN}║${RESET} %-20s: %s\n" "VIP config" "${base}/config/vip.json"
  printf "${CYAN}║${RESET} %-20s: %s\n" "Webhook" "${base}/api/github/webhook"
  echo "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
}

cmd_git_edit() {
  need_root "$@"
  load_config
  color_setup
  echo "${BOLD}⚙️  Configurar GitHub para actualización de servidores${RESET}"
  echo "Deja vacío un campo para conservar el valor actual."
  echo
  local repo branch freep vipp interval enabled token webhook_secret
  repo="$(read_input "📦 Repositorio owner/repo" "${GITHUB_REPO:-chifladito-store/SERVERMIX}")"
  branch="$(read_input "🌿 Rama" "${GITHUB_BRANCH:-main}")"
  freep="$(read_input "🆓 Ruta JSON FREE" "${FREE_CONFIG_PATH:-FreeMode/Config.json}")"
  vipp="$(read_input "👑 Ruta JSON VIP" "${VIP_CONFIG_PATH:-VipMode/Config.mvgl.json}")"
  interval="$(read_input "⏱️  Sincronización VPS cada segundos" "${UPDATE_SYNC_INTERVAL:-5}")"
  enabled="$(read_input "✅ Activar canal update 1/0" "${UPDATE_ENABLED:-1}")"
  echo
  echo "Token actual: $(mask_token "${GITHUB_TOKEN:-}")"
  token="$(read_secret_input "🔐 Nuevo GitHub token (vacío = conservar)")"
  webhook_secret="${WEBHOOK_SECRET:-}"
  if [[ -z "$webhook_secret" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      webhook_secret="$(openssl rand -hex 32)"
    else
      webhook_secret="$(date +%s%N | sha256sum | awk '{print $1}')"
    fi
  fi

  set_config_value UPDATE_ENABLED "${enabled:-1}"
  set_config_value GITHUB_REPO "$repo"
  set_config_value GITHUB_BRANCH "$branch"
  set_config_value FREE_CONFIG_PATH "$freep"
  set_config_value VIP_CONFIG_PATH "$vipp"
  set_config_value UPDATE_SYNC_INTERVAL "${interval:-5}"
  set_config_value WEBHOOK_SECRET "$webhook_secret"
  if [[ -n "$token" ]]; then
    set_config_value GITHUB_TOKEN "$token"
  fi

  echo
  echo "✅ Configuración Git guardada. Reiniciando API..."
  cmd_restart
  echo
  cmd_git_config_show
}

cmd_git_sync() {
  need_root "$@"
  load_config
  local url="http://127.0.0.1:${API_PORT}/api/admin/sync?key=${APP_KEY}"
  echo "🔄 Sincronizando FREE/VIP desde GitHub hacia la VPS..."
  if command -v curl >/dev/null 2>&1; then
    curl -sS --max-time 20 "$url" || true
    echo
  else
    echo "curl no está instalado."
  fi
}

cmd_git_test() {
  load_config
  local base="http://127.0.0.1:${API_PORT}"
  echo "🧪 Probando endpoints locales de actualización..."
  echo
  for ep in "/health" "/api/update/free" "/api/update/vip" "/config/free.json" "/config/vip.json"; do
    echo "▶ ${ep}"
    if command -v curl >/dev/null 2>&1; then
      curl -sS --max-time 10 "${base}${ep}" | head -c 700 || true
      echo
      echo
    else
      echo "curl no está instalado."
    fi
  done
}

cmd_git_webhook() {
  load_config
  local base="http://$(public_ip):${API_PORT}"
  echo "╔════════════════════════════════════════════╗"
  echo "║          🔔 WEBHOOK DE GITHUB             ║"
  echo "╚════════════════════════════════════════════╝"
  echo "Payload URL : ${base}/api/github/webhook"
  echo "Content type: application/json"
  echo "Secret      : ${WEBHOOK_SECRET:-NO_CONFIGURADO}"
  echo "Evento      : Just the push event"
  echo
  echo "En GitHub: Settings → Webhooks → Add webhook"
}

cmd_git_menu() {
  need_root "$@"
  while true; do
    clear 2>/dev/null || true
    print_header
    echo ""
    echo "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────┐${RESET}"
    echo "${BOLD}${CYAN}│${RESET}        🚀  SUBMENÚ GIT / ACTUALIZACIÓN VPS           ${BOLD}${CYAN}│${RESET}"
    echo "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${RESET}"
    echo "  ${GREEN}1)${RESET} 👁️  Ver configuración Git / endpoints"
    echo "  ${GREEN}2)${RESET} ⚙️  Editar datos de GitHub"
    echo "  ${GREEN}3)${RESET} 🔄 Sincronizar ahora FREE/VIP"
    echo "  ${GREEN}4)${RESET} 🧪 Probar endpoints locales"
    echo "  ${GREEN}5)${RESET} 🔔 Ver datos para Webhook"
    echo "  ${GREEN}6)${RESET} ♻️  Reiniciar API"
    echo "  ${YELLOW}0)${RESET} ⬅️  Volver"
    echo
    read -r -p "Elige una opción: " op || true
    echo
    case "$op" in
      1) cmd_git_config_show; pause_menu ;;
      2) cmd_git_edit; pause_menu ;;
      3) cmd_git_sync; pause_menu ;;
      4) cmd_git_test; pause_menu ;;
      5) cmd_git_webhook; pause_menu ;;
      6) cmd_restart; pause_menu ;;
      0) return 0 ;;
      *) echo "Opción no válida."; pause_menu ;;
    esac
  done
}

pause_menu() {
  echo
  read -r -p "Presiona ENTER para continuar..." _ || true
}

select_token_menu() {
  local title="${1:-Selecciona cliente/token}" choice token name proto created expires status max_devices devices rest real_status now
  local n=0
  ensure_db
  color_setup
  now="$(now_epoch)"
  local rows=()

  echo "" >&2
  echo "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────┐${RESET}" >&2
  printf "${BOLD}${CYAN}│${RESET} %-58s ${BOLD}${CYAN}│${RESET}\n" "$title" >&2
  echo "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${RESET}" >&2
  printf >&2 "%-4s %-20s %-11s %-10s %-12s %s\n" "N" "CLIENTE" "ESTADO" "RESTANTE" "PROTO" "TOKEN ID"
  echo "--------------------------------------------------------------------------" >&2

  while IFS='|' read -r token name proto created expires status max_devices devices; do
    [[ -z "${token:-}" ]] && continue
    n=$((n+1))
    rest="$(remaining_days "${expires:-0}")"
    real_status="${status:-unknown}"
    if [[ "$real_status" == "active" ]] && (( expires < now )); then
      real_status="expired"
    fi
    rows+=("$token")
    printf >&2 "%-4s %-20.20s %-11.11s %-10.10s %-12.12s %s\n" "$n" "${name:-}" "$real_status" "$rest" "${proto:-}" "$token"
  done < "$DB_FILE"

  if (( n == 0 )); then
    echo "No hay clientes/tokens registrados." >&2
    return 1
  fi

  echo "" >&2
  read -r -p "Selecciona número de usuario/token [0 cancelar]: " choice || true
  choice="${choice:-0}"
  if [[ "$choice" == "0" ]]; then
    echo "Cancelado." >&2
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
    echo "Selección inválida." >&2
    return 1
  fi
  echo "${rows[$((choice-1))]}"
}

select_proto_menu() {
  local choice custom
  {
    echo "Selecciona protocolo/perfil:"
    echo "  1) all        - todos los metodos"
    echo "  2) ssh        - ssh/dropbear/ssl/ws"
    echo "  3) slowdns    - SlowDNS / SloDNS"
    echo "  4) udp        - UDP / UDPGW"
    echo "  5) udp-custom - UDP Custom"
    echo "  6) hysteria   - Hysteria"
    echo "  7) hysteria2  - Hysteria2"
    echo "  8) v2ray      - V2Ray / VMess / VLess"
    echo "  9) xray       - Xray / VLess / Reality / Trojan"
    echo " 10) singbox    - Sing-box"
    echo " 11) otro       - escribir manual"
  } >&2
  read -r -p "Opcion [1]: " choice || true
  case "${choice:-1}" in
    1) echo "all" ;;
    2) echo "ssh" ;;
    3) echo "slowdns" ;;
    4) echo "udp" ;;
    5) echo "udp-custom" ;;
    6) echo "hysteria" ;;
    7) echo "hysteria2" ;;
    8) echo "v2ray" ;;
    9) echo "xray" ;;
    10) echo "singbox" ;;
    11) custom="$(read_input "Escribe protocolo")"; normalize_proto "$custom" ;;
    *) echo "all" ;;
  esac
}

cmd_menu() {
  need_root "$@"
  ensure_db
  while true; do
    clear 2>/dev/null || true
    print_header
    echo ""
    echo "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────┐${RESET}"
    echo "${BOLD}${CYAN}│${RESET}             🔐  MENÚ PRINCIPAL TOKEN                ${BOLD}${CYAN}│${RESET}"
    echo "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${RESET}"
    echo "  ${GREEN}1)${RESET} 🟢 Crear cliente / Token ID"
    echo "  ${GREEN}2)${RESET} 📋 Ver lista de clientes/tokens"
    echo "  ${GREEN}3)${RESET} 🔎 Buscar cliente o token"
    echo "  ${GREEN}4)${RESET} 🧾 Ver detalle de usuario/token"
    echo "  ${GREEN}5)${RESET} ⏳ Renovar usuario/token"
    echo "  ${GREEN}6)${RESET} ✅ Activar usuario/token"
    echo "  ${GREEN}7)${RESET} ⛔ Desactivar usuario/token"
    echo "  ${GREEN}8)${RESET} 🔀 Cambiar protocolo por usuario"
    echo "  ${GREEN}9)${RESET} 📱 Cambiar límite de dispositivos"
    echo " ${GREEN}10)${RESET} 👤 Cambiar nombre del cliente"
    echo " ${GREEN}11)${RESET} ♻️  Reiniciar dispositivos vinculados"
    echo " ${GREEN}12)${RESET} 🧪 Probar validación local del token"
    echo " ${GREEN}13)${RESET} 🗑️  Eliminar token"
    echo " ${GREEN}14)${RESET} 🟢 Ver usuarios/conexiones en línea"
    echo " ${GREEN}15)${RESET} 👁️  Check user online por token"
    echo " ${GREEN}16)${RESET} 📊 Ver resumen general"
    echo " ${GREEN}17)${RESET} 🔗 Ver URL, IP, APP_KEY y JSON para app"
    echo " ${GREEN}18)${RESET} 🛠️  Estado de la API"
    echo " ${GREEN}19)${RESET} ♻️  Reiniciar API"
    echo " ${GREEN}20)${RESET} 📜 Ver logs"
    echo " ${MAGENTA}21)${RESET} 🚀 Git / Actualización de servidores"
    echo "  ${YELLOW}0)${RESET} 🚪 Salir"
    echo
    read -r -p "Elige una opcion: " op || true
    echo
    case "$op" in
      1)
        local name token_manual proto days maxd
        name="$(read_input "Nombre del cliente/usuario")"
        token_manual="$(read_input "Token ID")"
        token_manual="$(clean_token "$token_manual")"
        if [[ -z "$token_manual" ]]; then
          echo "ERROR: El Token ID es obligatorio. Debes escribirlo manualmente."
          pause_menu
          continue
        fi
        proto="$(select_proto_menu)"
        days="$(read_input "Dias de duracion" "30")"
        maxd="$(read_input "Max dispositivos" "1")"
        cmd_add "$name" "$proto" "$days" "$maxd" "$token_manual"
        pause_menu
        ;;
      2) cmd_list; pause_menu ;;
      3)
        local q
        q="$(read_input "Buscar por cliente, token o protocolo")"
        cmd_search "$q"
        pause_menu
        ;;
      4)
        local token
        token="$(select_token_menu "🧾 Selecciona cliente para ver detalle")" || { pause_menu; continue; }
        cmd_show "$token"
        pause_menu
        ;;
      5)
        local token days
        token="$(select_token_menu "⏳ Selecciona cliente para renovar")" || { pause_menu; continue; }
        days="$(read_input "Dias a aumentar" "30")"
        cmd_renew "$token" "$days"
        pause_menu
        ;;
      6)
        local token
        token="$(select_token_menu "✅ Selecciona cliente para activar")" || { pause_menu; continue; }
        update_status "$token" active
        pause_menu
        ;;
      7)
        local token
        token="$(select_token_menu "⛔ Selecciona cliente para desactivar")" || { pause_menu; continue; }
        update_status "$token" disabled
        pause_menu
        ;;
      8)
        local token proto
        token="$(select_token_menu "🔀 Selecciona cliente para cambiar protocolo")" || { pause_menu; continue; }
        proto="$(select_proto_menu)"
        cmd_set_proto "$token" "$proto"
        pause_menu
        ;;
      9)
        local token maxd
        token="$(select_token_menu "📱 Selecciona cliente para cambiar límite")" || { pause_menu; continue; }
        maxd="$(read_input "Nuevo max dispositivos" "1")"
        cmd_set_devices "$token" "$maxd"
        pause_menu
        ;;
      10)
        local token name
        token="$(select_token_menu "👤 Selecciona cliente para cambiar nombre")" || { pause_menu; continue; }
        name="$(read_input "Nuevo nombre del cliente")"
        cmd_set_name "$token" "$name"
        pause_menu
        ;;
      11)
        local token
        token="$(select_token_menu "♻️  Selecciona cliente para reiniciar dispositivos")" || { pause_menu; continue; }
        cmd_reset_devices "$token"
        pause_menu
        ;;
      12)
        local token proto dev
        token="$(select_token_menu "🧪 Selecciona cliente para probar validación")" || { pause_menu; continue; }
        proto="$(select_proto_menu)"
        dev="$(read_input "Device ID de prueba" "test-device")"
        cmd_validate_local "$token" "$proto" "$dev"
        pause_menu
        ;;
      13)
        local token confirm
        token="$(select_token_menu "🗑️  Selecciona cliente para eliminar")" || { pause_menu; continue; }
        confirm="$(read_input "Escribe SI para eliminar el token seleccionado" "NO")"
        [[ "$confirm" == "SI" ]] && cmd_del "$token" || echo "Cancelado."
        pause_menu
        ;;
      14) cmd_online; pause_menu ;;
      15)
        local token device
        token="$(select_token_menu "👁️  Selecciona cliente para check online")" || { pause_menu; continue; }
        device="$(read_input "Device ID opcional" "")"
        cmd_check_user_online "$token" "$device" || true
        pause_menu
        ;;
      16) cmd_estimate; pause_menu ;;
      17) cmd_api_config; echo; cmd_api_config json; pause_menu ;;
      18) cmd_status; pause_menu ;;
      19) cmd_restart; pause_menu ;;
      20) cmd_logs 120; pause_menu ;;
      21) cmd_git_menu ;;
      0) exit 0 ;;
      *) echo "Opcion no valida."; pause_menu ;;
    esac
  done
}

cmd_help() {
  cat <<HELP
SVRCODE Token Manager v${VERSION}

Uso rapido:
  sudo svrtoken menu
  sudo svrtoken add NOMBRE proto dias max_devices TOKEN_ID
  sudo svrtoken list
  sudo svrtoken search TEXTO
  sudo svrtoken show TOKEN
  sudo svrtoken renew TOKEN [dias]
  sudo svrtoken enable TOKEN
  sudo svrtoken disable TOKEN
  sudo svrtoken set-proto TOKEN PROTO
  sudo svrtoken set-devices TOKEN MAX
  sudo svrtoken set-name TOKEN NUEVO_NOMBRE
  sudo svrtoken del TOKEN
  sudo svrtoken reset-devices TOKEN
  sudo svrtoken test TOKEN [proto] [device_id]
  sudo svrtoken online
  sudo svrtoken check-user TOKEN [device_id]
  sudo svrtoken online-json
  sudo svrtoken estimate
  sudo svrtoken api-config [json]
  sudo svrtoken status
  sudo svrtoken restart
  sudo svrtoken logs [lineas]
  sudo svrtoken git-menu
  sudo svrtoken git-show
  sudo svrtoken git-sync
  sudo svrtoken git-test

Protocolos permitidos:
  $(protocols_text)

Alias aceptados:
  sinbox=singbox, slodns=slowdns, histeria=hysteria, hy2=hysteria2,
  ws=ssh-ws, stunnel/tls=ssl, udpcustom=udp-custom.

Ejemplos:
  sudo svrtoken add cliente1 all 30 1 MI_TOKEN_123
  sudo svrtoken add cliente2 xray 15 2 TOKEN_XRAY_123
  sudo svrtoken add cliente3 slowdns 7 1 TOKEN_DNS_123
  sudo svrtoken api-config json

Check user online desde la app:
  POST /check-user     {"token":"TOKEN_ID","device_id":"UUID_APP"}
  POST /heartbeat      {"token":"TOKEN_ID","proto":"xray","device_id":"UUID_APP"}
  POST /disconnect     {"token":"TOKEN_ID","device_id":"UUID_APP"}
  GET  /online         lista usuarios online con X-App-Key

Canal Git/VPS:
  sudo svrtoken git-menu       abre submenú visual de GitHub
  sudo svrtoken git-show       muestra repo, rutas y endpoints
  sudo svrtoken git-sync       sincroniza ahora FREE/VIP
  sudo svrtoken git-test       prueba endpoints locales
HELP
}

main() {
  local cmd="${1:-menu}"
  shift || true
  case "$cmd" in
    menu) cmd_menu "$@" ;;
    add|create|crear) cmd_add "$@" ;;
    list|listar|clientes) cmd_list "$@" ;;
    search|buscar) cmd_search "$@" ;;
    show|info|detalle) cmd_show "$@" ;;
    renew|renovar) cmd_renew "$@" ;;
    enable|activar) update_status "${1:-}" active ;;
    disable|desactivar) update_status "${1:-}" disabled ;;
    set-proto|proto) cmd_set_proto "$@" ;;
    set-devices|devices) cmd_set_devices "$@" ;;
    set-name|name) cmd_set_name "$@" ;;
    del|delete|remove|eliminar) cmd_del "$@" ;;
    reset-devices|reset|limpiar-dispositivos) cmd_reset_devices "$@" ;;
    test|validar) cmd_validate_local "$@" ;;
    online|linea) cmd_online "$@" ;;
    check-user|check|online-user|usuario-online) cmd_check_user_online "$@" ;;
    online-json|online-api) cmd_online_api_test "$@" ;;
    estimate|estimar|resumen|stats) cmd_estimate "$@" ;;
    api-config|config) cmd_api_config "${1:-text}" ;;
    protocols|protocolos) protocols_text ;;
    status|estado) cmd_status "$@" ;;
    restart|reiniciar) cmd_restart "$@" ;;
    logs) cmd_logs "${1:-80}" ;;
    git-menu|github|git) cmd_git_menu "$@" ;;
    git-show|update-show) cmd_git_config_show "$@" ;;
    git-edit|update-edit) cmd_git_edit "$@" ;;
    git-sync|update-sync) cmd_git_sync "$@" ;;
    git-test|update-test) cmd_git_test "$@" ;;
    git-webhook|update-webhook) cmd_git_webhook "$@" ;;
    help|-h|--help) cmd_help ;;
    *) echo "Comando no reconocido: $cmd" >&2; cmd_help; exit 1 ;;
  esac
}

main "$@"
