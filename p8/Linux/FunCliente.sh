#!/bin/bash
#
# FunCliente.sh -- Funciones cliente Linux Practica 8
# Logica: YuckierOlive370/Tarea8GCC  |  Diseno visual: estilo del proyecto
#

# ============================================================
# VARIABLES GLOBALES -- AJUSTAR SEGUN EL ENTORNO
# ============================================================
DC_IP="192.168.92.132"
DOMINIO="p8.local"
REALM="P8.LOCAL"
ADMIN_USER="Administrator"
ADMIN_PASS="Admin@12345!"

# ============================================================
# HELPERS DE OUTPUT
# ============================================================

aputs_info() {
    echo "  [INFO]    $1"
}
aputs_ok() {
    echo "  [OK]      $1"
}
aputs_error() {
    echo "  [ERROR]   $1"
}
aputs_warning() {
    echo "  [AVISO]   $1"
}
draw_line() {
    echo "  ----------------------------------------------------------"
}
pause() {
    echo ""
    echo "  Presione ENTER para continuar..."
    read -r _p
}
cli_banner() {
    local titulo="${1:-Practica 08 -- Cliente Linux}"
    echo ""
    echo "  =========================================================="
    echo "    ${titulo}"
    echo "  =========================================================="
    echo ""
}

# ============================================================
# VERIFICAR ROOT
# ============================================================

verificar_root() {
    if [ "$EUID" -ne 0 ]; then
        aputs_error "Este script debe ejecutarse como root (sudo bash $0)"
        exit 1
    fi
}

# ============================================================
# PASO 1 -- CONFIGURAR DNS HACIA EL DC
# ============================================================

configurar_dns() {
    cli_banner "Paso 1 -- Configurar DNS"
    aputs_info "Apuntando DNS al DC: ${DC_IP} (dominio: ${DOMINIO})"

    # Quitar inmutabilidad si existe
    chattr -i /etc/resolv.conf 2>/dev/null || true

    cat > /etc/resolv.conf << EOF
nameserver ${DC_IP}
search ${DOMINIO}
domain ${DOMINIO}
EOF

    # Hacer inmutable para que nada lo sobreescriba
    chattr +i /etc/resolv.conf 2>/dev/null || true
    aputs_ok "resolv.conf configurado (inmutable)"

    if host "${DOMINIO}" &>/dev/null 2>&1; then
        aputs_ok "DNS OK: ${DOMINIO} resuelto correctamente"
        return 0
    else
        aputs_error "No se puede resolver ${DOMINIO} -- verifique conectividad con el DC"
        return 1
    fi
}

# ============================================================
# PASO 2 -- INSTALAR PAQUETES
# ============================================================

instalar_paquetes() {
    cli_banner "Paso 2 -- Instalar Paquetes"
    aputs_info "Detectando gestor de paquetes..."

    if command -v apt &>/dev/null; then
        aputs_info "Usando apt (Debian/Ubuntu)"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq

        local pkgs="realmd sssd sssd-tools adcli samba-common-bin krb5-user
                    libnss-sss libpam-sss libsss-sudo oddjob oddjob-mkhomedir packagekit"

        aputs_info "Instalando paquetes AD..."
        for p in $pkgs; do
            printf "    %-32s " "${p}..."
            if apt-get install -y "$p" -qq 2>/dev/null; then
                echo "OK"
            else
                echo "FALLO (puede ser opcional)"
            fi
        done

    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
        local gestor="dnf"; command -v dnf &>/dev/null || gestor="yum"
        aputs_info "Usando ${gestor} (RHEL/CentOS/Fedora)"
        ${gestor} install -y realmd sssd sssd-tools adcli samba-common \
            krb5-workstation oddjob oddjob-mkhomedir 2>/dev/null
    else
        aputs_error "Gestor de paquetes no reconocido"
        return 1
    fi

    aputs_ok "Paquetes instalados"
    systemctl enable sssd   --quiet 2>/dev/null || true
    systemctl enable oddjobd --quiet 2>/dev/null || true
}

# ============================================================
# PASO 3 -- CONFIGURAR KERBEROS
# ============================================================

