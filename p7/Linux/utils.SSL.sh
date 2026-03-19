#!/bin/bash
#
# utilsSSL.sh -- Constantes globales y helpers compartidos para SSL/TLS
#

[[ -n "${_SSL_UTILS_LOADED:-}" ]] && return 0
readonly _SSL_UTILS_LOADED=1

# ------------------------------------------------------------
# Constantes de certificado
# ------------------------------------------------------------

readonly SSL_DIR="/etc/ssl/reprobados"
readonly SSL_CERT="${SSL_DIR}/reprobados.crt"
readonly SSL_KEY="${SSL_DIR}/reprobados.key"
readonly SSL_DOMAIN="reprobados.com"
readonly SSL_DAYS=365
readonly SSL_KEY_BITS=2048
readonly SSL_SUBJECT="/C=MX/ST=Mexico/L=Mexico City/O=Administracion de Sistemas/OU=Practica7/CN=${SSL_DOMAIN}"

# ------------------------------------------------------------
# Constantes del repositorio FTP
# ------------------------------------------------------------

readonly SSL_FTP_ROOT="/srv/ftp"
readonly SSL_FTP_CHROOT="${SSL_FTP_ROOT}/ftp_repo"        # raiz chroot del usuario repo
readonly SSL_FTP_USER="repo"                               # usuario FTP local
readonly SSL_FTP_RED_INTERNA="192.168.100"                 # red interna excluida

# Detectar la primera IP del servidor que NO sea la red interna ni loopback
_ssl_detectar_ip() {
    hostname -I 2>/dev/null \
        | tr ' ' '\n' \
        | grep -v "^$" \
        | grep -v "^127\." \
        | grep -v "^::1" \
        | grep -v "^${SSL_FTP_RED_INTERNA}\." \
        | head -1
}
readonly SSL_FTP_IP="$(_ssl_detectar_ip)"
readonly SSL_REPO_ROOT="${SSL_FTP_ROOT}/repositorio"       # ubicacion fisica del repo
readonly SSL_REPO_LINUX="${SSL_REPO_ROOT}/http/Linux"
readonly SSL_REPO_APACHE="${SSL_REPO_LINUX}/Apache"
readonly SSL_REPO_NGINX="${SSL_REPO_LINUX}/Nginx"
readonly SSL_REPO_TOMCAT="${SSL_REPO_LINUX}/Tomcat"

# ------------------------------------------------------------
# Constantes de puertos SSL
# ------------------------------------------------------------

readonly SSL_PUERTO_HTTPS_APACHE=443
readonly SSL_PUERTO_HTTPS_ALT=8443
readonly SSL_PUERTO_HTTPS_TOMCAT=8444

# ------------------------------------------------------------
# Constantes de configuracion de servicios
# ------------------------------------------------------------

readonly SSL_CONF_APACHE="/etc/httpd/conf/httpd.conf"
readonly SSL_CONF_APACHE_SSL="/etc/httpd/conf.d/ssl_reprobados.conf"
readonly SSL_CONF_NGINX="/etc/nginx/nginx.conf"
readonly SSL_CONF_VSFTPD="/etc/vsftpd/vsftpd.conf"

SSL_CONF_TOMCAT() {
    local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
    echo "${catalina}/conf/server.xml"
}

SSL_KEYSTORE_TOMCAT() {
    local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
    echo "${catalina}/conf/reprobados.p12"
}

# ------------------------------------------------------------
# Helpers de output -- sin colores
# ------------------------------------------------------------

aputs_info() {
    echo "  [INFO]    $1"
}

aputs_success() {
    echo "  [OK]      $1"
}

aputs_warning() {
    echo "  [AVISO]   $1"
}

aputs_error() {
    echo "  [ERROR]   $1" >&2
}

draw_line() {
    echo "  ----------------------------------------------------------"
}

pause() {
    echo ""
    read -rp "  Presione Enter para continuar..." _
}

# ------------------------------------------------------------
# Helpers de estado
# ------------------------------------------------------------

