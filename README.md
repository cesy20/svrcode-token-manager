# svrcode-token-manager v0.10

Administrador de clientes y token ID para validar acceso desde una app VPN por API local en la VPS.

## Comando principal

Después de instalar, para entrar al menú usa:

```bash
sudo svrtoken
```

También funciona:

```bash
sudo svrtoken menu
```

## Instalación rápida desde GitHub

Usa este comando cuando el repo ya tenga esta versión subida:

```bash
apt update -y && apt install -y git curl python3 iproute2 openssl ca-certificates && rm -rf /root/svrcode-token-manager && git clone https://github.com/cesy20/svrcode-token-manager.git /root/svrcode-token-manager && cd /root/svrcode-token-manager && chmod +x install.sh svrcode-token.sh uninstall.sh && bash install.sh 5000
```

## Instalación desde ZIP

```bash
unzip svrcode-token-manager-v10-token-id-obligatorio.zip
cd svrcode-token-manager-v10-token-id-obligatorio
chmod +x install.sh svrcode-token.sh uninstall.sh
bash install.sh 5000
```

## Comandos principales

```bash
sudo svrtoken
sudo svrtoken add cliente1 all 30 1 MI_TOKEN_ID
sudo svrtoken add cliente_xray xray 30 1 TOKEN_XRAY
sudo svrtoken add cliente_singbox singbox 30 1 TOKEN_SINGBOX
sudo svrtoken add cliente_slowdns slowdns 7 1 TOKEN_SLOWDNS
sudo svrtoken list
sudo svrtoken online
sudo svrtoken check-user TOKEN_ID
sudo svrtoken api-config json
```

## Protocolos aceptados

- all
- ssh
- ssh-ws
- ssl
- dropbear
- slowdns / slodns
- openvpn
- udp
- udp-custom
- hysteria / histeria
- hysteria2
- v2ray
- xray
- singbox / sinbox
- vless
- vmess
- trojan
- reality
- shadowsocks
- tuic

## API para la app

Flujo recomendado:

```text
POST /validate      valida token y registra usuario online
POST /heartbeat     mantiene vivo al usuario online
POST /check-user    consulta si token o device está online
POST /disconnect    elimina usuario online al desconectar
GET  /online        lista usuarios online
```

## Desinstalar

Sin borrar tokens/configuración:

```bash
sudo bash /opt/svrcode-token-manager/uninstall.sh
```

Borrar todo:

```bash
sudo bash /opt/svrcode-token-manager/uninstall.sh --purge
```


## Nuevo en v0.10

- Al crear cliente desde el menu `svrtoken`, ahora pide solamente `Token ID`.
- El Token ID es obligatorio y debe escribirse manualmente.
- Se elimina el modo `AUTO`: ya no genera token automatico.
- Tambien se puede crear desde comando directo:

```bash
sudo svrtoken add cliente1 all 60 1 MI_TOKEN_ID
```



## Nuevo en v0.11 - Canal de actualización por el mismo puerto

Este paquete mantiene la API de token y agrega endpoints de actualización en el mismo puerto, por ejemplo 5000:

```bash
GET /api/update/free
GET /api/update/vip
GET /config/free.json
GET /config/vip.json
GET /api/admin/sync    # requiere X-App-Key o ?key=APP_KEY
POST /api/github/webhook
```

La app puede usar el mismo host y puerto del token manager, sin abrir 80/443 ni instalar Nginx.

Variables nuevas en `/etc/svrcode-token/config.env`:

```env
UPDATE_ENABLED=1
GITHUB_TOKEN=TU_TOKEN_FINE_GRAINED_CONTENTS_READ
GITHUB_REPO=chifladito-store/SERVERMIX
GITHUB_BRANCH=main
FREE_CONFIG_PATH=FreeMode/Config.json
VIP_CONFIG_PATH=VipMode/Config.mvgl.json
UPDATE_CACHE_DIR=/var/lib/svrcode-token/update-cache
UPDATE_SYNC_INTERVAL=5
WEBHOOK_SECRET=opcional
```
