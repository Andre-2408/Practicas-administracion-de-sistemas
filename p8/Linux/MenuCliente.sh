#!/bin/bash
#
# MenuCliente.sh -- Menu interactivo cliente Linux Practica 8
# Logica: YuckierOlive370/Tarea8GCC  |  Diseno visual: estilo del proyecto
#
# Uso:
#   sudo bash MenuCliente.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/FunCliente.sh"

verificar_root

# ============================================================
# INDICADORES DE ESTADO
# ============================================================

_icono() {
    [[ "$1" == "ok" ]] && echo "[*]" || echo "[ ]"
}

_st_dns() {
    host "${DOMINIO}" &>/dev/null 2>&1 && echo "ok" || echo "no"
}
_st_paquetes() {
    command -v realm &>/dev/null && command -v sssd &>/dev/null && echo "ok" || echo "no"
}
_st_kerberos() {
    [[ -f /etc/krb5.conf ]] && grep -q "${REALM}" /etc/krb5.conf 2>/dev/null && echo "ok" || echo "no"
}
_st_dominio() {
    realm list 2>/dev/null | grep -q "${DOMINIO}" && echo "ok" || echo "no"
}
_st_sssd() {
    [[ -f /etc/sssd/sssd.conf ]] && \
    grep -q "fallback_homedir" /etc/sssd/sssd.conf 2>/dev/null && echo "ok" || echo "no"
}
_st_sudoers() {
    [[ -f /etc/sudoers.d/ad-admins ]] && echo "ok" || echo "no"
}
_st_sssd_activo() {
    systemctl is-active --quiet sssd 2>/dev/null && echo "ok" || echo "no"
}

# ============================================================
# DIBUJAR MENU
# ============================================================

_dibujar_menu() {
    clear

    local s1 s2 s3 s4 s5 s6 s7
    s1=$(_icono "$(_st_dns)")
    s2=$(_icono "$(_st_paquetes)")
    s3=$(_icono "$(_st_kerberos)")
    s4=$(_icono "$(_st_dominio)")
    s5=$(_icono "$(_st_sssd)")
    s6=$(_icono "$(_st_sudoers)")
    s7=$(_icono "$(_st_sssd_activo)")

    echo ""
    echo "  =========================================================="
    echo "    Practica 08 -- Cliente Linux  (MenuCliente)"
    echo "  =========================================================="
    echo ""
    printf "  Dominio : %s   DC: %s\n" "${DOMINIO}" "${DC_IP}"
    printf "  Realm   : %s\n" "${REALM}"
    echo ""
    echo "  -- Pasos de Configuracion ------------------------------------"
    echo "  1) ${s1}  Configurar DNS hacia el DC"
    echo "             nameserver ${DC_IP}"
    echo "  2) ${s2}  Instalar paquetes (realmd, sssd, adcli, krb5)"
    echo "  3) ${s3}  Configurar Kerberos (/etc/krb5.conf)"
    echo "  4) ${s4}  Unirse al dominio  (realm join)"
    echo "  5) ${s5}  Configurar SSSD + PAM mkhomedir"
    echo "             fallback_homedir = /home/%u@%d"
    echo "  6) ${s6}  Configurar sudoers (domain admins)"
    echo "  7) ${s7}  Reiniciar SSSD y verificar"
    echo ""
    echo "  -- Utiles ----------------------------------------------------"
    echo "  a)  Flujo COMPLETO (pasos 1 al 7 en orden)"
    echo "  e)  Mostrar evidencia para la rubrica"
    echo "  r)  Refrescar indicadores de estado"
    echo ""
    echo "  0)  Salir"
    echo ""
}

# ============================================================
# LOOP PRINCIPAL
# ============================================================

while true; do
    _dibujar_menu
    read -rp "  Opcion: " op

    case "${op}" in
        1)
            configurar_dns
            ;;
        2)
            instalar_paquetes
            ;;
        3)
            configurar_kerberos
            ;;
        4)
            unir_dominio
            ;;
        5)
            configurar_sssd
            ;;
        6)
            configurar_sudoers
            ;;
        7)
            reiniciar_sssd
            ;;
        a|A)
            echo ""
            echo "  >> Ejecutando flujo completo (pasos 1-7)..."
            instalar_todo
            ;;
        e|E)
            mostrar_evidencia
            ;;
        r|R)
            # Solo redibujar
            ;;
        0)
            echo ""
            aputs_info "Saliendo..."
            echo ""
            exit 0
            ;;
        *)
            echo ""
            aputs_error "Opcion no valida"
            sleep 1
            ;;
    esac

    echo ""
    read -rp "  Presione ENTER para volver al menu..." _
done
