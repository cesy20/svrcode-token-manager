#!/usr/bin/env python3
"""SVRCODE Token API v0.10.

Endpoints:
  GET  /health
  POST /validate
  GET  /protocols      requiere header X-App-Key
  GET  /online         requiere header X-App-Key
  POST /check-user     requiere header X-App-Key
  POST /heartbeat      requiere header X-App-Key
  POST /disconnect     requiere header X-App-Key

Header requerido para validar:
  X-App-Key: <APP_KEY>

Body ejemplo:
  {"token":"TOKEN_ID", "proto":"ssh", "device_id":"UUID_APP"}

La base sigue siendo compatible con versiones anteriores:
  token|cliente|proto|created|expires|status|max_devices|devices
"""

import json
import os
import time
import base64
import hashlib
import hmac
import threading
import urllib.parse
import urllib.request
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Tuple

CONFIG_FILE = "/etc/svrcode-token/config.env"
VERSION = "0.14"

CANONICAL_PROTOCOLS = [
    "all",
    "ssh",
    "ssh-ws",
    "ssl",
    "dropbear",
    "slowdns",
    "openvpn",
    "udp",
    "udp-custom",
    "hysteria",
    "hysteria2",
    "v2ray",
    "xray",
    "singbox",
    "vless",
    "vmess",
    "trojan",
    "reality",
    "shadowsocks",
    "tuic",
]

ALIASES = {
    "todos": "all",
    "todo": "all",
    "full": "all",
    "any": "all",
    "sinbox": "singbox",
    "sing-box": "singbox",
    "sing_box": "singbox",
    "sb": "singbox",
    "slodns": "slowdns",
    "slow-dns": "slowdns",
    "slow_dns": "slowdns",
    "dns": "slowdns",
    "histeria": "hysteria",
    "hy": "hysteria",
    "hysteria1": "hysteria",
    "hy2": "hysteria2",
    "hysteria-2": "hysteria2",
    "hysteria_2": "hysteria2",
    "udpcustom": "udp-custom",
    "udp_custom": "udp-custom",
    "sshws": "ssh-ws",
    "ssh-websocket": "ssh-ws",
    "websocket": "ssh-ws",
    "ws": "ssh-ws",
    "sslssh": "ssl",
    "stunnel": "ssl",
    "tls": "ssl",
    "v2": "v2ray",
    "v2-ray": "v2ray",
    "x-ray": "xray",
    "ss": "shadowsocks",
    "shadow-socks": "shadowsocks",
}

# Un token creado para un perfil amplio puede validar protocolos hijos.
PROTOCOL_GROUPS = {
    "all": set(CANONICAL_PROTOCOLS),
    "ssh": {"ssh", "dropbear", "ssl", "ssh-ws", "slowdns"},
    "dropbear": {"dropbear", "ssh"},
    "ssl": {"ssl", "ssh", "dropbear"},
    "ssh-ws": {"ssh-ws", "ssh", "dropbear", "ssl"},
    "slowdns": {"slowdns", "ssh"},
    "udp": {"udp", "udp-custom"},
    "udp-custom": {"udp-custom", "udp"},
    "hysteria": {"hysteria", "hysteria2"},
    "hysteria2": {"hysteria2", "hysteria"},
    "v2ray": {"v2ray", "vless", "vmess"},
    "xray": {"xray", "vless", "vmess", "trojan", "reality"},
    "singbox": {"singbox", "vless", "vmess", "trojan", "reality", "hysteria", "hysteria2", "shadowsocks", "tuic"},
    "vless": {"vless", "v2ray", "xray", "singbox"},
    "vmess": {"vmess", "v2ray", "xray", "singbox"},
    "trojan": {"trojan", "xray", "singbox"},
    "reality": {"reality", "xray", "singbox"},
    "shadowsocks": {"shadowsocks", "singbox"},
    "tuic": {"tuic", "singbox"},
    "openvpn": {"openvpn"},
}


def load_env_file(path: str) -> None:
    p = Path(path)
    if not p.exists():
        return
    for raw in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


load_env_file(CONFIG_FILE)

