#!/bin/bash
# lib/dhcp_functions.sh
# Depende de: common_functions.sh

INTERFAZ_DHCP="ens224"
LEASE_FILE="/var/lib/dnsmasq/dnsmasq.leases"

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
dhcp_verificar() {
    echo ""
    echo "=== Verificando instalacion ==="
    if rpm -q dnsmasq &>/dev/null; then
        msg_ok "dnsmasq instalado: $(rpm -q dnsmasq)"
    else
        msg_warn "dnsmasq NO esta instalado"
    fi
    echo ""
    if systemctl is-active dnsmasq &>/dev/null; then
        msg_ok "Servicio: ACTIVO"
    else
        msg_warn "Servicio: INACTIVO"
    fi
    echo ""
    if [ -f /etc/dnsmasq.conf ]; then
        msg_ok "Configuracion actual:"
        grep -v "^#" /etc/dnsmasq.conf | grep -v "^$"
    else
        msg_warn "Sin archivo de configuracion"
    fi
    pausar
}

# ─────────────────────────────────────────
# MONITOR
# ─────────────────────────────────────────
dhcp_monitor() {
    while true; do
        clear
        echo "=== MONITOR DHCP SERVER ==="
        echo ""
        echo "Estado del servicio:"
        systemctl status dnsmasq --no-pager | head -n 8
        echo ""
        echo "Concesiones activas:"
        if [ -f "$LEASE_FILE" ] && [ -s "$LEASE_FILE" ]; then
            cat "$LEASE_FILE"
            echo "Total: $(wc -l < "$LEASE_FILE")"
        else
            echo "No hay concesiones activas"
        fi
        echo ""
        echo "Configuracion:"
        grep -v "^#" /etc/dnsmasq.conf 2>/dev/null | grep -v "^$"
        echo ""
        echo "Ultimos logs:"
        journalctl -u dnsmasq -n 10 --no-pager 2>/dev/null || tail -n 10 /var/log/messages 2>/dev/null | grep dnsmasq || echo "Sin logs"
        echo ""
        echo "r) Refrescar    0) Volver"
        read -rp "> " opt
        [ "$opt" = "0" ] && return
    done
}

# ─────────────────────────────────────────
# INSTALAR
# ─────────────────────────────────────────
dhcp_instalar() {
    echo ""
    echo "=== Instalacion DHCP Server ==="

    if rpm -q dnsmasq &>/dev/null && systemctl is-active dnsmasq &>/dev/null; then
        msg_warn "dnsmasq ya esta instalado y activo."
        read -rp "  ¿Reinstalar? (s/n): " r
        [[ ! "$r" =~ ^[sS]$ ]] && return
    fi

    if ! rpm -q dnsmasq &>/dev/null; then
        echo "Instalando dnsmasq..."
        dnf install -y dnsmasq
    fi

    local SERVER_IP
    SERVER_IP=$(ip -4 addr show $INTERFAZ_DHCP 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)192\.168\.\d+\.\d+' | head -1)

    if [ -z "$SERVER_IP" ]; then
        msg_warn "No se detecto IP fija."
        SERVER_IP=$(pedir_ip "IP fija del servidor" "192.168.100.20")
    else
        echo "  IP detectada: $SERVER_IP"
    fi

    read -rp "  Prefijo de subred [24]: " PREFIX; PREFIX=${PREFIX:-24}
    local MASK; MASK=$(calcular_mascara "$PREFIX")
    echo "  Mascara: $MASK"

    local START; START=$(pedir_ip "Rango inicial" "192.168.100.50")

    local END
    while true; do
        END=$(pedir_ip "Rango final" "192.168.100.150")
        [ "$(ip_to_int "$END")" -le "$(ip_to_int "$START")" ] \
            && echo "  Error: el final debe ser mayor que el inicial ($START)" \
            || break
    done

    IFS='.' read -r a b c d <<< "$START"
    local SERVER_STATIC="$a.$b.$c.$d"
    local START_REAL="$a.$b.$c.$((d + 1))"
    echo "  IP fija del servidor: $SERVER_STATIC"
    echo "  Rango DHCP real:      $START_REAL - $END"

    echo "  Configurando IP fija en $INTERFAZ_DHCP..."
    nmcli connection modify $INTERFAZ_DHCP ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null || \
    nmcli connection add type ethernet con-name $INTERFAZ_DHCP ifname $INTERFAZ_DHCP ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null
    nmcli connection up $INTERFAZ_DHCP &>/dev/null
    msg_ok "IP $SERVER_STATIC/$PREFIX asignada"

    read -rp "  Gateway (Enter para omitir): " GW
    if [ -n "$GW" ]; then
        while ! validar_ip "$GW" 2>/dev/null; do
            read -rp "  Gateway invalido. Intenta de nuevo (Enter para omitir): " GW
            [ -z "$GW" ] && break
        done
    fi

    local DNS_OPTS=""
    read -rp "  ¿Configurar DNS primario? (s/n) [n]: " conf_dns1
    if [[ "$conf_dns1" =~ ^[sS]$ ]]; then
        local DNS1; DNS1=$(pedir_ip "DNS primario" "192.168.100.1")
        read -rp "  ¿DNS alternativo? (s/n) [n]: " conf_dns2
        if [[ "$conf_dns2" =~ ^[sS]$ ]]; then
            local DNS2; DNS2=$(pedir_ip "DNS alternativo" "8.8.8.8")
            DNS_OPTS="dhcp-option=6,$DNS1,$DNS2"
        else
            DNS_OPTS="dhcp-option=6,$DNS1"
        fi
    fi

    mkdir -p /var/lib/dnsmasq
    touch /var/lib/dnsmasq/dnsmasq.leases
    chown dnsmasq:dnsmasq /var/lib/dnsmasq /var/lib/dnsmasq/dnsmasq.leases
    chmod 755 /var/lib/dnsmasq; chmod 664 /var/lib/dnsmasq/dnsmasq.leases

    cat > /etc/dnsmasq.conf <<EOF
interface=$INTERFAZ_DHCP
dhcp-range=$START_REAL,$END,$MASK,12h
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
EOF
    [ -n "$GW" ]       && echo "dhcp-option=3,$GW"  >> /etc/dnsmasq.conf
    [ -n "$DNS_OPTS" ] && echo "$DNS_OPTS"           >> /etc/dnsmasq.conf

    firewall-cmd --permanent --add-service=dhcp &>/dev/null
    firewall-cmd --permanent --add-service=dns  &>/dev/null
    firewall-cmd --reload &>/dev/null

    if command -v getenforce &>/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
        setenforce 0
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        msg_ok "SELinux en permissive"
    fi

    systemctl enable --now dnsmasq
    systemctl restart dnsmasq

    echo ""
    echo "=== INSTALACION COMPLETADA ==="
    echo "  Rango:   $START_REAL - $END"
    echo "  Mascara: $MASK"
    [ -n "$GW" ]       && echo "  Gateway: $GW"
    [ -n "$DNS_OPTS" ] && echo "  DNS:     $DNS_OPTS"
    pausar
}

