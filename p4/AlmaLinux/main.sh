#!/bin/bash
# main.sh — Administrador de servicios
# Uso: sudo bash main.sh

DIR="$(cd "$(dirname "$0")" && pwd)"

source "$DIR/common-functions.sh"
source "$DIR/ssh-functions.sh"
source "/home/andre/menu-dhcp.sh"
source "/home/andre/DnsLinux.sh"

verificar_root

# ─────────────────────────────────────────
# MENUS POR SERVICIO
# ─────────────────────────────────────────
menu_ssh() {
    while true; do
        clear
        echo ""
        echo "================================"
        echo "   SSH Manager - Linux          "
        echo "================================"
        echo "1) Verificar instalacion"
        echo "2) Instalar OpenSSH Server"
        echo "3) Configurar seguridad"
        echo "4) Reiniciar servicio"
        echo "0) Volver"
        echo "--------------------------------"
        read -rp "> " opt
        case "$opt" in
            1) ssh_verificar   ;;
            2) ssh_instalar    ;;
            3) ssh_configurar  ;;
            4) ssh_reiniciar   ;;
            0) return          ;;
            *) echo "Opcion invalida"; sleep 1 ;;
        esac
    done
}

menu_dhcp() {
    while true; do
        clear
        echo ""
        echo "================================"
        echo "   DHCP Manager - Linux         "
        echo "================================"
        echo "1) Verificar instalacion"
        echo "2) Instalar DHCP"
        echo "3) Modificar configuracion"
        echo "4) Monitor"
        echo "5) Reiniciar servicio"
        echo "0) Volver"
        echo "--------------------------------"
        read -rp "> " opt
        case "$opt" in
            1) dhcp_verificar  ;;
            2) dhcp_instalar   ;;
            3) dhcp_modificar  ;;
            4) dhcp_monitor    ;;
            5) dhcp_reiniciar  ;;
            0) return          ;;
            *) echo "Opcion invalida"; sleep 1 ;;
        esac
    done
}

menu_dns() {
    while true; do
        clear
        echo ""
        echo "================================"
        echo "   DNS Manager - Linux          "
        echo "================================"
        echo "1) Verificar instalacion"
        echo "2) Instalar DNS"
        echo "3) Configurar zona base"
        echo "4) Reconfigurar"
        echo "5) Administrar dominios (ABC)"
        echo "6) Validar y probar resolucion"
        echo "0) Volver"
        echo "--------------------------------"
        read -rp "> " opt
        case "$opt" in
            1) dns_verificar    ;;
            2) dns_instalar     ;;
            3) dns_configurar   ;;
            4) dns_reconfigurar ;;
            5) dns_administrar  ;;
            6) dns_validar      ;;
            0) return           ;;
            *) echo "Opcion invalida"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────
# MENU PRINCIPAL
# ─────────────────────────────────────────
while true; do
    clear
    echo ""
    echo "================================"
    echo "   Administrador de Servicios   "
    echo "       Linux Server             "
    echo "================================"
    echo "1) SSH  - Acceso remoto"
    echo "2) DHCP - Servidor DHCP"
    echo "3) DNS  - Servidor DNS"
    echo "4) Salir"
    echo "--------------------------------"
    read -rp "> " opt
    case "$opt" in
        1) menu_ssh  ;;
        2) menu_dhcp ;;
        3) menu_dns  ;;
        4) echo "Saliendo..."; exit 0 ;;
        *) echo "Opcion invalida"; sleep 1 ;;
    esac
done