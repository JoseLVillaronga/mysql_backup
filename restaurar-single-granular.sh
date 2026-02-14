#!/bin/bash

# --- CONFIGURACIÓN Y CARGA DE VARIABLES ---

# Cargar el archivo .env
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "ERROR: No se encontró el archivo .env en $SCRIPT_DIR"
    exit 1
fi

# --- DETECCIÓN AUTOMÁTICA DEL DIRECTORIO DE BINLOGS ---
# En lugar de hardcodear la ruta, preguntamos a MySQL cuál es su 'datadir'.
# Por defecto, los binlogs se guardan ahí.

MYSQL_DATADIR=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
  -N -e "SHOW VARIABLES LIKE 'datadir';" | awk '{print $2}')

# Verificamos que hayamos obtenido una ruta válida
if [ -z "$MYSQL_DATADIR" ]; then
    echo -e "${RED}ERROR CRÍTICO: No se pudo detectar el directorio de datos (datadir) de MySQL.${NC}"
    echo "Verifica que el servicio esté corriendo y que las credenciales son correctas."
    exit 1
fi

# Definimos BINLOG_DIR usando la ruta detectada
BINLOG_DIR="$MYSQL_DATADIR"

echo -e "${GREEN}INFO:${NC} Detectado directorio de Binlogs: $BINLOG_DIR"
echo "---------------------------------------------------"

# Colores para UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo "==================================================="
echo "   RESTAURACIÓN PITR (UNA BASE DE DATOS)         "
echo "==================================================="
echo ""

# --- AVISO SOBRE FORMATO DE LOG ---
# Verificamos el formato de binlog ( ROW vs STATEMENT )
BINLOG_FORMAT=$(sudo mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SELECT @@binlog_format;")
if [ "$BINLOG_FORMAT" == "ROW" ]; then
    echo -e "${YELLOW}ADVERTENCIA: Tu binlog_format es ROW.${NC}"
    echo "El filtro por base de datos puede no funcionar correctamente."
    echo "Se recomienda usar MIXED o STATEMENT para este script."
    echo "---------------------------------------------------"
    read -p "¿Deseas continuar de todos modos? (s/N): " CONTINUE_ROW
    if [[ "$CONTINUE_ROW" != "s" && "$CONTINUE_ROW" != "S" ]]; then
        echo "Cancelado."
        exit 0
    fi
fi

# --- PASO 1: SELECCIONAR BASE DE DATOS ---
echo "[PASO 1] Seleccionando Base de Datos a restaurar..."
echo "---------------------------------------------------"

DATABASES=$(sudo mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
  -N -e "SHOW DATABASES;" | grep -Ev "information_schema|performance_schema|mysql|sys")

select DB in $DATABASES "SALIR"; do
    if [ "$DB" == "SALIR" ]; then
        echo "Operación cancelada."
        exit 0
    elif [ -n "$DB" ]; then
        echo -e "${GREEN}Base seleccionada: $DB${NC}"
        break
    else
        echo "Opción inválida."
    fi
done

# --- PASO 2: RESTAURAR BACKUP COMPLETO ---
FULL_BACKUP="${DIR_DESTINO_INC}/${DB}-back.sql"

if [ ! -f "$FULL_BACKUP" ]; then
    echo -e "${RED}ERROR: No existe el archivo de backup diario: $FULL_BACKUP${NC}"
    exit 1
fi

echo ""
echo "[PASO 2] Restaurando Backup Diario (Full)..."
echo "Archivo: $FULL_BACKUP"
read -p "¿Estás seguro? (s/N): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    exit 0
fi

sudo mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" < "$FULL_BACKUP" 2> /dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Backup completo restaurado.${NC}"
else
    echo -e "${RED}ERROR al restaurar el backup.${NC}"
    exit 1
fi

BACKUP_TIME=$(stat -c %y "$FULL_BACKUP" | cut -d'.' -f1)

# --- PASO 3: SELECCIONAR BINLOGS ---
echo ""
echo "[PASO 3] Selección de Punto de Restauración..."
echo "---------------------------------------------------"
echo "Se aplicarán cambios SOLO para la base de datos '$DB' (si el formato lo permite)."
echo ""

BINLOGS=($(ls -1v "$BINLOG_DIR"/mysql-bin.* 2>/dev/null | grep -v "\.index$"))

if [ ${#BINLOGS[@]} -eq 0 ]; then
    echo "No se encontraron binlogs."
    exit 0
fi

echo "Archivos disponibles:"
for i in "${!BINLOGS[@]}"; do
    FILE="${BINLOGS[$i]}"
    FIRST_EVENT=$(mysqlbinlog --no-defaults "$FILE" 2>/dev/null | grep -m1 "^# [0-9]* [0-9][0-9]:[0-9][0-9]:[0-9][0-9]" | head -1)
    echo "$((i+1))) $(basename $FILE)"
    echo "   -> $FIRST_EVENT"
done

echo ""
read -p "Hasta qué número de archivo aplicar? (0 = solo backup): " CHOICE_INDEX

if [ "$CHOICE_INDEX" -eq 0 ]; then
    echo "Finalizado (Solo backup)."
    exit 0
fi

if ! [[ "$CHOICE_INDEX" =~ ^[0-9]+$ ]] || [ "$CHOICE_INDEX" -gt ${#BINLOGS[@]} ]; then
    echo -e "${RED}Opción inválida.${NC}"
    exit 1
fi

TARGET_FILE="${BINLOGS[$((CHOICE_INDEX-1))]}"

echo ""
read -p "Detener en hora exacta? (YYYY-MM-DD HH:MM:SS, vacío para final del archivo): " STOP_TIME

# --- PASO 4: RESTAURACIÓN CON FILTRO ---
echo ""
echo "Aplicando Binlogs filtrados para: $DB ..."

# AQUÍ ESTÁ EL CAMBIO: Agregamos --database="$DB"
CMD="mysqlbinlog --no-defaults --database=\"$DB\" --start-datetime=\"$BACKUP_TIME\""

if [ -n "$STOP_TIME" ]; then
    CMD="$CMD --stop-datetime=\"$STOP_TIME\""
fi

for i in $(seq 0 $((CHOICE_INDEX-1))); do
    CMD="$CMD \"${BINLOGS[$i]}\""
done

CMD="$CMD | mysql -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" -h\"$MYSQL_HOST\""

eval $CMD 2> /dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}¡Restauración específica completada!${NC}"
else
    echo -e "${RED}Error durante la restauración de binlogs.${NC}"
fi
