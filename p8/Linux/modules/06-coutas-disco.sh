#!/bin/bash
#
# 06-cuotas-disco.sh -- Cuotas de disco para usuarios AD
# Requiere: utils.AD.sh cargado previamente
#
# Limites aplicados al directorio home de los usuarios (/home)
#   Soft limit: 100 MB (aviso al superarlo)
#   Hard limit: 150 MB (bloqueo al superarlo)
#

readonly QUOTA_SOFT_KB=102400    # 100 MB en KB
readonly QUOTA_HARD_KB=153600    # 150 MB en KB
readonly QUOTA_MOUNTPOINT="/home"

# ------------------------------------------------------------
# Instalar paquetes necesarios
# ------------------------------------------------------------

cuotas_instalar_paquetes() {
    aputs_info "Verificando paquetes de cuotas..."

    local gestor
    gestor=$(ad_gestor_paquetes)

    local pkgs_necesarios=()
    command -v quota    &>/dev/null || pkgs_necesarios+=("quota")
    command -v setquota &>/dev/null || pkgs_necesarios+=("quota")
    command -v repquota &>/dev/null || pkgs_necesarios+=("quota")

    if [[ ${#pkgs_necesarios[@]} -eq 0 ]]; then
        aputs_ok "Paquetes de cuota ya instalados"
        return 0
    fi

    aputs_info "Instalando: ${pkgs_necesarios[*]}"
    case "${gestor}" in
        dnf|yum) "${gestor}" install -y quota &>/dev/null ;;
        apt)     DEBIAN_FRONTEND=noninteractive apt-get install -y quota &>/dev/null ;;
        *)       aputs_warning "Instale manualmente: quota" ; return 1 ;;
    esac

    command -v quota &>/dev/null && aputs_ok "Paquete quota instalado" || \
        aputs_warning "No se pudo instalar quota"
}

# ------------------------------------------------------------
# Detectar tipo de filesystem
# ------------------------------------------------------------

cuotas_detectar_fs() {
    local mp="${1:-${QUOTA_MOUNTPOINT}}"
    df -T "${mp}" 2>/dev/null | awk 'NR==2 {print $2}'
}

cuotas_detectar_dispositivo() {
    local mp="${1:-${QUOTA_MOUNTPOINT}}"
    df "${mp}" 2>/dev/null | awk 'NR==2 {print $1}'
}

# ------------------------------------------------------------
# Habilitar cuotas en XFS
# ------------------------------------------------------------

cuotas_habilitar_xfs() {
    local mountpoint="${1}"

    aputs_info "Habilitando cuotas XFS en ${mountpoint}..."

    # Verificar si ya están activas
    if xfs_quota -x -c "state" "${mountpoint}" 2>/dev/null | grep -q "User quota.*ON\|Accounting.*ON"; then
        aputs_ok "Cuotas XFS ya activas en ${mountpoint}"
        return 0
    fi

    local device
    device=$(cuotas_detectar_dispositivo "${mountpoint}")

    # Agregar uquota a fstab si no está
    if ! grep -E "${mountpoint}|${device}" /etc/fstab 2>/dev/null | grep -q "uquota\|usrquota"; then
        aputs_info "Agregando opcion uquota en /etc/fstab..."
        # Buscar la linea del mountpoint y agregar uquota a las opciones
        sed -i -E "s|^([^#].*[[:space:]]${mountpoint}[[:space:]].*xfs[[:space:]])(defaults)|\1\2,uquota|" /etc/fstab 2>/dev/null || \
        sed -i -E "s|^([^#].*[[:space:]]${mountpoint}[[:space:]].*xfs[[:space:]].*)(defaults,.*)|\1\2,uquota|" /etc/fstab 2>/dev/null || true
        aputs_ok "fstab actualizado con uquota"
    else
        aputs_info "uquota ya presente en fstab"
    fi

    # Intentar remontar en caliente
    aputs_info "Intentando remontar ${mountpoint} con cuotas..."
    if mount -o remount,uquota "${mountpoint}" 2>/dev/null; then
        aputs_ok "${mountpoint} remontado con soporte de cuotas"
    else
        aputs_warning "No se pudo remontar en caliente"
        aputs_info "Si /home esta en la misma particion que /, reinicie el sistema"
        aputs_info "y vuelva a ejecutar este paso para activar las cuotas"
    fi
}

