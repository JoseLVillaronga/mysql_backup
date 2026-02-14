# Estrategia de Backup y Restauración MySQL (PITR)
Este documento detalla la implementación de una estrategia de backup y recuperación a un punto en el tiempo (PITR - Point-In-Time Recovery) para MySQL, emulando el funcionamiento de Full Backup + Transaction Logs de SQL Server.

## Alcance y relación con README_WEB_INTERFACE.md
- Este documento es la **referencia técnica** (arquitectura, fundamentos de PITR, cron y scripts).
- `README_WEB_INTERFACE.md` es la **guía operativa** (instalación, uso diario de la web y troubleshooting).

Para una lectura coherente:
1) Operación diaria: README.
2) Detalle técnico y decisiones: este documento.

1. Estrategia General
La estrategia se basa en dos pilares:

Backup Diario Completo (Full): Se ejecuta una vez al día. Contiene la estructura y los datos de todas las bases. Se utiliza como línea base.
Rotación de Binary Logs (Binlogs) - "Incremental": Se ejecuta cada 15 minutos. Los binlogs registran cada cambio (INSERT, UPDATE, DELETE) ocurrido en el servidor. Al rotarlos y respaldarlos, logramos tener una recuperación granular con una resolución de hasta 15 minutos.

2. Configuración Adicional de MySQL
Para que esta estrategia funcione, especialmente la restauración filtrada por base de datos, fue necesario modificar la configuración del motor.

Archivo: my.cnf (o mysqld.cnf)
Se añadieron o modificaron los siguientes parámetros en la sección [mysqld]:

ini

[mysqld]
# Habilita el registro binario (necesario para PITR)
log-bin = mysql-bin

# Formato del log: STATEMENT
# MOTIVO: MySQL 8 usa por defecto 'ROW'. Sin embargo, para poder filtrar
# la restauración por una sola base de datos usando '--database' en mysqlbinlog,
# es necesario usar 'STATEMENT' o 'MIXED'. En modo ROW puro, el filtro
# por base de datos no es efectivo.
binlog_format = STATEMENT

# (Opcional) Días a retener los logs en el servidor antes de borrarlos automáticamente
expire_logs_days = 7
Acción requerida: Reiniciar el servicio MySQL después de este cambio (sudo systemctl restart mysql).

### Nota técnica clave: precisión con `binlog_format=STATEMENT`

Se usa `STATEMENT` para habilitar restauración PITR granular por base con `mysqlbinlog --database=...`.

Sin embargo, al registrarse sentencias y no filas materializadas, hay casos donde el resultado re-ejecutado puede no ser idéntico al original, por ejemplo cuando la sentencia usa funciones no deterministas:

- `NOW()`
- `RAND()`
- `UUID()`
- u otras dependientes del momento/contexto de ejecución.

Implicancia práctica:
- La restauración sigue siendo **filtrada por base** y funcional para PITR.
- Si se requiere exactitud estricta de ciertos valores, conviene evitar esas funciones en operaciones críticas o persistir explícitamente los valores calculados en la app antes del `INSERT/UPDATE`.

3. Estructura de Archivos y Directorios
Se asume la siguiente estructura para el proyecto:

text

/mysql_backup
├── .env                      # Archivo de credenciales y configuraciones
├── back-sql-single.sh        # Script de Backup Diario (Full)
├── rotate_binlogs.sh         # Script de Rotación de Logs (cada 15 min)
├── restaurar_historico.sh    # Restaurar desde un Full Backup
├── restaurar_mysql.sh        # Restaurar PITR (Full + Binlogs)
└── /mnt/backup/mysql/        # Directorio de destino (ejemplo)
    ├── /inc/                 # Backups diarios (piso anterior)
    └── /binlogs/             # Respaldo de binlogs rotados

Ruta de Binlogs en la aplicación web: La app primero intenta usar `BINLOG_BACKUP_DIR` (si está configurado y contiene binlogs). Si no hay ruta explícita o está vacía, consulta el `datadir` de MySQL y utiliza esa ruta automáticamente.

4. Archivo de Configuración (.env)
Centraliza las credenciales para evitar hardcodearlas en los scripts.

