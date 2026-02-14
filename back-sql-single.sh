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
mkdir -p "$DIR_DESTINO"

# 4. Definir bases a excluir
EXCLUDE_DB="information_schema|performance_schema|mysql|sys"

# 5. Obtener lista de bases válidas
# Nota: Usamos las variables cargadas ($MYSQL_USER, etc.)
DATABASES=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
  -N -e "SHOW DATABASES;" | grep -Ev "$EXCLUDE_DB")

# 6. Bucle para recorrer cada base de datos
for DB in $DATABASES; do
  
  # NUEVO FORMATO DE NOMBRE SOLICITADO: ${DB}-back_${FECHA}.sql.gz
  NOMBRE_ARCHIVO="${DIR_DESTINO}/${DB}-back_${FECHA}.sql.gz"

  echo "Iniciando backup de: $DB en $NOMBRE_ARCHIVO"

  # Ejecutar mysqldump
  # Elimina 'sudo' si vas a correr este script como root directamente
  sudo mysqldump \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
    --databases "$DB" \
    --routines \
    --events \
    --triggers \
    --single-transaction \
    --add-drop-database \
    --set-gtid-purged=OFF \
  | gzip -9 > "$NOMBRE_ARCHIVO"

  # Verificación simple de éxito
  if [ $? -eq 0 ]; then
     echo " [OK] Backup completado: $NOMBRE_ARCHIVO"
  else
     echo " [ERROR] Falló el backup de: $DB"
  fi

done

echo "Proceso finalizado."
