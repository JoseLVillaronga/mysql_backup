#!/bin/bash

# 1. Cargar el archivo .env
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "ERROR: No se encontró el archivo .env"
    exit 1
fi

# 2. Configurar rutas
# Si no definiste BINLOG_BACKUP_DIR en el .env, usa este por defecto
BINLOG_BACKUP_DIR="${BINLOG_BACKUP_DIR:-/mnt/backup/mysql/binlogs}"
mkdir -p "$BINLOG_BACKUP_DIR"

# 3. Obtener el directorio de datos de MySQL (donde vive el binlog)
MYSQL_DATADIR=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW VARIABLES LIKE 'datadir';" | awk '{print $2}')

if [ -z "$MYSQL_DATADIR" ]; then
    echo "ERROR: No se pudo determinar el datadir de MySQL."
    exit 1
fi

# 4. Forzar la rotación de logs
# Esto cierra el archivo actual y abre uno nuevo
echo "Rotando logs binarios..."
sudo mysqladmin -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" flush-logs 2> /dev/null

if [ $? -ne 0 ]; then
    echo "ERROR: Falló el comando 'flush-logs'. Verifica credenciales."
    exit 1
fi

# 5. Identificar cuál es el archivo de log ACTUAL (el nuevo que se acaba de abrir)
# El formato suele ser mysql-bin.00000X
CURRENT_LOG=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW MASTER STATUS;" | awk '{print $1}')

if [ -z "$CURRENT_LOG" ]; then
    echo "ERROR: No se pudo obtener el estado del Master."
    exit 1
fi

echo "Log actual activo: $CURRENT_LOG (No se copiará)"

# 6. Copiar los archivos de logs al destino
# Recorremos los archivos binlog en el datadir
for LOG_FILE in "$MYSQL_DATADIR"mysql-bin.*; do
    
    # Obtenemos solo el nombre del archivo
    FILENAME=$(basename "$LOG_FILE")

    # Solo copiamos si NO es el archivo activo actual 
    # Y si es un archivo regular (no el index)
    if [ "$FILENAME" != "$CURRENT_LOG" ] && [ -f "$LOG_FILE" ]; then
        
        # Usamos 'cp -u' para no re-copiar archivos que ya tengamos y no han cambiado
        # Usamos 'sudo' porque el datadir de mysql suele ser propiedad de root/mysql
        sudo cp -u "$LOG_FILE" "$BINLOG_BACKUP_DIR/"
        
        if [ $? -eq 0 ]; then
            echo "Copiado/Actualizado: $FILENAME"
        fi
    fi
done

echo "Rotación y backup de binlogs finalizado."