API_HOST = os.getenv("API_HOST", "0.0.0.0")
API_PORT = int(os.getenv("API_PORT", "5000"))
APP_KEY = os.getenv("APP_KEY", "")
TOKEN_DB = os.getenv("TOKEN_DB", "/var/lib/svrcode-token/tokens.db")
ONLINE_DB = os.getenv("ONLINE_DB", "/var/lib/svrcode-token/online.db")
try:
    ONLINE_TTL = max(60, int(os.getenv("ONLINE_TTL", "300")))
except ValueError:
    ONLINE_TTL = 300

# -----------------------------------------------------------------------------
# Canal de actualización de servidores por el MISMO puerto de la API de token.
# La app puede consultar: /api/update/free, /api/update/vip, /config/free.json, /config/vip.json
# -----------------------------------------------------------------------------
UPDATE_ENABLED = os.getenv("UPDATE_ENABLED", "1").strip() not in ("0", "false", "False", "no", "NO")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")
GITHUB_REPO = os.getenv("GITHUB_REPO", "chifladito-store/SERVERMIX")
GITHUB_BRANCH = os.getenv("GITHUB_BRANCH", "main")
FREE_CONFIG_PATH = os.getenv("FREE_CONFIG_PATH", "FreeMode/Config.json")
VIP_CONFIG_PATH = os.getenv("VIP_CONFIG_PATH", "VipMode/Config.mvgl.json")
UPDATE_CACHE_DIR = os.getenv("UPDATE_CACHE_DIR", "/var/lib/svrcode-token/update-cache")
GIT_CACHE_DIR = os.getenv("GIT_CACHE_DIR", "/var/lib/svrcode-token/git-cache")
GIT_REPO_URL = os.getenv("GIT_REPO_URL", "")
GIT_SYNC_ENABLED = os.getenv("GIT_SYNC_ENABLED", "1").strip() not in ("0", "false", "False", "no", "NO")
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "")
try:
    UPDATE_SYNC_INTERVAL = max(3, int(os.getenv("UPDATE_SYNC_INTERVAL", "5")))
except ValueError:
    UPDATE_SYNC_INTERVAL = 5



def normalize_proto(proto: str) -> str:
    p = str(proto or "").strip().lower().replace(" ", "")
    return ALIASES.get(p, p)


def protocol_allowed(allowed_proto: str, requested_proto: str) -> bool:
    allowed = normalize_proto(allowed_proto or "all")
    requested = normalize_proto(requested_proto)
    if allowed == requested:
        return True
    allowed_set = PROTOCOL_GROUPS.get(allowed, {allowed})
    return requested in allowed_set


def parse_db() -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    db = Path(TOKEN_DB)
    if not db.exists():
        return rows
    for raw in db.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not raw.strip() or "|" not in raw:
            continue
        parts = raw.split("|")
        while len(parts) < 8:
            parts.append("")
        token, name, proto, created, expires, status, max_devices, devices = parts[:8]
        rows.append({
            "token": token,
            "name": name,
            "proto": normalize_proto(proto or "all"),
            "created": created,
            "expires": expires,
            "status": status or "active",
            "max_devices": max_devices or "1",
            "devices": devices,
        })
    return rows


def write_db(rows: List[Dict[str, str]]) -> None:
    db = Path(TOKEN_DB)
    db.parent.mkdir(parents=True, exist_ok=True)
    data = []
    for r in rows:
        data.append("|".join([
            r.get("token", ""),
            r.get("name", ""),
            normalize_proto(r.get("proto", "all")),
            r.get("created", ""),
            r.get("expires", ""),
            r.get("status", ""),
            r.get("max_devices", "1"),
            r.get("devices", ""),
        ]))
    db.write_text("\n".join(data) + ("\n" if data else ""), encoding="utf-8")
    try:
        os.chmod(db, 0o600)
    except PermissionError:
        pass



def clean_field(value: object, limit: int = 160) -> str:
    text = str(value or "").replace("|", "-").replace("\r", " ").replace("\n", " ").strip()
    return text[:limit]


