#!/usr/bin/env bash
#
# install-ospos.sh
#
# Instalador automatizado de OSPOS (opensourcepos) 3.4.1 para Ubuntu 22.04/24.04 LTS
# con Apache 2.4 + PHP + MariaDB, corrigiendo los bugs conocidos del paquete
# de distribución oficial de esa versión.
#
# Autor: Clay Velázquez Rubio (@McClay429)
# GitHub: https://github.com/McClay429
#
# Ver TROUBLESHOOTING.md en este mismo repositorio para el detalle técnico de
# cada corrección aplicada aquí.
#
# USO:
#   sudo ./install-ospos.sh              Instala normalmente
#   sudo ./install-ospos.sh --dry-run    Muestra qué haría, sin ejecutar nada
#   sudo ./install-ospos.sh --uninstall  Elimina la instalación (no borra la BD)
#   sudo ./install-ospos.sh --https      Además configura HTTPS con certificado autofirmado
#   ./install-ospos.sh --help            Muestra esta ayuda
#
# Si el script falla a la mitad, corrígelo y vuelve a correrlo tal cual:
# es reanudable, salta automáticamente los pasos que ya se completaron.
#
# Requisitos previos (el script NO los instala):
#   - Ubuntu 22.04 o 24.04 LTS
#   - Apache 2.4 ya instalado y funcionando
#   - PHP ya instalado y funcionando con Apache (libapache2-mod-php)
#   - MariaDB o MySQL ya instalado y funcionando
#   - Una base de datos y un usuario YA CREADOS en MariaDB con permisos sobre ella
#
set -euo pipefail

# ============================================================================
# CONFIGURACIÓN — edita estos valores antes de correr el script,
# o expórtalos como variables de entorno antes de invocarlo.
# ============================================================================

OSPOS_VERSION="${OSPOS_VERSION:-3.4.1}"
INSTALL_DIR="${INSTALL_DIR:-/var/www/ospos}"
APACHE_SITE_NAME="${APACHE_SITE_NAME:-ospos}"

DB_HOST="${DB_HOST:-localhost}"
DB_NAME="${DB_NAME:-ospos}"
DB_USER="${DB_USER:-ospos}"
DB_PASSWORD="${DB_PASSWORD:-}"          # Si se deja vacío, el script lo pedirá interactivamente.

APP_BASE_URL="${APP_BASE_URL:-http://localhost/}"
APP_TIMEZONE="${APP_TIMEZONE:-America/Mexico_City}"
SYSTEM_LOCALE="${SYSTEM_LOCALE:-es_MX.UTF-8}"

GITHUB_REPO="opensourcepos/opensourcepos"

# Extensiones que OSPOS valida activamente en cada login
# (app/Config/Validation/OSPOSRules.php::installation_check())
REQUIRED_PHP_EXTENSIONS=(bcmath intl gd openssl mbstring curl xml json)
REQUIRED_APT_PACKAGES=(php-bcmath php-intl php-gd php-mbstring php-curl php-xml php-mysql unzip curl)

# Estado interno (no editar)
DRY_RUN=false
DO_UNINSTALL=false
DO_HTTPS=false
STATE_FILE="${INSTALL_DIR}/.install_state"

# ============================================================================
# Utilidades de salida con color
# ============================================================================

if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

log_step()    { echo -e "${C_BLUE}${C_BOLD}==>${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}    ✓${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}    ⚠${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}${C_BOLD}ERROR:${C_RESET} $*" >&2; }
log_dryrun()  { echo -e "${C_YELLOW}    [DRY-RUN]${C_RESET} $*"; }

# Ejecuta un comando, o solo lo describe si estamos en --dry-run
run() {
    if $DRY_RUN; then
        log_dryrun "$*"
    else
        "$@"
    fi
}

# ============================================================================
# Parseo de argumentos
# ============================================================================

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --uninstall) DO_UNINSTALL=true ;;
        --https) DO_HTTPS=true ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            log_error "Argumento desconocido: $arg (usa --help para ver opciones)"
            exit 1
            ;;
    esac
done

# ============================================================================
# Funciones de estado (permiten reanudar el script si falla a la mitad)
# ============================================================================

