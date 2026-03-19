#!/bin/bash
#
# installFTP.sh -- Instalacion de servicios HTTP desde el repositorio FTP propio
#

[[ -n "${_INSTALL_FTP_LOADED:-}" ]] && return 0
readonly _INSTALL_FTP_LOADED=1

# ------------------------------------------------------------
# Configuracion de sesion FTP
# ------------------------------------------------------------

_FTP_HOST=""
_FTP_USER="${SSL_FTP_USER:-repo}"
_FTP_PASS=""
_FTP_REPO_PATH="/repositorio/http/Linux"
_FTP_TMP="/tmp/ftp_install"

# ------------------------------------------------------------
# Verificar e instalar lftp
# ------------------------------------------------------------

_ftp_check_lftp() {
    if ! command -v lftp &>/dev/null; then
        aputs_info "lftp no encontrado -- instalando..."
        dnf install -y lftp &>/dev/null \
            && aputs_success "lftp instalado" \
            || { aputs_error "No se pudo instalar lftp"; return 1; }
    fi
}

# ------------------------------------------------------------
# Conectar al servidor FTP
# ------------------------------------------------------------

_ftp_conectar() {
    clear
    ssl_mostrar_banner "Conexion al Repositorio FTP"

    _FTP_HOST="${SSL_FTP_IP}"
    _FTP_USER="${SSL_FTP_USER}"

    echo ""
    printf "  %-12s %s\n" "Servidor:" "ftp://${_FTP_HOST}"
    printf "  %-12s %s\n" "Usuario:"  "${_FTP_USER}"
    echo ""

    read -rsp "  Contrasena: " _FTP_PASS
    echo ""
    echo ""

    aputs_info "Verificando conexion a ftp://${_FTP_HOST}..."

    if ! _ftp_exec "ls ${_FTP_REPO_PATH}/" &>/dev/null; then
        aputs_error "No se pudo conectar o autenticar"
        aputs_info  "Verifique que el servidor FTP esta activo y la contrasena es correcta"
        return 1
    fi

    aputs_success "Conexion establecida con ftp://${_FTP_HOST}"
    echo ""
}

# ------------------------------------------------------------
# Ejecutar comando lftp con sesion TLS
# ------------------------------------------------------------

_ftp_exec() {
    local cmd="$1"
    local script
    script=$(mktemp /tmp/lftp_XXXXXX)
    cat > "$script" << LFTPEOF
set ssl:verify-certificate no
set ssl:check-hostname no
set ftp:ssl-force yes
set ftp:ssl-allow yes
set ftp:passive-mode yes
open ftp://${_FTP_HOST}
user ${_FTP_USER} ${_FTP_PASS}
${cmd}
bye
LFTPEOF
    lftp -f "$script" 2>/dev/null
    local rc=$?
    rm -f "$script"
    return $rc
}

# ------------------------------------------------------------
# Listar contenido de un directorio FTP
# ------------------------------------------------------------

_ftp_listar_dir() {
    local dir="$1"
    _ftp_exec "cls --sort=name ${dir}" 2>/dev/null \
        | grep -v "^$" \
        | sed 's|/$||' \
        | awk -F'/' '{print $NF}'
}

# ------------------------------------------------------------
# Descargar RPMs de un directorio FTP
# ------------------------------------------------------------

_ftp_descargar_dir() {
    local remote="$1" local_dest="$2"
    mkdir -p "$local_dest"

    aputs_info "Descargando desde ftp://${_FTP_HOST}${remote}..."

    lftp -u "${_FTP_USER},${_FTP_PASS}" \
         -e "set ssl:verify-certificate no; \
             set ftp:ssl-force yes; \
             set ftp:passive-mode yes; \
             cd ${remote}; \
             mget -O ${local_dest} *.rpm; \
             bye" \
         "ftp://${_FTP_HOST}" &>/dev/null

    local cnt
    cnt=$(find "$local_dest" -name "*.rpm" 2>/dev/null | wc -l)

    if [[ "$cnt" -eq 0 ]]; then
        aputs_error "No se descargaron RPMs desde ${remote}"
        return 1
    fi

    aputs_success "${cnt} RPM(s) descargados en ${local_dest}"
}

# ------------------------------------------------------------
# Mapeos de nombres
# ------------------------------------------------------------

