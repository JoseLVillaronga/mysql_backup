# Interfaz Web para Gestión de Backups MySQL/MongoDB

Interfaz web Flask con Bootstrap 5 para gestionar restauraciones de backups MySQL con capacidad PITR (Point-In-Time Recovery).

## 📚 Mapa de documentación (unificado)

- **Este archivo (`README_WEB_INTERFACE.md`)**: guía operativa de instalación, ejecución y uso diario de la web.
- **`documento.md`**: detalle técnico de la estrategia PITR, fundamentos, cron y decisiones de diseño.

Orden recomendado de lectura:
1. README (operación de la aplicación)
2. `documento.md` (arquitectura y consideraciones avanzadas)

## 🎯 Características

- **Dashboard**: Vista general de backups históricos, incrementales y binlogs
- **Restauración Histórica**: Restauración completa desde backups comprimidos (.sql.gz)
- **Restauración PITR**: Recuperación granular a un punto exacto en el tiempo
- **Rotación Manual de Binlogs**: Forzar rotación de binlogs desde la interfaz
- **Diseño Responsive**: Interfaz moderna con Bootstrap 5
- **Confirmaciones de Seguridad**: Requiere confirmación explícita ("SI") para operaciones críticas

## 📋 Requisitos Previos

- Python 3.8+
- MySQL/MariaDB con binary logs habilitados
- Directorios de backup configurados
- Credenciales de acceso a MySQL

## 🚀 Instalación

### 1. Activar Entorno Virtual

```bash
cd /home/jose/mysql_backup
source venv/bin/activate
```

### 2. Instalar Dependencias

```bash
pip install -r requirements.txt
```

Las dependencias incluyen:
- Flask==3.1.0
- Flask-Bootstrap==3.3.7.1
- gunicorn==21.2.0

### 3. Configurar Archivo .env

Asegúrate de que el archivo `.env` exista con las credenciales correctas:

```bash
# Copia el ejemplo si no existe
cp .env.example .env

# Edita con tus credenciales reales
nano .env
```

Variables requeridas:
- `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_HOST`
- `DIR_DESTINO`, `DIR_DESTINO_INC`, `BINLOG_BACKUP_DIR` (opcional)

### Resolución de ruta de binlogs en la app

La aplicación resuelve la fuente de binlogs en este orden:
1. `BINLOG_BACKUP_DIR` (si está configurado y tiene binlogs)
2. `datadir` real de MySQL (consultado con `SHOW VARIABLES LIKE 'datadir'`)

Esto permite operar sin hardcodear `/mnt/backup/mysql/binlogs` cuando se usan binlogs en `/var/lib/mysql`.

### 4. Verificar Permisos

La aplicación necesita acceso a:
- Archivos de backup (`/mnt/backup/mysql/*`)
- Directorio de binlogs de MySQL (datadir)
- Ejecutar comandos mysql, mysqladmin, mysqlbinlog

```bash
# Asegúrate que el usuario pueda acceder a los backups
ls -la /mnt/backup/mysql/

# Verifica que mysql y mysqladmin funcionen sin contraseña interactiva
mysql -u TU_USUARIO -pTU_PASSWORD -h 127.0.0.1 -e "SELECT 1;"
```

## 🔧 Configuración de Servicio (Opcional - Producción)

### Instalar como servicio systemd:

```bash
# Copiar el archivo de servicio
sudo cp mysql-backup-web.service /etc/systemd/system/

# Recargar systemd
sudo systemctl daemon-reload

# Habilitar el servicio (inicio automático)
sudo systemctl enable mysql-backup-web

# Iniciar el servicio
sudo systemctl start mysql-backup-web

# Verificar estado
sudo systemctl status mysql-backup-web
```

### Logs del servicio:

```bash
# Ver logs en tiempo real
sudo journalctl -u mysql-backup-web -f

# Ver últimos 50 líneas
sudo journalctl -u mysql-backup-web -n 50
```

## 🌐 Uso

### Modo Desarrollo

```bash
# Activar entorno virtual
source venv/bin/activate

# Ejecutar en modo desarrollo
python3 app.py
```

