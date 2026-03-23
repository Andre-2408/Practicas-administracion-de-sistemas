#!/bin/bash
#
# 01-instalar-paquetes.sh -- Instalar paquetes necesarios para unirse al dominio AD
# Requiere: utils.AD.sh cargado previamente
#
# Paquetes:
#   realmd    -- Descubrimiento y union al dominio
#   sssd      -- Autenticacion y proveedor de identidad AD
#   sssd-tools -- Herramientas CLI de sssd
#   adcli     -- Herramienta para operaciones en AD Kerberos
#   samba-common-bin (Debian) / samba-common (RHEL) -- utilidades Samba
#   krb5-user (Debian) / krb5-workstation (RHEL)   -- cliente Kerberos
#   oddjob / oddjob-mkhomedir -- Creacion automatica de directorios home
#   packagekit -- Requerido por realmd en algunos sistemas

# ------------------------------------------------------------
# Detectar familia de distribucion y definir paquetes
# ------------------------------------------------------------

_paquetes_segun_distro() {
    local gestor
    gestor=$(ad_gestor_paquetes)

    case "${gestor}" in
        apt)
            echo "realmd sssd sssd-tools adcli samba-common-bin krb5-user libnss-sss libpam-sss oddjob oddjob-mkhomedir packagekit"
            ;;
        dnf|yum)
            echo "realmd sssd sssd-tools adcli samba-common krb5-workstation oddjob oddjob-mkhomedir"
            ;;
        zypper)
            echo "realmd sssd sssd-tools adcli samba-client krb5-client"
            ;;
        *)
            aputs_error "Gestor de paquetes no soportado: ${gestor}"
            echo ""
            ;;
    esac
}

# ------------------------------------------------------------
# Instalar paquetes necesarios
# ------------------------------------------------------------

paquetes_instalar() {
    local gestor
    gestor=$(ad_gestor_paquetes)

    aputs_info "Actualizando lista de paquetes..."

    case "${gestor}" in
        apt)
            apt-get update -qq
            ;;
        dnf)
            dnf makecache --quiet
            ;;
        yum)
            yum makecache --quiet
            ;;
        zypper)
            zypper refresh --quiet
            ;;
    esac

    aputs_ok "Lista de paquetes actualizada"
    echo ""

    local paquetes
    paquetes=$(_paquetes_segun_distro)

    if [[ -z "${paquetes}" ]]; then
        return 1
    fi

    aputs_info "Instalando paquetes AD (${gestor}):"
    echo ""

    local errores=0

    for paquete in ${paquetes}; do
        printf "    %-32s " "${paquete}..."

        if ad_instalar_paquete "${paquete}" 2>/dev/null; then
            echo "OK"
        else
            echo "FALLO"
            errores=$(( errores + 1 ))
        fi
    done

    echo ""

    if [[ "${errores}" -gt 0 ]]; then
        aputs_warning "${errores} paquete(s) no se pudieron instalar"
        aputs_info   "Algunos pueden no existir en esta distribucion -- es normal"
        return 0   # No fallo fatal: algunos paquetes son opcionales segun la distro
    fi

    aputs_ok "Todos los paquetes instalados correctamente"
    return 0
}

# ------------------------------------------------------------
# Habilitar y arrancar servicios necesarios
# ------------------------------------------------------------

paquetes_habilitar_servicios() {
    aputs_info "Habilitando servicios..."

    local servicios=("sssd" "oddjobd")

    for svc in "${servicios[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 \
            && systemctl list-unit-files "${svc}.service" | grep -q "${svc}"; then
            systemctl enable "${svc}" --quiet 2>/dev/null || true
            aputs_ok "Servicio habilitado: ${svc}"
        fi
    done
}

# ------------------------------------------------------------
# Verificar que los paquetes estan instalados
# ------------------------------------------------------------

paquetes_verificar() {
    echo ""
    aputs_info "--- Verificacion de paquetes ---"
    echo ""

    local paquetes_clave=("realmd" "sssd" "adcli")

    for pkg in "${paquetes_clave[@]}"; do
        if command -v "${pkg}" &>/dev/null 2>&1; then
            local version
            version=$("${pkg}" --version 2>/dev/null | head -1 || echo "instalado")
            printf "    %-20s : %s\n" "${pkg}" "${version}"
        else
            printf "    %-20s : NO ENCONTRADO\n" "${pkg}"
        fi
    done

    echo ""

    # Verificar modulos sssd
    if command -v sssd &>/dev/null 2>&1; then
        aputs_ok "sssd: $(sssd --version 2>/dev/null || echo 'instalado')"
    else
        aputs_warning "sssd no encontrado"
    fi
}

# ------------------------------------------------------------
# Orquestador: instalacion completa
# ------------------------------------------------------------

paquetes_instalar_completo() {
    clear
    ad_mostrar_banner "Paso 1 -- Instalacion de Paquetes AD"

    echo ""
    echo "  Paquetes a instalar:"
    echo "    realmd, sssd, sssd-tools, adcli, samba-common,"
    echo "    krb5-client, oddjob, oddjob-mkhomedir"
    echo ""
    draw_line
    echo ""

    if ! paquetes_instalar; then
        aputs_error "Error durante la instalacion de paquetes"
        pause
        return 1
    fi

    echo ""
    paquetes_habilitar_servicios
    echo ""
    paquetes_verificar
    echo ""
    draw_line
    aputs_ok "Paquetes instalados y servicios configurados"

    pause
    return 0
}
