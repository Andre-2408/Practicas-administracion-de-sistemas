#!/bin/bash
#
# FTP-SSL.sh -- Configuracion de FTPS/TLS en vsftpd
#

[[ -n "${_FTP_SSL_LOADED:-}" ]] && return 0
readonly _FTP_SSL_LOADED=1

# ------------------------------------------------------------
# Aplicar FTPS/TLS a vsftpd
# ------------------------------------------------------------

ssl_ftp_aplicar() {
    aputs_info "Configurando FTPS/TLS en vsftpd..."
    echo ""

    if ! rpm -q vsftpd &>/dev/null; then
        aputs_error "vsftpd no esta instalado"
        return 1
    fi

    if ! ssl_cert_existe; then
        aputs_error "No hay certificado SSL -- ejecute primero la gestion de certificados"
        return 1
    fi

    ssl_hacer_backup "${SSL_CONF_VSFTPD}"

    # Eliminar directivas SSL previas para evitar duplicados
    sed -i '/^ssl_enable/d'           "${SSL_CONF_VSFTPD}"
    sed -i '/^allow_anon_ssl/d'       "${SSL_CONF_VSFTPD}"
    sed -i '/^force_local_data_ssl/d' "${SSL_CONF_VSFTPD}"
    sed -i '/^force_local_logins_ssl/d' "${SSL_CONF_VSFTPD}"
    sed -i '/^ssl_tlsv1/d'            "${SSL_CONF_VSFTPD}"
    sed -i '/^ssl_sslv2/d'            "${SSL_CONF_VSFTPD}"
    sed -i '/^ssl_sslv3/d'            "${SSL_CONF_VSFTPD}"
    sed -i '/^rsa_cert_file/d'        "${SSL_CONF_VSFTPD}"
    sed -i '/^rsa_private_key_file/d' "${SSL_CONF_VSFTPD}"
    sed -i '/^require_ssl_reuse/d'    "${SSL_CONF_VSFTPD}"
    sed -i '/^ssl_ciphers/d'          "${SSL_CONF_VSFTPD}"

    cat >> "${SSL_CONF_VSFTPD}" << EOF

# === Practica7 FTPS/TLS ===
ssl_enable=YES
allow_anon_ssl=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO
ssl_ciphers=HIGH
rsa_cert_file=${SSL_CERT}
rsa_private_key_file=${SSL_KEY}
EOF

    aputs_success "Directivas FTPS escritas en ${SSL_CONF_VSFTPD}"

    # Abrir puerto 21 si firewall activo
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-service=ftp &>/dev/null
        firewall-cmd --reload &>/dev/null
        aputs_success "Puerto 21/ftp abierto en firewall"
    fi

    # SELinux: permitir FTPS
    if command -v setsebool &>/dev/null; then
        setsebool -P ftpd_use_passive_mode 1 &>/dev/null || true
        aputs_success "SELinux: ftpd_use_passive_mode habilitado"
    fi

    # Reiniciar vsftpd
    if systemctl restart vsftpd 2>/dev/null; then
        aputs_success "vsftpd reiniciado con FTPS/TLS activo"
    else
        aputs_error "Error al reiniciar vsftpd"
        aputs_info  "Revise: journalctl -u vsftpd --no-pager -n 20"
        return 1
    fi

    echo ""
    draw_line
    echo ""
    aputs_success "FTPS/TLS configurado correctamente"
    printf "  %-22s %s\n" "Puerto:"      "21 (TLS explicito)"
    printf "  %-22s %s\n" "Certificado:" "${SSL_CERT}"
    printf "  %-22s %s\n" "Protocolo:"   "TLSv1 (SSLv2/v3 deshabilitados)"
    echo ""
}