ssl_cert_existe() {
    [[ -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]
}

ssl_servicio_instalado() {
    local paquete="$1"
    rpm -q "$paquete" &>/dev/null
}

ssl_servicio_activo() {
    local svc="$1"
    systemctl is-active --quiet "$svc" 2>/dev/null
}

ssl_puerto_https() {
    local http_port="$1"
    case "$http_port" in
        80)   echo "443"  ;;
        8080) echo "8443" ;;
        *)    echo $(( http_port + 363 )) ;;
    esac
}

ssl_leer_puerto_http() {
    local servicio="$1"

    if declare -f _http_leer_puerto_config &>/dev/null; then
        _http_leer_puerto_config "$servicio"
        return
    fi

    case "$servicio" in
        httpd)
            grep -E "^Listen\s+[0-9]+" "${SSL_CONF_APACHE}" 2>/dev/null \
                | awk '{print $2}' | head -1 || echo "80"
            ;;
        nginx)
            grep -E "^\s+listen\s+[0-9]+" "${SSL_CONF_NGINX}" 2>/dev/null \
                | grep -v ' ssl' \
                | grep -oP '\d+' | head -1 || echo "80"
            ;;
        tomcat)
            grep 'protocol="HTTP/1.1"' "$(SSL_CONF_TOMCAT)" 2>/dev/null \
                | grep -oP 'port="\K[0-9]+' | head -1 || echo "8080"
            ;;
        *)
            echo "80"
            ;;
    esac
}

ssl_mostrar_banner() {
    local titulo="${1:-SSL/TLS}"
    echo ""
    echo "  =========================================================="
    echo "    ${titulo}"
    echo "  =========================================================="
    echo ""
}

ssl_verificar_prereqs() {
    local faltantes=0

    aputs_info "Verificando herramientas SSL..."
    echo ""

    if command -v openssl &>/dev/null; then
        local ver
        ver=$(openssl version 2>/dev/null | head -1)
        printf "  [OK]  openssl    -- %s\n" "$ver"
    else
        printf "  [NO]  openssl    -- NO encontrado\n"
        aputs_info "        Instalar con: sudo dnf install openssl -y"
        faltantes=$(( faltantes + 1 ))
    fi

    if rpm -q mod_ssl &>/dev/null; then
        printf "  [OK]  mod_ssl    -- instalado\n"
    else
        printf "  [--]  mod_ssl    -- no instalado (necesario para Apache SSL)\n"
        aputs_info "        Se instalara automaticamente al aplicar SSL a Apache"
    fi

    if command -v keytool &>/dev/null; then
        printf "  [OK]  keytool    -- disponible (JDK presente)\n"
    else
        printf "  [--]  keytool    -- no encontrado (necesario para Tomcat SSL)\n"
        aputs_info "        Se instalara con: sudo dnf install java-17-openjdk -y"
    fi

    if command -v curl &>/dev/null; then
        printf "  [OK]  curl       -- disponible\n"
    else
        printf "  [NO]  curl       -- NO encontrado\n"
        faltantes=$(( faltantes + 1 ))
    fi

    echo ""

    if [[ "$faltantes" -gt 0 ]]; then
        aputs_error "${faltantes} herramienta(s) critica(s) faltante(s)"
        return 1
    fi

    aputs_success "Herramientas SSL verificadas"
    return 0
}

ssl_abrir_puerto_firewall() {
    local puerto="$1"

    firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null
    firewall-cmd --reload &>/dev/null
    aputs_success "Puerto ${puerto}/tcp abierto en firewall (permanente)"

    if command -v semanage &>/dev/null; then
        if ! semanage port -l | grep -q "^http_port_t.*tcp.*\b${puerto}\b"; then
            semanage port -a -t http_port_t -p tcp "${puerto}" &>/dev/null \
                || semanage port -m -t http_port_t -p tcp "${puerto}" &>/dev/null
            aputs_success "Puerto ${puerto}/tcp registrado en SELinux (http_port_t)"
        fi
    fi
}