_ftp_svc_p6() {
    case "${1,,}" in
        apache) echo "apache2" ;;
        nginx)  echo "nginx"   ;;
        tomcat) echo "tomcat"  ;;
    esac
}

_ftp_svc_systemd() {
    case "${1,,}" in
        apache) echo "httpd"  ;;
        nginx)  echo "nginx"  ;;
        tomcat) echo "tomcat" ;;
    esac
}

_ftp_svc_rpm() {
    case "${1,,}" in
        apache) echo "httpd"  ;;
        nginx)  echo "nginx"  ;;
        tomcat) echo "tomcat" ;;
    esac
}

_ftp_puerto_default() {
    case "${1,,}" in
        apache) echo "80"   ;;
        nginx)  echo "8080" ;;
        tomcat) echo "8080" ;;
    esac
}

# Lee el puerto HTTP actualmente configurado para el servicio
_ftp_leer_puerto_actual() {
    local servicio="$1"
    case "${servicio,,}" in
        apache)
            grep -E "^Listen\s+[0-9]+" /etc/httpd/conf/httpd.conf 2>/dev/null \
                | awk '{print $2}' | head -1 \
                || echo "80"
            ;;
        nginx)
            grep -E "^\s+listen\s+[0-9]+" /etc/nginx/conf.d/ssl_reprobados.conf \
                /etc/nginx/nginx.conf 2>/dev/null \
                | grep -v ' ssl' | grep -oP '\d+' | head -1 \
                || echo "8080"
            ;;
        tomcat)
            grep -oP '(?<=port=")[0-9]+' /etc/tomcat/server.xml 2>/dev/null \
                | head -1 || echo "8080"
            ;;
        *) echo "80" ;;
    esac
}

_ftp_https_port_default() {
    case "${1,,}" in
        apache) echo "443"  ;;
        nginx)  echo "8443" ;;
        tomcat) echo "8444" ;;
    esac
}

# ------------------------------------------------------------
# Verificar si un servicio esta instalado
# ------------------------------------------------------------

_ftp_esta_instalado() {
    local servicio="$1"
    local pkg
    pkg=$(_ftp_svc_rpm "$servicio")
    rpm -q "$pkg" &>/dev/null
}

# ------------------------------------------------------------
# Menu para servicio ya instalado
# ------------------------------------------------------------

_ftp_menu_ya_instalado() {
    local servicio="$1"
    local svc_sd svc_rpm
    svc_sd=$(_ftp_svc_systemd "$servicio")
    svc_rpm=$(_ftp_svc_rpm "$servicio")

    clear
    ssl_mostrar_banner "Repo FTP -- ${servicio}"

    local estado="inactivo"
    systemctl is-active --quiet "$svc_sd" 2>/dev/null && estado="activo"

    aputs_warning "${servicio} ya esta instalado  (${svc_rpm}, servicio: ${estado})"
    echo ""
    echo "  Que desea hacer?"
    echo ""
    echo "  1) Reinstalar (sobreescribir con version del FTP)"
    echo "  2) Reconfigurar puerto HTTP"
    echo "  3) Configurar / reconfigurar SSL"
    echo "  4) Desinstalar ${servicio}"
    echo "  0) Cancelar"
    echo ""

    local op
    read -rp "  Opcion: " op
    echo "$op"
}

# ------------------------------------------------------------
# Reconfigurar puerto de un servicio instalado
# ------------------------------------------------------------

_ftp_reconfigurar_puerto() {
    local servicio="$1"
    local svc_p6 svc_sd puerto_default puerto
    svc_p6=$(_ftp_svc_p6 "$servicio")
    svc_sd=$(_ftp_svc_systemd "$servicio")
    puerto_default=$(_ftp_leer_puerto_actual "$servicio" "$svc_p6")

    echo ""
    read -rp "  Nuevo puerto HTTP [${puerto_default}]: " puerto
    puerto="${puerto:-$puerto_default}"

    local p6_functions="${SCRIPT_DIR}/../P6/http_functions.sh"
    if [[ -f "$p6_functions" ]]; then
        source "$p6_functions" 2>/dev/null
        aputs_info "Aplicando puerto ${puerto}..."
        _http_aplicar_puerto "$svc_p6" "$puerto" 2>/dev/null || true
        _http_fw_abrir "$puerto" 2>/dev/null || true
    else
        case "${servicio,,}" in
            apache) sed -i "s/^Listen .*/Listen ${puerto}/" /etc/httpd/conf/httpd.conf 2>/dev/null || true ;;
            nginx)  sed -i "s/listen\s\+[0-9]\+/listen ${puerto}/g" /etc/nginx/nginx.conf 2>/dev/null || true ;;
        esac
        firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi

    # Actualizar el VirtualHost del redirect en ssl_reprobados.conf si existe
    _ftp_ssl_actualizar_http_port "$servicio" "$puerto" || true

    echo ""
    _ftp_reiniciar_servicio "$servicio" "$svc_sd" || true
}