ini

# .env
# Credenciales
MYSQL_USER="usuario"
MYSQL_PASS="password"
MYSQL_HOST="127.0.0.1"

# Formato de fecha para nombres de archivo
FECHA_FORMAT="%Y-%m-%d-%H-%M"

# Rutas
# DIR_DESTINO: Para backups históricos comprimidos
DIR_DESTINO="/mnt/backup/mysql"

# DIR_DESTINO_INC: Para el backup diario de referencia (se pisa)
DIR_DESTINO_INC="/mnt/backup/mysql/inc"

# BINLOG_BACKUP_DIR: Donde se copian los binlogs rotados
BINLOG_BACKUP_DIR="/mnt/backup/mysql/binlogs"

5. Scripts Desarrollados
A. Backup Diario Completo (back-sql-single.sh)
Función: Realiza un dump de todas las bases de datos (excluyendo las del sistema), las comprime con gzip y les pone la fecha en el nombre. Ideal para guardar un histórico nocturno.

Características:

Usa --single-transaction para no bloquear tablas InnoDB.
Incluye Rutinas, Eventos y Triggers.
No usa --master-data=2 en este script específico, ya que es un archivo de archivo histórico, no la base para el PITR en tiempo real.

bash

#!/bin/bash
# ... (Carga de .env y cálculo de fecha) ...
# ... (Bucle de bases de datos) ...
  NOMBRE_ARCHIVO="${DIR_DESTINO}/${DB}-back_${FECHA}.sql.gz"
  
  sudo mysqldump \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
    --databases "$DB" \
    --routines --events --triggers \
    --single-transaction \
    --add-drop-database \
    --set-gtid-purged=OFF \
  | gzip -9 > "$NOMBRE_ARCHIVO"
# ...

B. Backup Diario de Referencia (Piso) (back-sql-single.sh modificado)
Función: Igual al anterior, pero sin compresión y con --master-data=2. Este archivo se guarda en DIR_DESTINO_INC y se sobrescribe cada día. Sirve como la "Línea Base" para aplicar los binlogs encima.

Características:

Archivo de salida: ${DB}-back.sql.
--master-data=2: Anota la posición exacta del binlog al inicio del archivo.
Sin compresión para agilizar la restauración diaria si es necesario.

bash

#!/bin/bash
# ... (Carga .env) ...
  NOMBRE_ARCHIVO="${DIR_DESTINO_INC}/${DB}-back.sql"
  
  sudo mysqldump \
    -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" \
    --databases "$DB" \
    --routines --events --triggers \
    --master-data=2 \       # CLAVE PARA PITR
    --single-transaction \
    --add-drop-database \
    --set-gtid-purged=OFF \
  > "$NOMBRE_ARCHIVO" 2> /dev/null
# ...

C. Rotación de Binlogs (rotate_binlogs.sh)
Función: Se ejecuta cada 15 minutos. Fuerza a MySQL a cerrar el archivo de log actual y comienza uno nuevo. Luego, copia los archivos cerrados a la carpeta de backup.

Lógica:

mysqladmin flush-logs: Rota los logs.
Detecta cuál es el archivo "activo" (el que MySQL está escribiendo ahora).
Copia (cp -u) todos los archivos excepto el activo. Esto evita copiar archivos corruptos o a medias.

bash

#!/bin/bash
# ... (Carga .env) ...

# Detectar automáticamente el datadir de MySQL (donde viven los binlogs por defecto)
MYSQL_DATADIR=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW VARIABLES LIKE 'datadir';" | awk '{print $2}')

# Rotar
mysqladmin -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" flush-logs 2> /dev/null

# Obtener el archivo actual (para no copiarlo)
CURRENT_LOG=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" -N -e "SHOW MASTER STATUS;" | awk '{print $1}')

# Copiar archivos cerrados
for LOG_FILE in "$MYSQL_DATADIR"mysql-bin.*; do
    FILENAME=$(basename "$LOG_FILE")
    if [ "$FILENAME" != "$CURRENT_LOG" ] && [ -f "$LOG_FILE" ]; then
        sudo cp -u "$LOG_FILE" "$BINLOG_BACKUP_DIR/"
    fi
