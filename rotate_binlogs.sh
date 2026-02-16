#!/bin/bash

# 1. Cargar el archivo .env
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "ERROR: No se encontro el archivo .env"
    exit 1
fi

# 2. Configurar rutas
# Si no definiste BINLOG_BACKUP_DIR en el .env, usa este por defecto
BINLOG_BACKUP_DIR="${BINLOG_BACKUP_DIR:-/mnt/backup/mysql/binlogs}"
mkdir -p "$BINLOG_BACKUP_DIR"

# 3. Obtener el directorio de datos de MySQL \(donde vive el binlog\)
MYSQL_DATADIR=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW VARIABLES LIKE 'datadir';" | awk '{print $2}')

if [ -z "$MYSQL_DATADIR" ]; then
    echo "ERROR: No se pudo determinar el datadir de MySQL."
    exit 1
fi

# --- NUEVO: DETECTAR DINAMICAMENTE EL PREFIJO ---
# Le preguntamos a MySQL cual es el nombre base de los archivos de log
# Ejemplo de respuesta: /var/lib/mysql/mysql-bin o /var/lib/mysql/binlog
BINLOG_BASENAME=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW VARIABLES LIKE 'log_bin_basename';" | awk '{print $2}')

if [ -z "$BINLOG_BASENAME" ]; then
    # Fallback por seguridad si falla la deteccion
    BINLOG_PREFIX="mysql-bin"
    echo "AVISO: No se pudo detectar el prefijo del binlog, usando por defecto: $BINLOG_PREFIX"
else
    # Extraemos solo el nombre del archivo \(basename\) de la ruta completa
    BINLOG_PREFIX=$(basename "$BINLOG_BASENAME")
    echo "Prefijo de Binlog detectado: $BINLOG_PREFIX"
fi

# 4. Forzar la rotacion de logs
# Esto cierra el archivo actual y abre uno nuevo
echo "Rotando logs binarios..."
sudo mysqladmin -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" flush-logs 2> /dev/null

if [ $? -ne 0 ]; then
    echo "ERROR: Fallo el comando 'flush-logs'. Verifica credenciales."
    exit 1
fi

# 5. Identificar cual es el archivo de log ACTUAL \(el nuevo que se acaba de abrir\)
# El formato suele ser PREFIJO.00000X
CURRENT_LOG=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW MASTER STATUS;" | awk '{print $1}')

if [ -z "$CURRENT_LOG" ]; then
    echo "ERROR: No se pudo obtener el estado del Master."
    exit 1
fi

# He escapado los parentesis con \( y \) para evitar el error de sintaxis
echo "Log actual activo: $CURRENT_LOG \(No se copiara\)"

# 6. Copiar los archivos de logs al destino
# MODIFICADO: Usamos la variable $BINLOG_PREFIX en lugar de "mysql-bin" harcodeado
for LOG_FILE in "$MYSQL_DATADIR"${BINLOG_PREFIX}.*; do

    # Obtenemos solo el nombre del archivo
    FILENAME=$(basename "$LOG_FILE")

    # Solo copiamos si NO es el archivo activo actual
    # Y si es un archivo regular \(no el index\)
    if [ "$FILENAME" != "$CURRENT_LOG" ] && [ -f "$LOG_FILE" ]; then

        # Usamos 'cp -u' para no re-copiar archivos que ya tengamos y no han cambiado
        # Usamos 'sudo' porque el datadir de mysql suele ser propiedad de root/mysql
        sudo cp -u "$LOG_FILE" "$BINLOG_BACKUP_DIR/"

        if [ $? -eq 0 ]; then
            echo "Copiado/Actualizado: $FILENAME"
        fi
    fi
done

# MODIFICADO: Borrado usando el prefijo dinamico
sudo find "$BINLOG_BACKUP_DIR" -type f -name "${BINLOG_PREFIX}.*" -mtime +0 -delete

echo "Rotacion y backup de binlogs finalizado."