# Actualiza el puerto en el SSL config cuando cambia el puerto del servicio
_ftp_ssl_actualizar_http_port() {
    local servicio="$1" nuevo_puerto="$2"

    case "${servicio,,}" in
        apache)
            local ssl_conf="${SSL_CONF_APACHE_SSL}"
            [[ -f "$ssl_conf" ]] || return 0
            # Modelo de puerto unico: reemplazar todos los puertos en el archivo
            python3 - "$ssl_conf" "$nuevo_puerto" << 'PYEOF'
import sys, re
f, puerto = sys.argv[1], sys.argv[2]
with open(f) as fh:
    content = fh.read()
# Actualizar Listen
content = re.sub(r'^# Puerto: \d+', f'# Puerto: {puerto}', content, flags=re.MULTILINE)
# Actualizar VirtualHost
content = re.sub(r'<VirtualHost \*:\d+>', f'<VirtualHost *:{puerto}>', content)
with open(f, 'w') as fh:
    fh.write(content)
PYEOF
            aputs_success "ssl_reprobados.conf actualizado (puerto: ${nuevo_puerto})"
            ;;
        nginx)
            local ssl_conf="/etc/nginx/conf.d/ssl_reprobados.conf"
            [[ -f "$ssl_conf" ]] || return 0
            # Modelo de puerto unico: listen <puerto> ssl
            sed -i "s/listen [0-9]\+ ssl;/listen ${nuevo_puerto} ssl;/" "$ssl_conf" 2>/dev/null || true
            sed -i "s/# Puerto: [0-9]*/# Puerto: ${nuevo_puerto}/" "$ssl_conf" 2>/dev/null || true
            aputs_success "ssl_reprobados.conf de Nginx actualizado (puerto: ${nuevo_puerto})"
            ;;
        tomcat)
            # Para Tomcat el conector SSL se actualiza regenerando con _ftp_ssl_tomcat
            aputs_info "Regenerando conector SSL de Tomcat en puerto ${nuevo_puerto}..."
            _ftp_ssl_tomcat || true
            ;;
    esac
}

# ------------------------------------------------------------
# Reiniciar servicio con diagnostico de errores
# ------------------------------------------------------------

