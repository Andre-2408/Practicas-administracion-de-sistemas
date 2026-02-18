#!/bin/bash
# =========================================================
# Cliente DHCP + DNS - POP!_OS
# Interfaz: ens37 | Red: 192.168.100.0/24
# =========================================================

INTERFAZ="ens37"
DOMINIO="reprobados.com"
EVIDENCIA_DIR="$HOME/evidencias_dhcp_dns"
LOG="${EVIDENCIA_DIR}/cliente.log"

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
B='\033[1m'
N='\033[0m'

msg_ok()   { echo -e "  ${G}[OK]${N} $1"; }
msg_err()  { echo -e "  ${R}[ERROR]${N} $1"; }
msg_info() { echo -e "  ${C}[INFO]${N} $1"; }
msg_warn() { echo -e "  ${Y}[AVISO]${N} $1"; }
pausar()   { echo ""; read -rp "  Presione ENTER para continuar... " _; }

validar_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a o <<< "$ip"
        for oct in "${o[@]}"; do (( oct < 0 || oct > 255 )) && return 1; done
        return 0
    fi
    return 1
}

obtener_info() {
    IP_CLIENTE=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    GW=$(ip route | grep default | grep "$INTERFAZ" | awk '{print $3}' | head -1)

    # obtener DNS configurado
    CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    if [[ -n "$CON" ]]; then
        METODO=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
        DNS_ASIGNADO=$(nmcli -g IP4.DNS device show "$INTERFAZ" 2>/dev/null | head -1)
    fi
}

# funciones release/renew usando nmcli (no depende de dhclient)
hacer_release() {
    CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    if command -v dhclient &>/dev/null; then
        dhclient -r "$INTERFAZ" 2>/dev/null
    fi
    nmcli device disconnect "$INTERFAZ" 2>/dev/null
    sleep 2
}

hacer_renew() {
    CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
    if [[ -z "$CON" ]]; then
        CON=$(nmcli -t -f NAME connection show 2>/dev/null | grep -i "dhcp\|${INTERFAZ}\|Wired\|ethernet" | head -1)
    fi
    if [[ -n "$CON" ]]; then
        nmcli connection up "$CON" 2>/dev/null
    else
        nmcli device connect "$INTERFAZ" 2>/dev/null
    fi
    sleep 5
}

if [[ $EUID -ne 0 ]]; then
    echo "Error: ejecute como root (sudo)."
    exit 1
fi

mkdir -p "$EVIDENCIA_DIR"

# =========================================================
# MENU PRINCIPAL
# =========================================================
while true; do
    clear
    obtener_info

    echo ""
    echo -e "  ${B}CLIENTE DHCP + DNS - POP!_OS${N}"
    echo "  ================================================"
    echo "  Interfaz: $INTERFAZ | IP: ${IP_CLIENTE:-N/A} | Metodo: ${METODO:-N/A}"
    echo "  DNS: ${DNS_ASIGNADO:-N/A} | Gateway: ${GW:-N/A}"
    echo "  ================================================"
    echo ""
    echo "  1) Verificar estado de red"
    echo "  2) Configurar interfaz en DHCP"
    echo "  3) Release / Renew (obtener IP por DHCP)"
    echo "  4) Verificar que DHCP asigno DNS"
    echo "  5) Probar resolucion DNS"
    echo "  6) Prueba completa (DHCP + DNS + evidencias)"
    echo "  7) Instalar herramientas"
    echo "  0) Salir"
    echo ""
    read -rp "  Opcion: " opc

    case $opc in

