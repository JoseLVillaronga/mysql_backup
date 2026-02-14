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

# 2. Calcular la fecha actual usando el formato cargado
FECHA=$(date +"$FECHA_FORMAT")

# 3. Asegurar que el directorio de destino existe
mkdir -p "$DIR_DESTINO_INC"

# 4. Definir bases a excluir
EXCLUDE_DB="information_schema|performance_schema|mysql|sys"

# 5. Obtener lista de bases válidas
# Nota: Usamos las variables cargadas ($MYSQL_USER, etc.)
DATABASES=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
  -N -e "SHOW DATABASES;" | grep -Ev "$EXCLUDE_DB")

# 6. Bucle para recorrer cada base de datos
for DB in $DATABASES; do

  # Nombre del archivo sin compresión (.sql)
  # Nota: En tu snippet quitaste la variable de fecha del nombre, así lo he dejado.
  NOMBRE_ARCHIVO="${DIR_DESTINO_INC}/${DB}-back.sql"

  echo "Iniciando backup de: $DB en $NOMBRE_ARCHIVO"

  # Ejecutar mysqldump SIN compresión y SALIDA SILENCIOSA
  # - Se elimina '| gzip -9'
  # - Se añade '> "$NOMBRE_ARCHIVO" 2> /dev/null'
  sudo mysqldump \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
    --databases "$DB" \
    --routines \
    --events \
    --triggers \
    --master-data=2 \
    --single-transaction \
    --add-drop-database \
    --set-gtid-purged=OFF \
  > "$NOMBRE_ARCHIVO" 2> /dev/null

  # Verificación simple de éxito
  if [ $? -eq 0 ]; then
     echo " [OK] Backup completado: $NOMBRE_ARCHIVO"
  else
     echo " [ERROR] Falló el backup de: $DB"
  fi

done

echo "Proceso finalizado."
