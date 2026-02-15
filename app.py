#!/usr/bin/env python3
"""
Aplicación Flask para Gestión de Backups MySQL/MongoDB
Interfaz web para restauración de backups
"""

import os
import subprocess
import re
import shutil
from datetime import datetime, timedelta
from flask import Flask, render_template, request, jsonify, flash, redirect, url_for
from flask_bootstrap import Bootstrap
from pathlib import Path

app = Flask(__name__)
app.secret_key = 'your-secret-key-change-in-production'
bootstrap = Bootstrap(app)

# Cargar configuración desde .env
def load_env():
    env_path = Path(__file__).parent / '.env'
    env_vars = {}
    if env_path.exists():
        with open(env_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    # Remover comillas si existen
                    value = value.strip('"\'')
                    env_vars[key] = value
    return env_vars

env = load_env()

# Configuración de directorios
DIR_DESTINO = env.get('DIR_DESTINO', '/mnt/backup/mysql')
DIR_DESTINO_INC = env.get('DIR_DESTINO_INC', '/mnt/backup/mysql/incremental')
BINLOG_BACKUP_DIR = env.get('BINLOG_BACKUP_DIR', '').strip()
HORA_INICIO = env.get('HORA_INICIO', '00:00:00').strip()
BINLOG_FILE_PATTERNS = ('mysql-bin.*', 'mariadb-bin.*', 'binlog.*')
EXCLUDE_DB = {
    db.strip().lower()
    for db in env.get('EXCLUDE_DB', 'information_schema|performance_schema|mysql|sys').split('|')
    if db.strip()
}

# Configuración MongoDB
MONGO_HOST = env.get('HOST', '127.0.0.1').strip()
MONGO_PORT = env.get('PUERTO', '27017').strip()
MONGO_USER = env.get('USUARIO', '').strip()
MONGO_PASS = env.get('CONTRASENA', '').strip()
MONGO_AUTH_DB = env.get('AUTH_DB', 'admin').strip()
MONGO_BACKUP_DEST = env.get('DESTINO', '/mnt/backup/mongo').strip()
MONGO_SYSTEM_DATABASES = {'admin', 'config', 'local'}


def get_excluded_databases():
    """Obtiene bases a excluir desde EXCLUDE_DB (separadas por '|')."""
    return set(EXCLUDE_DB)


EXCLUDED_DATABASES = get_excluded_databases()


def is_excluded_database(db_name):
    return bool(db_name) and db_name.strip().lower() in EXCLUDED_DATABASES


def get_hora_inicio_time():
    """Parsea HORA_INICIO (HH:MM[:SS]) para filtrar binlogs PITR del día."""
    if not HORA_INICIO:
        return datetime.strptime('00:00:00', '%H:%M:%S').time()

    for fmt in ('%H:%M:%S', '%H:%M'):
        try:
            return datetime.strptime(HORA_INICIO, fmt).time()
        except ValueError:
            continue

    print(f"HORA_INICIO inválida ('{HORA_INICIO}'). Usando 00:00:00")
    return datetime.strptime('00:00:00', '%H:%M:%S').time()

# Obtener datadir de MySQL
def get_mysql_datadir():
    try:
        result = subprocess.run(
            ['mysql', f'-u{env["MYSQL_USER"]}', f'-p{env["MYSQL_PASS"]}', 
             f'-h{env["MYSQL_HOST"]}', '-N', '-e', "SHOW VARIABLES LIKE 'datadir';"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            lines = result.stdout.strip().split('\t')
            if len(lines) >= 2:
                return lines[1].rstrip('/')
        else:
            print(f"Error mysql datadir: {result.stderr.strip()}")
    except Exception as e:
        print(f"Error obteniendo datadir: {e}")
    return None


def list_binlog_files(binlog_dir):
    """Lista binlogs soportando distintos prefijos (MySQL/MariaDB)."""
    if not binlog_dir or not binlog_dir.exists() or not binlog_dir.is_dir():
        return []

    files_by_name = {}
    for pattern in BINLOG_FILE_PATTERNS:
        for file in binlog_dir.glob(pattern):
            if file.is_file() and not file.name.endswith('.index'):
                files_by_name[file.name] = file

    return [files_by_name[name] for name in sorted(files_by_name)]


def get_binlog_source_dir():
    """Resuelve el directorio de binlogs a utilizar en la app.

    1) Preferir BINLOG_BACKUP_DIR (copias rotadas para PITR)
    2) Fallback a datadir real de MySQL
    """
    if BINLOG_BACKUP_DIR:
        backup_dir = Path(BINLOG_BACKUP_DIR)
        if backup_dir.exists() and backup_dir.is_dir() and list_binlog_files(backup_dir):
            return backup_dir

    mysql_datadir = get_mysql_datadir()
    if mysql_datadir:
        datadir = Path(mysql_datadir)
        if datadir.exists() and datadir.is_dir() and list_binlog_files(datadir):
            return datadir

    return None

# Obtener lista de bases de datos
def get_databases():
    try:
        result = subprocess.run(
            ['mysql', f'-u{env["MYSQL_USER"]}', f'-p{env["MYSQL_PASS"]}', 
             f'-h{env["MYSQL_HOST"]}', '-N', '-e', 'SHOW DATABASES;'],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            databases = result.stdout.strip().split('\n')
            return [db for db in databases if db and not is_excluded_database(db)]
    except Exception as e:
        print(f"Error obteniendo bases de datos: {e}")
    return []

# Obtener backups históricos
def get_historical_backups():
    backups = []
    backup_dir = Path(DIR_DESTINO)
    if backup_dir.exists():
        for file in sorted(backup_dir.glob('*-back_*.sql.gz'), reverse=True):
            # Extraer nombre de base y fecha
            match = re.match(r'(.+)-back_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2})\.sql\.gz', file.name)
            if match:
                db_name = match.group(1)
                if is_excluded_database(db_name):
                    continue
                date_str = match.group(2)
                try:
                    date_obj = datetime.strptime(date_str, '%Y-%m-%d_%H-%M')
                    size = file.stat().st_size
                    size_mb = size / (1024 * 1024)
                    backups.append({
                        'filename': file.name,
                        'db_name': db_name,
                        'date': date_obj,
                        'date_str': date_obj.strftime('%d/%m/%Y %H:%M'),
                        'size': f"{size_mb:.2f} MB",
                        'path': str(file)
                    })
                except ValueError:
                    continue
    return backups


def get_directory_size_bytes(directory):
    """Calcula el tamaño total de un directorio de forma recursiva."""
    total = 0
    for path in directory.rglob('*'):
        if path.is_file():
            try:
                total += path.stat().st_size
            except OSError:
                continue
    return total


def get_mongo_backups():
    """Obtiene backups históricos de MongoDB (mongodump --out backup_YYYY-MM-DD_HH-MM)."""
    backups = []
    backup_dir = Path(MONGO_BACKUP_DEST)
    if not backup_dir.exists() or not backup_dir.is_dir():
        return backups

    for folder in sorted(backup_dir.glob('backup_*'), reverse=True):
        if not folder.is_dir():
            continue

        stat = folder.stat()
        modified_dt = datetime.fromtimestamp(stat.st_mtime)
        dbs = sorted([
            p.name for p in folder.iterdir()
            if p.is_dir() and p.name not in MONGO_SYSTEM_DATABASES
        ])
        size_mb = get_directory_size_bytes(folder) / (1024 * 1024)

        backups.append({
            'name': folder.name,
            'path': str(folder),
            'modified': modified_dt.strftime('%d/%m/%Y %H:%M'),
            'size': f"{size_mb:.2f} MB",
            'databases': dbs,
            'db_count': len(dbs)
        })

    return backups


def build_mongorestore_base_cmd():
    """Construye argumentos base de conexión para mongorestore."""
    cmd = ['mongorestore', '--host', MONGO_HOST, '--port', MONGO_PORT]
    if MONGO_USER:
        cmd.extend(['--username', MONGO_USER])
    if MONGO_PASS:
        cmd.extend(['--password', MONGO_PASS])
    if MONGO_AUTH_DB:
        cmd.extend(['--authenticationDatabase', MONGO_AUTH_DB])
    return cmd


def cleanup_mysql_historical_backups(days):
    """Elimina backups .sql.gz de MySQL más antiguos que N días."""
    deleted = []
    backup_dir = Path(DIR_DESTINO)
    if not backup_dir.exists() or not backup_dir.is_dir():
        return deleted

    cutoff = datetime.now() - timedelta(days=days)
    for file in backup_dir.glob('*-back_*.sql.gz'):
        if not file.is_file():
            continue

        file_modified = datetime.fromtimestamp(file.stat().st_mtime)
        if file_modified < cutoff:
            file.unlink(missing_ok=True)
            deleted.append(file.name)

    return deleted


def cleanup_mongo_historical_backups(days):
    """Elimina carpetas backup_* de MongoDB más antiguas que N días."""
    deleted = []
    backup_dir = Path(MONGO_BACKUP_DEST)
    if not backup_dir.exists() or not backup_dir.is_dir():
        return deleted

    cutoff = datetime.now() - timedelta(days=days)
    for folder in backup_dir.glob('backup_*'):
        if not folder.is_dir():
            continue

        folder_modified = datetime.fromtimestamp(folder.stat().st_mtime)
        if folder_modified < cutoff:
            shutil.rmtree(folder)
            deleted.append(folder.name)

    return deleted

# Obtener backups incrementales
def get_incremental_backups():
    backups = []
    backup_dir = Path(DIR_DESTINO_INC)
    if backup_dir.exists():
        for file in backup_dir.glob('*-back.sql'):
            match = re.match(r'(.+)-back\.sql', file.name)
            if match:
                db_name = match.group(1)
                if is_excluded_database(db_name):
                    continue
                stat = file.stat()
                size_mb = stat.st_size / (1024 * 1024)
                backups.append({
                    'filename': file.name,
                    'db_name': db_name,
                    'path': str(file),
                    'size': f"{size_mb:.2f} MB",
                    'modified': datetime.fromtimestamp(stat.st_mtime).strftime('%d/%m/%Y %H:%M')
                })
    return backups

# Obtener binlogs
def get_binlogs():
    binlogs = []
    binlog_dir = get_binlog_source_dir()
    if binlog_dir:
        for file in list_binlog_files(binlog_dir):
            stat = file.stat()
            size_mb = stat.st_size / (1024 * 1024)
            binlogs.append({
                'filename': file.name,
                'path': str(file),
                'size': f"{size_mb:.2f} MB",
                'modified': datetime.fromtimestamp(stat.st_mtime).strftime('%d/%m/%Y %H:%M')
            })
    return binlogs


def get_pitr_binlogs_today():
    """Binlogs visibles en PITR: solo hoy desde HORA_INICIO."""
    source_dir = get_binlog_source_dir()
    if not source_dir:
        return []

    today = datetime.now().date()
    hora_inicio = get_hora_inicio_time()
    binlogs = []

    for file in list_binlog_files(source_dir):
        stat = file.stat()
        modified_dt = datetime.fromtimestamp(stat.st_mtime)

        if modified_dt.date() != today:
            continue
        if modified_dt.time() < hora_inicio:
            continue

        size_mb = stat.st_size / (1024 * 1024)
        binlogs.append({
            'filename': file.name,
            'path': str(file),
            'size': f"{size_mb:.2f} MB",
            'modified': modified_dt.strftime('%d/%m/%Y %H:%M')
        })

    return binlogs

# Obtener formato de binlog
def get_binlog_format():
    try:
        result = subprocess.run(
            ['mysql', f'-u{env["MYSQL_USER"]}', f'-p{env["MYSQL_PASS"]}', 
             f'-h{env["MYSQL_HOST"]}', '-N', '-e', "SELECT @@binlog_format;"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return result.stdout.strip()
        print(f"Error mysql binlog_format: {result.stderr.strip()}")
    except:
        pass
    return "UNKNOWN"

# Rutas de la aplicación
@app.route('/')
def index():
    """Página principal con dashboard"""
    historical = get_historical_backups()[:10]  # Últimos 10
    incremental = get_incremental_backups()
    binlogs = get_binlogs()[:10]  # Últimos 10
    mongo_backups = get_mongo_backups()[:5]
    binlog_format = get_binlog_format()
    
    binlog_dir = get_binlog_source_dir()

    return render_template('index.html', 
                         historical=historical,
                         incremental=incremental,
                         binlogs=binlogs,
                         mongo_backups=mongo_backups,
                         binlog_format=binlog_format,
                         mysql_datadir=str(binlog_dir) if binlog_dir else None)

@app.route('/historical')
def historical():
    """Listado de backups históricos"""
    backups = get_historical_backups()
    return render_template('historical.html', backups=backups)

@app.route('/pitr')
def pitr():
    """Página de restauración PITR"""
    databases = get_databases()
    incremental = get_incremental_backups()
    binlogs = get_pitr_binlogs_today()
    binlog_format = get_binlog_format()
    
    return render_template('pitr.html', 
                         databases=databases,
                         incremental=incremental,
                         binlogs=binlogs,
                         binlog_format=binlog_format,
                         hora_inicio=HORA_INICIO)


@app.route('/mongodb')
def mongodb():
    """Página de restauración histórica MongoDB (total o parcial)."""
    backups = get_mongo_backups()
    return render_template('mongodb.html', backups=backups, backups_dir=MONGO_BACKUP_DEST)

@app.route('/api/restore/historical', methods=['POST'])
def api_restore_historical():
    """API para restaurar backup histórico"""
    data = request.json
    backup_file = data.get('backup_file')
    confirm = data.get('confirm', '').upper()
    
    if confirm != 'SI':
        return jsonify({'success': False, 'error': 'Debe confirmar escribiendo "SI"'}), 400
    
    if not backup_file:
        return jsonify({'success': False, 'error': 'No se especificó el archivo de backup'}), 400
    
    backup_path = Path(DIR_DESTINO) / backup_file
    if not backup_path.exists():
        return jsonify({'success': False, 'error': 'El archivo de backup no existe'}), 404
    
    try:
        # Ejecutar restauración
        cmd = f'gunzip -c "{backup_path}" | mysql -u{env["MYSQL_USER"]} -p{env["MYSQL_PASS"]} -h{env["MYSQL_HOST"]}'
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            return jsonify({'success': True, 'message': 'Restauración completada con éxito'})
        else:
            return jsonify({'success': False, 'error': f'Error durante la restauración: {result.stderr}'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/cleanup/backups', methods=['POST'])
def api_cleanup_backups():
    """API para limpieza de backups históricos por antigüedad."""
    data = request.json or {}
    backup_type = data.get('backup_type', '').strip().lower()
    confirm = data.get('confirm', '').upper()
    days_raw = data.get('days')

    if confirm != 'SI':
        return jsonify({'success': False, 'error': 'Debe confirmar escribiendo "SI"'}), 400

    try:
        days = int(days_raw)
    except (TypeError, ValueError):
        return jsonify({'success': False, 'error': 'El valor de días es inválido'}), 400

    if days not in (7, 15, 30):
        return jsonify({'success': False, 'error': 'Solo se permiten 7, 15 o 30 días'}), 400

    try:
        if backup_type == 'mysql_historical':
            deleted = cleanup_mysql_historical_backups(days)
            return jsonify({
                'success': True,
                'message': f'Se eliminaron {len(deleted)} backups históricos MySQL con más de {days} días',
                'deleted': deleted
            })

        if backup_type == 'mongo_historical':
            deleted = cleanup_mongo_historical_backups(days)
            return jsonify({
                'success': True,
                'message': f'Se eliminaron {len(deleted)} backups históricos MongoDB con más de {days} días',
                'deleted': deleted
            })

        return jsonify({'success': False, 'error': 'Tipo de backup inválido'}), 400

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/restore/mongo', methods=['POST'])
def api_restore_mongo():
    """API para restauración de backups MongoDB (total o parcial por bases)."""
    data = request.json
    backup_name = data.get('backup_name', '').strip()
    mode = data.get('mode', '').strip().lower()
    selected_dbs = data.get('databases', [])
    confirm = data.get('confirm', '').upper()

    if confirm != 'SI':
        return jsonify({'success': False, 'error': 'Debe confirmar escribiendo "SI"'}), 400

    if not backup_name:
        return jsonify({'success': False, 'error': 'No se especificó backup de MongoDB'}), 400

    if mode not in ('full', 'partial'):
        return jsonify({'success': False, 'error': 'Modo inválido. Use full o partial'}), 400

    backup_path = Path(MONGO_BACKUP_DEST) / backup_name
    if not backup_path.exists() or not backup_path.is_dir():
        return jsonify({'success': False, 'error': 'El backup seleccionado no existe'}), 404

    try:
        if mode == 'full':
            cmd = build_mongorestore_base_cmd() + ['--drop', str(backup_path)]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                return jsonify({'success': False, 'error': f'Error restaurando MongoDB completo: {result.stderr}'}), 500

            return jsonify({'success': True, 'message': f'Restauración MongoDB completa realizada desde {backup_name}'})

        # mode == 'partial'
        if not isinstance(selected_dbs, list) or not selected_dbs:
            return jsonify({'success': False, 'error': 'Debe seleccionar al menos una base para restauración parcial'}), 400

        restore_errors = []
        restored = []
        for db_name in selected_dbs:
            if not db_name or db_name in MONGO_SYSTEM_DATABASES:
                continue

            db_backup_path = backup_path / db_name
            if not db_backup_path.exists() or not db_backup_path.is_dir():
                restore_errors.append(f'No existe dump para la base {db_name}')
                continue

            cmd = build_mongorestore_base_cmd() + ['--drop', '--db', db_name, str(db_backup_path)]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                restore_errors.append(f'{db_name}: {result.stderr.strip()}')
            else:
                restored.append(db_name)

        if restore_errors:
            return jsonify({
                'success': False,
                'error': 'Se restauraron parcialmente algunas bases',
                'details': restore_errors,
                'restored': restored
            }), 500

        if not restored:
            return jsonify({
                'success': False,
                'error': 'No se restauró ninguna base válida. Revisa la selección.'
            }), 400

        return jsonify({'success': True, 'message': f'Restauración parcial completada: {", ".join(restored)}'})

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/restore/pitr', methods=['POST'])
def api_restore_pitr():
    """API para restauración PITR"""
    data = request.json
    db_name = data.get('db_name')
    confirm = data.get('confirm', '').upper()
    
    if confirm != 'SI':
        return jsonify({'success': False, 'error': 'Debe confirmar escribiendo "SI"'}), 400
    
    if not db_name:
        return jsonify({'success': False, 'error': 'No se especificó la base de datos'}), 400
    
    # Verificar backup incremental
    inc_backup = Path(DIR_DESTINO_INC) / f'{db_name}-back.sql'
    if not inc_backup.exists():
        return jsonify({'success': False, 'error': f'No existe backup incremental para {db_name}'}), 404
    
    try:
        # Paso 1: Restaurar backup completo
        cmd1 = f'mysql -u{env["MYSQL_USER"]} -p{env["MYSQL_PASS"]} -h{env["MYSQL_HOST"]} < "{inc_backup}"'
        result1 = subprocess.run(cmd1, shell=True, capture_output=True, text=True)
        
        if result1.returncode != 0:
            return jsonify({'success': False, 'error': f'Error restaurando backup completo: {result1.stderr}'}), 500
        
        # Paso 2: Obtener tiempo del backup
        backup_time = datetime.fromtimestamp(inc_backup.stat().st_mtime).strftime('%Y-%m-%d %H:%M:%S')
        
        # Paso 3: Aplicar binlogs si se especificaron
        stop_time = data.get('stop_time')
        binlog_files = data.get('binlogs', [])
        
        if binlog_files:
            # Construir comando mysqlbinlog
            binlog_cmd = f'mysqlbinlog --no-defaults --database="{db_name}" --start-datetime="{backup_time}"'
            if stop_time:
                binlog_cmd += f' --stop-datetime="{stop_time}"'
            
            binlog_dir = get_binlog_source_dir()
            if not binlog_dir:
                return jsonify({'success': False, 'error': 'No se encontró directorio de binlogs disponible'}), 500

            for binlog in binlog_files:
                binlog_path = binlog_dir / binlog
                if binlog_path.exists():
                    binlog_cmd += f' "{binlog_path}"'
            
            binlog_cmd += f' | mysql -u{env["MYSQL_USER"]} -p{env["MYSQL_PASS"]} -h{env["MYSQL_HOST"]}'
            
            result2 = subprocess.run(binlog_cmd, shell=True, capture_output=True, text=True)
            
            if result2.returncode != 0:
                return jsonify({'success': False, 'error': f'Error aplicando binlogs: {result2.stderr}'}), 500
        
        return jsonify({'success': True, 'message': 'Restauración PITR completada con éxito'})
    
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/rotate-binlogs', methods=['POST'])
def api_rotate_binlogs():
    """API para rotar binlogs manualmente"""
    try:
        cmd = f'mysqladmin -u{env["MYSQL_USER"]} -p{env["MYSQL_PASS"]} -h{env["MYSQL_HOST"]} flush-logs'
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode == 0:
            return jsonify({'success': True, 'message': 'Binlogs rotados exitosamente'})
        else:
            return jsonify({'success': False, 'error': result.stderr}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8200, debug=False)