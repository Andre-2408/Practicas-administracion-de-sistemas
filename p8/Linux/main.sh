#!/bin/bash
#
# main.sh -- Orquestador principal Practica 8 (Linux Client)
# Gobernanza, Cuotas y Control de Aplicaciones en Active Directory
# Union del cliente Linux al dominio AD
#
# Uso:
#   sudo bash main.sh
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Verificar root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo ""
    echo "  [ERROR] Este script requiere privilegios de root."
    echo "  Ejecute: sudo bash ${BASH_SOURCE[0]}"
    echo ""
    exit 1
fi

# ------------------------------------------------------------
# Verificar estructura de archivos
# ------------------------------------------------------------

_verificar_estructura() {
    local errores=0

    local archivos_req=(
        "${SCRIPT_DIR}/utils.AD.sh"
    )

    for archivo in "${archivos_req[@]}"; do
        if [[ ! -f "${archivo}" ]]; then
            echo "  [ERROR] Archivo no encontrado: ${archivo}"
            errores=$(( errores + 1 ))
        fi
    done

    local modulos=(
        "${SCRIPT_DIR}/modules/01-instalar-paquetes.sh"
        "${SCRIPT_DIR}/modules/02-unirse-dominio.sh"
        "${SCRIPT_DIR}/modules/03-configurar-sssd.sh"
        "${SCRIPT_DIR}/modules/04-configurar-sudo.sh"
        "${SCRIPT_DIR}/modules/05-restriccion-horaria.sh"
        "${SCRIPT_DIR}/modules/06-cuotas-disco.sh"
    )

    for mod in "${modulos[@]}"; do
        if [[ ! -f "${mod}" ]]; then
            echo "  [AVISO] Modulo no encontrado: ${mod}"
        fi
    done

    if [[ "${errores}" -gt 0 ]]; then
        echo ""
        echo "  Verifique la estructura de la Practica 8:"
        echo "  p8/Linux/main.sh"
        echo "  p8/Linux/utils.AD.sh"
        echo "  p8/Linux/modules/0x-*.sh"
        echo ""
        exit 1
    fi
}

# ------------------------------------------------------------
# Cargar utils y modulos
# ------------------------------------------------------------

_cargar_modulos() {
    # shellcheck source=utils.AD.sh
    source "${SCRIPT_DIR}/utils.AD.sh"

    local modulos=(
        "${SCRIPT_DIR}/modules/01-instalar-paquetes.sh"
        "${SCRIPT_DIR}/modules/02-unirse-dominio.sh"
        "${SCRIPT_DIR}/modules/03-configurar-sssd.sh"
        "${SCRIPT_DIR}/modules/04-configurar-sudo.sh"
        "${SCRIPT_DIR}/modules/05-restriccion-horaria.sh"
        "${SCRIPT_DIR}/modules/06-cuotas-disco.sh"
    )

    for mod in "${modulos[@]}"; do
        [[ -f "${mod}" ]] && source "${mod}"
    done
}

# ------------------------------------------------------------
# Indicadores de estado
# ------------------------------------------------------------

_icono_estado() {
    local condicion="$1"
    [[ "${condicion}" == "ok" ]] && echo "[*]" || echo "[ ]"
}

_estado_paquetes() {
    command -v realm &>/dev/null 2>&1 && \
    command -v sssd  &>/dev/null 2>&1 && \
    command -v adcli &>/dev/null 2>&1 && echo "ok" || echo "no"
}

_estado_dominio() {
    ad_verificar_dominio_unido && echo "ok" || echo "no"
}

_estado_sssd() {
    [[ -f "${AD_SSSD_CONF}" ]] && \
    grep -q "fallback_homedir.*%u@%d" "${AD_SSSD_CONF}" 2>/dev/null && \
    systemctl is-active --quiet sssd 2>/dev/null && echo "ok" || echo "no"
}

_estado_sudo() {
    [[ -f "${AD_SUDOERS_FILE}" ]] && echo "ok" || echo "no"
}

_estado_horario() {
    grep -q "pam_time.so" /etc/pam.d/system-auth 2>/dev/null && echo "ok" || echo "no"
}

_estado_cuotas() {
    local fstype
    fstype=$(df -T /home 2>/dev/null | awk 'NR==2 {print $2}')
    if [[ "${fstype}" == "xfs" ]]; then
        xfs_quota -x -c "state" /home 2>/dev/null | grep -q "Accounting.*ON" && echo "ok" || echo "no"
    else
        [[ -f /home/aquota.user ]] && echo "ok" || echo "no"
    fi
}

# ------------------------------------------------------------
# Dibujar menu principal
# ------------------------------------------------------------

