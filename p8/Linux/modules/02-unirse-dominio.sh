#!/bin/bash
#
# 02-unirse-dominio.sh -- Union del cliente Linux al dominio AD usando realmd
# Requiere: utils.AD.sh cargado previamente

# ------------------------------------------------------------
# Verificar y configurar la resolucion DNS hacia el DC
# ------------------------------------------------------------

dominio_verificar_dns() {
    aputs_info "Verificando resolucion DNS del dominio: ${AD_DOMINIO}"

    if host "${AD_DOMINIO}" &>/dev/null 2>&1; then
        local ip
        ip=$(host "${AD_DOMINIO}" | grep "has address" | head -1 | awk '{print $NF}')
        aputs_ok "DNS resuelve ${AD_DOMINIO} -> ${ip}"
        return 0
    fi

    aputs_warning "No se puede resolver '${AD_DOMINIO}'"

    if [[ -z "${AD_DC_IP}" ]]; then
        aputs_warning "AD_DC_IP no configurada en utils.AD.sh"
        aputs_info   "Edite utils.AD.sh y configure AD_DC_IP con la IP del controlador de dominio"
        return 1
    fi

    aputs_info "Configurando DNS para apuntar al DC: ${AD_DC_IP}"
    _dominio_configurar_dns "${AD_DC_IP}"
    return $?
}

# ------------------------------------------------------------
# Configurar /etc/resolv.conf para apuntar al DC
# ------------------------------------------------------------