ssl_hacer_backup() {
    local archivo="$1"

    [[ ! -f "$archivo" ]] && return 0

    if declare -f http_crear_backup &>/dev/null; then
        http_crear_backup "$archivo"
        return
    fi

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local backup="${archivo}.bak_ssl_${ts}"

    if cp "$archivo" "$backup" 2>/dev/null; then
        aputs_success "Backup: ${backup}"
    else
        aputs_error "No se pudo crear backup de: ${archivo}"
        return 1
    fi
}

ssl_leer_puerto_https() {
    local servicio="$1"
    local puerto=""

    case "$servicio" in
        httpd)
            if [[ -f "${SSL_CONF_APACHE_SSL}" ]]; then
                puerto=$(grep -E "^Listen\s+[0-9]+" "${SSL_CONF_APACHE_SSL}" 2>/dev/null \
                    | awk '{print $2}' | head -1) || true
            fi
            ;;
        nginx)
            if [[ -f "${SSL_CONF_NGINX}" ]]; then
                puerto=$(grep -E "^\s+listen\s+[0-9]+\s+ssl" "${SSL_CONF_NGINX}" 2>/dev/null \
                    | grep -oP '\d+' | head -1) || true
            fi
            ;;
        tomcat)
            local server_xml
            server_xml=$(SSL_CONF_TOMCAT 2>/dev/null)
            if [[ -f "$server_xml" ]]; then
                puerto=$(python3 - "$server_xml" 2>/dev/null << 'PYEOF_TOMCAT'
import sys, re
server_xml = sys.argv[1]
try:
    with open(server_xml) as f:
        content = f.read()
    idx = content.find("Practica7 SSL")
    if idx >= 0:
        snippet = content[idx:idx+500]
        m = re.search(r'port="(\d+)"', snippet)
        if m:
            print(m.group(1))
            sys.exit(0)
    idx = content.find('SSLEnabled="true"')
    while idx >= 0:
        start = content.rfind('<Connector', 0, idx)
        if start >= 0:
            snippet = content[start:idx+200]
            m = re.search(r'port="(\d+)"', snippet)
            if m:
                print(m.group(1))
                sys.exit(0)
        idx = content.find('SSLEnabled="true"', idx+1)
except Exception:
    pass
PYEOF_TOMCAT
) || true
            fi
            ;;
    esac

    if [[ -z "$puerto" ]]; then
        local http_port
        http_port=$(ssl_leer_puerto_http "$servicio")
        puerto=$(ssl_puerto_https "$http_port")
    fi

    echo "$puerto"
}

# ------------------------------------------------------------
# Exportar
# ------------------------------------------------------------
export SSL_DIR SSL_CERT SSL_KEY SSL_DOMAIN SSL_DAYS SSL_KEY_BITS SSL_SUBJECT
export SSL_FTP_ROOT SSL_FTP_CHROOT SSL_FTP_USER SSL_FTP_IP SSL_FTP_RED_INTERNA
export SSL_REPO_ROOT SSL_REPO_LINUX
export SSL_REPO_APACHE SSL_REPO_NGINX SSL_REPO_TOMCAT
export SSL_PUERTO_HTTPS_APACHE SSL_PUERTO_HTTPS_ALT SSL_PUERTO_HTTPS_TOMCAT
export SSL_CONF_APACHE SSL_CONF_APACHE_SSL SSL_CONF_NGINX SSL_CONF_VSFTPD

export -f SSL_CONF_TOMCAT
export -f SSL_KEYSTORE_TOMCAT
export -f ssl_cert_existe
export -f ssl_servicio_instalado
export -f ssl_servicio_activo
export -f ssl_puerto_https
export -f ssl_leer_puerto_http
export -f ssl_leer_puerto_https
export -f ssl_mostrar_banner
export -f ssl_verificar_prereqs
export -f ssl_abrir_puerto_firewall
export -f ssl_hacer_backup
export -f aputs_info
export -f aputs_success
export -f aputs_warning
export -f aputs_error
export -f draw_line
export -f pause
