#!/bin/bash

# --- CONFIGURACIÓN Y CARGA DE VARIABLES ---

# Cargar el archivo .env
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "ERROR: No se encontró el archivo .env en $SCRIPT_DIR"
    exit 1
fi

# Verificar que exista la variable de destino
if [ -z "$DIR_DESTINO" ]; then
    echo "ERROR: La variable DIR_DESTINO no está definida en el .env"
    exit 1
fi

if [ ! -d "$DIR_DESTINO" ]; then
    echo "ERROR: No existe el directorio de backups: $DIR_DESTINO"
    exit 1
fi

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo "======================================================"
# He escapado los paréntesis con \( y \) para evitar el error de sintaxis
echo "     RESTAURACIÓN DE BACKUP HISTÓRICO \(COMPRIMIDO\)    "
echo "======================================================"
echo ""
echo -e "${YELLOW}ADVERTENCIA: Esta operación ${RED}BORRARÁ${YELLOW} la base de datos actual y la reemplazará con el backup seleccionado.${NC}"
echo ""

# --- PASO 1: LISTAR BACKUPS DISPONIBLES ---
echo "Buscando backups en: $DIR_DESTINO ..."
echo "------------------------------------------------------"

# Buscar archivos .sql.gz, ordenar por tiempo (nuevos primero)
BACKUP_LIST=($(ls -1t "$DIR_DESTINO"/*-back_*.sql.gz 2>/dev/null))

if [ ${#BACKUP_LIST[@]} -eq 0 ]; then
    echo "No se encontraron backups válidos (*-back_*.sql.gz)."
    exit 0
fi

# Crear menú de selección
echo "Selecciona un backup para restaurar:"
select BACKUP_FILE in "${BACKUP_LIST[@]}" "SALIR"; do
    if [ "$BACKUP_FILE" == "SALIR" ]; then
        echo "Operación cancelada."
        exit 0
    elif [ -n "$BACKUP_FILE" ]; then
        # Extraer nombre base del archivo para mostrarlo bonito
        FILENAME=$(basename "$BACKUP_FILE")
        echo -e "${GREEN}Seleccionado: $FILENAME${NC}"
        break
    else
        echo "Opción inválida."
    fi
done

# --- PASO 2: IDENTIFICAR LA BASE DE DATOS ---
# El formato del nombre es: DBNAME-back_FECHA.sql.gz
# Extraemos todo lo que esté antes de "-back"
DB_NAME=$(basename "$BACKUP_FILE" | sed 's/-back_.*//')

echo ""
echo "------------------------------------------------------"
echo "Resumen de la operación:"
echo "  Archivo: $BACKUP_FILE"
echo "  Base de Datos objetivo: $DB_NAME"
echo "------------------------------------------------------"

# --- PASO 3: CONFIRMACIÓN DE SEGURIDAD ---
echo ""
echo -e "${RED}¡CUIDADO! Se eliminará toda la información actual de '$DB_NAME'.${NC}"
read -p "¿Estás seguro de continuar? Escribe 'SI' para confirmar: " CONFIRM

if [[ "$CONFIRM" != "SI" ]]; then
    echo "Restauración cancelada por el usuario (no se escribió 'SI')."
    exit 0
fi

# --- PASO 4: EJECUTAR RESTAURACIÓN ---
echo ""
echo "Descomprimiendo y restaurando... (Esto puede tardar dependiendo del tamaño)"

# Usamos 'gunzip -c' para descomprimir a stdout (pantalla) y redirigimos a mysql
gunzip -c "$BACKUP_FILE" | mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" 2> /dev/null

# Verificación
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}¡RESTAURACIÓN COMPLETADA CON ÉXITO!${NC}"
    echo "La base de datos '$DB_NAME' ha sido restaurada al estado del backup."
else
    echo ""
    echo -e "${RED}ERROR durante la restauración.${NC}"
    echo "Verifica que la contraseña sea correcta y que el archivo no esté corrupto."
fi