# ─────────────────────────────────────────
# MODIFICAR CONFIGURACION
# ─────────────────────────────────────────
dhcp_modificar() {
    echo ""
    echo "=== Modificar configuracion DHCP ==="

    if [ ! -f /etc/dnsmasq.conf ]; then
        msg_err "No hay configuracion. Instala primero."
        pausar; return
    fi

    echo "  Configuracion actual:"
    grep -v "^#" /etc/dnsmasq.conf | grep -v "^$"
    echo ""

    read -rp "  Prefijo de subred [24]: " PREFIX; PREFIX=${PREFIX:-24}
    local MASK; MASK=$(calcular_mascara "$PREFIX")
    echo "  Mascara: $MASK"

    local START; START=$(pedir_ip "Rango inicial" "192.168.100.50")

    local END
    while true; do
        END=$(pedir_ip "Rango final" "192.168.100.150")
        [ "$(ip_to_int "$END")" -le "$(ip_to_int "$START")" ] \
            && echo "  Error: el final debe ser mayor que el inicial" \
            || break
    done

    IFS='.' read -r a b c d <<< "$START"
    local SERVER_STATIC="$a.$b.$c.$d"
    local START_REAL="$a.$b.$c.$((d + 1))"
    echo "  IP fija: $SERVER_STATIC  |  Rango DHCP: $START_REAL - $END"

    nmcli connection modify $INTERFAZ_DHCP ipv4.addresses "$SERVER_STATIC/$PREFIX" ipv4.method manual 2>/dev/null
    nmcli connection up $INTERFAZ_DHCP &>/dev/null
    msg_ok "IP $SERVER_STATIC/$PREFIX asignada"

    read -rp "  Gateway (Enter para omitir): " GW
    if [ -n "$GW" ]; then
        while ! validar_ip "$GW" 2>/dev/null; do
            read -rp "  Gateway invalido (Enter para omitir): " GW
            [ -z "$GW" ] && break
        done
    fi

    local DNS_OPTS=""
    read -rp "  ¿Configurar DNS primario? (s/n) [n]: " conf_dns1
    if [[ "$conf_dns1" =~ ^[sS]$ ]]; then
        local DNS1; DNS1=$(pedir_ip "DNS primario" "192.168.100.1")
        read -rp "  ¿DNS alternativo? (s/n) [n]: " conf_dns2
        if [[ "$conf_dns2" =~ ^[sS]$ ]]; then
            local DNS2; DNS2=$(pedir_ip "DNS alternativo" "8.8.8.8")
            DNS_OPTS="dhcp-option=6,$DNS1,$DNS2"
        else
            DNS_OPTS="dhcp-option=6,$DNS1"
        fi
    fi

    cat > /etc/dnsmasq.conf <<EOF
interface=$INTERFAZ_DHCP
dhcp-range=$START_REAL,$END,$MASK,12h
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
EOF
    [ -n "$GW" ]       && echo "dhcp-option=3,$GW" >> /etc/dnsmasq.conf
    [ -n "$DNS_OPTS" ] && echo "$DNS_OPTS"          >> /etc/dnsmasq.conf

    systemctl restart dnsmasq

    echo ""
    echo "=== CONFIGURACION ACTUALIZADA ==="
    echo "  Rango:   $START_REAL - $END"
    echo "  Mascara: $MASK"
    [ -n "$GW" ]       && echo "  Gateway: $GW"
    [ -n "$DNS_OPTS" ] && echo "  DNS:     $DNS_OPTS"
    pausar
}

# ─────────────────────────────────────────
# REINICIAR
# ─────────────────────────────────────────
dhcp_reiniciar() {
    echo ""
    echo "Reiniciando dnsmasq..."
    systemctl restart dnsmasq
    systemctl status dnsmasq --no-pager | head -5
    pausar
}