def parse_online_db(prune: bool = True) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []
    db = Path(ONLINE_DB)
    if not db.exists():
        return rows
    now = int(time.time())
    changed = False
    for raw in db.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not raw.strip() or "|" not in raw:
            continue
        parts = raw.split("|")
        while len(parts) < 7:
            parts.append("")
        token, name, proto, device_id, ip, last_seen, user_agent = parts[:7]
        try:
            last = int(last_seen or "0")
        except ValueError:
            last = 0
        if prune and (last <= 0 or now - last > ONLINE_TTL):
            changed = True
            continue
        rows.append({
            "token": token,
            "name": name,
            "proto": normalize_proto(proto),
            "device_id": device_id,
            "ip": ip,
            "last_seen": last,
            "age_seconds": max(0, now - last) if last else None,
            "user_agent": user_agent,
        })
    if prune and changed:
        write_online_db(rows)
    return rows


def write_online_db(rows: List[Dict[str, object]]) -> None:
    db = Path(ONLINE_DB)
    db.parent.mkdir(parents=True, exist_ok=True)
    data = []
    for r in rows:
        data.append("|".join([
            clean_field(r.get("token", ""), 80),
            clean_field(r.get("name", ""), 80),
            normalize_proto(clean_field(r.get("proto", ""), 40)),
            clean_field(r.get("device_id", ""), 120),
            clean_field(r.get("ip", ""), 80),
            str(r.get("last_seen", "0") or "0"),
            clean_field(r.get("user_agent", ""), 180),
        ]))
    db.write_text("\n".join(data) + ("\n" if data else ""), encoding="utf-8")
    try:
        os.chmod(db, 0o600)
    except PermissionError:
        pass


def register_online(info: Dict[str, object], device_id: str, proto: str, ip: str, user_agent: str) -> Dict[str, object]:
    now = int(time.time())
    token = clean_field(info.get("token_id", ""), 80)
    name = clean_field(info.get("user", ""), 80)
    requested_proto = normalize_proto(proto or str(info.get("requested_proto", "")))
    device = clean_field(device_id or f"ip:{ip}", 120)
    rows = parse_online_db(prune=True)
    replaced = False
    for row in rows:
        if row.get("token") == token and row.get("device_id") == device and row.get("proto") == requested_proto:
            row.update({
                "name": name,
                "ip": clean_field(ip, 80),
                "last_seen": now,
                "user_agent": clean_field(user_agent, 180),
            })
            replaced = True
            break
    if not replaced:
        rows.append({
            "token": token,
            "name": name,
            "proto": requested_proto,
            "device_id": device,
            "ip": clean_field(ip, 80),
            "last_seen": now,
            "user_agent": clean_field(user_agent, 180),
        })
    write_online_db(rows)
    return {"online_count": len(rows), "online_ttl": ONLINE_TTL}


def check_user_online(token: str, device_id: str = "") -> Dict[str, object]:
    token = clean_field(token, 80)
    device_id = clean_field(device_id, 120)
    rows = parse_online_db(prune=True)
    matches = []
    for row in rows:
        if row.get("token") != token:
            continue
        if device_id and row.get("device_id") != device_id:
            continue
        public = dict(row)
        if public.get("token"):
            public["token_mask"] = str(public["token"])[:6] + "..." + str(public["token"])[-4:]
            public.pop("token", None)
        matches.append(public)
    return {"online": bool(matches), "count": len(matches), "matches": matches, "online_ttl": ONLINE_TTL}


def disconnect_online(token: str, device_id: str = "", proto: str = "") -> Dict[str, object]:
    token = clean_field(token, 80)
    device_id = clean_field(device_id, 120)
    proto = normalize_proto(proto)
    rows = parse_online_db(prune=True)
    kept = []
    removed = 0
    for row in rows:
        same_token = row.get("token") == token
        same_device = (not device_id) or row.get("device_id") == device_id
        same_proto = (not proto) or row.get("proto") == proto
        if same_token and same_device and same_proto:
            removed += 1
        else:
            kept.append(row)
    write_online_db(kept)
    return {"removed": removed, "online_count": len(kept)}


