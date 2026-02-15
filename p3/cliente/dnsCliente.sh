#!/bin/bash
#==============================================================================
#  SCRIPT DE VALIDACIÓN DNS - CLIENTE
#  Sistema Operativo: POP!_OS
#  Dominio base: reprobados.com
#==============================================================================

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Variables globales ───────────────────────────────────────────────────────
DOMINIO_BASE="reprobados.com"
EVIDENCIA_DIR="$HOME/evidencias_dns_cliente"
LOG_FILE="${EVIDENCIA_DIR}/cliente_dns_$(date +%Y%m%d).log"
IP_SERVIDOR_DNS=""
IP_CLIENTE=""

# ── Funciones de utilidad ────────────────────────────────────────────────────
exito() { echo -e "${GREEN}  [✔] $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}  [✘] $1${NC}" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}  [ℹ] $1${NC}" | tee -a "$LOG_FILE"; }
aviso() { echo -e "${YELLOW}  [⚠] $1${NC}" | tee -a "$LOG_FILE"; }

separador() { echo -e "${CYAN}  ──────────────────────────────────────────────────────────${NC}"; }
pausar() { echo ""; read -rp "  Presione ENTER para continuar..." _; }

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Este script debe ejecutarse como root (sudo)."
        exit 1
    fi
}

validar_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octetos <<< "$ip"
        for octeto in "${octetos[@]}"; do
            if (( octeto < 0 || octeto > 255 )); then return 1; fi
        done
        return 0
    fi
    return 1
}

# ── Detectar interfaz activa ─────────────────────────────────────────────────
detectar_interfaz() {
    INTERFAZ=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$INTERFAZ" ]]; then
        # Buscar primera interfaz activa que no sea loopback
        INTERFAZ=$(ip -br link show | grep -v "lo" | grep "UP" | awk '{print $1}' | head -1)
    fi
    IP_CLIENTE=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
}

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER Y MENÚ PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║         CLIENTE DNS - POP!_OS                              ║"
    echo "  ║         Validación y pruebas de resolución                 ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

menu_principal() {
    while true; do
        banner
        detectar_interfaz

        echo -e "  ${BOLD}Estado:${NC} Interfaz: ${INTERFAZ:-N/A} | IP: ${IP_CLIENTE:-Sin IP} | DNS: ${IP_SERVIDOR_DNS:-Sin configurar}"
        separador
        echo ""
        echo -e "  ${BOLD}Menú Principal${NC}"
        echo ""
        echo -e "    ${CYAN}1)${NC} Verificar configuración de red"
        echo -e "    ${CYAN}2)${NC} Configurar IP estática"
        echo -e "    ${CYAN}3)${NC} Configurar servidor DNS"
        echo -e "    ${CYAN}4)${NC} Ejecutar pruebas de resolución"
        echo -e "    ${CYAN}5)${NC} Release / Renew (renovar IP)"
        echo -e "    ${CYAN}6)${NC} Instalar herramientas DNS"
        echo -e "    ${CYAN}0)${NC} Salir"
        echo ""
        read -rp "  Seleccione una opción: " opcion

        case $opcion in
            1) opcion_verificar ;;
            2) opcion_ip_estatica ;;
            3) opcion_configurar_dns ;;
            4) opcion_pruebas ;;
            5) opcion_release_renew ;;
            6) opcion_herramientas ;;
            0) echo -e "\n  ${GREEN}Saliendo...${NC}\n"; exit 0 ;;
            *) error "Opción inválida." ; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  1) VERIFICAR CONFIGURACIÓN DE RED