configurar_kerberos() {
    cli_banner "Paso 3 -- Configurar Kerberos"
    aputs_info "Escribiendo /etc/krb5.conf para realm ${REALM}..."

    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc   = true
    ticket_lifetime  = 24h
    renew_lifetime   = 7d
    forwardable      = true

[realms]
    ${REALM} = {
        kdc            = ${DC_IP}
        admin_server   = ${DC_IP}
        default_domain = ${DOMINIO}
    }

[domain_realm]
    .${DOMINIO} = ${REALM}
    ${DOMINIO}  = ${REALM}
EOF

    aputs_ok "Kerberos configurado (realm: ${REALM})"
}

# ============================================================
# PASO 4 -- UNIRSE AL DOMINIO
# ============================================================

unir_dominio() {
    cli_banner "Paso 4 -- Unirse al Dominio"
    aputs_info "Dominio objetivo: ${DOMINIO}  |  Admin: ${ADMIN_USER}"
    echo ""

    if realm list 2>/dev/null | grep -q "${DOMINIO}"; then
        aputs_warning "Este equipo ya esta unido al dominio ${DOMINIO}"
        echo ""
        read -rp "  Volver a unirse? [s/N]: " resp
        if [[ ! "${resp}" =~ ^[sS]$ ]]; then
            aputs_info "Operacion cancelada"
            return 0
        fi
        realm leave "${DOMINIO}" 2>/dev/null || true
    fi

    aputs_info "Ejecutando: realm join --user=${ADMIN_USER} ${DOMINIO}"
    aputs_info "Se solicitara la contrasena del administrador..."
    echo ""

    # Intentar con password en variable primero
    if [[ -n "${ADMIN_PASS}" ]]; then
        echo "${ADMIN_PASS}" | realm join --user="${ADMIN_USER}" "${DOMINIO}" 2>/dev/null && {
            aputs_ok "Union completada (password automatico)"
            return 0
        }
    fi

    # Fallback interactivo
    realm join --user="${ADMIN_USER}" "${DOMINIO}"

    if realm list 2>/dev/null | grep -q "${DOMINIO}"; then
        aputs_ok "Union al dominio '${DOMINIO}' exitosa"
    else
        aputs_error "No se pudo unir al dominio"
        echo ""
        echo "  Causas comunes:"
        echo "    - DNS no apunta al DC (verifique /etc/resolv.conf)"
        echo "    - Credenciales incorrectas"
        echo "    - Reloj desincronizado (Kerberos requiere < 5 min diferencia)"
        return 1
    fi
}

# ============================================================
# PASO 5 -- CONFIGURAR SSSD
# ============================================================

configurar_sssd() {
    cli_banner "Paso 5 -- Configurar SSSD"
    aputs_info "Escribiendo /etc/sssd/sssd.conf..."

    mkdir -p /etc/sssd

    cat > /etc/sssd/sssd.conf << EOF
[sssd]
domains             = ${DOMINIO}
config_file_version = 2
services            = nss, pam, sudo

[domain/${DOMINIO}]
id_provider         = ad
auth_provider       = ad
access_provider     = ad

ad_domain           = ${DOMINIO}
krb5_realm          = ${REALM}

fallback_homedir    = /home/%u@%d
default_shell       = /bin/bash

# False: login con solo "usuario" (sin @dominio)
use_fully_qualified_names = False

cache_credentials   = True
ldap_id_mapping     = True
ldap_referrals      = False
EOF

    chmod 600 /etc/sssd/sssd.conf
    chown root:root /etc/sssd/sssd.conf
    aputs_ok "sssd.conf configurado (permisos 600)"
    aputs_info "use_fully_qualified_names = False (login: usuario sin @dominio)"

    # PAM mkhomedir
    aputs_info "Configurando PAM mkhomedir..."
    if command -v pam-auth-update &>/dev/null 2>&1; then
        pam-auth-update --enable mkhomedir --force 2>/dev/null
        aputs_ok "pam_mkhomedir habilitado via pam-auth-update"
    else
        local pam_session="/etc/pam.d/common-session"
        if [[ -f "${pam_session}" ]] && ! grep -q "pam_mkhomedir" "${pam_session}"; then
            echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0077" >> "${pam_session}"
            aputs_ok "pam_mkhomedir agregado a common-session"
        else
            aputs_info "pam_mkhomedir ya estaba configurado"
        fi
    fi
}