def validate_token(token: str, proto: str, device_id: str) -> Tuple[bool, Dict[str, object]]:
    now = int(time.time())
    requested_proto = normalize_proto(proto)
    rows = parse_db()

    if requested_proto not in CANONICAL_PROTOCOLS:
        return False, {"reason": "proto_unknown", "requested_proto": requested_proto, "protocols": CANONICAL_PROTOCOLS}

    for row in rows:
        if row["token"] != token:
            continue

        if row.get("status") != "active":
            return False, {"reason": "token_disabled", "user": row.get("name", "")}

        try:
            expires = int(row.get("expires", "0"))
        except ValueError:
            expires = 0
        if expires and expires < now:
            return False, {"reason": "token_expired", "user": row.get("name", ""), "expires": expires}

        allowed_proto = normalize_proto(row.get("proto", "all"))
        if not protocol_allowed(allowed_proto, requested_proto):
            return False, {
                "reason": "proto_not_allowed",
                "allowed_proto": allowed_proto,
                "requested_proto": requested_proto,
            }

        max_devices = 1
        try:
            max_devices = max(1, int(row.get("max_devices", "1")))
        except ValueError:
            max_devices = 1

        devices = [d for d in row.get("devices", "").split(",") if d]
        if device_id:
            if device_id not in devices:
                if len(devices) >= max_devices:
                    return False, {
                        "reason": "device_limit",
                        "max_devices": max_devices,
                        "used_devices": len(devices),
                    }
                devices.append(device_id)
                row["devices"] = ",".join(devices)
                write_db(rows)

        return True, {
            "reason": "ok",
            "user": row.get("name", ""),
            "allowed_proto": allowed_proto,
            "requested_proto": requested_proto,
            "expires": expires,
            "max_devices": max_devices,
            "used_devices": len(devices),
            "token_id": token,
        }

    return False, {"reason": "token_not_found"}


def ensure_update_cache() -> None:
    Path(UPDATE_CACHE_DIR).mkdir(parents=True, exist_ok=True)


def update_mode_path(mode: str) -> str:
    return VIP_CONFIG_PATH if mode == "vip" else FREE_CONFIG_PATH


def update_config_file(mode: str) -> Path:
    return Path(UPDATE_CACHE_DIR) / f"{mode}.json"


def update_meta_file(mode: str) -> Path:
    return Path(UPDATE_CACHE_DIR) / f"{mode}.meta.json"


def read_update_meta(mode: str) -> Dict[str, object]:
    try:
        return json.loads(update_meta_file(mode).read_text(encoding="utf-8"))
    except Exception:
        return {}


def update_meta_stale(meta: Dict[str, object]) -> bool:
    try:
        if not meta:
            return True
        updated = int(meta.get("updated_at", 0) or 0)
        # Se permite margen corto. Así /api/update y /config refrescan sin esperar admin/sync.
        return updated <= 0 or (time.time() - updated) >= max(2, UPDATE_SYNC_INTERVAL)
    except Exception:
        return True


def find_version_in_json(obj: object, depth: int = 0) -> str:
    if depth > 6 or not isinstance(obj, dict):
        return ""
    keys = [
        "Version", "version", "VERSION",
        "FreeVersion", "freeVersion", "FREEVersion",
        "VIPversion", "VIPVersion", "VipVersion", "vipVersion",
        "ConfigVersion", "configVersion",
        "ServerVersion", "serverVersion",
        "versionName", "version_code", "versionCode",
    ]
    for key in keys:
        value = obj.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    for value in obj.values():
        found = find_version_in_json(value, depth + 1)
        if found:
            return found
    return ""


def extract_update_version(text: str, sha: str = "") -> str:
    try:
        data = json.loads(text)
        found = find_version_in_json(data)
        if found:
            return found
    except Exception:
        pass
    # respaldo simple para JSON cifrado o estructuras no estándar
    for key in ("Version", "version", "VIPversion", "VIPVersion", "FreeVersion", "ConfigVersion", "ServerVersion", "versionName"):
        token = '"' + key + '"'
        pos = text.find(token)
        if pos >= 0:
            fragment = text[pos:pos + 120]
            for sep in (':"', ': "'):
                if sep in fragment:
                    value = fragment.split(sep, 1)[1].split('"', 1)[0].strip()
                    if value:
                        return value
    return sha[:8] if sha else "0"


def git_repo_dir() -> Path:
    repo_name = GITHUB_REPO.strip().strip('/').split('/')[-1] or 'SERVERMIX'
    return Path(GIT_CACHE_DIR) / repo_name


