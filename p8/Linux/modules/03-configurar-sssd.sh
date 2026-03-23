#!/bin/bash
#
# 03-configurar-sssd.sh -- Configurar sssd para autenticacion AD
# Requiere: utils.AD.sh cargado previamente
#
# Parametros clave en sssd.conf:
#   fallback_homedir = /home/%u@%d   (requerido por la practica)
#   use_fully_qualified_names = True
#   access_provider = ad

# ------------------------------------------------------------
# Hacer backup de la configuracion existente
# ------------------------------------------------------------

sssd_backup() {
    if [[ -f "${AD_SSSD_CONF}" ]]; then
        local backup="${AD_SSSD_CONF_BACKUP}"
        cp "${AD_SSSD_CONF}" "${backup}"
        aputs_ok "Backup creado: ${backup}"
    fi
}

# ------------------------------------------------------------
# Escribir /etc/sssd/sssd.conf con los parametros requeridos
# ------------------------------------------------------------

sssd_configurar() {
    aputs_info "Escribiendo configuracion sssd.conf..."

    # Asegurar que el directorio existe
    mkdir -p "$(dirname "${AD_SSSD_CONF}")"

    cat > "${AD_SSSD_CONF}" << EOF
#
# sssd.conf -- Configuracion para AD (Practica 8)
# Generado automaticamente por 03-configurar-sssd.sh
#

[sssd]
domains             = ${AD_DOMINIO}
config_file_version = 2
services            = nss, pam

[domain/${AD_DOMINIO}]
# Proveedor de identidad: Active Directory
id_provider         = ad
auth_provider       = ad
access_provider     = ad

# Informacion del dominio
ad_domain           = ${AD_DOMINIO}
krb5_realm          = ${AD_REALM}

# Directorio home de los usuarios de AD
# %u = nombre de usuario (sin dominio)
# %d = nombre del dominio
fallback_homedir    = ${AD_FALLBACK_HOMEDIR}

# Shell por defecto para usuarios AD
default_shell       = ${AD_DEFAULT_SHELL}

# Usar nombre completo (usuario@dominio) para evitar conflictos
use_fully_qualified_names = True

# Cachear credenciales para acceso offline
cache_credentials   = True

# Almacenar contrasena cifrada para acceso sin conectividad al DC
krb5_store_password_if_offline = True

# Mapeo de UID/GID a partir de atributos AD (no usar rangos locales)
ldap_id_mapping     = True

# Identificador del equipo para realmd
realmd_tags         = manages-system joined-with-adcli

# Reconnection y timeouts
ad_maximum_machine_account_password_age = 30
EOF

    # Permisos estrictos requeridos por sssd
    chmod 600 "${AD_SSSD_CONF}"
    chown root:root "${AD_SSSD_CONF}"

    aputs_ok "sssd.conf configurado (permisos 600 root:root)"
    aputs_info "fallback_homedir = ${AD_FALLBACK_HOMEDIR}"
    aputs_info "use_fully_qualified_names = True"
}

# ------------------------------------------------------------
# Configurar PAM para crear directorios home automaticamente
# (pam_mkhomedir al primer inicio de sesion)
# ------------------------------------------------------------

sssd_configurar_pam_mkhomedir() {
    aputs_info "Configurando PAM para creacion automatica de directorios home..."

    local gestor
    gestor=$(ad_gestor_paquetes)

    if [[ "${gestor}" == "apt" ]]; then
        # Debian/Ubuntu: usar pam-auth-update
        if command -v pam-auth-update &>/dev/null 2>&1; then
            pam-auth-update --enable mkhomedir --force 2>/dev/null
            aputs_ok "pam_mkhomedir habilitado via pam-auth-update"
        else
            # Agregar manualmente a common-session
            local pam_session="/etc/pam.d/common-session"
            if [[ -f "${pam_session}" ]] && \
               ! grep -q "pam_mkhomedir.so" "${pam_session}"; then
                echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" >> "${pam_session}"
                aputs_ok "pam_mkhomedir agregado a common-session"
            else
                aputs_info "pam_mkhomedir ya configurado en common-session"
            fi
        fi
    else
        # RHEL/CentOS/Fedora: authconfig o authselect
        if command -v authselect &>/dev/null 2>&1; then
            authselect select sssd with-mkhomedir --force 2>/dev/null \
                && aputs_ok "authselect: sssd con mkhomedir habilitado" \
                || aputs_warning "authselect: fallo la configuracion"
        elif command -v authconfig &>/dev/null 2>&1; then
            authconfig --enablesssd --enablesssdauth --enablemkhomedir --update 2>/dev/null \
                && aputs_ok "authconfig: sssd y mkhomedir habilitados" \
                || aputs_warning "authconfig: fallo la configuracion"
        else
            # Agregar manualmente a /etc/pam.d/system-auth
            local pam_sys="/etc/pam.d/system-auth"
            if [[ -f "${pam_sys}" ]] && ! grep -q "pam_mkhomedir.so" "${pam_sys}"; then
                sed -i '/^session.*pam_unix.so/a session     required      pam_mkhomedir.so skel=/etc/skel/ umask=0022' "${pam_sys}"
                aputs_ok "pam_mkhomedir agregado a system-auth"
            else
                aputs_info "pam_mkhomedir ya configurado en system-auth"
            fi
        fi
    fi
}