_dibujar_menu() {
    clear

    local s1 s2 s3 s4 s5 s6
    s1=$(_icono_estado "$(_estado_paquetes)")
    s2=$(_icono_estado "$(_estado_dominio)")
    s3=$(_icono_estado "$(_estado_sssd)")
    s4=$(_icono_estado "$(_estado_sudo)")
    s5=$(_icono_estado "$(_estado_horario)")
    s6=$(_icono_estado "$(_estado_cuotas)")

    echo ""
    echo "  =========================================================="
    echo "    Practica 08 -- Union al Dominio AD (Linux)"
    echo "  =========================================================="
    echo ""
    printf "  Dominio objetivo : %s  (%s)\n" "${AD_DOMINIO}" "${AD_REALM}"
    echo ""
    echo "  -- Pasos de Configuracion ------------------------------------"
    echo "  1) ${s1}  Instalar paquetes (realmd, sssd, adcli, krb5)"
    echo "  2) ${s2}  Unirse al dominio AD   (realm join)"
    echo "  3) ${s3}  Configurar sssd.conf"
    echo "             fallback_homedir = /home/%u@%d"
    echo "  4) ${s4}  Configurar sudo para usuarios AD"
    echo "             /etc/sudoers.d/ad-admins"
    echo "  5) ${s5}  Restriccion de login por horario"
    echo "             pam_time -- Lunes-Viernes 08:00-20:00"
    echo "  6) ${s6}  Cuotas de disco para usuarios AD"
    echo "             Soft: 100 MB | Hard: 150 MB"
    echo ""
    echo "  -- Utiles ----------------------------------------------------"
    echo "  a)  Ejecutar todos los pasos en orden (1-6)"
    echo "  v)  Verificacion general del sistema"
    echo ""
    echo "  0)  Salir"
    echo ""
}

# ------------------------------------------------------------
# Verificacion general
# ------------------------------------------------------------

_verificacion_general() {
    clear
    ad_mostrar_banner "Verificacion General -- Practica 8 (Linux)"

    echo ""
    draw_line

    aputs_info "Sistema:"
    printf "    %-24s : %s\n" "Hostname"  "$(hostname -f 2>/dev/null || hostname)"
    printf "    %-24s : %s\n" "Distro"    "$(ad_detectar_distro)"
    printf "    %-24s : %s\n" "Paquetes"  "$(ad_gestor_paquetes)"
    echo ""

    aputs_info "Paquetes AD:"
    for pkg in realmd sssd adcli; do
        if command -v "${pkg}" &>/dev/null 2>&1; then
            printf "    %-20s : instalado\n" "${pkg}"
        else
            printf "    %-20s : NO encontrado\n" "${pkg}"
        fi
    done
    echo ""

    draw_line
    echo ""

    aputs_info "Estado del dominio:"
    if realm list 2>/dev/null | grep -q "${AD_DOMINIO}"; then
        realm list 2>/dev/null | while IFS= read -r linea; do
            echo "    ${linea}"
        done
    else
        aputs_warning "No unido al dominio"
    fi
    echo ""

    draw_line
    sssd_verificar 2>/dev/null

    echo ""
    draw_line
    sudo_verificar 2>/dev/null

    echo ""
    draw_line
    pause
}

# ------------------------------------------------------------
# Ejecutar todos los pasos en orden
# ------------------------------------------------------------

_todos_los_pasos() {
    clear
    ad_mostrar_banner "Configuracion Completa -- Pasos 1 al 4"

    echo ""
    echo "  Se ejecutaran todos los pasos en orden."
    echo ""
    read -rp "  Desea continuar? [S/n]: " respuesta
    if [[ "${respuesta}" =~ ^[nN]$ ]]; then
        aputs_info "Operacion cancelada"
        pause
        return
    fi

    set +e   # No salir en errores durante la ejecucion de pasos
    echo ""

    aputs_info ">>> Paso 1: Instalar paquetes"
    paquetes_instalar_completo

    aputs_info ">>> Paso 2: Unirse al dominio"
    dominio_unirse_completo

    aputs_info ">>> Paso 3: Configurar sssd"
    sssd_configurar_completo

    aputs_info ">>> Paso 4: Configurar sudo"
    sudo_configurar_completo

    aputs_info ">>> Paso 5: Restriccion horaria"
    tiempo_configurar_completo

    aputs_info ">>> Paso 6: Cuotas de disco"
    cuotas_configurar_completo

    set -e

    echo ""
    draw_line
    aputs_ok "Configuracion completa finalizada"
    echo ""
    aputs_info "Para iniciar sesion como usuario AD: usuario@${AD_DOMINIO}"
    pause
}

# ------------------------------------------------------------
# Menu principal
# ------------------------------------------------------------

main_menu() {
    while true; do
        _dibujar_menu

        local op
        read -rp "  Opcion: " op

        case "${op}" in
            1) paquetes_instalar_completo   ;;
            2) dominio_unirse_completo      ;;
            3) sssd_configurar_completo     ;;
            4) sudo_configurar_completo     ;;
            5) tiempo_configurar_completo   ;;
            6) cuotas_configurar_completo   ;;
            a|A) _todos_los_pasos           ;;
            v|V) _verificacion_general      ;;
            0)
                echo ""
                aputs_info "Saliendo de la Practica 8..."
                echo ""
                exit 0
                ;;
            *)
                aputs_error "Opcion invalida"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Punto de entrada
# ------------------------------------------------------------

_verificar_estructura
_cargar_modulos
main_menu
