#!/bin/bash

# 1. Cargar el archivo .env
# Buscamos el archivo .env en el mismo directorio del script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    # Exportamos las variables del archivo .env
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "ERROR: No se encontró el archivo .env en $SCRIPT_DIR"
    exit 1
fi

# Timestamp
FECHA=$(date +"$FECHA_FORMAT")

# Archivo de salida
BACKUP="/mnt/backup/mysql/back-no-data_${FECHA}.sql.gz"

# Obtener lista de bases válidas
DATABASES=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
  -N -e "SHOW DATABASES;" | grep -Ev "$EXCLUDE_DB")

# Dump solo estructura + objetos
sudo mysqldump \
  -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
  --databases $DATABASES \
  --no-data \
  --routines \
  --events \
  --triggers \
  --single-transaction \
  --add-drop-database \
  --set-gtid-purged=OFF \
| gzip -9 > "$BACKUP"