La aplicación estará disponible en: http://localhost:8200

### Modo Producción con Gunicorn

```bash
# Activar entorno virtual
source venv/bin/activate

# Ejecutar con gunicorn
gunicorn -w 4 -b 0.0.0.0:8200 app:app
```

O usando el servicio systemd:
```bash
sudo systemctl start mysql-backup-web
```

## 📱 Interfaz Web

### Páginas Disponibles

1. **Dashboard** (`/`)
   - Vista general de últimos backups
   - Binlogs disponibles
   - Información del sistema
   - Botón para rotar binlogs manualmente

2. **Backups Históricos** (`/historical`)
   - Listado completo de backups históricos
   - Buscador por nombre de base
   - Botón de restauración para cada backup

3. **Restauración PITR** (`/pitr`)
   - Selección de base de datos
   - Selección de binlogs a aplicar
   - Configuración de punto de corte (fecha/hora exacta)
   - Resumen antes de restaurar

### Flujo de Restauración Histórica

1. Navegar a `/historical`
2. Buscar el backup deseado
3. Clic en "Restaurar"
4. Escribir "SI" en el campo de confirmación
5. Confirmar la operación

### Flujo de Restauración PITR

1. Navegar a `/pitr`
2. Paso 1: Seleccionar la base de datos
3. Paso 2: Seleccionar los binlogs a aplicar (checkboxes)
4. Paso 3: Opcionalmente, especificar hora de corte
5. Revisar el resumen de operación
6. Clic en "Iniciar Restauración PITR"
7. Escribir "SI" en el campo de confirmación
8. Confirmar la operación

## ⚠️ Advertencias Importantes

### Formato de Binlog

La restauración PITR granular por base de datos **REQUIERE** que el formato de binlog sea `STATEMENT` o `MIXED`. No funcionará correctamente con formato `ROW`.

**Verificar formato actual:**
```bash
mysql -u TU_USUARIO -p -e "SELECT @@binlog_format;"
```

**Configurar formato STATEMENT en my.cnf:**
```ini
[mysqld]
log-bin = mysql-bin
binlog_format = STATEMENT
expire_logs_days = 7
```

**Reiniciar MySQL después del cambio:**
```bash
sudo systemctl restart mysql
```

### Precisión de datos con `STATEMENT` (IMPORTANTE)

Cuando el motor usa `binlog_format=STATEMENT`, los eventos se registran como sentencias SQL.
Esto habilita el filtrado por base (`mysqlbinlog --database=...`) que usa este proyecto para PITR granular.

Pero hay una implicancia importante:

- Si tus transacciones dependen de funciones no deterministas (por ejemplo `NOW()`, `RAND()`, `UUID()`, etc.),
  durante la reproducción del binlog esas funciones pueden evaluarse nuevamente en el momento de restauración,
  y el valor resultante puede diferir del valor original.

En resumen:
- **Sí**: PITR granular por base funciona con `STATEMENT`.
- **Atención**: si necesitás exactitud absoluta en esos valores, hay que revisar el diseño de escritura de datos
  (evitar funciones no deterministas en sentencias críticas o persistir valores calculados de forma explícita).

### Seguridad

- La aplicación requiere permisos para ejecutar comandos de MySQL
- Las contraseñas se cargan desde `.env` (proteger con `chmod 600 .env`)
- Las operaciones de restauración requieren confirmación explícita ("SI")
- **IMPORTANTE**: La restauración BORRA toda la información actual de la base de datos

### Permisos de Archivos

Asegúrate que el usuario que ejecuta la aplicación tenga acceso:

```bash
# Permiso de lectura en backups
chmod -R 755 /mnt/backup/mysql/

# Permiso de lectura en datadir de MySQL (binlogs)
sudo chmod -R 755 /var/lib/mysql/  # Ajustar ruta según tu configuración

# O agregar usuario al grupo mysql
sudo usermod -aG mysql TU_USUARIO
```

## 🔒 Configuración de Seguridad Adicional

### 1. Usar ~/.my.cnf en lugar de contraseñas en línea de comandos

