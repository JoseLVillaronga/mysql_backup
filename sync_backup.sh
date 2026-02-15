#!/bin/bash

# --- 1. CARGAR CONFIGURACIÓN ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "ERROR: No se encontró el archivo .env en $SCRIPT_DIR"
    exit 1
fi

# --- 2. VALIDACIONES DE SEGURIDAD ---

# A. Verificar que DIR_DESTINO_ORIGEN esté definido y no sea vacío
if [ -z "${DIR_DESTINO_ORIGEN+x}" ] || [ -z "$DIR_DESTINO_ORIGEN" ]; then
    echo "ERROR: La variable DIR_DESTINO_ORIGEN no esta definida o esta vacia."
    exit 1
fi

# B. Verificar que DIR_DESTINO_REMOTO esté definido y no sea vacío
if [ -z "${DIR_DESTINO_REMOTO+x}" ] || [ -z "$DIR_DESTINO_REMOTO" ]; then
    echo "ERROR: La variable DIR_DESTINO_REMOTO no esta definida o esta vacia."
    exit 1
fi

# C. Verificar que NO sean la misma ruta (evitar bucle/sincronizarse consigo mismo)
if [ "$DIR_DESTINO_ORIGEN" == "$DIR_DESTINO_REMOTO" ]; then
    echo "ERROR: DIR_DESTINO_ORIGEN y DIR_DESTINO_REMOTO son iguales. La sincronizacion se cancelo para evitar danos."
    exit 1
fi

# D. Verificar que el directorio de origen existe realmente
if [ ! -d "$DIR_DESTINO_ORIGEN" ]; then
    echo "ERROR: El directorio de origen no existe: $DIR_DESTINO_ORIGEN"
    exit 1
fi

# --- 3. EJECUCIÓN DE LA SINCRONIZACIÓN ---

# Crear el directorio remoto si no existe (para evitar errores de rsync)
mkdir -p "$DIR_DESTINO_REMOTO"

echo "Iniciando sincronizacion..."
echo "  Origen: $DIR_DESTINO_ORIGEN"
echo "  Destino: $DIR_DESTINO_REMOTO"

# Opciones de RSYNC explicadas:
# -a: modo archivo (preserva permisos, fechas, propietarios, recursivo)
# -v: verbose (muestra progreso)
# -z: comprime los datos durante la transferencia (mas rapido)
# --delete: ELIMINA archivos en el destino que ya no estan en el origen (MIRROR)
# --progress: muestra barra de progreso
# Nota el / al final de ORIGEN: copia el *contenido* de la carpeta, no la carpeta en si.

sudo rsync -avz --no-o --no-g --delete --progress "$DIR_DESTINO_ORIGEN/" "$DIR_DESTINO_REMOTO/"

# Verificar codigo de salida
if [ $? -eq 0 ]; then
    echo ""
    echo "Sincronizacion finalizada con exito."
else
    echo ""
    echo "ERROR: La sincronizacion fallo con codigo de error $?."
    exit 1
fi