_ftp_reiniciar_servicio() {
    local servicio="$1" svc_sd="$2"

    # Verificar configuracion antes de reiniciar
    case "${servicio,,}" in
        apache)
            # Eliminar Listen duplicados en conf.d antes de validar
            for conf_f in /etc/httpd/conf.d/*.conf; do
                [[ -f "$conf_f" ]] || continue
                [[ "$conf_f" == "${SSL_CONF_APACHE_SSL}" ]] && continue
                while IFS= read -r port; do
                    [[ -z "$port" ]] && continue
                    if grep -q "^Listen ${port}" "${SSL_CONF_APACHE_SSL}" 2>/dev/null; then
                        sed -i "s|^Listen ${port}.*|# Listen ${port} # comentado por Practica7|" "$conf_f" 2>/dev/null || true
                    fi
                done < <(grep -oP "^Listen \K[0-9]+" "$conf_f" 2>/dev/null)
            done

            if ! apachectl configtest 2>/dev/null; then
                aputs_error "Configuracion de Apache invalida:"
                apachectl configtest 2>&1 | grep -v "^$" | head -15 | sed 's/^/    /'
                aputs_info "Corrija los errores antes de reiniciar"
                return 1
            fi
            ;;
        nginx)
            if ! nginx -t 2>/dev/null; then
                aputs_error "Configuracion de Nginx invalida:"
                nginx -t 2>&1 | grep -v "^$" | head -10 | sed 's/^/    /'
                return 1
            fi
            ;;
    esac

    aputs_info "Reiniciando ${svc_sd}..."

    if systemctl restart "$svc_sd" 2>/dev/null; then
        aputs_success "${servicio} reiniciado correctamente"
    else
        aputs_error "Error al reiniciar ${svc_sd}"
        echo ""
        aputs_info "Ultimas lineas del log:"
        journalctl -u "$svc_sd" --no-pager -n 10 2>/dev/null | sed 's/^/    /' || true
        echo ""
        aputs_info "Ver log completo: journalctl -xeu ${svc_sd} --no-pager | tail -30"
        return 1
    fi
}

# ------------------------------------------------------------
# Desinstalar un servicio
# ------------------------------------------------------------

_ftp_desinstalar() {
    local servicio="$1"
    local svc_rpm svc_sd
    svc_rpm=$(_ftp_svc_rpm "$servicio")
    svc_sd=$(_ftp_svc_systemd "$servicio")

    echo ""
    read -rp "  Confirmar desinstalacion de ${servicio}? [s/N]: " conf
    [[ ! "$conf" =~ ^[sS]$ ]] && { aputs_info "Cancelado"; return 0; }

    systemctl stop "$svc_sd" 2>/dev/null || true
    systemctl disable "$svc_sd" 2>/dev/null || true

    dnf remove -y "$svc_rpm" &>/dev/null \
        && aputs_success "${servicio} desinstalado" \
        || aputs_error "Error al desinstalar ${svc_rpm}"
}

# ------------------------------------------------------------
# Configurar SSL para el servicio instalado
# ------------------------------------------------------------

_ftp_configurar_ssl() {
    local servicio="$1"
    local svc_sd
    svc_sd=$(_ftp_svc_systemd "$servicio")

    echo ""
    draw_line
    echo ""
    aputs_info "Configuracion SSL para ${servicio}"
    echo ""

    # Crear certificado si no existe
    if ! ssl_cert_existe; then
        aputs_warning "No hay certificado SSL -- generando uno ahora..."
        echo ""
        ssl_cert_generar || { aputs_error "No se pudo generar el certificado"; return 1; }
        echo ""
    else
        aputs_success "Certificado existente: ${SSL_CERT}"
        ssl_cert_mostrar_info
    fi

    echo ""
    aputs_info "Aplicando SSL en ${servicio} (usando el puerto HTTP configurado)..."
    echo ""

    case "${servicio,,}" in
        apache)
            _ftp_ssl_apache
            ;;
        nginx)
            _ftp_ssl_nginx
            ;;
        tomcat)
            _ftp_ssl_tomcat
            ;;
    esac

    # Abrir el puerto del servicio en el firewall
    local svc_puerto
    svc_puerto=$(_ftp_leer_puerto_actual "$servicio" 2>/dev/null || true)
    [[ -n "$svc_puerto" ]] && ssl_abrir_puerto_firewall "$svc_puerto" || true

    echo ""
    _ftp_reiniciar_servicio "$servicio" "$svc_sd" || true
}

_ftp_ssl_apache() {
    local puerto
    puerto=$(grep -E "^Listen\s+[0-9]+" "${SSL_CONF_APACHE}" 2>/dev/null | awk '{print $2}' | head -1)
    puerto="${puerto:-80}"

    if ! rpm -q mod_ssl &>/dev/null; then
        aputs_info "Instalando mod_ssl..."
        dnf install -y mod_ssl &>/dev/null && aputs_success "mod_ssl instalado" || true
    fi

    ssl_hacer_backup "${SSL_CONF_APACHE_SSL}"

    # Comentar cualquier Listen ${puerto} en otros conf.d para evitar duplicado
    while IFS= read -r f; do
        [[ "$f" != "${SSL_CONF_APACHE_SSL}" ]] && \
            sed -i "s|^Listen ${puerto}.*|# Listen ${puerto} # comentado por Practica7|" "$f" 2>/dev/null || true
    done < <(grep -rl "^Listen ${puerto}" /etc/httpd/conf.d/ 2>/dev/null || true)

    local server_ip="${SSL_FTP_IP:-}"
    if [[ -z "$server_ip" ]]; then
        server_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
            | grep -v "^127\." \
            | grep -v "^${SSL_FTP_RED_INTERNA:-192.168.100}\." \
            | head -1 || true)
        server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    fi

    cat > "${SSL_CONF_APACHE_SSL}" << EOF
# === Practica7 SSL Apache ===
# Puerto: ${puerto} (HTTPS directo -- sin redirect)

<VirtualHost *:${puerto}>
    ServerName ${server_ip}
    ServerAlias ${SSL_DOMAIN}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile    ${SSL_CERT}
    SSLCertificateKeyFile ${SSL_KEY}
    SSLProtocol all -SSLv2 -SSLv3
    SSLCipherSuite HIGH:!aNULL:!MD5

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog  /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined
</VirtualHost>
EOF

    aputs_success "SSL configurado en Apache puerto ${puerto}"
    aputs_info    "Acceso: https://${server_ip}:${puerto}"
}

_ftp_ssl_nginx() {
    local puerto
    puerto=$(grep -E "^\s+listen\s+[0-9]+" /etc/nginx/conf.d/http-manager.conf 2>/dev/null \
        | grep -v ssl | grep -oP '\d+' | head -1)
    [[ -z "$puerto" ]] && \
        puerto=$(grep -E "^\s+listen\s+[0-9]+" /etc/nginx/nginx.conf 2>/dev/null \
            | grep -v ssl | grep -oP '\d+' | head -1)
    puerto="${puerto:-8080}"

    local server_ip="${SSL_FTP_IP:-}"
    if [[ -z "$server_ip" ]]; then
        server_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
            | grep -v "^127\." \
            | grep -v "^${SSL_FTP_RED_INTERNA:-192.168.100}\." \
            | head -1 || true)
        server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    fi

    local ssl_conf="/etc/nginx/conf.d/ssl_reprobados.conf"
    ssl_hacer_backup "$ssl_conf"

    cat > "$ssl_conf" << EOF
# === Practica7 SSL Nginx ===
# Puerto: ${puerto} (HTTPS directo -- sin redirect)
server {
    listen ${puerto} ssl;
    server_name ${server_ip} ${SSL_DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    root  /usr/share/nginx/html;
    index index.html;

    access_log /var/log/nginx/ssl_access.log;
    error_log  /var/log/nginx/ssl_error.log;
}
EOF
    aputs_success "SSL configurado en Nginx puerto ${puerto}"
    aputs_info    "Acceso: https://${server_ip}:${puerto}"
}

_ftp_ssl_tomcat() {
    local puerto
    puerto=$(_ftp_leer_puerto_actual "tomcat" 2>/dev/null || true)
    puerto="${puerto:-8080}"

    local server_xml keystore
    server_xml="${SSL_CONF_TOMCAT:-/etc/tomcat/server.xml}"
    keystore="${SSL_KEYSTORE_TOMCAT:-/etc/tomcat/reprobados.p12}"

    [[ ! -f "$server_xml" ]] && { aputs_error "server.xml no encontrado: ${server_xml}"; return 1; }

    openssl pkcs12 -export \
        -in "${SSL_CERT}" -inkey "${SSL_KEY}" \
        -out "$keystore" -name reprobados \
        -passout pass:reprobados123 2>/dev/null \
        && aputs_success "Keystore generado: ${keystore}" \
        || { aputs_error "Error al generar keystore"; return 1; }

    ssl_hacer_backup "$server_xml"

    # Reemplazar o agregar conector SSL en el puerto configurado
    python3 - "$server_xml" "$puerto" "$keystore" << 'PYEOF'
import sys, re
f, port, ks = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    content = fh.read()

# Eliminar conector previo de Practica7
content = re.sub(r'\n\s*<!-- Practica7 SSL Tomcat.*?</Connector>\s*\n',
                 '\n', content, flags=re.DOTALL)

# Eliminar Connector HTTP en el mismo puerto para evitar conflicto
content = re.sub(
    r'<Connector\s[^>]*port="' + port + r'"[^>]*(?:/>|>.*?</Connector>)',
    '', content, flags=re.DOTALL)

connector = f"""
    <!-- Practica7 SSL Tomcat -->
    <Connector port="{port}" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="{ks}"
                         certificateKeystorePassword="reprobados123"
                         certificateKeystoreType="PKCS12" />
        </SSLHostConfig>
    </Connector>"""

content = content.replace('</Service>', connector + '\n    </Service>', 1)
with open(f, 'w') as fh:
    fh.write(content)
PYEOF

    local server_ip="${SSL_FTP_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    aputs_success "Connector SSL configurado en Tomcat puerto ${puerto}"
    aputs_info    "Acceso: https://${server_ip}:${puerto}"
}

# ------------------------------------------------------------
# Instalar RPMs + configuracion completa via P6
# ------------------------------------------------------------

_ftp_instalar_rpms() {
    local dir="$1" servicio="$2" version="$3"

    local rpms=()
    while IFS= read -r rpm; do
        rpms+=("$rpm")
    done < <(find "$dir" -name "*.rpm" 2>/dev/null | sort)

    if [[ ${#rpms[@]} -eq 0 ]]; then
        aputs_error "No hay RPMs en ${dir}"
        return 1
    fi

    echo ""
    aputs_info "RPMs a instalar:"
    for rpm in "${rpms[@]}"; do
        printf "    %s\n" "$(basename "$rpm")"
    done
    echo ""

    local puerto_default
    puerto_default=$(_ftp_puerto_default "$servicio")
    local puerto
    read -rp "  Puerto HTTP [${puerto_default}]: " puerto
    puerto="${puerto:-$puerto_default}"

    echo ""
    read -rp "  Confirmar instalacion de ${servicio} ${version} en puerto ${puerto}? [S/n]: " conf
    [[ "$conf" =~ ^[nN]$ ]] && { aputs_info "Instalacion cancelada"; return 0; }

    echo ""
    aputs_info "Instalando RPMs con dnf localinstall..."

    if ! dnf localinstall -y "${rpms[@]}" 2>/dev/null; then
        aputs_warning "dnf localinstall fallo -- intentando con rpm -ivh..."
        rpm -ivh --nodeps "${rpms[@]}" 2>/dev/null \
            || { aputs_error "No se pudo instalar ${servicio}"; return 1; }
    fi

    aputs_success "RPMs instalados"
    echo ""

    # Configuracion via P6
    local p6_functions="${SCRIPT_DIR}/../P6/http_functions.sh"
    local svc_p6 svc_sd
    svc_p6=$(_ftp_svc_p6 "$servicio")
    svc_sd=$(_ftp_svc_systemd "$servicio")

    if [[ -f "$p6_functions" ]]; then
        source "$p6_functions" 2>/dev/null
        aputs_info "Configurando puerto ${puerto}..."
        _http_aplicar_puerto "$svc_p6" "$puerto" 2>/dev/null || true
        local webroot
        webroot=$(_http_webroot "$svc_p6" 2>/dev/null)
        _http_usuario_dedicado "$svc_p6" "$webroot" 2>/dev/null || true
        http_aplicar_seguridad "$svc_p6" "$puerto" 2>/dev/null || true
        _http_crear_index "$svc_p6" "$version" "$puerto" "$webroot" 2>/dev/null || true
        _http_fw_abrir "$puerto" 2>/dev/null || true
        _http_guardar_estado "$svc_p6" "$puerto" "$version" 2>/dev/null || true
    else
        case "${servicio,,}" in
            apache) sed -i "s/^Listen .*/Listen ${puerto}/" /etc/httpd/conf/httpd.conf 2>/dev/null || true ;;
            nginx)  sed -i "s/listen\s\+[0-9]\+/listen ${puerto}/g" /etc/nginx/nginx.conf 2>/dev/null || true ;;
        esac
        firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi

    systemctl enable "$svc_sd" --quiet 2>/dev/null || true
    echo ""
    _ftp_reiniciar_servicio "$servicio" "$svc_sd" || true

    echo ""

    # Preguntar SSL
    read -rp "  Desea configurar SSL/HTTPS para ${servicio}? [s/N]: " conf_ssl
    if [[ "$conf_ssl" =~ ^[sS]$ ]]; then
        _ftp_configurar_ssl "$servicio"
    fi
}

