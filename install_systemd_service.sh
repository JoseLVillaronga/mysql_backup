#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mysql-backup-web"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="$(id -un)"
APP_GROUP="$(id -gn)"
VENV_BIN_DIR="${SCRIPT_DIR}/venv/bin"
GUNICORN_BIN="${VENV_BIN_DIR}/gunicorn"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ ! -x "${GUNICORN_BIN}" ]]; then
  echo "ERROR: No se encontró gunicorn ejecutable en: ${GUNICORN_BIN}"
  echo "Instalá dependencias y/o verificá el venv antes de continuar."
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/app.py" ]]; then
  echo "ERROR: No se encontró app.py en ${SCRIPT_DIR}"
  exit 1
fi

echo "Instalando servicio systemd '${SERVICE_NAME}'..."
echo "- Proyecto: ${SCRIPT_DIR}"
echo "- Usuario: ${APP_USER}"
echo "- Grupo: ${APP_GROUP}"

if getent group mysql >/dev/null 2>&1; then
  echo "Agregando usuario '${APP_USER}' al grupo 'mysql' para lectura de binlogs..."
  sudo usermod -aG mysql "${APP_USER}"
else
  echo "WARN: No existe el grupo 'mysql'."
  echo "      Crealo o aplicá ACL manual para lectura de binlogs antes de usar PITR."
fi

sudo tee "${SERVICE_PATH}" > /dev/null <<EOF
[Unit]
Description=Flask MySQL Backup Web Interface
After=network.target mysql.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${SCRIPT_DIR}
Environment="PATH=${VENV_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${GUNICORN_BIN} -w 4 -b 0.0.0.0:8200 app:app
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=mixed
TimeoutStopSec=5
PrivateTmp=true
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

echo
echo "Servicio instalado y arrancado."
echo "Comandos útiles:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo "  sudo journalctl -u ${SERVICE_NAME} -f"