# ------------------------------------------------------------
# Habilitar cuotas en ext4
# ------------------------------------------------------------

cuotas_habilitar_ext4() {
    local mountpoint="${1}"

    aputs_info "Habilitando cuotas ext4 en ${mountpoint}..."

    # Crear archivos de cuota si no existen
    if [[ ! -f "${mountpoint}/aquota.user" ]]; then
        aputs_info "Inicializando base de datos de cuotas..."
        quotacheck -cugm "${mountpoint}" 2>/dev/null || true
    fi

    # Activar cuotas
    quotaon -u "${mountpoint}" 2>/dev/null && \
        aputs_ok "Cuotas activadas en ${mountpoint}" || \
        aputs_info "Cuotas ya activas o requieren reinicio"
}

# ------------------------------------------------------------
# Asignar cuota a un usuario
# ------------------------------------------------------------

cuotas_asignar_usuario() {
    local usuario="$1"
    local mountpoint="${2:-${QUOTA_MOUNTPOINT}}"
    local fstype
    fstype=$(cuotas_detectar_fs "${mountpoint}")

    aputs_info "Asignando cuota a: ${usuario}"
    aputs_info "  Soft: $((QUOTA_SOFT_KB / 1024)) MB | Hard: $((QUOTA_HARD_KB / 1024)) MB"

    if [[ "${fstype}" == "xfs" ]]; then
        if xfs_quota -x -c \
            "limit -u bsoft=${QUOTA_SOFT_KB}k bhard=${QUOTA_HARD_KB}k ${usuario}" \
            "${mountpoint}" 2>/dev/null; then
            aputs_ok "Cuota XFS aplicada a ${usuario}"
        else
            aputs_warning "No se pudo aplicar cuota XFS (cuotas no activas aun en el FS)"
            aputs_info "  Reinicie el sistema, ejecute este paso de nuevo y asigne la cuota"
        fi
    else
        if command -v setquota &>/dev/null; then
            setquota -u "${usuario}" \
                "${QUOTA_SOFT_KB}" "${QUOTA_HARD_KB}" 0 0 \
                "${mountpoint}" 2>/dev/null && \
                aputs_ok "Cuota aplicada a ${usuario}" || \
                aputs_warning "No se pudo aplicar cuota a ${usuario}"
        else
            aputs_warning "setquota no disponible"
        fi
    fi
}

# ------------------------------------------------------------
# Mostrar cuota de un usuario
# ------------------------------------------------------------

cuotas_mostrar_usuario() {
    local usuario="$1"
    local mountpoint="${2:-${QUOTA_MOUNTPOINT}}"
    local fstype
    fstype=$(cuotas_detectar_fs "${mountpoint}")

    echo ""
    aputs_info "Cuota actual de ${usuario}:"
    echo ""

    if [[ "${fstype}" == "xfs" ]]; then
        xfs_quota -x -c "quota -u ${usuario}" "${mountpoint}" 2>/dev/null | \
            while IFS= read -r linea; do echo "    ${linea}"; done || \
            aputs_warning "No se pudo consultar cuota (cuotas no activas)"
    else
        if command -v quota &>/dev/null; then
            quota -u "${usuario}" 2>/dev/null | \
                while IFS= read -r linea; do echo "    ${linea}"; done || true
        fi
    fi
}

# ------------------------------------------------------------
# Verificar estado general de cuotas
# ------------------------------------------------------------