# ------------------------------------------------------------
# Menu de versiones FTP con deteccion de servicio instalado
# ------------------------------------------------------------

_ftp_menu_versiones() {
    local servicio="$1"
    local remote_base="${_FTP_REPO_PATH}/${servicio}"

    while true; do
        clear
        ssl_mostrar_banner "Repo FTP -- ${servicio}"

        # Detectar si ya esta instalado
        if _ftp_esta_instalado "$servicio"; then
            local svc_sd estado
            svc_sd=$(_ftp_svc_systemd "$servicio")
            systemctl is-active --quiet "$svc_sd" 2>/dev/null && estado="activo" || estado="inactivo"

            aputs_warning "${servicio} ya instalado  (${estado})"
            echo ""
            echo "  1) Reinstalar desde FTP (elegir version)"
            echo "  2) Reconfigurar puerto HTTP"
            echo "  3) Configurar / reconfigurar SSL"
            echo "  4) Desinstalar ${servicio}"
            echo "  0) Volver"
            echo ""

            local op
            read -rp "  Opcion: " op
            case "$op" in
                1) ;; # cae al flujo de versiones abajo
                2) _ftp_reconfigurar_puerto "$servicio"; pause; continue ;;
                3) _ftp_configurar_ssl "$servicio";      pause; continue ;;
                4) _ftp_desinstalar "$servicio";         pause; continue ;;
                0) return ;;
                *) aputs_error "Opcion invalida"; sleep 1; continue ;;
            esac
        fi

        # Listar versiones disponibles en FTP
        echo ""
        aputs_info "Conectado a ftp://${_FTP_HOST}"
        aputs_info "Directorio: ${remote_base}"
        echo ""
        aputs_info "Versiones disponibles:"
        echo ""

        local versiones=()
        while IFS= read -r v; do
            [[ -n "$v" ]] && versiones+=("$v")
        done < <(_ftp_listar_dir "${remote_base}/")

        if [[ ${#versiones[@]} -eq 0 ]]; then
            aputs_warning "No hay versiones en ${remote_base}"
            aputs_info   "Descargue RPMs primero desde el Paso 4"
            pause
            return
        fi

        local i=1
        for v in "${versiones[@]}"; do
            printf "  %2d) %s\n" "$i" "$v"
            i=$(( i + 1 ))
        done
        echo ""
        echo "  0) Volver"
        echo ""

        local op
        read -rp "  Seleccione version: " op
        [[ "$op" == "0" ]] && return

        if [[ "$op" =~ ^[0-9]+$ ]] && [[ "$op" -ge 1 && "$op" -le "${#versiones[@]}" ]]; then
            local version="${versiones[$((op-1))]}"
            local remote_dir="${remote_base}/${version}"
            local local_dir="${_FTP_TMP}/${servicio}/${version}"

            echo ""
            draw_line

            aputs_info "Contenido de ${remote_dir}:"
            echo ""
            _ftp_listar_dir "${remote_dir}/" | grep "\.rpm$" | while read -r f; do
                printf "    %s\n" "$f"
            done
            echo ""

            if _ftp_descargar_dir "$remote_dir" "$local_dir"; then
                echo ""
                draw_line
                _ftp_instalar_rpms "$local_dir" "$servicio" "$version"
            fi

            pause
        else
            aputs_error "Opcion invalida"
            sleep 1
        fi
    done
}

# ------------------------------------------------------------
# Menu de servicios
# ------------------------------------------------------------

_ftp_menu_servicios() {
    while true; do
        clear
        ssl_mostrar_banner "Instalar desde Repositorio FTP"

        aputs_success "Sesion activa: ftp://${_FTP_HOST}  usuario: ${_FTP_USER}"
        echo ""

        # Estado de cada servicio
        for svc in Apache Nginx Tomcat; do
            local rpm estado icono
            rpm=$(_ftp_svc_rpm "$svc")
            if rpm -q "$rpm" &>/dev/null; then
                local sd
                sd=$(_ftp_svc_systemd "$svc")
                systemctl is-active --quiet "$sd" 2>/dev/null && estado="activo" || estado="instalado/inactivo"
                icono="[*]"
            else
                estado="no instalado"
                icono="[ ]"
            fi
            printf "  %s %-8s %s\n" "$icono" "${svc}:" "$estado"
        done

        echo ""
        echo "  1) Apache  (httpd)"
        echo "  2) Nginx"
        echo "  3) Tomcat"
        echo "  0) Volver"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _ftp_menu_versiones "Apache" ;;
            2) _ftp_menu_versiones "Nginx"  ;;
            3) _ftp_menu_versiones "Tomcat" ;;
            0) return ;;
            *) aputs_error "Opcion invalida"; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# Punto de entrada principal
# ------------------------------------------------------------

ssl_instalar_desde_ftp() {
    _ftp_check_lftp || { pause; return 1; }
    _ftp_conectar   || { pause; return 1; }
    _ftp_menu_servicios
    rm -rf "${_FTP_TMP}" 2>/dev/null || true
}
