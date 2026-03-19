#!/bin/bash
#
# HTTP-SSL.sh -- Configuracion de SSL/HTTPS para Apache, Nginx y Tomcat
#

[[ -n "${_HTTP_SSL_LOADED:-}" ]] && return 0
readonly _HTTP_SSL_LOADED=1

# ------------------------------------------------------------
# Apache SSL
# ------------------------------------------------------------

_ssl_apache_aplicar() {
    aputs_info "Configurando SSL en Apache (httpd)..."

    if ! rpm -q mod_ssl &>/dev/null; then
        aputs_info "Instalando mod_ssl..."
        dnf install -y mod_ssl &>/dev/null \
            && aputs_success "mod_ssl instalado" \
            || { aputs_error "No se pudo instalar mod_ssl"; return 1; }
    fi

    ssl_hacer_backup "${SSL_CONF_APACHE_SSL}"

    local http_port https_port
    http_port=$(ssl_leer_puerto_http "httpd")
    https_port="${SSL_PUERTO_HTTPS_APACHE}"

    # Evitar Listen duplicado si mod_ssl u otro archivo ya lo define (ej. "Listen 443 https")
    grep -rl "^Listen ${https_port}" /etc/httpd/conf.d/ 2>/dev/null | while read -r f; do
        [[ "$f" != "${SSL_CONF_APACHE_SSL}" ]] && \
            sed -i "s|^Listen ${https_port}.*|# Listen ${https_port} # comentado por Practica7|" "$f" 2>/dev/null || true
    done

    local server_ip
    server_ip="${SSL_FTP_IP:-$(hostname -I | tr ' ' '\n' | grep -v "^127\." | grep -v "^${SSL_FTP_RED_INTERNA:-192.168.100}\." | head -1)}"

    cat > "${SSL_CONF_APACHE_SSL}" << EOF
# === Practica7 SSL Apache ===
Listen ${https_port}

<VirtualHost *:${http_port}>
    ServerName ${server_ip}
    ServerAlias ${SSL_DOMAIN}
    Redirect permanent / https://${server_ip}:${https_port}/
</VirtualHost>

<VirtualHost *:${https_port}>
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

    aputs_success "Configuracion SSL escrita en ${SSL_CONF_APACHE_SSL}"

    ssl_abrir_puerto_firewall "${https_port}"

    if apachectl configtest &>/dev/null 2>&1; then
        systemctl restart httpd 2>/dev/null \
            && aputs_success "httpd reiniciado con SSL en puerto ${https_port}" \
            || aputs_error "Error al reiniciar httpd"
    else
        aputs_error "Configuracion de Apache invalida:"
        apachectl configtest 2>&1 | head -10
        return 1
    fi
}

# ------------------------------------------------------------
# Nginx SSL
# ------------------------------------------------------------

