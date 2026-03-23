#!/bin/bash
#
# 04-configurar-sudo.sh -- Configurar sudo para usuarios de Active Directory
# Requiere: utils.AD.sh cargado previamente
#
# Crea /etc/sudoers.d/ad-admins con:
#   - Grupo "Domain Admins" de AD con acceso sudo completo
#   - Configuracion validada con visudo antes de aplicar

# ------------------------------------------------------------
# Construir la entrada de sudoers para el grupo AD
# ------------------------------------------------------------

sudo_construir_entrada() {
    # En sudoers, los espacios en nombres de grupos se escapan con \
    # Nombre: "domain admins" -> "%domain\ admins@p8.local"
    local grupo_escapado
    grupo_escapado=$(echo "${AD_GRUPO_ADMINS}" | sed 's/ /\\ /g')

    cat << EOF
#
# /etc/sudoers.d/ad-admins
# Configurado por Practica 8 -- Permisos sudo para usuarios AD
#
# Permite a los miembros del grupo 'Domain Admins' del dominio ${AD_DOMINIO}
# ejecutar cualquier comando con sudo sin restriccion.
#
# NOTA: Los usuarios deben iniciar sesion con el nombre completo:
#         usuario@${AD_DOMINIO}
#

# Grupo Domain Admins del dominio AD
%${grupo_escapado}@${AD_DOMINIO} ALL=(ALL:ALL) ALL

EOF
}

# ------------------------------------------------------------
# Verificar sintaxis del archivo sudoers con visudo
# ------------------------------------------------------------

sudo_validar() {
    local archivo="$1"

    if command -v visudo &>/dev/null 2>&1; then
        if visudo -c -f "${archivo}" &>/dev/null 2>&1; then
            aputs_ok "Sintaxis del archivo sudoers valida"
            return 0
        else
            local errores
            errores=$(visudo -c -f "${archivo}" 2>&1)
            aputs_error "Error de sintaxis en sudoers:"
            echo "${errores}" | while IFS= read -r linea; do
                echo "    ${linea}"
            done
            return 1
        fi
    else
        aputs_warning "visudo no disponible -- omitiendo validacion de sintaxis"
        return 0
    fi
}

# ------------------------------------------------------------
# Crear el archivo /etc/sudoers.d/ad-admins
# ------------------------------------------------------------

sudo_configurar() {
    aputs_info "Configurando sudoers para usuarios AD..."

    # Asegurar directorio
    mkdir -p /etc/sudoers.d
    chmod 750 /etc/sudoers.d

    # Verificar que sudoers incluye el directorio .d
    if ! grep -q "^#includedir /etc/sudoers.d" /etc/sudoers 2>/dev/null && \
       ! grep -q "^@includedir /etc/sudoers.d" /etc/sudoers 2>/dev/null; then
        aputs_warning "sudoers no incluye /etc/sudoers.d -- verificando..."
        # Muchos sistemas modernos ya lo incluyen; si no, agregar
        if ! grep -q "includedir.*sudoers.d" /etc/sudoers 2>/dev/null; then
            echo "#includedir /etc/sudoers.d" >> /etc/sudoers
            aputs_ok "Directorio sudoers.d agregado al archivo sudoers principal"
        fi
    fi

    # Construir contenido y escribir a archivo temporal para validar
    local tmp_file
    tmp_file=$(mktemp /tmp/sudoers_ad_XXXXXX)
    sudo_construir_entrada > "${tmp_file}"

    # Validar sintaxis
    if ! sudo_validar "${tmp_file}"; then
        rm -f "${tmp_file}"
        return 1
    fi

    # Hacer backup del archivo existente
    if [[ -f "${AD_SUDOERS_FILE}" ]]; then
        cp "${AD_SUDOERS_FILE}" "${AD_SUDOERS_FILE}.bak"
        aputs_info "Backup creado: ${AD_SUDOERS_FILE}.bak"
    fi

    # Instalar el archivo
    mv "${tmp_file}" "${AD_SUDOERS_FILE}"
    chmod 0440 "${AD_SUDOERS_FILE}"
    chown root:root "${AD_SUDOERS_FILE}"

    aputs_ok "Archivo creado: ${AD_SUDOERS_FILE} (permisos 0440 root:root)"

    return 0
}

# ------------------------------------------------------------
# Verificar la configuracion de sudo
# ------------------------------------------------------------

sudo_verificar() {
    echo ""
    aputs_info "--- Verificacion de sudo para AD ---"
    echo ""

    if [[ -f "${AD_SUDOERS_FILE}" ]]; then
        aputs_ok "Archivo existe: ${AD_SUDOERS_FILE}"
        echo ""
        echo "  Contenido:"
        echo ""
        while IFS= read -r linea; do
            [[ "${linea}" =~ ^# ]] && continue   # saltar comentarios para brevedad
            [[ -z "${linea}" ]] && continue
            echo "    ${linea}"
        done < "${AD_SUDOERS_FILE}"
        echo ""

        # Validar permisos
        local perms
        perms=$(stat -c "%a %U:%G" "${AD_SUDOERS_FILE}" 2>/dev/null)
        printf "    %-20s : %s\n" "Permisos" "${perms}"

        # Validar sintaxis
        if visudo -c -f "${AD_SUDOERS_FILE}" &>/dev/null 2>&1; then
            aputs_ok "Sintaxis correcta"
        else
            aputs_error "Error de sintaxis detectado"
        fi
    else
        aputs_warning "Archivo no encontrado: ${AD_SUDOERS_FILE}"
    fi

    echo ""
    aputs_info "Para probar: iniciar sesion como usuario de AD y ejecutar 'sudo -l'"
    aputs_info "Ejemplo: sudo -l -U administrador@${AD_DOMINIO}"
}

# ------------------------------------------------------------
# Orquestador: configuracion completa sudo
# ------------------------------------------------------------

sudo_configurar_completo() {
    clear
    ad_mostrar_banner "Paso 4 -- Configuracion de Sudo para AD"

    echo ""
    echo "  Se configurara acceso sudo para:"
    printf "    Grupo: %s@%s\n" "${AD_GRUPO_ADMINS}" "${AD_DOMINIO}"
    echo ""
    echo "  Archivo de salida: ${AD_SUDOERS_FILE}"
    echo ""
    draw_line
    echo ""

    if ! sudo_configurar; then
        aputs_error "No se pudo configurar el archivo sudoers"
        pause
        return 1
    fi

    echo ""
    sudo_verificar
    echo ""
    draw_line
    aputs_ok "Sudo configurado para usuarios de AD"
    echo ""
    echo "  Resumen de permisos de inicio de sesion:"
    printf "    Usuarios de AD pueden iniciar sesion en: /home/%%u@%%d\n"
    printf "    'Domain Admins' tienen acceso sudo completo\n"
    echo ""

    pause
    return 0
}