done
# ...

D. Restauración Histórica (restaurar_historico.sh)
Función: Permite elegir un backup comprimido (.sql.gz) de la carpeta histórica y restaurarlo por completo.

Seguridad:

Pide confirmación escribiendo "SI".
Usa gunzip -c para descomprimir al vuelo hacia MySQL.

bash

#!/bin/bash
# ... (Carga .env y listado de archivos) ...
# Selección interactiva del archivo...

# Confirmación estricta
read -p "¿Estás seguro? Escribe 'SI': " CONFIRM
if [[ "$CONFIRM" != "SI" ]]; then exit 0; fi

# Restauración
gunzip -c "$BACKUP_FILE" | mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST"
# ...

E. Restauración PITR (restaurar_mysql.sh)
Función: El script más potente. Permite recuperar una base de datos a un punto exacto en el tiempo.

Flujo:

Restaura el Backup Diario de Referencia (el de DIR_DESTINO_INC).
Lista los Binlogs disponibles.
Pide al usuario hasta qué archivo y hora aplicar.
Aplica los binlogs usando mysqlbinlog --database=NOMBRE_DB para filtrar solo esa base.
Requisito: binlog_format debe ser STATEMENT (configurado en my.cnf).

bash

#!/bin/bash
# ... (Selección de DB y Restauración del Full Backup) ...

# Selección de binlogs y hora de corte (STOP_TIME)

# Comando mágico de restauración incremental filtrada
CMD="mysqlbinlog --no-defaults --database=\"$DB\" --start-datetime=\"$BACKUP_TIME\""

if [ -n "$STOP_TIME" ]; then
    CMD="$CMD --stop-datetime=\"$STOP_TIME\""
fi

# Añadir archivos secuenciales
for i in $(seq 0 $((CHOICE_INDEX-1))); do
    CMD="$CMD \"${BINLOGS[$i]}\""
done

CMD="$CMD | mysql -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" -h\"$MYSQL_HOST\""

eval $CMD
# ...

6. Automatización (Crontab)
Se configuraron dos tareas programadas en el crontab del usuario root (para evitar problemas de permisos con sudo dentro de los scripts y acceso a carpetas de sistema).

1. Rotación de Binlogs (Lunes a Viernes, 07:00 a 18:00)
Ejecuta el script de rotación cada 15 minutos solo en horario laboral.

cron

*/15 7-18 * * * /ruta/a/mysql_backup/rotate_binlogs.sh >> /var/log/rotate_binlogs.log 2>&1
2. Backup Diario Completo (Todas las noches)
Ejecuta el script de backup histórico comprimido. Ejemplo a las 02:00 AM.

cron

0 2 * * * /ruta/a/mysql_backup/back-sql-single.sh >> /var/log/back-sql-single.log 2>&1
(Nota: El backup de referencia "pisable" se puede programar en otro horario, ej. 03:00 AM, apuntando a la versión sin compresión).

7. Notas Importantes y Solución de Problemas
Ruta de Binlogs: Se decidió usar la ruta por defecto de MySQL (datadir) para la generación de logs, y usar el script rotate_binlogs.sh para copiarlos a la carpeta de backup. Esto evita problemas de arranque de MySQL si el disco de backup no está montado al inicio.
Formato STATEMENT vs ROW:
ROW (Default): Mejor para replicación, pero difícil de filtrar por base de datos en una restauración puntual.
STATEMENT (Configurado): Permite usar mysqlbinlog --database=.... Ojo: las funciones no deterministas (como NOW()) se ejecutarán con la fecha de la restauración, no la original.
AppArmor (Ubuntu): Si se llegara a cambiar la ruta física donde MySQL escribe los binlogs, recordar configurar AppArmor para permitir el acceso.
Contraseñas en scripts: Al usar mysql -p"..." en bash, la contraseña queda en el historial. Para máxima seguridad en producción, se recomienda usar ~/.my.cnf o variables de entorno, aunque para este caso de estudio se usó el método directo por simplicidad operativa.