# ============================================================
# PASO 6 -- CONFIGURAR SUDOERS
# ============================================================

configurar_sudoers() {
    cli_banner "Paso 6 -- Configurar Sudoers"
    aputs_info "Otorgando sudo al grupo 'domain admins'..."

    cat > /etc/sudoers.d/ad-admins << EOF
%domain\ admins@${DOMINIO} ALL=(ALL:ALL) ALL
EOF

    chmod 440 /etc/sudoers.d/ad-admins
    aputs_ok "/etc/sudoers.d/ad-admins configurado"
}

# ============================================================
# PASO 7 -- REINICIAR SSSD Y VERIFICAR
# ============================================================

reiniciar_sssd() {
    cli_banner "Paso 7 -- Reiniciar SSSD"
    aputs_info "Limpiando cache y reiniciando sssd..."

    sss_cache -E 2>/dev/null || true
    rm -f /var/lib/sss/db/*.ldb 2>/dev/null || true

    systemctl enable sssd --quiet 2>/dev/null || true
    systemctl restart sssd
    sleep 3

    if systemctl is-active --quiet sssd; then
        aputs_ok "sssd: ACTIVO"
    else
        aputs_error "sssd no pudo iniciarse"
        echo ""
        echo "  Revise: journalctl -u sssd -n 30"
        return 1
    fi
}

# ============================================================
# MOSTRAR EVIDENCIA PARA LA RUBRICA
# ============================================================

mostrar_evidencia() {
    cli_banner "Evidencia -- Practica 08 (Cliente Linux)"

    echo "  Fecha : $(date)"
    echo "  Host  : $(hostname -f 2>/dev/null || hostname)"
    draw_line

    echo ""
    aputs_info "1. UNION AL DOMINIO"
    realm list 2>/dev/null || aputs_warning "realm list sin resultado"

    echo ""
    draw_line
    aputs_info "2. RESOLUCION DE USUARIOS AD"
    for u in cramirez smendez; do
        printf "    %-20s : " "$u"
        id "$u" 2>/dev/null || echo "NO RESUELTO"
    done

    echo ""
    draw_line
    aputs_info "3. GRUPOS AD"
    getent group "grp_cuates"   2>/dev/null || echo "    GRP_Cuates   : no encontrado"
    getent group "grp_nocuates" 2>/dev/null || echo "    GRP_NoCuates : no encontrado"

    echo ""
    draw_line
    aputs_info "4. ESTADO DE SSSD"
    systemctl is-active sssd

    echo ""
    draw_line
    aputs_info "5. SUDOERS"
    cat /etc/sudoers.d/ad-admins 2>/dev/null || aputs_warning "Archivo no encontrado"

    echo ""
    draw_line
    aputs_info "6. SSSD -- fallback_homedir"
    grep "fallback_homedir\|use_fully_qualified" /etc/sssd/sssd.conf 2>/dev/null

    echo ""
    draw_line
    aputs_info "7. PRUEBA DE LOGIN"
    echo "  Ejecuta: su - cramirez"
    echo "  Ejecuta: su - smendez"
    draw_line
}

# ============================================================
# FLUJO COMPLETO
# ============================================================

instalar_todo() {
    verificar_root
    configurar_dns       || { aputs_error "DNS fallo -- abortando"; return 1; }
    instalar_paquetes    || { aputs_error "Paquetes fallaron -- abortando"; return 1; }
    configurar_kerberos
    unir_dominio         || { aputs_error "Union al dominio fallo -- abortando"; return 1; }
    configurar_sssd
    configurar_sudoers
    reiniciar_sssd       || { aputs_error "SSSD no inicio -- revise los logs"; return 1; }
    echo ""
    draw_line
    aputs_ok "CONFIGURACION COMPLETA"
    draw_line
    echo ""
    mostrar_evidencia
}