_dominio_configurar_dns() {
    local ip_dc="$1"

    # Hacer backup del resolv.conf actual
    if [[ -f /etc/resolv.conf ]] && [[ ! -f /etc/resolv.conf.bak ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
        aputs_info "Backup de resolv.conf creado"
    fi

    # Escribir nuevo resolv.conf
    cat > /etc/resolv.conf << EOF
# Configurado por Practica 8 -- AD join
search ${AD_DOMINIO}
nameserver ${ip_dc}
EOF

    aputs_ok "resolv.conf configurado con nameserver ${ip_dc}"

    # Verificar resolucion
    sleep 2
    if host "${AD_DOMINIO}" &>/dev/null 2>&1; then
        aputs_ok "DNS resuelve correctamente ${AD_DOMINIO}"
        return 0
    else
        aputs_error "DNS sigue sin resolver ${AD_DOMINIO} -- verifique conectividad con el DC"
        return 1
    fi
}

# ------------------------------------------------------------
# Descubrir el dominio con realmd
# ------------------------------------------------------------

dominio_descubrir() {
    aputs_info "Descubriendo dominio: ${AD_DOMINIO}"

    local output
    output=$(realm discover "${AD_DOMINIO}" 2>&1)
    local ret=$?

    if [[ ${ret} -ne 0 ]]; then
        aputs_error "realm discover fallo: ${output}"
        return 1
    fi

    echo ""
    echo "${output}" | while IFS= read -r linea; do
        echo "    ${linea}"
    done
    echo ""

    aputs_ok "Dominio descubierto correctamente"
    return 0
}

# ------------------------------------------------------------
# Unirse al dominio con realm join
# ------------------------------------------------------------

dominio_unirse() {
    aputs_info "Iniciando union al dominio: ${AD_DOMINIO}"
    echo ""

    # Verificar si ya esta unido
    if ad_verificar_dominio_unido; then
        aputs_warning "Este equipo ya esta unido al dominio ${AD_DOMINIO}"
        echo ""
        read -rp "  Desea volver a unirse? (reimportara la cuenta) [s/N]: " respuesta
        if [[ ! "${respuesta}" =~ ^[sS]$ ]]; then
            aputs_info "Operacion cancelada"
            return 0
        fi

        # Salir primero para poder volver a unirse
        aputs_info "Saliendo del dominio para volver a unirse..."
        realm leave "${AD_DOMINIO}" 2>/dev/null || true
    fi

    echo ""
    aputs_info "Se requiere la contrasena del administrador del dominio (${AD_ADMIN})"
    echo ""

    # Intentar la union (realm join solicita la contrasena interactivamente)
    echo "" | realm join \
        --user="${AD_ADMIN}" \
        --computer-ou="OU=Computers,DC=$(echo "${AD_DOMINIO}" | sed 's/\./,DC=/g')" \
        "${AD_DOMINIO}" 2>/dev/null

    # realm join necesita la contrasena; si el pipe vacio falla, pedir interactivamente
    if ! ad_verificar_dominio_unido; then
        aputs_info "Intentando union interactiva (introduzca la contrasena cuando se solicite):"
        echo ""
        realm join --user="${AD_ADMIN}" "${AD_DOMINIO}"
    fi

    if ad_verificar_dominio_unido; then
        aputs_ok "Union al dominio '${AD_DOMINIO}' exitosa"
        return 0
    else
        aputs_error "No se pudo unir al dominio '${AD_DOMINIO}'"
        echo ""
        echo "  Causas comunes:"
        echo "    - DNS no apunta al DC (verifique /etc/resolv.conf)"
        echo "    - Credenciales incorrectas"
        echo "    - El servicio Kerberos no es accesible (puerto 88)"
        echo "    - Reloj del cliente fuera de sincronizacion con el DC (NTP)"
        return 1
    fi
}

# ------------------------------------------------------------
# Verificar el estado de la union al dominio
# ------------------------------------------------------------

dominio_verificar_estado() {
    echo ""
    aputs_info "--- Estado de la union al dominio ---"
    echo ""

    if realm list 2>/dev/null | grep -q "${AD_DOMINIO}"; then
        realm list 2>/dev/null | while IFS= read -r linea; do
            echo "    ${linea}"
        done
        echo ""
        aputs_ok "Este equipo esta unido al dominio ${AD_DOMINIO}"
    else
        aputs_warning "Este equipo NO esta unido a ningun dominio"
        return 1
    fi

    # Verificar que sssd esta activo
    if systemctl is-active --quiet sssd 2>/dev/null; then
        aputs_ok "sssd: activo"
    else
        aputs_warning "sssd: inactivo (reinicie con: systemctl restart sssd)"
    fi

    return 0
}

# ------------------------------------------------------------
# Sincronizar reloj con el DC (evitar errores Kerberos)
# ------------------------------------------------------------

dominio_sincronizar_reloj() {
    aputs_info "Sincronizando reloj con el DC (requerido por Kerberos)..."

    if command -v ntpdate &>/dev/null 2>&1; then
        ntpdate -u "${AD_DC}" 2>/dev/null && aputs_ok "Reloj sincronizado con ntpdate"
    elif command -v chronyd &>/dev/null 2>&1; then
        chronyc makestep 2>/dev/null && aputs_ok "Reloj sincronizado con chronyc"
    elif command -v timedatectl &>/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null && aputs_ok "NTP habilitado con timedatectl"
    else
        aputs_warning "No se encontro herramienta NTP -- verifique que el reloj esta sincronizado"
    fi
}

# ------------------------------------------------------------
# Orquestador: union completa al dominio
# ------------------------------------------------------------

dominio_unirse_completo() {
    clear
    ad_mostrar_banner "Paso 2 -- Union al Dominio AD"

    echo ""
    echo "  Dominio objetivo : ${AD_DOMINIO}"
    echo "  Realm Kerberos   : ${AD_REALM}"
    echo "  Administrador    : ${AD_ADMIN}"
    echo ""
    draw_line
    echo ""

    # 1. Verificar DNS
    if ! dominio_verificar_dns; then
        aputs_error "Resolucion DNS fallida -- corrija la configuracion DNS primero"
        pause
        return 1
    fi

    echo ""
    draw_line
    echo ""

    # 2. Sincronizar reloj
    dominio_sincronizar_reloj
    echo ""
    draw_line
    echo ""

    # 3. Descubrir dominio
    if ! dominio_descubrir; then
        aputs_error "No se pudo descubrir el dominio -- verifique DNS y conectividad"
        pause
        return 1
    fi

    draw_line
    echo ""

    # 4. Unirse al dominio
    if ! dominio_unirse; then
        pause
        return 1
    fi

    echo ""
    dominio_verificar_estado
    echo ""
    draw_line
    aputs_ok "Union al dominio completada"
    aputs_info "Continuar con Paso 3 para configurar sssd.conf"

    pause
    return 0
}