_ssl_nginx_aplicar() {
    aputs_info "Configurando SSL en Nginx..."

    local http_port https_port
    http_port=$(ssl_leer_puerto_http "nginx")
    https_port="${SSL_PUERTO_HTTPS_ALT}"

    local ssl_conf="/etc/nginx/conf.d/ssl_reprobados.conf"
    ssl_hacer_backup "$ssl_conf"

    local server_ip
    server_ip="${SSL_FTP_IP:-$(hostname -I | tr ' ' '\n' | grep -v "^127\." | grep -v "^${SSL_FTP_RED_INTERNA:-192.168.100}\." | head -1)}"

    cat > "$ssl_conf" << EOF
# === Practica7 SSL Nginx ===
server {
    listen ${http_port};
    server_name ${server_ip} ${SSL_DOMAIN};
    return 301 https://${server_ip}:${https_port}\$request_uri;
}

server {
    listen ${https_port} ssl;
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

    aputs_success "Configuracion SSL escrita en ${ssl_conf}"

    ssl_abrir_puerto_firewall "${https_port}"

    if nginx -t &>/dev/null 2>&1; then
        systemctl restart nginx 2>/dev/null \
            && aputs_success "nginx reiniciado con SSL en puerto ${https_port}" \
            || aputs_error "Error al reiniciar nginx"
    else
        aputs_error "Configuracion de Nginx invalida:"
        nginx -t 2>&1 | head -10
        return 1
    fi
}

# ------------------------------------------------------------
# Tomcat SSL
# ------------------------------------------------------------

_ssl_tomcat_aplicar() {
    aputs_info "Configurando SSL en Tomcat..."

    local server_xml keystore
    server_xml=$(SSL_CONF_TOMCAT)
    keystore=$(SSL_KEYSTORE_TOMCAT)

    if [[ ! -f "$server_xml" ]]; then
        aputs_error "server.xml no encontrado: ${server_xml}"
        return 1
    fi

    # Verificar keytool
    if ! command -v keytool &>/dev/null; then
        aputs_info "keytool no encontrado -- instalando java..."
        dnf install -y java-17-openjdk &>/dev/null \
            && aputs_success "java instalado" \
            || { aputs_error "No se pudo instalar java"; return 1; }
    fi

    local https_port="${SSL_PUERTO_HTTPS_TOMCAT}"

    # Generar keystore PKCS12 a partir del certificado existente
    aputs_info "Generando keystore PKCS12 para Tomcat..."
    openssl pkcs12 -export \
        -in  "${SSL_CERT}" \
        -inkey "${SSL_KEY}" \
        -out "${keystore}" \
        -name reprobados \
        -passout pass:reprobados123 2>/dev/null \
        && aputs_success "Keystore generado: ${keystore}" \
        || { aputs_error "Error al generar keystore"; return 1; }

    ssl_hacer_backup "${server_xml}"

    # Insertar Connector SSL antes de </Service> si no existe ya
    if ! grep -q "Practica7 SSL" "${server_xml}"; then
        python3 - "${server_xml}" "${https_port}" "${keystore}" << 'PYEOF'
import sys
f, port, ks = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    content = fh.read()

connector = f"""
    <!-- Practica7 SSL Tomcat -->
    <Connector port="{port}" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="{ks}"
                         certificateKeystorePassword="reprobados123"
                         certificateKeystoreType="PKCS12" />
        </SSLHostConfig>
    </Connector>
    """

content = content.replace('</Service>', connector + '</Service>', 1)
with open(f, 'w') as fh:
    fh.write(content)
PYEOF
        aputs_success "Connector SSL agregado a server.xml (puerto ${https_port})"
    else
        aputs_info "Connector SSL ya existe en server.xml"
    fi

    ssl_abrir_puerto_firewall "${https_port}"

    systemctl restart tomcat 2>/dev/null \
        && aputs_success "tomcat reiniciado con SSL en puerto ${https_port}" \
        || aputs_error "Error al reiniciar tomcat -- revise logs"
}

# ------------------------------------------------------------
# Aplicar SSL a todos los servicios HTTP instalados
# ------------------------------------------------------------

ssl_http_aplicar_todos() {
    local aplicado=0

    if ssl_servicio_instalado httpd; then
        echo ""
        draw_line
        _ssl_apache_aplicar && aplicado=$(( aplicado + 1 )) || true
    fi

    if ssl_servicio_instalado nginx; then
        echo ""
        draw_line
        _ssl_nginx_aplicar && aplicado=$(( aplicado + 1 )) || true
    fi

    if ssl_servicio_instalado tomcat; then
        echo ""
        draw_line
        _ssl_tomcat_aplicar && aplicado=$(( aplicado + 1 )) || true
    fi

    echo ""
    draw_line
    echo ""

    if [[ "$aplicado" -eq 0 ]]; then
        aputs_warning "No se aplico SSL a ningun servicio"
    else
        aputs_success "SSL aplicado a ${aplicado} servicio(s)"
    fi
}