# ══════════════════════════════════════════════════════════════════════════════
opcion_verificar() {
    banner
    echo -e "  ${BOLD}═══ VERIFICACIÓN DE RED ═══${NC}\n"

    detectar_interfaz

    # Interfaz
    info "Interfaz activa: $INTERFAZ"
    if [[ -n "$INTERFAZ" ]]; then
        ESTADO=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
        IP_COMPLETA=$(ip -4 addr show "$INTERFAZ" | grep inet | awk '{print $2}' | head -1)
        exito "Estado: $ESTADO | IP: ${IP_COMPLETA:-Sin IP}"

        # Tipo de IP
        CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -n "$CONEXION" ]]; then
            METODO=$(nmcli -g ipv4.method connection show "$CONEXION" 2>/dev/null)
            if [[ "$METODO" == "manual" ]]; then
                exito "Tipo: IP Estática"
            else
                aviso "Tipo: DHCP"
            fi
        fi
    else
        error "No se detectó interfaz activa."
    fi

    # Gateway
    echo ""
    info "Gateway:"
    GW=$(ip route | grep default | awk '{print $3}' | head -1)
    if [[ -n "$GW" ]]; then
        exito "Gateway: $GW"
    else
        aviso "Sin gateway configurado."
    fi

    # DNS configurado
    echo ""
    info "Servidores DNS:"
    if [[ -n "$CONEXION" ]]; then
        DNS_CONF=$(nmcli -g ipv4.dns connection show "$CONEXION" 2>/dev/null)
        if [[ -n "$DNS_CONF" ]]; then
            exito "DNS: $DNS_CONF"
        else
            aviso "Sin DNS personalizado (usando defaults)."
        fi
    fi

    echo ""
    info "Contenido de /etc/resolv.conf:"
    cat /etc/resolv.conf 2>/dev/null | while read -r line; do echo "    $line"; done

    # Herramientas
    echo ""
    info "Herramientas DNS:"
    for cmd in nslookup dig ping; do
        if command -v "$cmd" &>/dev/null; then
            exito "$cmd: Disponible"
        else
            error "$cmd: No instalado"
        fi
    done

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  2) CONFIGURAR IP ESTÁTICA
# ══════════════════════════════════════════════════════════════════════════════
opcion_ip_estatica() {
    banner
    echo -e "  ${BOLD}═══ CONFIGURAR IP ESTÁTICA ═══${NC}\n"

    detectar_interfaz

    if [[ -z "$INTERFAZ" ]]; then
        error "No se detectó interfaz activa."
        pausar
        return
    fi

    info "Interfaz: $INTERFAZ | IP actual: ${IP_CLIENTE:-Sin IP}"

    # Verificar si ya es estática
    CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    if [[ -n "$CONEXION" ]]; then
        METODO=$(nmcli -g ipv4.method connection show "$CONEXION" 2>/dev/null)
        if [[ "$METODO" == "manual" ]]; then
            exito "Ya tiene IP estática."
            echo ""
            echo -e "  ${YELLOW}¿Desea reconfigurar? (s/n) [n]:${NC}"
            read -rp "  " OPCION
            [[ ! "$OPCION" =~ ^[sS]$ ]] && return
        fi
    else
        CONEXION=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -z "$CONEXION" ]]; then
            aviso "Creando conexión para $INTERFAZ..."
            nmcli connection add type ethernet ifname "$INTERFAZ" con-name "cliente-${INTERFAZ}" 2>/dev/null
            CONEXION="cliente-${INTERFAZ}"
        fi
    fi

    echo ""
    while true; do
        read -rp "  Dirección IP [${IP_CLIENTE}]: " INPUT_IP
        INPUT_IP="${INPUT_IP:-$IP_CLIENTE}"
        if validar_ip "$INPUT_IP"; then break; fi
        error "IP inválida."
    done

    PREFIJO=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | head -1 | cut -d/ -f2)
    PREFIJO="${PREFIJO:-24}"
    read -rp "  Prefijo CIDR [${PREFIJO}]: " INPUT_PREF
    INPUT_PREF="${INPUT_PREF:-$PREFIJO}"

    GW=$(ip route | grep default | awk '{print $3}' | head -1)
    while true; do
        read -rp "  Gateway [${GW}]: " INPUT_GW
        INPUT_GW="${INPUT_GW:-$GW}"
        if validar_ip "$INPUT_GW"; then break; fi
        error "Gateway inválido."
    done

    read -rp "  DNS primario (IP del servidor DNS) [${IP_SERVIDOR_DNS}]: " INPUT_DNS
    INPUT_DNS="${INPUT_DNS:-$IP_SERVIDOR_DNS}"

    read -rp "  DNS secundario [8.8.8.8]: " INPUT_DNS2
    INPUT_DNS2="${INPUT_DNS2:-8.8.8.8}"

    info "Aplicando..."
    nmcli connection modify "$CONEXION" ipv4.addresses "${INPUT_IP}/${INPUT_PREF}"
    nmcli connection modify "$CONEXION" ipv4.gateway "$INPUT_GW"
    nmcli connection modify "$CONEXION" ipv4.dns "${INPUT_DNS} ${INPUT_DNS2}"
    nmcli connection modify "$CONEXION" ipv4.ignore-auto-dns yes
    nmcli connection modify "$CONEXION" ipv4.method manual
    nmcli connection down "$CONEXION" 2>/dev/null && nmcli connection up "$CONEXION" 2>/dev/null
    sleep 3

    IP_CLIENTE="$INPUT_IP"
    IP_SERVIDOR_DNS="$INPUT_DNS"
    exito "IP estática: $IP_CLIENTE/$INPUT_PREF | DNS: $IP_SERVIDOR_DNS"

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  3) CONFIGURAR SERVIDOR DNS
# ══════════════════════════════════════════════════════════════════════════════
opcion_configurar_dns() {
    banner
    echo -e "  ${BOLD}═══ CONFIGURAR SERVIDOR DNS DEL CLIENTE ═══${NC}\n"

    detectar_interfaz

    while true; do
        read -rp "  IP del servidor DNS: " IP_SERVIDOR_DNS
        if validar_ip "$IP_SERVIDOR_DNS"; then break; fi
        error "IP inválida."
    done

    read -rp "  DNS de respaldo [8.8.8.8]: " DNS_BACKUP
    DNS_BACKUP="${DNS_BACKUP:-8.8.8.8}"

    CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    if [[ -z "$CONEXION" ]]; then
        CONEXION=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    fi

    if [[ -n "$CONEXION" ]]; then
        nmcli connection modify "$CONEXION" ipv4.dns "${IP_SERVIDOR_DNS} ${DNS_BACKUP}"
        nmcli connection modify "$CONEXION" ipv4.ignore-auto-dns yes
        nmcli connection down "$CONEXION" 2>/dev/null && nmcli connection up "$CONEXION" 2>/dev/null
        sleep 3
        exito "DNS configurado: primario=${IP_SERVIDOR_DNS} | respaldo=${DNS_BACKUP}"
    else
        aviso "No se encontró conexión. Editando resolv.conf directamente..."
        echo "nameserver ${IP_SERVIDOR_DNS}" > /etc/resolv.conf
        echo "nameserver ${DNS_BACKUP}" >> /etc/resolv.conf
        exito "resolv.conf actualizado."
    fi

    echo ""
    info "resolv.conf actual:"
    cat /etc/resolv.conf 2>/dev/null | while read -r line; do echo "    $line"; done

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  4) EJECUTAR PRUEBAS DE RESOLUCIÓN
# ══════════════════════════════════════════════════════════════════════════════
opcion_pruebas() {
    banner
    echo -e "  ${BOLD}═══ PRUEBAS DE RESOLUCIÓN DNS ═══${NC}\n"

    # Pedir datos si no están configurados
    if [[ -z "$IP_SERVIDOR_DNS" ]]; then
        while true; do
            read -rp "  IP del servidor DNS: " IP_SERVIDOR_DNS
            if validar_ip "$IP_SERVIDOR_DNS"; then break; fi
            error "IP inválida."
        done
    fi

    # Preguntar dominio a probar
    read -rp "  Dominio a probar [${DOMINIO_BASE}]: " DOMINIO_TEST
    DOMINIO_TEST="${DOMINIO_TEST:-$DOMINIO_BASE}"

    read -rp "  IP esperada de resolución (ENTER para omitir): " IP_ESPERADA

    echo ""

    # Archivo de evidencias
    EVIDENCIA_FILE="${EVIDENCIA_DIR}/pruebas_$(date +%Y%m%d_%H%M%S).txt"

    cat > "$EVIDENCIA_FILE" <<EOF
==============================================================================
  REPORTE DE PRUEBAS DNS - CLIENTE POP!_OS
  Fecha:          $(date '+%Y-%m-%d %H:%M:%S')
  Servidor DNS:   $IP_SERVIDOR_DNS
  Dominio:        $DOMINIO_TEST
  IP Esperada:    ${IP_ESPERADA:-No especificada}
  Hostname:       $(hostname)
  IP Cliente:     ${IP_CLIENTE}
==============================================================================

EOF

    TOTAL=0
    OK=0
    FAIL=0

    # ── TEST 1: Ping al servidor DNS ──
    TOTAL=$((TOTAL+1))
    info "TEST 1: Conectividad con servidor DNS ($IP_SERVIDOR_DNS)"
    echo "--- TEST 1: ping $IP_SERVIDOR_DNS ---" >> "$EVIDENCIA_FILE"
    PING_SRV=$(ping -c 3 "$IP_SERVIDOR_DNS" 2>&1)
    echo "$PING_SRV" >> "$EVIDENCIA_FILE"
    if echo "$PING_SRV" | grep -q " 0% packet loss\| 0.0% packet loss"; then
        exito "Servidor DNS accesible"
        OK=$((OK+1))
    else
        error "No se alcanza el servidor DNS"
        FAIL=$((FAIL+1))
    fi

    # ── TEST 2: nslookup dominio ──
    TOTAL=$((TOTAL+1))
    info "TEST 2: nslookup ${DOMINIO_TEST} @${IP_SERVIDOR_DNS}"
    echo "--- TEST 2: nslookup ${DOMINIO_TEST} ---" >> "$EVIDENCIA_FILE"
    NSLOOKUP1=$(nslookup "$DOMINIO_TEST" "$IP_SERVIDOR_DNS" 2>&1)
    echo "$NSLOOKUP1" >> "$EVIDENCIA_FILE"

    if [[ -n "$IP_ESPERADA" ]]; then
        if echo "$NSLOOKUP1" | grep -q "$IP_ESPERADA"; then
            exito "${DOMINIO_TEST} → ${IP_ESPERADA} ✔"
            OK=$((OK+1))
        else
            error "${DOMINIO_TEST} → No coincide con $IP_ESPERADA"
            FAIL=$((FAIL+1))
        fi
    else
        if echo "$NSLOOKUP1" | grep -qE "Address:.*[0-9]+\.[0-9]+"; then
            exito "nslookup ${DOMINIO_TEST}: Resuelve"
            OK=$((OK+1))
        else
            error "nslookup ${DOMINIO_TEST}: Sin respuesta"
            FAIL=$((FAIL+1))
        fi
    fi

    # ── TEST 3: nslookup www ──
    TOTAL=$((TOTAL+1))
    info "TEST 3: nslookup www.${DOMINIO_TEST} @${IP_SERVIDOR_DNS}"
    echo "--- TEST 3: nslookup www.${DOMINIO_TEST} ---" >> "$EVIDENCIA_FILE"
    NSLOOKUP2=$(nslookup "www.${DOMINIO_TEST}" "$IP_SERVIDOR_DNS" 2>&1)
    echo "$NSLOOKUP2" >> "$EVIDENCIA_FILE"

    if echo "$NSLOOKUP2" | grep -qE "canonical name|Address.*[0-9]+\.[0-9]+"; then
        exito "nslookup www.${DOMINIO_TEST}: Resuelve"
        OK=$((OK+1))
    else
        error "nslookup www.${DOMINIO_TEST}: Sin respuesta"
        FAIL=$((FAIL+1))
    fi

    # ── TEST 4: dig dominio ──
    TOTAL=$((TOTAL+1))
    info "TEST 4: dig ${DOMINIO_TEST} @${IP_SERVIDOR_DNS}"
    echo "--- TEST 4: dig ${DOMINIO_TEST} ---" >> "$EVIDENCIA_FILE"
    DIG1=$(dig @"$IP_SERVIDOR_DNS" "$DOMINIO_TEST" A 2>&1)
    echo "$DIG1" >> "$EVIDENCIA_FILE"
    DIG1_SHORT=$(dig @"$IP_SERVIDOR_DNS" "$DOMINIO_TEST" A +short 2>&1)

    if [[ -n "$DIG1_SHORT" ]]; then
        exito "dig ${DOMINIO_TEST} → ${DIG1_SHORT}"
        OK=$((OK+1))
    else
        error "dig ${DOMINIO_TEST}: Sin resultado"
        FAIL=$((FAIL+1))
    fi

    # ── TEST 5: dig www ──
    TOTAL=$((TOTAL+1))
    info "TEST 5: dig www.${DOMINIO_TEST} @${IP_SERVIDOR_DNS}"
    echo "--- TEST 5: dig www.${DOMINIO_TEST} ---" >> "$EVIDENCIA_FILE"
    DIG2=$(dig @"$IP_SERVIDOR_DNS" "www.${DOMINIO_TEST}" 2>&1)
    echo "$DIG2" >> "$EVIDENCIA_FILE"

    if echo "$DIG2" | grep -qE "ANSWER SECTION"; then
        exito "dig www.${DOMINIO_TEST}: Resuelve"
        OK=$((OK+1))
    else
        error "dig www.${DOMINIO_TEST}: Sin respuesta"
        FAIL=$((FAIL+1))
    fi

    # ── TEST 6: ping dominio ──
    TOTAL=$((TOTAL+1))
    info "TEST 6: ping ${DOMINIO_TEST}"
    echo "--- TEST 6: ping ${DOMINIO_TEST} ---" >> "$EVIDENCIA_FILE"
    PING_DOM=$(ping -c 2 "$DOMINIO_TEST" 2>&1)
    echo "$PING_DOM" >> "$EVIDENCIA_FILE"

    if echo "$PING_DOM" | grep -q "bytes from"; then
        exito "ping ${DOMINIO_TEST}: Responde"
        OK=$((OK+1))
    else
        aviso "ping ${DOMINIO_TEST}: Sin respuesta ICMP"
        FAIL=$((FAIL+1))
    fi

    # ── TEST 7: ping www ──
    TOTAL=$((TOTAL+1))
    info "TEST 7: ping www.${DOMINIO_TEST}"
    echo "--- TEST 7: ping www.${DOMINIO_TEST} ---" >> "$EVIDENCIA_FILE"
    PING_WWW=$(ping -c 2 "www.${DOMINIO_TEST}" 2>&1)
    echo "$PING_WWW" >> "$EVIDENCIA_FILE"

    if echo "$PING_WWW" | grep -q "bytes from"; then
        exito "ping www.${DOMINIO_TEST}: Responde"
        OK=$((OK+1))
    else
        aviso "ping www.${DOMINIO_TEST}: Sin respuesta ICMP"
        FAIL=$((FAIL+1))
    fi

    # ── Resumen ──
    PORCENTAJE=0
    [[ $TOTAL -gt 0 ]] && PORCENTAJE=$(( (OK * 100) / TOTAL ))

    cat >> "$EVIDENCIA_FILE" <<EOF

==============================================================================
  RESUMEN:  $OK/$TOTAL exitosas (${PORCENTAJE}%)
==============================================================================
EOF

    echo ""
    if [[ $FAIL -eq 0 ]]; then COLOR="${GREEN}"
    elif [[ $FAIL -le 2 ]]; then COLOR="${YELLOW}"
    else COLOR="${RED}"; fi

    echo -e "${COLOR}${BOLD}"
    echo "  ╔════════════════════════════════════════════╗"
    echo "  ║            RESUMEN DE PRUEBAS             ║"
    echo "  ╠════════════════════════════════════════════╣"
    printf "  ║  Servidor DNS:  %-25s ║\n" "$IP_SERVIDOR_DNS"
    printf "  ║  Dominio:       %-25s ║\n" "$DOMINIO_TEST"
    printf "  ║  Exitosas:      %-3s / %-3s (%s%%)           ║\n" "$OK" "$TOTAL" "$PORCENTAJE"
    printf "  ║  Fallidas:      %-25s ║\n" "$FAIL"
    echo "  ╠════════════════════════════════════════════╣"
    printf "  ║  Evidencias: %-28s ║\n" "$(basename $EVIDENCIA_FILE)"
    echo "  ╚════════════════════════════════════════════╝"
    echo -e "${NC}"

    exito "Ruta: $EVIDENCIA_FILE"

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  5) RELEASE / RENEW
# ══════════════════════════════════════════════════════════════════════════════
opcion_release_renew() {
    banner
    echo -e "  ${BOLD}═══ RELEASE / RENEW ═══${NC}\n"

    detectar_interfaz

    CONEXION=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    METODO=$(nmcli -g ipv4.method connection show "$CONEXION" 2>/dev/null)

    info "Interfaz: $INTERFAZ | IP actual: $IP_CLIENTE"
    info "Método: $METODO"
    echo ""

    if [[ "$METODO" == "auto" ]]; then
        echo -e "    ${CYAN}1)${NC} Release (liberar IP)"
        echo -e "    ${CYAN}2)${NC} Renew (renovar IP)"
        echo -e "    ${CYAN}3)${NC} Release + Renew completo"
        echo -e "    ${CYAN}0)${NC} Volver"
        echo ""
        read -rp "  Seleccione: " sub

        case $sub in
            1)
                info "Ejecutando release..."
                dhclient -r "$INTERFAZ" 2>/dev/null || nmcli device disconnect "$INTERFAZ" 2>/dev/null
                sleep 2
                exito "IP liberada."
                ip -4 addr show "$INTERFAZ" | grep inet | while read -r line; do echo "    $line"; done
                ;;
            2)
                info "Ejecutando renew..."
                dhclient "$INTERFAZ" 2>/dev/null || nmcli connection up "$CONEXION" 2>/dev/null
                sleep 3
                NUEVA_IP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
                exito "IP renovada: $NUEVA_IP"
                ;;
            3)
                info "Release..."
                dhclient -r "$INTERFAZ" 2>/dev/null || nmcli device disconnect "$INTERFAZ" 2>/dev/null
                sleep 2
                exito "IP liberada."

                info "Renew..."
                dhclient "$INTERFAZ" 2>/dev/null || nmcli connection up "$CONEXION" 2>/dev/null
                sleep 3
                NUEVA_IP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
                exito "IP renovada: $NUEVA_IP"
                ;;
            0) return ;;
        esac
    else
        aviso "La interfaz tiene IP estática. Release/Renew aplica solo para DHCP."
        echo ""
        echo -e "  ${YELLOW}¿Desea reiniciar la conexión de todas formas? (s/n):${NC}"
        read -rp "  " OPCION
        if [[ "$OPCION" =~ ^[sS]$ ]]; then
            info "Reiniciando conexión..."
            nmcli connection down "$CONEXION" 2>/dev/null && nmcli connection up "$CONEXION" 2>/dev/null
            sleep 3
            NUEVA_IP=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
            exito "Conexión reiniciada. IP: $NUEVA_IP"
        fi
    fi

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  6) INSTALAR HERRAMIENTAS
# ══════════════════════════════════════════════════════════════════════════════
opcion_herramientas() {
    banner
    echo -e "  ${BOLD}═══ INSTALAR HERRAMIENTAS DNS ═══${NC}\n"

    FALTANTES=()

    for cmd in nslookup dig host; do
        if command -v "$cmd" &>/dev/null; then
            exito "$cmd: Instalado"
        else
            error "$cmd: No instalado"
            FALTANTES+=("dnsutils")
        fi
    done

    if ! command -v ping &>/dev/null; then
        error "ping: No instalado"
        FALTANTES+=("iputils-ping")
    else
        exito "ping: Instalado"
    fi

    if ! command -v dhclient &>/dev/null; then
        aviso "dhclient: No instalado (opcional para release/renew)"
        FALTANTES+=("isc-dhcp-client")
    else
        exito "dhclient: Instalado"
    fi

    # Eliminar duplicados
    FALTANTES=($(echo "${FALTANTES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [[ ${#FALTANTES[@]} -gt 0 ]]; then
        echo ""
        info "Paquetes faltantes: ${FALTANTES[*]}"
        echo -e "  ${YELLOW}¿Instalar? (s/n) [s]:${NC}"
        read -rp "  " OPCION
        OPCION="${OPCION:-s}"

        if [[ "$OPCION" =~ ^[sS]$ ]]; then
            info "Instalando..."
            apt-get update -qq
            apt-get install -y "${FALTANTES[@]}" 2>&1 | tee -a "$LOG_FILE"
            echo ""
            exito "Paquetes instalados."
        fi
    else
        echo ""
        exito "Todas las herramientas están disponibles."
    fi

    pausar
}

# ══════════════════════════════════════════════════════════════════════════════
#  INICIO
# ══════════════════════════════════════════════════════════════════════════════
verificar_root
mkdir -p "$EVIDENCIA_DIR"
menu_principal