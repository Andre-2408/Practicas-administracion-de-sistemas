#!/bin/bash
#
# 05-restriccion-horaria.sh -- Restriccion de login por horario via pam_time
# Requiere: utils.AD.sh cargado previamente
#
# Restringe el acceso al sistema segun el horario configurado.
# Usa pam_time.so con /etc/security/time.conf
#

readonly PAM_TIME_CONF="/etc/security/time.conf"
readonly TIEMPO_HORA_INICIO="0800"
readonly TIEMPO_HORA_FIN="2000"
readonly TIEMPO_DIAS="Wk"   # Wk = lunes-viernes | Al = todos los dias

# ------------------------------------------------------------
# Configurar /etc/security/time.conf
# ------------------------------------------------------------

tiempo_configurar_time_conf() {
    aputs_info "Configurando ${PAM_TIME_CONF}..."

    # Backup
    if [[ -f "${PAM_TIME_CONF}" ]]; then
        cp "${PAM_TIME_CONF}" "${PAM_TIME_CONF}.bak"
    fi

    # Eliminar reglas anteriores de esta practica si las hay
    sed -i '/Practica 8/,/^$/d' "${PAM_TIME_CONF}" 2>/dev/null || true

    # Agregar regla: todos los servicios, todos los terminales,
    # todos los usuarios excepto root, en horario laboral
    cat >> "${PAM_TIME_CONF}" << 'REGLA'

# Restriccion horaria -- Practica 8
# formato: servicio;terminal;usuarios;dias+horas
# Wk = lunes a viernes, 0800-2000
*;*;!root;Wk0800-2000
REGLA

    aputs_ok "Regla configurada: Lunes-Viernes ${TIEMPO_HORA_INICIO}-${TIEMPO_HORA_FIN} (excepto root)"
}

# ------------------------------------------------------------
# Habilitar pam_time.so en la pila PAM
# ------------------------------------------------------------

tiempo_configurar_pam() {
    aputs_info "Habilitando pam_time.so en PAM..."

    local archivos=("/etc/pam.d/system-auth" "/etc/pam.d/password-auth")

    for pam_file in "${archivos[@]}"; do
        if [[ ! -f "${pam_file}" ]]; then
            aputs_warning "No encontrado: ${pam_file}"
            continue
        fi

        if grep -q "pam_time.so" "${pam_file}" 2>/dev/null; then
            aputs_info "pam_time.so ya presente en: ${pam_file##*/}"
            continue
        fi

        # Insertar en la seccion account, antes de pam_unix.so
        if grep -q "^account.*pam_unix.so" "${pam_file}"; then
            sed -i '/^account.*pam_unix.so/i account    required     pam_time.so' "${pam_file}"
            aputs_ok "pam_time.so insertado en: ${pam_file##*/}"
        else
            # Si no hay pam_unix.so en account, agregar al final de la seccion account
            echo "account    required     pam_time.so" >> "${pam_file}"
            aputs_ok "pam_time.so agregado al final de: ${pam_file##*/}"
        fi
    done
}

# ------------------------------------------------------------
# Verificar la configuracion
# ------------------------------------------------------------

tiempo_verificar() {
    echo ""
    aputs_info "--- Verificacion de restriccion horaria ---"
    echo ""

    # Reglas activas
    if [[ -f "${PAM_TIME_CONF}" ]]; then
        local reglas
        reglas=$(grep -v "^#" "${PAM_TIME_CONF}" 2>/dev/null | grep -v "^$") || true
        if [[ -n "${reglas}" ]]; then
            echo "  Reglas activas en time.conf:"
            echo "${reglas}" | while IFS= read -r linea; do
                echo "    ${linea}"
            done
        else
            aputs_warning "No hay reglas activas en ${PAM_TIME_CONF}"
        fi
    fi

    echo ""

    # Estado de PAM
    local activo=0
    for pam_file in "/etc/pam.d/system-auth" "/etc/pam.d/password-auth"; do
        if grep -q "pam_time.so" "${pam_file}" 2>/dev/null; then
            printf "    %-30s : activo\n" "${pam_file##*/}"
            activo=$(( activo + 1 ))
        else
            printf "    %-30s : NO configurado\n" "${pam_file##*/}"
        fi
    done

    echo ""
    if [[ "${activo}" -gt 0 ]]; then
        aputs_ok "Restriccion horaria activa"
        aputs_info "Horario: Lunes-Viernes ${TIEMPO_HORA_INICIO}-${TIEMPO_HORA_FIN} (root excluido)"
        aputs_info "Para probar: intente 'su - usuario@${AD_DOMINIO}' fuera del horario configurado"
    else
        aputs_warning "pam_time.so no detectado en PAM"
    fi
}

# ------------------------------------------------------------
# Orquestador
# ------------------------------------------------------------

tiempo_configurar_completo() {
    clear
    ad_mostrar_banner "Paso 5 -- Restriccion de Login por Horario"

    echo ""
    echo "  Configuracion de acceso por horario:"
    printf "    %-28s : Lunes-Viernes %s-%s\n" "Horario permitido" "${TIEMPO_HORA_INICIO}" "${TIEMPO_HORA_FIN}"
    printf "    %-28s : Todos excepto root\n" "Usuarios restringidos"
    printf "    %-28s : pam_time.so\n" "Mecanismo PAM"
    echo ""
    draw_line
    echo ""

    tiempo_configurar_time_conf
    echo ""
    tiempo_configurar_pam
    echo ""
    tiempo_verificar
    echo ""
    draw_line
    aputs_ok "Restriccion horaria configurada correctamente"

    pause
    return 0
}