# ------------------------------------------------------------
# Reiniciar y verificar el servicio sssd
# ------------------------------------------------------------

sssd_reiniciar() {
    aputs_info "Reiniciando servicio sssd..."

    # Limpiar cache de sssd antes de reiniciar
    if command -v sss_cache &>/dev/null 2>&1; then
        sss_cache -E 2>/dev/null || true
    fi

    # Limpiar base de datos de sssd
    local db_dir="/var/lib/sss/db"
    if [[ -d "${db_dir}" ]]; then
        rm -f "${db_dir}"/*.ldb 2>/dev/null || true
    fi

    systemctl restart sssd 2>/dev/null
    sleep 2

    if systemctl is-active --quiet sssd; then
        aputs_ok "sssd reiniciado y activo"
        return 0
    else
        aputs_error "sssd no pudo iniciarse -- verifique el log: journalctl -u sssd"
        return 1
    fi
}

# ------------------------------------------------------------
# Verificar la configuracion de sssd
# ------------------------------------------------------------

sssd_verificar() {
    echo ""
    aputs_info "--- Verificacion de sssd ---"
    echo ""

    # Estado del servicio
    local estado
    estado=$(systemctl is-active sssd 2>/dev/null || echo "inactivo")
    printf "    %-28s : %s\n" "sssd" "${estado}"

    # Verificar configuracion clave
    if [[ -f "${AD_SSSD_CONF}" ]]; then
        local fallback domain
        fallback=$(grep "fallback_homedir" "${AD_SSSD_CONF}" | awk -F= '{print $2}' | tr -d ' ')
        domain=$(grep "^ad_domain" "${AD_SSSD_CONF}" | awk -F= '{print $2}' | tr -d ' ')

        printf "    %-28s : %s\n" "fallback_homedir" "${fallback}"
        printf "    %-28s : %s\n" "ad_domain" "${domain}"
    else
        aputs_warning "sssd.conf no encontrado en ${AD_SSSD_CONF}"
    fi

    echo ""

    # Intentar resolver un usuario de AD para verificar funcionamiento
    if ad_verificar_dominio_unido; then
        aputs_info "Prueba de resolucion de usuarios AD (getent):"
        echo ""
        if command -v getent &>/dev/null 2>&1; then
            local resultado=""
            resultado=$(timeout 5 getent passwd "Administrador@${AD_DOMINIO}" 2>/dev/null) || resultado=""
            if [[ -n "${resultado}" ]]; then
                echo "    ${resultado}"
                aputs_ok "Resolucion de usuarios AD funcionando"
            else
                aputs_info "  No se pudo resolver usuario de prueba (normal si SSSD aun inicializando)"
            fi
        fi
    fi
}

# ------------------------------------------------------------
# Orquestador: configuracion completa sssd
# ------------------------------------------------------------

sssd_configurar_completo() {
    clear
    ad_mostrar_banner "Paso 3 -- Configuracion de sssd"

    echo ""
    echo "  Parametros que se configuraran:"
    printf "    %-28s : %s\n" "fallback_homedir" "${AD_FALLBACK_HOMEDIR}"
    printf "    %-28s : %s\n" "default_shell" "${AD_DEFAULT_SHELL}"
    printf "    %-28s : %s\n" "use_fully_qualified_names" "True"
    printf "    %-28s : %s\n" "cache_credentials" "True"
    echo ""
    draw_line
    echo ""

    # 1. Backup
    sssd_backup
    echo ""

    # 2. Escribir sssd.conf
    sssd_configurar
    echo ""

    # 3. Configurar PAM mkhomedir
    sssd_configurar_pam_mkhomedir
    echo ""

    # 4. Reiniciar sssd
    if ! sssd_reiniciar; then
        aputs_warning "sssd no inicio -- revise: journalctl -u sssd -n 50"
        pause
        return 1
    fi

    echo ""
    sssd_verificar
    echo ""
    draw_line
    aputs_ok "sssd configurado correctamente"
    aputs_info "Los usuarios de AD podran iniciar sesion con: usuario@${AD_DOMINIO}"

    pause
    return 0
}