```bash
# Crear archivo ~/.my.cnf
cat > ~/.my.cnf << EOF
[client]
user = TU_USUARIO
password = TU_PASSWORD
host = 127.0.0.1
EOF

# Proteger el archivo
chmod 600 ~/.my.cnf
```

Luego modificar `app.py` para no pasar `-p` y `-u`.

### 2. Firewall

Asegurar acceso solo desde redes permitidas:

```bash
# Solo permitir desde localhost (si se usa Nginx como proxy)
sudo ufw allow from 127.0.0.1 to any port 8200

# O permitir desde red específica
sudo ufw allow from 192.168.1.0/24 to any port 8200
```

### 3. HTTPS con Nginx (Opcional)

Configurar Nginx como reverse proxy con SSL:

```nginx
server {
    listen 443 ssl;
    server_name tu-dominio.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 🐛 Solución de Problemas

### Error: "No se pudo determinar el datadir de MySQL"

**Causa**: La aplicación no puede conectarse a MySQL o el usuario no tiene permisos.

**Solución**:
```bash
# Verificar conexión
mysql -u TU_USUARIO -pTU_PASSWORD -h 127.0.0.1 -e "SHOW VARIABLES LIKE 'datadir';"

# Verificar permisos del usuario
mysql -u TU_USUARIO -pTU_PASSWORD -h 127.0.0.1 -e "SHOW GRANTS FOR CURRENT_USER();"
```

### Error: "No se encontraron backups válidos"

**Causa**: El directorio de backup no existe o está vacío.

**Solución**:
```bash
# Verificar directorio
ls -la /mnt/backup/mysql/

# Crear directorio si no existe
sudo mkdir -p /mnt/backup/mysql
sudo chown TU_USUARIO: /mnt/backup/mysql
```

### Error: "Permission denied" al ejecutar mysql/mysqldump

**Causa**: El usuario no tiene permisos o no puede acceder a los binarios.

**Solución**:
```bash
# Verificar ruta de mysql
which mysql

# Verificar permisos
ls -la $(which mysql)

# Asegurar que el usuario pueda ejecutar mysql
sudo chmod +x $(which mysql)
```

### Error: "El formato de binlog es ROW"

**Causa**: MySQL está configurado con formato ROW que no permite filtrado por base de datos.

**Solución**: Cambiar a STATEMENT en my.cnf y reiniciar MySQL (ver sección "Formato de Binlog" arriba).

## 📊 Monitoreo

### Verificar que el servicio está corriendo:

```bash
# Status del servicio
sudo systemctl status mysql-backup-web

# Ver proceso
ps aux | grep gunicorn

# Ver puerto
netstat -tulpn | grep 8200
# o
ss -tulpn | grep 8200
```

### Verificar accesibilidad:

```bash
# Desde el servidor
curl http://localhost:8200/

# Desde otra máquina
curl http://IP_DEL_SERVIDOR:8200/
```

## 🔄 Actualización

Para actualizar la aplicación:

```bash
# Detener servicio (si está activo)
sudo systemctl stop mysql-backup-web

# Activar entorno virtual
source venv/bin/activate

# Actualizar dependencias
pip install -r requirements.txt --upgrade

# Reiniciar servicio
sudo systemctl start mysql-backup-web
```

## 📝 Archivos del Proyecto

```
mysql_backup/
├── app.py                      # Aplicación Flask principal
├── requirements.txt             # Dependencias de Python
├── mysql-backup-web.service     # Archivo de servicio systemd
├── templates/
│   ├── base.html              # Plantilla base
│   ├── index.html             # Dashboard
│   ├── historical.html         # Backups históricos
│   └── pitr.html             # Restauración PITR
├── .env                       # Credenciales (NO versionar)
├── .env.example              # Ejemplo de configuración
└── venv/                     # Entorno virtual (NO versionar)
```

## 🤝 Soporte

Para problemas o sugerencias, revisa:
1. Logs de la aplicación: `sudo journalctl -u mysql-backup-web`
2. Logs de errores en la interfaz web
3. Documentación de scripts de backup en `documento.md`

## 📄 Licencia

Este software es parte del sistema de backup MySQL/MongoDB implementado.