# =========================================================
# 1) VERIFICAR ESTADO
# =========================================================
    1)
        clear
        echo ""
        echo "  -- ESTADO DE RED --"
        echo ""

        echo "  Interfaz $INTERFAZ:"
        if ip link show "$INTERFAZ" &>/dev/null; then
            EST=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
            IP_FULL=$(ip -4 addr show "$INTERFAZ" | grep inet | awk '{print $2}' | head -1)
            msg_ok "$EST | $IP_FULL"

            if [[ -n "$CON" ]]; then
                if [[ "$METODO" == "auto" ]]; then
                    msg_ok "Metodo: DHCP (auto)"
                elif [[ "$METODO" == "manual" ]]; then
                    msg_warn "Metodo: Estatico (manual)"
                fi
            fi
        else
            msg_err "interfaz no encontrada"
        fi

        echo ""
        echo "  Gateway:"
        [[ -n "$GW" ]] && msg_ok "$GW" || msg_warn "sin gateway"

        echo ""
        echo "  DNS asignado:"
        DNS_ALL=$(nmcli -g IP4.DNS device show "$INTERFAZ" 2>/dev/null)
        if [[ -n "$DNS_ALL" ]]; then
            echo "$DNS_ALL" | while IFS='|' read -r dns; do
                [[ -n "$dns" ]] && msg_ok "  $dns"
            done
        else
            msg_warn "sin DNS asignado"
        fi

        echo ""
        echo "  resolv.conf:"
        cat /etc/resolv.conf 2>/dev/null | sed 's/^/    /'

        echo ""
        echo "  Lease DHCP:"
        LEASE_INFO=$(journalctl -u NetworkManager --no-pager -n 50 2>/dev/null | grep -i "dhcp\|lease" | grep "$INTERFAZ" | tail -5)
        if [[ -n "$LEASE_INFO" ]]; then
            echo "$LEASE_INFO" | sed 's/^/    /'
        else
            # intentar con dhclient
            if [[ -f /var/lib/dhcp/dhclient.leases ]]; then
                echo "  Ultimo lease:"
                tail -20 /var/lib/dhcp/dhclient.leases 2>/dev/null | sed 's/^/    /'
            elif [[ -f /var/lib/dhclient/dhclient.leases ]]; then
                tail -20 /var/lib/dhclient/dhclient.leases 2>/dev/null | sed 's/^/    /'
            else
                msg_warn "sin informacion de lease"
            fi
        fi

        echo ""
        echo "  Herramientas:"
        for cmd in nslookup dig ping; do
            command -v "$cmd" &>/dev/null && msg_ok "$cmd" || msg_err "$cmd no instalado"
        done
        command -v dhclient &>/dev/null && msg_ok "dhclient (opcional)" || msg_info "dhclient no instalado (se usa nmcli)"

        pausar
        ;;

# =========================================================
# 2) CONFIGURAR INTERFAZ EN DHCP
# =========================================================
    2)
        clear
        echo ""
        echo "  -- CONFIGURAR $INTERFAZ EN MODO DHCP --"
        echo ""

        if ! ip link show "$INTERFAZ" &>/dev/null; then
            msg_err "Interfaz $INTERFAZ no existe."
            pausar
            continue
        fi

        obtener_info

        if [[ "$METODO" == "auto" ]]; then
            msg_ok "Ya esta en modo DHCP."
            pausar
            continue
        fi

        msg_info "Cambiando $INTERFAZ a modo DHCP..."

        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -z "$CON" ]]; then
            CON=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        fi
        if [[ -z "$CON" ]]; then
            msg_info "Creando conexion para $INTERFAZ..."
            nmcli connection add type ethernet ifname "$INTERFAZ" con-name "dhcp-${INTERFAZ}" 2>/dev/null
            CON="dhcp-${INTERFAZ}"
        fi

        nmcli connection modify "$CON" ipv4.method auto
        nmcli connection modify "$CON" ipv4.addresses ""
        nmcli connection modify "$CON" ipv4.gateway ""
        nmcli connection modify "$CON" ipv4.dns ""
        nmcli connection modify "$CON" ipv4.ignore-auto-dns no

        nmcli connection down "$CON" 2>/dev/null
        sleep 1
        nmcli connection up "$CON" 2>/dev/null
        sleep 5

        obtener_info

        if [[ -n "$IP_CLIENTE" ]]; then
            msg_ok "IP obtenida por DHCP: $IP_CLIENTE"
            [[ -n "$DNS_ASIGNADO" ]] && msg_ok "DNS recibido: $DNS_ASIGNADO"
            [[ -n "$GW" ]] && msg_ok "Gateway: $GW"
        else
            msg_err "No se obtuvo IP. Verifica que el servidor DHCP este activo."
        fi

        pausar
        ;;