def git_remote_url() -> str:
    if GIT_REPO_URL.strip():
        return GIT_REPO_URL.strip()
    repo = GITHUB_REPO.strip().strip('/')
    token = GITHUB_TOKEN.strip()
    if token and 'COLOCA' not in token.upper():
        safe_token = urllib.parse.quote(token, safe='')
        return f"https://x-access-token:{safe_token}@github.com/{repo}.git"
    return f"https://github.com/{repo}.git"


def run_cmd(cmd, timeout=25) -> str:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if p.returncode != 0:
        err = (p.stderr or p.stdout or '').strip()
        raise RuntimeError(err[:500] or f"comando fallo: {' '.join(cmd)}")
    return (p.stdout or '').strip()


def ensure_git_cache() -> Path:
    repo_dir = git_repo_dir()
    Path(GIT_CACHE_DIR).mkdir(parents=True, exist_ok=True)
    remote = git_remote_url()
    if not (repo_dir / '.git').exists():
        if repo_dir.exists():
            # carpeta incompleta: limpiar solo cache local del repositorio
            import shutil
            shutil.rmtree(repo_dir, ignore_errors=True)
        run_cmd(['git', 'clone', '--depth', '1', '--branch', GITHUB_BRANCH, remote, str(repo_dir)], timeout=45)
    else:
        run_cmd(['git', '-C', str(repo_dir), 'remote', 'set-url', 'origin', remote], timeout=10)
        run_cmd(['git', '-C', str(repo_dir), 'fetch', '--depth', '1', 'origin', GITHUB_BRANCH], timeout=35)
        run_cmd(['git', '-C', str(repo_dir), 'reset', '--hard', f'origin/{GITHUB_BRANCH}'], timeout=20)
    return repo_dir


def fetch_git_config(mode: str) -> Dict[str, object]:
    repo_dir = ensure_git_cache()
    repo_path = update_mode_path(mode)
    file_path = repo_dir / repo_path
    if not file_path.exists():
        raise RuntimeError(f"archivo no existe en git: {repo_path}")
    text = file_path.read_text(encoding='utf-8', errors='ignore')
    content_hash = hashlib.sha256(text.encode('utf-8', errors='ignore')).hexdigest()
    try:
        commit = run_cmd(['git', '-C', str(repo_dir), 'rev-parse', 'HEAD'], timeout=10)
    except Exception:
        commit = ''
    version = extract_update_version(text, content_hash)
    return {
        'mode': mode,
        'text': text,
        'version': version,
        'sha': commit or content_hash,
        'content_hash': content_hash,
        'source_path': repo_path,
        'size': len(text.encode('utf-8', errors='ignore')),
    }


def github_api_url(repo_path: str) -> str:
    encoded = "/".join(urllib.parse.quote(part, safe="") for part in repo_path.split("/"))
    repo = GITHUB_REPO.strip().strip("/")
    return f"https://api.github.com/repos/{repo}/contents/{encoded}?ref={urllib.parse.quote(GITHUB_BRANCH)}"


def github_request_headers() -> Dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "SVRCODE-TOKEN-UPDATE-API",
        "X-GitHub-Api-Version": "2022-11-28",
        "Cache-Control": "no-cache",
    }
    token = GITHUB_TOKEN.strip()
    if token and "COLOCA" not in token.upper():
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_github_config(mode: str) -> Dict[str, object]:
    if GIT_SYNC_ENABLED:
        try:
            return fetch_git_config(mode)
        except Exception as exc:
            print(f"GIT SYNC ERROR {mode.upper()}: {exc}", flush=True)
            # Respaldo API si git falla.
    repo_path = update_mode_path(mode)
    req = urllib.request.Request(github_api_url(repo_path), headers=github_request_headers(), method="GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8", errors="ignore")
            payload = json.loads(raw)
    except Exception as exc:
        raise RuntimeError(f"GitHub API fallo para {mode}: {exc}")

    content = str(payload.get("content", "")).replace("\n", "")
    encoding = str(payload.get("encoding", ""))
    sha = str(payload.get("sha", ""))
    if not content or encoding.lower() != "base64":
        raise RuntimeError(f"GitHub API no devolvio content base64 valido para {mode}")

    text = base64.b64decode(content).decode("utf-8", errors="ignore")
    content_hash = hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()
    version = extract_update_version(text, sha)
    return {
        "mode": mode,
        "text": text,
        "version": version,
        "sha": sha,
        "content_hash": content_hash,
        "source_path": repo_path,
        "size": len(text.encode("utf-8", errors="ignore")),
    }


