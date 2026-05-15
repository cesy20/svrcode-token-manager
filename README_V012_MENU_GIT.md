# SVRCODE Token Manager v0.14

Incluye menú visual mejorado para tokens y un submenú Git/VPS para configurar el canal de actualización de servidores FREE/VIP en el mismo puerto del token manager.

## Menú principal
```bash
sudo svrtoken menu
```

Nueva opción:
```text
21) 🚀 Git / Actualización de servidores
```

## Submenú Git directo
```bash
sudo svrtoken git-menu
```

Opciones incluidas:
- 👁️ Ver configuración Git / endpoints
- ⚙️ Editar datos de GitHub
- 🔄 Sincronizar ahora FREE/VIP
- 🧪 Probar endpoints locales
- 🔔 Ver datos para Webhook
- ♻️ Reiniciar API

## Instalación
```bash
cd /root
apt update -y && apt install -y unzip curl
unzip -o svrcode-token-manager-v013-menu-git.zip
cd svrcode-token-manager-v013-menu-git
sudo bash install.sh 5000
sudo svrtoken menu
```

## Endpoints para la app
```text
http://IP_DE_TU_VPS:5000/api/update/free
http://IP_DE_TU_VPS:5000/api/update/vip
http://IP_DE_TU_VPS:5000/config/free.json
http://IP_DE_TU_VPS:5000/config/vip.json
```

## Configuración GitHub
```bash
sudo svrtoken git-edit
sudo svrtoken git-sync
sudo svrtoken git-test
```

El token de GitHub se guarda en `/etc/svrcode-token/config.env` y no se muestra completo en el menú.