step_done() {
    [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

mark_step_done() {
    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$STATE_FILE")"
        echo "$1" >> "$STATE_FILE"
    fi
}

# ============================================================================
# Desinstalación
# ============================================================================

do_uninstall() {
    log_step "Desinstalando OSPOS de $INSTALL_DIR ..."

    if [[ -f "/etc/apache2/sites-enabled/${APACHE_SITE_NAME}.conf" ]]; then
        run a2dissite "${APACHE_SITE_NAME}.conf"
    fi
    if [[ -f "/etc/apache2/sites-available/${APACHE_SITE_NAME}.conf" ]]; then
        run rm -f "/etc/apache2/sites-available/${APACHE_SITE_NAME}.conf"
    fi
    if [[ -d "$INSTALL_DIR" ]]; then
        run rm -rf "$INSTALL_DIR"
    fi
    run systemctl reload apache2 || true

    log_ok "Archivos de la aplicación y VirtualHost eliminados."
    log_warn "La base de datos '$DB_NAME' NO se tocó — bórrala manualmente si ya no la necesitas:"
    echo "        mysql -u root -e \"DROP DATABASE ${DB_NAME};\""
    exit 0
}

# ============================================================================
# Validaciones previas (fail-fast): si algo no está listo, el script se
# detiene aquí con un mensaje claro, ANTES de descargar o instalar nada.
# ============================================================================

preflight_checks() {
    log_step "Validando requisitos previos..."
    local fail=false

    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe correrse con sudo/root."
        exit 1
    fi

    # --- Sistema operativo ---
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            log_warn "Este script fue probado en Ubuntu; detecté '${ID:-desconocido}'. Puede funcionar, pero sin garantía."
        else
            log_ok "Sistema operativo: Ubuntu ${VERSION_ID:-desconocida}"
        fi
    fi

    # --- PHP instalado y versión detectada ---
    if ! command -v php >/dev/null 2>&1; then
        log_error "PHP no está instalado. Instálalo primero, ej.: sudo apt install php8.1 libapache2-mod-php8.1"
        fail=true
    else
        PHP_VERSION_DETECTED="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
        log_ok "PHP detectado: versión $PHP_VERSION_DETECTED"
        if [[ "$(php -r 'echo PHP_MAJOR_VERSION;')" -lt 8 ]]; then
            log_error "OSPOS 3.4.x requiere PHP 8.x. Detecté PHP $PHP_VERSION_DETECTED."
            fail=true
        fi
    fi

    # --- Apache instalado y corriendo ---
    if ! command -v apache2 >/dev/null 2>&1; then
        log_error "Apache no está instalado. Instálalo primero, ej.: sudo apt install apache2"
        fail=true
    elif ! systemctl is-active --quiet apache2; then
        log_error "Apache está instalado pero no corriendo. Intenta: sudo systemctl start apache2"
        fail=true
    else
        log_ok "Apache está instalado y corriendo."
    fi

    # --- MariaDB/MySQL corriendo ---
    if ! command -v mysql >/dev/null 2>&1; then
        log_error "El cliente 'mysql' no está instalado. Instala MariaDB primero, ej.: sudo apt install mariadb-server"
        fail=true
    elif ! (systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql); then
        log_error "MariaDB/MySQL no está corriendo. Intenta: sudo systemctl start mariadb"
        fail=true
    else
        log_ok "MariaDB/MySQL está corriendo."
    fi

    if $fail; then
        log_error "Corrige los puntos anteriores antes de continuar. El script no modificó nada."
        exit 1
    fi

    # --- Contraseña de la base de datos ---
    if [[ -z "$DB_PASSWORD" ]]; then
        read -rsp "Contraseña del usuario '$DB_USER' de MariaDB para la base '$DB_NAME': " DB_PASSWORD
        echo
    fi

    # --- La base de datos y el usuario ya deben existir y ser accesibles ---
    if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1; then
        log_error "No pude conectarme a la base de datos '$DB_NAME' con el usuario '$DB_USER'."
        log_error "Este script NO crea la base de datos ni el usuario — deben existir antes. Ejemplo:"
        cat >&2 << EOF

    sudo mysql -u root -e "
    CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY 'tu_contraseña';
    GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_HOST}';
    FLUSH PRIVILEGES;
    "

EOF
        exit 1
    fi
    log_ok "Conexión a la base de datos '$DB_NAME' verificada correctamente."

    # --- Si la base de datos ya tiene tablas, advertir (podríamos pisar datos) ---
    TABLE_COUNT="$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -N -B -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${DB_NAME}';" 2>/dev/null || echo 0)"
    if [[ "$TABLE_COUNT" -gt 0 ]] && ! step_done "database_imported"; then
        log_warn "La base de datos '$DB_NAME' ya tiene $TABLE_COUNT tabla(s)."
        log_warn "Si es una instalación nueva, considera usar una base vacía para evitar conflictos."
        read -rp "    ¿Continuar de todas formas? [s/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado por el usuario."; exit 1; }
    fi

    log_ok "Todas las validaciones previas pasaron."
}