def sync_update_mode(mode: str) -> Dict[str, object]:
    if mode not in ("free", "vip"):
        raise ValueError("modo invalido")
    ensure_update_cache()
    remote = fetch_github_config(mode)
    old = read_update_meta(mode)
    changed = (
        not old or
        old.get("sha") != remote.get("sha") or
        old.get("version") != remote.get("version") or
        old.get("content_hash") != remote.get("content_hash")
    )
    if changed:
        update_config_file(mode).write_text(str(remote["text"]), encoding="utf-8")
        meta = {
            "ok": True,
            "mode": mode.upper(),
            "version": remote.get("version", "0"),
            "sha": remote.get("sha", ""),
            "content_hash": remote.get("content_hash", ""),
            "size": remote.get("size", 0),
            "source_path": remote.get("source_path", ""),
            "updated_at": int(time.time()),
            "config_url": f"/config/{mode}.json",
        }
        update_meta_file(mode).write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"UPDATE {mode.upper()} aplicado version={meta['version']} sha={str(meta['sha'])[:8]}", flush=True)
        return meta
    return old


def sync_update_all(reason: str = "interval") -> None:
    if not UPDATE_ENABLED:
        return
    for mode in ("free", "vip"):
        try:
            sync_update_mode(mode)
        except Exception as exc:
            print(f"UPDATE ERROR {mode.upper()} {reason}: {exc}", flush=True)


def update_sync_loop() -> None:
    # Primer sync al iniciar el servicio.
    sync_update_all("startup")
    while True:
        time.sleep(UPDATE_SYNC_INTERVAL)
        sync_update_all("interval")


