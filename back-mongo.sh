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

# Generar nombre de carpeta con fecha y hora (Ej: 2023-10-27_15-30)
FECHA=$(date +"$FECHA_FORMAT")
RUTA_FINAL="${DESTINO}/backup_${FECHA}"

# Crear el directorio si no existe
mkdir -p "${RUTA_FINAL}"

# Ejecutar el backup
# Nota: Usamos -p para que pida contraseña si no la quieres hardcodeada, 
# o ponla directamente --password "$CONTRASENA" si es un script automático.
mongodump --host "$HOST" --port "$PUERTO" \
          --username "$USUARIO" \
          --password "$CONTRASENA" \
          --authenticationDatabase admin \
          --out "$RUTA_FINAL"

# Opcional: Mensaje de éxito
echo "Backup completado en: $RUTA_FINAL"
find $DESTINO -mindepth 1 -maxdepth 1 -type d -mtime +7 -ls