# ============================================================================
# Instalación
# ============================================================================

do_install() {
    mkdir -p "$INSTALL_DIR"
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    # --- Paso 1: dependencias del sistema ---
    if step_done "dependencies"; then
        log_step "[1/10] Dependencias del sistema (ya aplicado, saltando)"
    else
        log_step "[1/10] Instalando dependencias del sistema..."
        run apt-get update -qq
        run apt-get install -y -qq "${REQUIRED_APT_PACKAGES[@]}"
        for ext in bcmath intl gd mbstring curl xml mysqli; do
            run phpenmod "$ext" || true
        done

        log_step "[1/10] Verificando extensiones PHP requeridas por OSPOS..."
        MISSING_EXTENSIONS=()
        for ext in "${REQUIRED_PHP_EXTENSIONS[@]}"; do
            if ! php -m | grep -qi "^${ext}$"; then
                MISSING_EXTENSIONS+=("$ext")
            fi
        done
        if [[ ${#MISSING_EXTENSIONS[@]} -gt 0 ]] && ! $DRY_RUN; then
            log_error "Faltan extensiones de PHP: ${MISSING_EXTENSIONS[*]}"
            log_error "Instálalas manualmente (el nombre de paquete puede variar según tu distro) y vuelve a correr el script."
            exit 1
        fi

        log_step "[1/10] Generando locale $SYSTEM_LOCALE..."
        run locale-gen "$SYSTEM_LOCALE" || true
        run update-locale || true
        run systemctl restart apache2 || true

        mark_step_done "dependencies"
        log_ok "Dependencias instaladas y verificadas."
    fi

    # --- Paso 2: descarga ---
    ZIP_CACHE="/var/cache/ospos-installer-${OSPOS_VERSION}.zip"
    if [[ -f "$ZIP_CACHE" ]]; then
        log_step "[2/10] Usando paquete ya descargado en caché ($ZIP_CACHE)"
        cp "$ZIP_CACHE" "$WORKDIR/ospos.zip"
    else
        log_step "[2/10] Buscando el asset de descarga para la release $OSPOS_VERSION..."
        ASSET_URL="$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${OSPOS_VERSION}" \
            | grep "browser_download_url.*zip" | cut -d '"' -f 4 | head -n1)"
        if [[ -z "$ASSET_URL" ]]; then
            log_error "No se pudo encontrar el .zip para la versión $OSPOS_VERSION en GitHub."
            exit 1
        fi
        log_ok "Descargando: $ASSET_URL"
        if ! $DRY_RUN; then
            curl -sL -o "$WORKDIR/ospos.zip" "$ASSET_URL"
            mkdir -p /var/cache
            cp "$WORKDIR/ospos.zip" "$ZIP_CACHE"
        else
            log_dryrun "curl -sL -o ospos.zip $ASSET_URL"
        fi
    fi

    # --- Paso 3: extraer y desplegar ---
    if step_done "extracted"; then
        log_step "[3/10] Archivos ya extraídos en $INSTALL_DIR (saltando)"
    else
        log_step "[3/10] Extrayendo e instalando en $INSTALL_DIR ..."
        if ! $DRY_RUN; then
            mkdir -p "$WORKDIR/extracted"
            unzip -q "$WORKDIR/ospos.zip" -d "$WORKDIR/extracted"
            cp -r "$WORKDIR"/extracted/. "$INSTALL_DIR"/
            chown -R www-data:www-data "$INSTALL_DIR"
            find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
            find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
            chmod -R 775 "$INSTALL_DIR/writable"
        else
            log_dryrun "unzip ospos.zip -> $INSTALL_DIR (con permisos www-data)"
        fi
        mark_step_done "extracted"
        log_ok "Archivos desplegados."
    fi

    # --- Paso 4: BUG FIX Config\Locale ---
    log_step "[4/10] Aplicando fix de la clase Config\\Locale faltante..."
    if ! $DRY_RUN; then
        cat > "$INSTALL_DIR/app/Config/Locale.php" << 'PHPEOF'
<?php

namespace Config;

/**
 * Clase puente: Config\Services::language() referencia "Locale::getDefault()"
 * sin barra invertida inicial, así que PHP la resuelve dentro del namespace
 * Config en vez de usar la clase nativa \Locale (extensión intl). Este
 * archivo no viene incluido en el paquete de distribución 3.4.1 oficial.
 * Requiere la extensión PHP "intl".
 */
class Locale extends \Locale
{
}
PHPEOF
        chown www-data:www-data "$INSTALL_DIR/app/Config/Locale.php"
    else
        log_dryrun "crear app/Config/Locale.php (clase puente hacia \\Locale nativo)"
    fi
    log_ok "Fix de Locale aplicado."

    # --- Paso 5: descargar spark ---
    if step_done "spark_downloaded"; then
        log_step "[5/10] 'spark' ya descargado (saltando)"
    else
        log_step "[5/10] Descargando 'spark'..."
        if ! $DRY_RUN; then
            curl -sL -o "$INSTALL_DIR/spark" \
                "https://raw.githubusercontent.com/${GITHUB_REPO}/${OSPOS_VERSION}/spark"
            chmod +x "$INSTALL_DIR/spark"
            chown www-data:www-data "$INSTALL_DIR/spark"
        else
            log_dryrun "curl -o spark https://raw.githubusercontent.com/${GITHUB_REPO}/${OSPOS_VERSION}/spark"
        fi
        mark_step_done "spark_downloaded"
        log_ok "'spark' descargado."
    fi

    # --- Paso 6: .env ---
    log_step "[6/10] Generando .env ..."
    if ! $DRY_RUN; then
        ENCRYPTION_KEY="hex2bin:$(php -r 'echo bin2hex(random_bytes(32));')"
        cat > "$INSTALL_DIR/.env" << EOF
CI_ENVIRONMENT = production
CI_DEBUG = false

app.baseURL = '${APP_BASE_URL}'
app.appTimezone = '${APP_TIMEZONE}'

encryption.key = '${ENCRYPTION_KEY}'

database.default.hostname = '${DB_HOST}'
database.default.database = '${DB_NAME}'
database.default.username = '${DB_USER}'
database.default.password = '${DB_PASSWORD}'
database.default.DBDriver = 'MySQLi'
database.default.DBPrefix = 'ospos_'
database.default.port = 3306
EOF
        chown www-data:www-data "$INSTALL_DIR/.env"
        chmod 640 "$INSTALL_DIR/.env"
    else
        log_dryrun "generar .env con baseURL=${APP_BASE_URL}, timezone=${APP_TIMEZONE}"
    fi
    log_ok ".env generado."

    # --- Paso 7: VirtualHost de Apache ---
    log_step "[7/10] Configurando VirtualHost de Apache..."
    if ! $DRY_RUN; then
        cat > "/etc/apache2/sites-available/${APACHE_SITE_NAME}.conf" << EOF
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot ${INSTALL_DIR}/public

    # BUG FIX: Config/Database.php sólo lee estas variables de entorno,
    # no las claves database.default.* del .env. Ver TROUBLESHOOTING.md
    SetEnv MYSQL_HOST_NAME ${DB_HOST}
    SetEnv MYSQL_USERNAME ${DB_USER}
    SetEnv MYSQL_PASSWORD ${DB_PASSWORD}
    SetEnv MYSQL_DB_NAME ${DB_NAME}

    <Directory ${INSTALL_DIR}/public>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APACHE_SITE_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${APACHE_SITE_NAME}_access.log combined
</VirtualHost>
EOF
        a2enmod rewrite >/dev/null
        a2enmod env >/dev/null
        a2ensite "${APACHE_SITE_NAME}.conf" >/dev/null
        a2dissite 000-default.conf >/dev/null 2>&1 || true
        apache2ctl configtest

        if $DO_HTTPS; then
            log_step "    Configurando HTTPS con certificado autofirmado..."
            a2enmod ssl >/dev/null
            mkdir -p "/etc/ssl/ospos"
            if [[ ! -f "/etc/ssl/ospos/ospos.key" ]]; then
                openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                    -keyout "/etc/ssl/ospos/ospos.key" \
                    -out "/etc/ssl/ospos/ospos.crt" \
                    -subj "/C=MX/ST=NA/L=NA/O=OSPOS/CN=localhost" >/dev/null 2>&1
            fi
            cat >> "/etc/apache2/sites-available/${APACHE_SITE_NAME}.conf" << EOF

<VirtualHost *:443>
    ServerName localhost
    DocumentRoot ${INSTALL_DIR}/public

    SSLEngine on
    SSLCertificateFile /etc/ssl/ospos/ospos.crt
    SSLCertificateKeyFile /etc/ssl/ospos/ospos.key

    SetEnv MYSQL_HOST_NAME ${DB_HOST}
    SetEnv MYSQL_USERNAME ${DB_USER}
    SetEnv MYSQL_PASSWORD ${DB_PASSWORD}
    SetEnv MYSQL_DB_NAME ${DB_NAME}

    <Directory ${INSTALL_DIR}/public>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APACHE_SITE_NAME}_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/${APACHE_SITE_NAME}_ssl_access.log combined
</VirtualHost>
EOF
            apache2ctl configtest
            log_warn "Certificado AUTOFIRMADO — el navegador mostrará una advertencia de seguridad (normal en pruebas locales)."
        fi
    else
        log_dryrun "crear VirtualHost en /etc/apache2/sites-available/${APACHE_SITE_NAME}.conf"
        $DO_HTTPS && log_dryrun "generar certificado autofirmado y VirtualHost :443"
    fi
    log_ok "Apache configurado."

    # --- Paso 8: importar esquema base ---
    if step_done "database_imported"; then
        log_step "[8/10] Esquema base ya importado (saltando)"
    else
        log_step "[8/10] Importando esquema base (database.sql)..."
        run bash -c "mysql -h '$DB_HOST' -u '$DB_USER' -p'$DB_PASSWORD' '$DB_NAME' < '$INSTALL_DIR/app/Database/database.sql'"
        mark_step_done "database_imported"
        log_ok "Esquema base importado."
    fi

    # --- Paso 9: migraciones reales ---
    if step_done "migrated"; then
        log_step "[9/10] Migraciones ya aplicadas (saltando)"
    else
        log_step "[9/10] Ejecutando migraciones reales de OSPOS (puede tardar un minuto)..."
        if ! $DRY_RUN; then
            cd "$INSTALL_DIR"
            sudo -u www-data \
                MYSQL_HOST_NAME="$DB_HOST" \
                MYSQL_USERNAME="$DB_USER" \
                MYSQL_PASSWORD="$DB_PASSWORD" \
                MYSQL_DB_NAME="$DB_NAME" \
                php spark migrate --force
        else
            log_dryrun "php spark migrate --force"
        fi
        mark_step_done "migrated"
        log_ok "Migraciones completas."
    fi

    # --- Paso 10: reiniciar Apache ---
    log_step "[10/10] Reiniciando Apache..."
    run systemctl restart apache2
    log_ok "Apache reiniciado."

    if $DRY_RUN; then
        echo
        log_warn "Esto fue un --dry-run: no se modificó nada en el sistema."
        exit 0
    fi

    cat << EOF

${C_GREEN}${C_BOLD}============================================================================
 ¡Instalación completa!
============================================================================${C_RESET}

 URL:       ${APP_BASE_URL}
 Usuario:   admin
 Password:  pointofsale   <-- CÁMBIALA en el primer login

 IMPORTANTE:
   - Revisa TROUBLESHOOTING.md para entender cada corrección aplicada.
   - Configura Localization e Impuestos según tu país desde
     Config -> Localization y Config -> Taxes dentro de la aplicación.
   - Para desinstalar: sudo ./install-ospos.sh --uninstall

============================================================================
EOF
}

# ============================================================================
# Punto de entrada
# ============================================================================

if $DO_UNINSTALL; then
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe correrse con sudo/root."
        exit 1
    fi
    do_uninstall
fi

preflight_checks
do_install
