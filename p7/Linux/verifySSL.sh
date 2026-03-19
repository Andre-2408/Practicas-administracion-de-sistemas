#!/bin/bash
#
# verifySSL.sh -- Verificacion general de la infraestructura SSL
#

[[ -n "${_VERIFY_SSL_LOADED:-}" ]] && return 0
readonly _VERIFY_SSL_LOADED=1

# ------------------------------------------------------------
# Helpers internos
# ------------------------------------------------------------

_verify_seccion() {
    echo ""
    echo "  -- $1 --"
    draw_line
}

_verify_check() {
    local desc="$1" resultado="$2"
    if [[ "$resultado" == "ok" ]]; then
        printf "  [OK]  %s\n" "$desc"
    else
        printf "  [NO]  %s\n" "$desc"
    fi
}

_check_puerto_ssl() {
    local host="127.0.0.1" puerto="$1"
    if timeout 3 bash -c "echo | openssl s_client -connect ${host}:${puerto} 2>/dev/null" \
        | grep -q "BEGIN CERTIFICATE"; then
        echo "ok"
    else
        echo "no"
    fi
}

# ------------------------------------------------------------
# Verificacion completa
# ------------------------------------------------------------

ssl_verify_todo() {
    clear
    ssl_mostrar_banner "Testing General -- Infraestructura SSL"

    # --- Certificado ---
    _verify_seccion "Certificado SSL"
    if ssl_cert_existe; then
        _verify_check "Certificado en ${SSL_CERT}" "ok"
        _verify_check "Clave privada en ${SSL_KEY}" "ok"

        local expiry
        expiry=$(openssl x509 -noout -enddate -in "${SSL_CERT}" 2>/dev/null \
                 | sed 's/notAfter=//')
        printf "  [--]  Expira: %s\n" "$expiry"

        # Verificar coherencia cert/key
        local cert_md key_md
        cert_md=$(openssl x509 -noout -modulus -in "${SSL_CERT}" 2>/dev/null | md5sum)
        key_md=$(openssl rsa -noout -modulus -in "${SSL_KEY}" 2>/dev/null | md5sum)
        if [[ "$cert_md" == "$key_md" ]]; then
            _verify_check "Certificado y clave coinciden" "ok"
        else
            _verify_check "Certificado y clave coinciden" "no"
        fi
    else
        _verify_check "Certificado SSL generado" "no"
    fi

    # --- FTP ---
    _verify_seccion "Servicio FTP"
    if rpm -q vsftpd &>/dev/null; then
        _verify_check "vsftpd instalado" "ok"
        if systemctl is-active --quiet vsftpd 2>/dev/null; then
            _verify_check "vsftpd activo" "ok"
        else
            _verify_check "vsftpd activo" "no"
        fi
        if grep -q "^ssl_enable=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
            _verify_check "FTPS/TLS habilitado" "ok"
        else
            _verify_check "FTPS/TLS habilitado" "no"
        fi
    else
        _verify_check "vsftpd instalado" "no"
    fi

    # --- Repositorio ---
    _verify_seccion "Repositorio FTP"
    if [[ -d "${SSL_REPO_ROOT}" ]]; then
        _verify_check "Directorio repositorio existe" "ok"
        local total
        total=$(find "${SSL_REPO_ROOT}" -name "*.rpm" 2>/dev/null | wc -l)
        printf "  [--]  RPMs encontrados: %d\n" "$total"
        for subdir in Apache Nginx Tomcat; do
            local cnt
            cnt=$(find "${SSL_REPO_LINUX}/${subdir}" -name "*.rpm" 2>/dev/null | wc -l)
            printf "        %-10s %d RPM(s)\n" "${subdir}:" "$cnt"
        done
    else
        _verify_check "Directorio repositorio existe" "no"
    fi

    # --- Apache ---
    _verify_seccion "Apache (httpd)"
    if rpm -q httpd &>/dev/null; then
        _verify_check "httpd instalado" "ok"
        if systemctl is-active --quiet httpd 2>/dev/null; then
            _verify_check "httpd activo" "ok"
        else
            _verify_check "httpd activo" "no"
        fi
        if [[ -f "${SSL_CONF_APACHE_SSL}" ]]; then
            _verify_check "Configuracion SSL existe" "ok"
            _verify_check "Puerto 443 responde SSL" "$(_check_puerto_ssl 443)"
        else
            _verify_check "Configuracion SSL existe" "no"
        fi
    else
        _verify_check "httpd instalado" "no"
    fi

    # --- Nginx ---
    _verify_seccion "Nginx"
    if rpm -q nginx &>/dev/null; then
        _verify_check "nginx instalado" "ok"
        if systemctl is-active --quiet nginx 2>/dev/null; then
            _verify_check "nginx activo" "ok"
        else
            _verify_check "nginx activo" "no"
        fi
        if grep -q "Practica7 SSL Nginx" "${SSL_CONF_NGINX}" 2>/dev/null; then
            _verify_check "Bloque SSL en nginx.conf" "ok"
            _verify_check "Puerto 8443 responde SSL" "$(_check_puerto_ssl 8443)"
        else
            _verify_check "Bloque SSL en nginx.conf" "no"
        fi
    else
        _verify_check "nginx instalado" "no"
    fi

    # --- Tomcat ---
    _verify_seccion "Tomcat"
    if rpm -q tomcat &>/dev/null; then
        _verify_check "tomcat instalado" "ok"
        if systemctl is-active --quiet tomcat 2>/dev/null; then
            _verify_check "tomcat activo" "ok"
        else
            _verify_check "tomcat activo" "no"
        fi
        local server_xml
        server_xml=$(SSL_CONF_TOMCAT)
        if grep -q "Practica7 SSL" "${server_xml}" 2>/dev/null; then
            _verify_check "Connector SSL en server.xml" "ok"
            _verify_check "Puerto 8444 responde SSL" "$(_check_puerto_ssl 8444)"
        else
            _verify_check "Connector SSL en server.xml" "no"
        fi
    else
        _verify_check "tomcat instalado" "no"
    fi

    echo ""
    draw_line
    echo ""
}