# =========================================================
# 3) RELEASE / RENEW
# =========================================================
    3)
        clear
        echo ""
        echo "  -- RELEASE / RENEW --"
        echo ""

        obtener_info
        msg_info "Interfaz: $INTERFAZ | IP actual: ${IP_CLIENTE:-N/A} | Metodo: $METODO"

        if [[ "$METODO" != "auto" ]]; then
            msg_warn "La interfaz no esta en DHCP. Use opcion 2 primero."
            pausar
            continue
        fi

        echo ""
        echo "  1) Release (liberar IP)"
        echo "  2) Renew (renovar IP)"
        echo "  3) Release + Renew completo"
        echo "  0) Volver"
        echo ""
        read -rp "  Opcion: " sub

        case $sub in
            1)
                msg_info "Liberando IP..."
                echo ""
                echo "  IP antes: $IP_CLIENTE"
                hacer_release
                IP_NUEVA=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
                echo "  IP despues: ${IP_NUEVA:-ninguna}"
                msg_ok "Release completado."
                ;;
            2)
                msg_info "Renovando IP..."
                echo ""
                echo "  IP antes: $IP_CLIENTE"
                hacer_renew
                obtener_info
                echo "  IP despues: ${IP_CLIENTE:-sin IP}"
                [[ -n "$DNS_ASIGNADO" ]] && echo "  DNS asignado: $DNS_ASIGNADO"
                [[ -n "$GW" ]] && echo "  Gateway: $GW"
                msg_ok "Renew completado."
                ;;
            3)
                msg_info "Release..."
                echo ""
                echo "  IP antes: $IP_CLIENTE"
                hacer_release
                msg_ok "IP liberada."

                msg_info "Renew..."
                hacer_renew
                obtener_info
                echo "  IP nueva: ${IP_CLIENTE:-sin IP}"
                [[ -n "$DNS_ASIGNADO" ]] && echo "  DNS asignado: $DNS_ASIGNADO"
                [[ -n "$GW" ]] && echo "  Gateway: $GW"
                msg_ok "Release + Renew completado."
                ;;
            0) continue ;;
        esac

        pausar
        ;;

# =========================================================
# 4) VERIFICAR QUE DHCP ASIGNO DNS
# =========================================================
    4)
        clear
        echo ""
        echo "  -- VERIFICAR ASIGNACION DHCP -> DNS --"
        echo ""

        obtener_info

        msg_info "Metodo de IP: $METODO"

        if [[ "$METODO" != "auto" ]]; then
            msg_warn "No esta en DHCP. El DNS no fue asignado por servidor DHCP."
            pausar
            continue
        fi

        msg_ok "IP obtenida por DHCP: $IP_CLIENTE"

        echo ""
        echo "  DNS recibidos del servidor DHCP:"
        DNS_ALL=$(nmcli -g IP4.DNS device show "$INTERFAZ" 2>/dev/null)
        if [[ -n "$DNS_ALL" ]]; then
            echo "$DNS_ALL" | tr '|' '\n' | while read -r dns; do
                [[ -n "$dns" ]] && msg_ok "  $dns"
            done
        else
            msg_err "No se recibio DNS por DHCP."
            msg_info "Verifica que el servidor DHCP tenga configurada la opcion DNS."
            msg_info "  Linux (dnsmasq): dhcp-option=6,<IP_DNS>"
            msg_info "  Windows: Set-DhcpServerv4OptionValue -OptionId 6 -Value <IP_DNS>"
            pausar
            continue
        fi

        echo ""
        echo "  Gateway recibido:"
        [[ -n "$GW" ]] && msg_ok "  $GW" || msg_warn "  sin gateway"

        echo ""
        echo "  resolv.conf (debe tener el DNS del servidor):"
        cat /etc/resolv.conf 2>/dev/null | grep nameserver | sed 's/^/    /'

        echo ""
        echo "  Informacion del lease:"
        # buscar en logs de NM
        journalctl -u NetworkManager --no-pager -n 100 2>/dev/null | grep -i "dhcp4" | grep "$INTERFAZ" | tail -8 | sed 's/^/    /'

        pausar
        ;;