def valid_webhook_signature(raw_body: bytes, signature: str) -> bool:
    if not WEBHOOK_SECRET:
        return True
    if not signature:
        return False
    expected = "sha256=" + hmac.new(WEBHOOK_SECRET.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    try:
        a = signature.encode("utf-8")
        b = expected.encode("utf-8")
        return len(a) == len(b) and hmac.compare_digest(a, b)
    except Exception:
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = f"SVRCODETokenAPI/{VERSION}"

    def log_message(self, fmt: str, *args) -> None:
        print("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), fmt % args), flush=True)

    def send_json(self, status_code: int, payload: Dict[str, object]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def app_key_valid(self) -> bool:
        try:
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            key = self.headers.get("X-App-Key", "") or (query.get("key", [""])[0])
            return bool(APP_KEY) and key == APP_KEY
        except Exception:
            return bool(APP_KEY) and self.headers.get("X-App-Key", "") == APP_KEY

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        clean_path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if clean_path == "/health":
            self.send_json(200, {
                "ok": True,
                "service": "svrcode-token-api",
                "version": VERSION,
                "port": API_PORT,
                "update_enabled": UPDATE_ENABLED,
                "git_sync_enabled": GIT_SYNC_ENABLED,
                "git_cache_dir": GIT_CACHE_DIR,
            })
            return

        if clean_path in ("/api/update/free", "/api/update/vip"):
            mode = "vip" if clean_path.endswith("/vip") else "free"
            meta = read_update_meta(mode)
            force_sync = (query.get("force", [""])[0] in ("1", "true", "yes", "si"))
            if force_sync or update_meta_stale(meta):
                try:
                    meta = sync_update_mode(mode)
                except Exception as exc:
                    if not meta:
                        self.send_json(503, {"ok": False, "mode": mode.upper(), "reason": "update_not_ready", "error": str(exc)})
                        return
                    meta["sync_warning"] = str(exc)
            self.send_json(200, meta)
            return

        if clean_path in ("/config/free.json", "/config/vip.json"):
            mode = "vip" if clean_path.endswith("vip.json") else "free"
            file_path = update_config_file(mode)
            meta = read_update_meta(mode)
            force_sync = (query.get("force", [""])[0] in ("1", "true", "yes", "si"))
            if force_sync or (not file_path.exists()) or update_meta_stale(meta):
                try:
                    sync_update_mode(mode)
                except Exception as exc:
                    if not file_path.exists():
                        self.send_json(503, {"ok": False, "reason": "config_not_ready", "error": str(exc)})
                        return
            if not file_path.exists():
                self.send_json(404, {"ok": False, "reason": "config_not_found"})
                return
            data = file_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if clean_path == "/api/admin/sync":
            key = self.headers.get("X-App-Key", "") or (query.get("key", [""])[0])
            if not APP_KEY or key != APP_KEY:
                self.send_json(401, {"ok": False, "reason": "invalid_app_key"})
                return
            sync_update_all("manual")
            self.send_json(200, {"ok": True, "free": read_update_meta("free"), "vip": read_update_meta("vip")})
            return

        if clean_path == "/protocols":
            if not self.app_key_valid():
                self.send_json(401, {"ok": False, "reason": "invalid_app_key"})
                return
            self.send_json(200, {"ok": True, "protocols": CANONICAL_PROTOCOLS, "aliases": ALIASES})
            return
        if clean_path in ("/online", "/online-users"):
            if not self.app_key_valid():
                self.send_json(401, {"ok": False, "reason": "invalid_app_key"})
                return
            online = parse_online_db(prune=True)
            public = []
            for row in online:
                item = dict(row)
                if item.get("token"):
                    item["token_mask"] = str(item["token"])[:6] + "..." + str(item["token"])[-4:]
                    item.pop("token", None)
                public.append(item)
            self.send_json(200, {"ok": True, "count": len(public), "online_ttl": ONLINE_TTL, "online": public})
            return
        self.send_json(404, {"ok": False, "reason": "not_found"})

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        clean_path = parsed.path

        if clean_path == "/api/github/webhook":
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw_body = self.rfile.read(length)
            signature = self.headers.get("X-Hub-Signature-256", "")
            if not valid_webhook_signature(raw_body, signature):
                self.send_json(401, {"ok": False, "reason": "invalid_webhook_signature"})
                return
            self.send_json(200, {"ok": True, "received": True})
            threading.Thread(target=sync_update_all, args=("webhook",), daemon=True).start()
            return

        if clean_path not in ("/validate", "/heartbeat", "/check-user", "/disconnect"):
            self.send_json(404, {"ok": False, "reason": "not_found"})
            return

        if not APP_KEY:
            self.send_json(500, {"ok": False, "reason": "app_key_not_configured"})
            return

        if self.headers.get("X-App-Key", "") != APP_KEY:
            self.send_json(401, {"ok": False, "reason": "invalid_app_key"})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", errors="ignore")
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self.send_json(400, {"ok": False, "reason": "invalid_json"})
            return

        token = str(body.get("token", body.get("token_id", ""))).strip()
        proto = str(body.get("proto", body.get("protocol", ""))).strip().lower()
        device_id = str(body.get("device_id", body.get("uuid", ""))).strip()

        if clean_path == "/check-user":
            if not token:
                self.send_json(400, {"ok": False, "reason": "token_required"})
                return
            self.send_json(200, {"ok": True, **check_user_online(token, device_id)})
            return

        if clean_path == "/disconnect":
            if not token:
                self.send_json(400, {"ok": False, "reason": "token_required"})
                return
            self.send_json(200, {"ok": True, **disconnect_online(token, device_id, proto)})
            return

        if not token or not proto:
            self.send_json(400, {"ok": False, "reason": "token_and_proto_required"})
            return

        ok, info = validate_token(token, proto, device_id)
        payload = {"ok": ok, **info}
        if ok:
            payload.update(register_online(
                info,
                device_id,
                proto,
                self.client_address[0] if self.client_address else "",
                self.headers.get("User-Agent", ""),
            ))
            if clean_path == "/heartbeat":
                payload["reason"] = "heartbeat_ok"
        self.send_json(200 if ok else 403, payload)


def main() -> None:
    if UPDATE_ENABLED:
        threading.Thread(target=update_sync_loop, daemon=True).start()
    httpd = ThreadingHTTPServer((API_HOST, API_PORT), Handler)
    print(f"SVRCODE Token API v{VERSION} escuchando en {API_HOST}:{API_PORT}", flush=True)
    if UPDATE_ENABLED:
        print(f"Canal update activo en el mismo puerto: /api/update/free /api/update/vip", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