cuotas_verificar() {
    echo ""
    aputs_info "--- Verificacion de cuotas de disco ---"
    echo ""

    local fstype
    fstype=$(cuotas_detectar_fs "${QUOTA_MOUNTPOINT}")
    local device
    device=$(cuotas_detectar_dispositivo "${QUOTA_MOUNTPOINT}")

    printf "    %-28s : %s\n" "Punto de montaje" "${QUOTA_MOUNTPOINT}"
    printf "    %-28s : %s\n" "Dispositivo" "${device}"
    printf "    %-28s : %s\n" "Filesystem" "${fstype}"
    printf "    %-28s : %d KB (%d MB)\n" "Limite soft" "${QUOTA_SOFT_KB}" "$((QUOTA_SOFT_KB/1024))"
    printf "    %-28s : %d KB (%d MB)\n" "Limite hard" "${QUOTA_HARD_KB}" "$((QUOTA_HARD_KB/1024))"
    echo ""

    if [[ "${fstype}" == "xfs" ]]; then
        aputs_info "Estado cuotas XFS:"
        xfs_quota -x -c "state" "${QUOTA_MOUNTPOINT}" 2>/dev/null | \
            grep -E "Accounting|Enforcement" | \
            while IFS= read -r linea; do echo "    ${linea}"; done || \
            aputs_warning "No se pudo consultar estado (cuotas no activas aun)"
    else
        if command -v repquota &>/dev/null; then
            aputs_info "Resumen de cuotas:"
            repquota -u "${QUOTA_MOUNTPOINT}" 2>/dev/null | head -15 | \
                while IFS= read -r linea; do echo "    ${linea}"; done || true
        fi
    fi

    echo ""
    local usuario_prueba="administrador@${AD_DOMINIO}"
    cuotas_mostrar_usuario "${usuario_prueba}" "${QUOTA_MOUNTPOINT}"
}

# ------------------------------------------------------------
# Orquestador
# ------------------------------------------------------------

cuotas_configurar_completo() {
    clear
    ad_mostrar_banner "Paso 6 -- Cuotas de Disco para Usuarios AD"

    echo ""
    echo "  Cuotas que se aplicaran en: ${QUOTA_MOUNTPOINT}"
    printf "    %-28s : %d KB (%d MB) -- aviso\n" "Soft limit" "${QUOTA_SOFT_KB}" "$((QUOTA_SOFT_KB/1024))"
    printf "    %-28s : %d KB (%d MB) -- bloqueo\n" "Hard limit" "${QUOTA_HARD_KB}" "$((QUOTA_HARD_KB/1024))"
    echo ""
    draw_line
    echo ""

    # 1. Paquetes
    cuotas_instalar_paquetes
    echo ""

    # 2. Detectar filesystem y habilitar cuotas
    local fstype
    fstype=$(cuotas_detectar_fs "${QUOTA_MOUNTPOINT}")
    aputs_info "Filesystem en ${QUOTA_MOUNTPOINT}: ${fstype}"
    echo ""

    if [[ "${fstype}" == "xfs" ]]; then
        cuotas_habilitar_xfs "${QUOTA_MOUNTPOINT}"
    elif [[ "${fstype}" == "ext4" || "${fstype}" == "ext3" ]]; then
        cuotas_habilitar_ext4 "${QUOTA_MOUNTPOINT}"
    else
        aputs_warning "Filesystem '${fstype}' no soportado automaticamente"
        aputs_info "Configure las cuotas manualmente para este tipo de filesystem"
    fi
    echo ""

    # 3. Asignar cuota al usuario de prueba
    local usuario_prueba="administrador@${AD_DOMINIO}"
    cuotas_asignar_usuario "${usuario_prueba}" "${QUOTA_MOUNTPOINT}"
    echo ""

    # 4. Verificar
    cuotas_verificar
    echo ""
    draw_line
    aputs_ok "Cuotas configuradas"
    aputs_info "Para probar: inicie sesion como usuario AD e intente crear archivos grandes"
    aputs_info "  dd if=/dev/zero of=~/test.img bs=1M count=200"
    aputs_info "Verificar cuota: xfs_quota -x -c 'quota -u administrador@${AD_DOMINIO}' ${QUOTA_MOUNTPOINT}"

    pause
    return 0
}