# =========================================================
# 5) PROBAR RESOLUCION DNS
# =========================================================
    5)
        clear
        echo ""
        echo "  -- PRUEBAS DE RESOLUCION DNS --"
        echo ""

        obtener_info

        # detectar servidor DNS a usar
        DNS_USE="$DNS_ASIGNADO"
        if [[ -z "$DNS_USE" ]]; then
            DNS_USE=$(grep nameserver /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')
        fi

        if [[ -z "$DNS_USE" ]]; then
            msg_warn "No hay DNS configurado."
            while true; do
                read -rp "  IP del servidor DNS: " DNS_USE
                validar_ip "$DNS_USE" && break
                msg_err "IP invalida."
            done
        fi

        read -rp "  Dominio a probar [$DOMINIO]: " DOM
        DOM="${DOM:-$DOMINIO}"

        echo ""
        msg_info "Usando DNS: $DNS_USE"
        msg_info "Dominio: $DOM"
        echo ""

        # nslookup dominio
        msg_info "nslookup $DOM @$DNS_USE"
        R1=$(nslookup "$DOM" "$DNS_USE" 2>&1)
        if echo "$R1" | grep -qE "Address:.*[0-9]+\.[0-9]+"; then
            IP_R=$(echo "$R1" | grep -A2 "Name:" | grep "Address" | awk '{print $2}' | head -1)
            [[ -z "$IP_R" ]] && IP_R=$(echo "$R1" | tail -2 | grep "Address" | awk '{print $2}')
            msg_ok "$DOM -> $IP_R"
        else
            msg_err "no resuelve"
        fi

        # nslookup www
        msg_info "nslookup www.$DOM @$DNS_USE"
        R2=$(nslookup "www.${DOM}" "$DNS_USE" 2>&1)
        if echo "$R2" | grep -qE "canonical name|Address.*[0-9]+\.[0-9]+"; then
            msg_ok "www.$DOM -> resuelve"
        else
            msg_err "no resuelve"
        fi

        # dig
        if command -v dig &>/dev/null; then
            msg_info "dig $DOM @$DNS_USE"
            D1=$(dig @"$DNS_USE" "$DOM" A +short 2>&1)
            [[ -n "$D1" ]] && msg_ok "$DOM -> $D1" || msg_err "sin resultado"
        fi

        # ping
        msg_info "ping $DOM"
        P1=$(ping -c 2 "$DOM" 2>&1)
        echo "$P1" | grep -q "bytes from" && msg_ok "responde" || msg_warn "sin respuesta ICMP"

        msg_info "ping www.$DOM"
        P2=$(ping -c 2 "www.${DOM}" 2>&1)
        echo "$P2" | grep -q "bytes from" && msg_ok "responde" || msg_warn "sin respuesta ICMP"

        pausar
        ;;

# =========================================================
# 6) PRUEBA COMPLETA (DHCP + DNS + EVIDENCIAS)
# =========================================================
    6)
        clear
        echo ""
        echo "  -- PRUEBA COMPLETA: DHCP + DNS --"
        echo "  (Flujo: Discover -> Offer -> Request -> Acknowledge -> DNS)"
        echo ""

        EVID="${EVIDENCIA_DIR}/prueba_completa_$(date +%Y%m%d_%H%M%S).txt"

        echo "=== PRUEBA COMPLETA DHCP + DNS ===" > "$EVID"
        echo "Fecha: $(date)" >> "$EVID"
        echo "Host: $(hostname)" >> "$EVID"
        echo "Interfaz: $INTERFAZ" >> "$EVID"
        echo "" >> "$EVID"

        TOTAL=0; OK=0; FAIL=0

        # --- PASO 1: Verificar interfaz ---
        echo "  Paso 1: Verificar interfaz"
        echo "--- PASO 1: Interfaz ---" >> "$EVID"
        TOTAL=$((TOTAL+1))
        if ip link show "$INTERFAZ" &>/dev/null; then
            EST=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
            msg_ok "$INTERFAZ: $EST"
            echo "Interfaz $INTERFAZ: $EST" >> "$EVID"
            OK=$((OK+1))
        else
            msg_err "$INTERFAZ no encontrada"
            echo "ERROR: $INTERFAZ no encontrada" >> "$EVID"
            FAIL=$((FAIL+1))
        fi

        # --- PASO 2: Poner en DHCP ---
        echo ""
        echo "  Paso 2: Configurar DHCP"
        echo "" >> "$EVID"
        echo "--- PASO 2: Configurar DHCP ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -z "$CON" ]]; then
            nmcli connection add type ethernet ifname "$INTERFAZ" con-name "dhcp-${INTERFAZ}" 2>/dev/null
            CON="dhcp-${INTERFAZ}"
        fi

        nmcli connection modify "$CON" ipv4.method auto 2>/dev/null
        nmcli connection modify "$CON" ipv4.addresses "" 2>/dev/null
        nmcli connection modify "$CON" ipv4.dns "" 2>/dev/null
        nmcli connection modify "$CON" ipv4.ignore-auto-dns no 2>/dev/null
        msg_ok "Interfaz configurada en DHCP"
        echo "Interfaz configurada en DHCP" >> "$EVID"
        OK=$((OK+1))

        # --- PASO 3: Release ---
        echo ""
        echo "  Paso 3: Release (liberar IP)"
        echo "" >> "$EVID"
        echo "--- PASO 3: Release ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        IP_ANTES=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
        echo "  IP antes: ${IP_ANTES:-ninguna}"
        echo "IP antes: ${IP_ANTES:-ninguna}" >> "$EVID"

        command -v dhclient &>/dev/null && dhclient -r "$INTERFAZ" &>/dev/null
        nmcli device disconnect "$INTERFAZ" 2>/dev/null
        sleep 3
        msg_ok "Release completado"
        echo "Release completado" >> "$EVID"
        OK=$((OK+1))

        # --- PASO 4: Renew (Discover -> Offer -> Request -> Ack) ---
        echo ""
        echo "  Paso 4: Renew (Discover -> Offer -> Request -> Acknowledge)"
        echo "" >> "$EVID"
        echo "--- PASO 4: Renew (DORA) ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        # intentar con nmcli (metodo principal)
        msg_info "Reconectando con nmcli..."
        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -z "$CON" ]]; then
            CON=$(nmcli -t -f NAME connection show 2>/dev/null | grep -i "dhcp\|${INTERFAZ}\|Wired\|ethernet" | head -1)
        fi
        if [[ -n "$CON" ]]; then
            nmcli connection up "$CON" 2>&1 | tee -a "$EVID"
        else
            nmcli device connect "$INTERFAZ" 2>&1 | tee -a "$EVID"
        fi
        sleep 5

        obtener_info

        if [[ -n "$IP_CLIENTE" ]]; then
            msg_ok "IP obtenida: $IP_CLIENTE"
            echo "IP obtenida: $IP_CLIENTE" >> "$EVID"
            OK=$((OK+1))
        else
            msg_err "No se obtuvo IP por DHCP"
            echo "ERROR: No se obtuvo IP" >> "$EVID"
            FAIL=$((FAIL+1))
            msg_warn "Verifica que el servidor DHCP este activo."
            echo "" >> "$EVID"
            echo "Resumen: $OK/$TOTAL" >> "$EVID"
            msg_info "Evidencia: $EVID"
            pausar
            continue
        fi

        # --- PASO 5: Verificar DNS asignado por DHCP ---
        echo ""
        echo "  Paso 5: Verificar DNS recibido por DHCP"
        echo "" >> "$EVID"
        echo "--- PASO 5: DNS de DHCP ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        DNS_ALL=$(nmcli -g IP4.DNS device show "$INTERFAZ" 2>/dev/null)
        if [[ -n "$DNS_ALL" ]]; then
            msg_ok "DNS recibido: $DNS_ALL"
            echo "DNS recibido: $DNS_ALL" >> "$EVID"
            OK=$((OK+1))
            DNS_USE=$(echo "$DNS_ALL" | tr '|' '\n' | head -1)
        else
            msg_warn "No se recibio DNS por DHCP"
            echo "AVISO: No se recibio DNS por DHCP" >> "$EVID"
            FAIL=$((FAIL+1))
            # intentar con resolv.conf
            DNS_USE=$(grep nameserver /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')
        fi

        echo ""
        echo "  Paso 5b: Gateway"
        TOTAL=$((TOTAL+1))
        obtener_info
        if [[ -n "$GW" ]]; then
            msg_ok "Gateway: $GW"
            echo "Gateway: $GW" >> "$EVID"
            OK=$((OK+1))
        else
            msg_warn "Sin gateway"
            echo "Sin gateway" >> "$EVID"
            FAIL=$((FAIL+1))
        fi

        # --- PASO 6: Ping al servidor DNS ---
        echo ""
        echo "  Paso 6: Conectividad con DNS ($DNS_USE)"
        echo "" >> "$EVID"
        echo "--- PASO 6: Ping DNS ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        if [[ -n "$DNS_USE" ]]; then
            P0=$(ping -c 3 "$DNS_USE" 2>&1)
            echo "$P0" >> "$EVID"
            if echo "$P0" | grep -q " 0% packet loss\| 0.0% packet loss"; then
                msg_ok "Servidor DNS accesible"
                echo "DNS accesible" >> "$EVID"
                OK=$((OK+1))
            else
                msg_err "No se alcanza el servidor DNS"
                echo "ERROR: DNS no accesible" >> "$EVID"
                FAIL=$((FAIL+1))
            fi
        else
            msg_err "Sin DNS para probar"
            FAIL=$((FAIL+1))
        fi

        # --- PASO 7: nslookup dominio ---
        echo ""
        echo "  Paso 7: nslookup $DOMINIO @${DNS_USE}"
        echo "" >> "$EVID"
        echo "--- PASO 7: nslookup $DOMINIO ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        if [[ -n "$DNS_USE" ]]; then
            R1=$(nslookup "$DOMINIO" "$DNS_USE" 2>&1)
            echo "$R1" >> "$EVID"
            if echo "$R1" | grep -qE "Address:.*[0-9]+\.[0-9]+"; then
                IP_R=$(echo "$R1" | grep -A2 "Name:" | grep "Address" | awk '{print $2}' | head -1)
                [[ -z "$IP_R" ]] && IP_R=$(echo "$R1" | tail -2 | grep "Address" | awk '{print $2}')
                msg_ok "$DOMINIO -> $IP_R"
                OK=$((OK+1))
            else
                msg_err "nslookup $DOMINIO: no resuelve"
                FAIL=$((FAIL+1))
            fi
        else
            msg_err "sin DNS"; FAIL=$((FAIL+1))
        fi

        # --- PASO 8: nslookup www ---
        echo ""
        echo "  Paso 8: nslookup www.$DOMINIO @${DNS_USE}"
        echo "" >> "$EVID"
        echo "--- PASO 8: nslookup www.$DOMINIO ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        if [[ -n "$DNS_USE" ]]; then
            R2=$(nslookup "www.${DOMINIO}" "$DNS_USE" 2>&1)
            echo "$R2" >> "$EVID"
            if echo "$R2" | grep -qE "canonical name|Address.*[0-9]+\.[0-9]+"; then
                msg_ok "www.$DOMINIO -> resuelve"
                OK=$((OK+1))
            else
                msg_err "www.$DOMINIO: no resuelve"
                FAIL=$((FAIL+1))
            fi
        else
            msg_err "sin DNS"; FAIL=$((FAIL+1))
        fi

        # --- PASO 9: dig ---
        echo ""
        echo "  Paso 9: dig $DOMINIO @${DNS_USE}"
        echo "" >> "$EVID"
        echo "--- PASO 9: dig ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        if command -v dig &>/dev/null && [[ -n "$DNS_USE" ]]; then
            D1=$(dig @"$DNS_USE" "$DOMINIO" A +short 2>&1)
            D1_FULL=$(dig @"$DNS_USE" "$DOMINIO" A 2>&1)
            echo "$D1_FULL" >> "$EVID"
            if [[ -n "$D1" ]]; then
                msg_ok "dig $DOMINIO -> $D1"
                OK=$((OK+1))
            else
                msg_err "dig: sin resultado"
                FAIL=$((FAIL+1))
            fi
        else
            msg_warn "dig no disponible o sin DNS"
            FAIL=$((FAIL+1))
        fi

        # --- PASO 10: ping dominio ---
        echo ""
        echo "  Paso 10: ping $DOMINIO"
        echo "" >> "$EVID"
        echo "--- PASO 10: ping $DOMINIO ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        P1=$(ping -c 2 "$DOMINIO" 2>&1)
        echo "$P1" >> "$EVID"
        if echo "$P1" | grep -q "bytes from"; then
            msg_ok "ping $DOMINIO: responde"
            OK=$((OK+1))
        else
            msg_warn "ping $DOMINIO: sin respuesta ICMP"
            FAIL=$((FAIL+1))
        fi

        # --- PASO 11: ping www ---
        echo ""
        echo "  Paso 11: ping www.$DOMINIO"
        echo "" >> "$EVID"
        echo "--- PASO 11: ping www.$DOMINIO ---" >> "$EVID"
        TOTAL=$((TOTAL+1))

        P2=$(ping -c 2 "www.${DOMINIO}" 2>&1)
        echo "$P2" >> "$EVID"
        if echo "$P2" | grep -q "bytes from"; then
            msg_ok "ping www.$DOMINIO: responde"
            OK=$((OK+1))
        else
            msg_warn "ping www.$DOMINIO: sin respuesta ICMP"
            FAIL=$((FAIL+1))
        fi

        # --- RESUMEN ---
        PCT=0
        [[ $TOTAL -gt 0 ]] && PCT=$(( (OK * 100) / TOTAL ))

        echo "" >> "$EVID"
        echo "==========================================" >> "$EVID"
        echo "RESUMEN: $OK/$TOTAL exitosas ($PCT%)" >> "$EVID"
        echo "IP obtenida: $IP_CLIENTE" >> "$EVID"
        echo "DNS recibido: ${DNS_ALL:-N/A}" >> "$EVID"
        echo "Gateway: ${GW:-N/A}" >> "$EVID"
        echo "==========================================" >> "$EVID"

        echo ""
        echo "  ================================================"
        echo "  RESUMEN"
        echo "  IP obtenida (DHCP): $IP_CLIENTE"
        echo "  DNS recibido:       ${DNS_ALL:-N/A}"
        echo "  Gateway:            ${GW:-N/A}"
        echo "  Pruebas:            $OK / $TOTAL ($PCT%)"
        echo "  Fallidas:           $FAIL"
        echo "  Evidencia:          $(basename $EVID)"
        echo "  ================================================"

        pausar
        ;;

# =========================================================
# 7) INSTALAR HERRAMIENTAS
# =========================================================
    7)
        clear
        echo ""
        echo "  -- HERRAMIENTAS --"
        echo ""

        FALTA=()
        for cmd in nslookup dig host; do
            command -v "$cmd" &>/dev/null && msg_ok "$cmd" || { msg_err "$cmd"; FALTA+=("dnsutils"); }
        done
        command -v ping &>/dev/null && msg_ok "ping" || { msg_err "ping"; FALTA+=("iputils-ping"); }
        command -v dhclient &>/dev/null && msg_ok "dhclient (opcional)" || msg_info "dhclient no instalado (se usa nmcli, no es necesario)"

        FALTA=($(echo "${FALTA[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

        if [[ ${#FALTA[@]} -gt 0 ]]; then
            echo ""
            msg_info "Faltantes: ${FALTA[*]}"
            read -rp "  Instalar? (s/n) [s]: " resp
            resp="${resp:-s}"
            if [[ "$resp" =~ ^[sS]$ ]]; then
                apt-get update -qq
                apt-get install -y "${FALTA[@]}" 2>&1 | tee -a "$LOG"
                echo ""
                msg_ok "Listo."
            fi
        else
            msg_ok "Todo instalado."
        fi

        pausar
        ;;

    0)
        echo ""
        echo "  Saliendo..."
        exit 0
        ;;

    *)
        msg_err "Opcion invalida."
        sleep 1
        ;;
    esac
done