#!/bin/bash
# lib/dns_functions.sh
# Depende de: common_functions.sh

DOMINIO_BASE="reprobados.com"
INTERFAZ_DNS="ens224"
NAMED_CONF="/etc/named.conf"
ZONA_DIR="/var/named"
EVIDENCIA_DIR="/root/evidencias_dns"

obtener_ip_dns() {
    IP_SERVIDOR=$(ip -4 addr show "$INTERFAZ_DNS" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
}

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
dns_verificar() {
    clear; echo ""
    echo "=== Verificando instalacion ==="
    echo ""
    echo "  Paquetes:"
    for pkg in bind bind-utils; do
        rpm -q "$pkg" &>/dev/null \
            && msg_ok "$pkg: $(rpm -q $pkg)" \
            || msg_err "$pkg: no instalado"
    done

    echo ""
    echo "  Servicio named:"
    if systemctl is-active --quiet named; then
        msg_ok "activo"
        systemctl status named --no-pager -l 2>/dev/null | head -6 | sed 's/^/    /'
    else
        msg_warn "inactivo"
    fi

    echo ""
    echo "  Interfaz $INTERFAZ_DNS:"
    if ip link show "$INTERFAZ_DNS" &>/dev/null; then
        local EST IP_A
        EST=$(ip link show "$INTERFAZ_DNS" | grep -o "state [A-Z]*" | awk '{print $2}')
        IP_A=$(ip -4 addr show "$INTERFAZ_DNS" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        msg_ok "$EST | $IP_A"
    else
        msg_err "no encontrada"
    fi

    echo ""
    echo "  Zonas configuradas:"
    if [ -f "$NAMED_CONF" ]; then
        local ZONAS
        ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr" | awk -F'"' '{print $2}')
        [ -n "$ZONAS" ] && while IFS= read -r z; do echo "    - $z"; done <<< "$ZONAS" || msg_warn "ninguna"
    fi
    pausar
}

# ─────────────────────────────────────────
# INSTALAR BIND
# ─────────────────────────────────────────
dns_instalar() {
    clear; echo ""
    echo "=== Instalacion DNS (BIND) ==="
    echo ""

    if rpm -q bind bind-utils &>/dev/null; then
        msg_ok "BIND ya instalado, no hay nada que hacer."
        systemctl is-active --quiet named && msg_ok "Servicio named activo."
        pausar; return
    fi

    msg_info "Instalando bind y bind-utils..."
    dnf install -y bind bind-utils 2>&1

    if [ $? -eq 0 ]; then
        msg_ok "Paquetes instalados."
        systemctl enable named 2>&1
        msg_ok "Servicio habilitado al inicio."
        msg_info "Use la opcion Configurar para crear la zona."
    else
        msg_err "Fallo en la instalacion."
    fi
    pausar
}

# ─────────────────────────────────────────
# CONFIGURAR IP ESTATICA (interna)
# ─────────────────────────────────────────
_dns_configurar_ip() {
    msg_info "Verificando IP en $INTERFAZ_DNS..."

    ip link show "$INTERFAZ_DNS" &>/dev/null || { msg_err "Interfaz $INTERFAZ_DNS no existe."; return 1; }

    local EST CON MET
    EST=$(ip link show "$INTERFAZ_DNS" | grep -o "state [A-Z]*" | awk '{print $2}')
    [[ "$EST" != "UP" ]] && nmcli device connect "$INTERFAZ_DNS" 2>/dev/null && sleep 2

    CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ_DNS}$" | cut -d: -f1)
    [ -z "$CON" ] && nmcli connection add type ethernet ifname "$INTERFAZ_DNS" con-name "red-interna-${INTERFAZ_DNS}" 2>/dev/null && CON="red-interna-${INTERFAZ_DNS}"

    MET=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
    if [[ "$MET" == "manual" ]]; then
        IP_SERVIDOR=$(nmcli -g ipv4.addresses connection show "$CON" | head -1 | cut -d/ -f1)
        msg_ok "IP estatica: $IP_SERVIDOR"
        return 0
    fi

    msg_warn "En DHCP, se necesita IP fija."
    local IP_ACT PREF GW IN_IP IN_PREF IN_GW IN_DNS
    IP_ACT=$(ip -4 addr show "$INTERFAZ_DNS" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    echo ""
    while true; do
        read -rp "  IP del servidor [$IP_ACT]: " IN_IP; IN_IP="${IN_IP:-$IP_ACT}"
        validar_ip "$IN_IP" && break; msg_err "IP invalida."
    done
    PREF=$(ip -4 addr show "$INTERFAZ_DNS" 2>/dev/null | grep inet | awk '{print $2}' | head -1 | cut -d/ -f2); PREF="${PREF:-24}"
    read -rp "  Prefijo CIDR [$PREF]: " IN_PREF; IN_PREF="${IN_PREF:-$PREF}"
    GW=$(ip route | grep default | awk '{print $3}' | head -1)
    while true; do
        read -rp "  Gateway [$GW]: " IN_GW; IN_GW="${IN_GW:-$GW}"
        validar_ip "$IN_GW" && break; msg_err "IP invalida."
    done
    read -rp "  DNS de respaldo [8.8.8.8]: " IN_DNS; IN_DNS="${IN_DNS:-8.8.8.8}"

    nmcli connection modify "$CON" ipv4.addresses "${IN_IP}/${IN_PREF}"
    nmcli connection modify "$CON" ipv4.gateway "$IN_GW"
    nmcli connection modify "$CON" ipv4.dns "127.0.0.1 ${IN_DNS}"
    nmcli connection modify "$CON" ipv4.method manual
    nmcli connection down "$CON" 2>/dev/null && nmcli connection up "$CON" 2>/dev/null
    sleep 3
    IP_SERVIDOR="$IN_IP"
    msg_ok "IP configurada: $IP_SERVIDOR/$IN_PREF"
    return 0
}

_dns_crear_zona() {
    local dominio=$1 ip_cliente=$2
    local SERIAL; SERIAL=$(date +%Y%m%d%H)
    obtener_ip_dns

    cat > "${ZONA_DIR}/db.${dominio}" <<EOF
; Zona: ${dominio}
\$TTL    86400
@       IN      SOA     ns1.${dominio}. admin.${dominio}. (
                        ${SERIAL}   ; Serial
                        3600        ; Refresh
                        1800        ; Retry
                        604800      ; Expire
                        86400 )     ; Minimum TTL

@       IN      NS      ns1.${dominio}.
ns1     IN      A       ${IP_SERVIDOR}
@       IN      A       ${ip_cliente}
www     IN      CNAME   ${dominio}.
EOF
    chown named:named "${ZONA_DIR}/db.${dominio}"
    chmod 640 "${ZONA_DIR}/db.${dominio}"
}

# ─────────────────────────────────────────
# CONFIGURAR ZONA BASE
# ─────────────────────────────────────────
dns_configurar() {
    clear; echo ""
    echo "=== Configuracion inicial DNS ==="
    echo ""

    rpm -q bind &>/dev/null || { msg_err "BIND no instalado. Use la opcion Instalar."; pausar; return; }

    _dns_configurar_ip || { pausar; return; }

    echo ""
    msg_info "Los registros A apuntaran a la IP del cliente."
    local IP_CLIENTE
    while true; do
        read -rp "  IP de la maquina cliente: " IP_CLIENTE
        validar_ip "$IP_CLIENTE" && break; msg_err "IP invalida."
    done

    echo ""
    msg_info "Configurando named.conf..."
    cp "$NAMED_CONF" "${NAMED_CONF}.bak.$(date +%s)" 2>/dev/null

    sed -i 's/listen-on port 53 {.*};/listen-on port 53 { any; };/'       "$NAMED_CONF"
    sed -i 's/listen-on-v6 port 53 {.*};/listen-on-v6 port 53 { none; };/' "$NAMED_CONF"
    sed -i 's/allow-query {.*};/allow-query { any; };/'                    "$NAMED_CONF"

    if grep -q "zone \"${DOMINIO_BASE}\"" "$NAMED_CONF" 2>/dev/null; then
        msg_warn "Zona existente, se reemplazara."
        sed -i "/\/\/ Zona: ${DOMINIO_BASE}/d" "$NAMED_CONF"
        sed -i "/zone \"${DOMINIO_BASE}\"/,/^};/d" "$NAMED_CONF"
    fi

    cat >> "$NAMED_CONF" <<EOF

// Zona: ${DOMINIO_BASE}
zone "${DOMINIO_BASE}" IN {
    type master;
    file "${ZONA_DIR}/db.${DOMINIO_BASE}";
    allow-update { none; };
};
EOF
    msg_ok "Zona agregada a named.conf"

    _dns_crear_zona "$DOMINIO_BASE" "$IP_CLIENTE"
    msg_ok "Archivo de zona creado"

    command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]] && \
        restorecon -Rv /var/named/ &>/dev/null && setsebool -P named_write_master_zones 1 2>/dev/null && msg_ok "SELinux ajustado"

    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=dns &>/dev/null
        firewall-cmd --permanent --add-port=53/tcp &>/dev/null
        firewall-cmd --permanent --add-port=53/udp &>/dev/null
        firewall-cmd --reload &>/dev/null
        msg_ok "Firewall configurado"
    fi

    named-checkconf "$NAMED_CONF" 2>&1
    [ $? -eq 0 ] && msg_ok "named-checkconf: OK" || { msg_err "Error en named.conf"; pausar; return; }

    named-checkzone "$DOMINIO_BASE" "${ZONA_DIR}/db.${DOMINIO_BASE}" 2>&1
    [ $? -eq 0 ] && msg_ok "named-checkzone: OK" || { msg_err "Error en zona"; pausar; return; }

    systemctl restart named 2>&1; sleep 2
    systemctl is-active --quiet named && msg_ok "Servicio named activo" || msg_err "No pudo iniciar"

    echo ""
    echo "  Resumen:"
    echo "    $DOMINIO_BASE      -> A     $IP_CLIENTE"
    echo "    www.$DOMINIO_BASE  -> CNAME $DOMINIO_BASE"
    echo "    ns1.$DOMINIO_BASE  -> A     $IP_SERVIDOR"
    pausar
}

# ─────────────────────────────────────────
# RECONFIGURAR
# ─────────────────────────────────────────
dns_reconfigurar() {
    clear; echo ""
    echo "=== Reconfigurar DNS ==="
    echo ""
    echo "  1) Cambiar IP estatica de $INTERFAZ_DNS"
    echo "  2) Cambiar IP cliente en zona $DOMINIO_BASE"
    echo "  3) Reiniciar servicio named"
    echo "  0) Volver"
    echo ""
    read -rp "  Opcion: " sub

    case $sub in
        1)
            _dns_configurar_ip
            systemctl is-active --quiet named && systemctl restart named && msg_ok "named reiniciado"
            ;;
        2)
            obtener_ip_dns
            [ -z "$IP_SERVIDOR" ] && { msg_err "Sin IP en $INTERFAZ_DNS"; pausar; return; }
            local IP_CLIENTE
            while true; do
                read -rp "  Nueva IP del cliente: " IP_CLIENTE
                validar_ip "$IP_CLIENTE" && break; msg_err "IP invalida."
            done
            _dns_crear_zona "$DOMINIO_BASE" "$IP_CLIENTE"
            named-checkzone "$DOMINIO_BASE" "${ZONA_DIR}/db.${DOMINIO_BASE}" 2>&1
            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
            msg_ok "Zona actualizada."
            ;;
        3)
            systemctl restart named 2>&1; sleep 2
            systemctl is-active --quiet named && msg_ok "named activo" || msg_err "no pudo iniciar"
            ;;
    esac
    pausar
}

# ─────────────────────────────────────────
# ADMINISTRAR DOMINIOS (ABC)
# ─────────────────────────────────────────
dns_administrar() {
    while true; do
        clear; echo ""
        echo "=== Administracion de dominios ==="
        echo ""
        echo "  1) Consultar  (listar zonas y registros)"
        echo "  2) Agregar    (nueva zona)"
        echo "  3) Configurar (editar registros)"
        echo "  4) Eliminar   (quitar zona)"
        echo "  0) Volver"
        echo ""
        read -rp "  Opcion: " sub5

        case $sub5 in
        1)
            clear; echo ""
            echo "=== Zonas configuradas ==="
            echo ""
            local ZONAS
            ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr" | awk -F'"' '{print $2}')
            [ -z "$ZONAS" ] && { msg_warn "No hay zonas personalizadas."; pausar; continue; }
            local n=1
            while IFS= read -r z; do
                local ZF="${ZONA_DIR}/db.${z}"
                echo "  [$n] $z"
                if [ -f "$ZF" ]; then
                    local RA RC
                    RA=$(grep -E "IN\s+A\s+" "$ZF" | grep -v "^\s*;")
                    RC=$(grep -E "IN\s+CNAME\s+" "$ZF" | grep -v "^\s*;")
                    [ -n "$RA" ] && echo "      A:" && while IFS= read -r r; do
                        local NM IP_R
                        NM=$(echo "$r" | awk '{print $1}'); IP_R=$(echo "$r" | awk '{print $NF}')
                        [ "$NM" = "@" ] && echo "        $z -> $IP_R" || echo "        $NM.$z -> $IP_R"
                    done <<< "$RA"
                    [ -n "$RC" ] && echo "      CNAME:" && while IFS= read -r r; do
                        echo "        $(echo "$r" | awk '{print $1}').$z -> $(echo "$r" | awk '{print $NF}')"
                    done <<< "$RC"
                else
                    msg_warn "      archivo no encontrado"
                fi
                echo ""; n=$((n+1))
            done <<< "$ZONAS"
            pausar
            ;;
        2)
            clear; echo ""
            echo "=== Agregar dominio ==="
            echo ""
            obtener_ip_dns
            [ -z "$IP_SERVIDOR" ] && { msg_err "Sin IP en $INTERFAZ_DNS"; pausar; continue; }
            local ND IP_D
            read -rp "  Nombre del dominio (ej: ejemplo.com): " ND
            [[ -z "$ND" || ! "$ND" =~ \. ]] && { msg_err "Nombre invalido."; pausar; continue; }
            grep -q "zone \"${ND}\"" "$NAMED_CONF" 2>/dev/null && { msg_err "Ya existe '$ND'."; pausar; continue; }
            while true; do
                read -rp "  IP destino para $ND: " IP_D
                validar_ip "$IP_D" && break; msg_err "IP invalida."
            done
            cat >> "$NAMED_CONF" <<EOF

// Zona: ${ND}
zone "${ND}" IN {
    type master;
    file "${ZONA_DIR}/db.${ND}";
    allow-update { none; };
};
EOF
            _dns_crear_zona "$ND" "$IP_D"
            named-checkconf "$NAMED_CONF" 2>&1; [ $? -ne 0 ] && { msg_err "Error en named.conf"; pausar; continue; }
            named-checkzone "$ND" "${ZONA_DIR}/db.${ND}" 2>&1; [ $? -ne 0 ] && { msg_err "Error en zona"; pausar; continue; }
            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null; sleep 1
            msg_ok "Dominio $ND agregado."
            echo "    $ND      -> A     $IP_D"
            echo "    www.$ND  -> CNAME $ND"
            echo "    ns1.$ND  -> A     $IP_SERVIDOR"
            pausar
            ;;
        3)
            clear; echo ""
            echo "=== Configurar registros ==="
            echo ""
            local ZONAS
            ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr" | awk -F'"' '{print $2}')
            [ -z "$ZONAS" ] && { msg_warn "No hay zonas."; pausar; continue; }
            local n=1; declare -A ZM
            while IFS= read -r z; do echo "  $n) $z"; ZM[$n]="$z"; n=$((n+1)); done <<< "$ZONAS"
            echo ""; read -rp "  Seleccione zona: " sel
            local ZS="${ZM[$sel]}"
            [ -z "$ZS" ] && { msg_err "Seleccion invalida."; unset ZM; pausar; continue; }
            local ZF="${ZONA_DIR}/db.${ZS}"
            [ ! -f "$ZF" ] && { msg_err "Archivo no encontrado: $ZF"; unset ZM; pausar; continue; }

            while true; do
                clear; echo ""
                echo "  -- Editando: $ZS --"
                echo ""
                echo "  Registros actuales:"
                grep -E "IN\s+(A|CNAME)\s+" "$ZF" | grep -v "^\s*;" | sed 's/^/    /'
                echo ""
                echo "  1) Agregar registro A"
                echo "  2) Agregar registro CNAME"
                echo "  3) Eliminar registro"
                echo "  4) Cambiar IP raiz (@)"
                echo "  0) Volver"
                echo ""
                read -rp "  Opcion: " ac
                case $ac in
                    1)
                        read -rp "  Subdominio (ej: ftp, mail): " SD
                        [ -z "$SD" ] && { msg_err "Vacio."; sleep 1; continue; }
                        grep -qE "^${SD}\s+IN\s+A\s+" "$ZF" && sed -i "/^${SD}\s\+IN\s\+A\s/d" "$ZF"
                        local IP_S
                        while true; do
                            read -rp "  IP para ${SD}.${ZS}: " IP_S
                            validar_ip "$IP_S" && break; msg_err "IP invalida."
                        done
                        echo "${SD}     IN      A       ${IP_S}" >> "$ZF"
                        local SER; SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                        [ -n "$SER" ] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"
                        named-checkzone "$ZS" "$ZF" 2>&1
                        systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                        msg_ok "A: ${SD}.${ZS} -> $IP_S"; sleep 2
                        ;;
                    2)
                        read -rp "  Nombre del alias: " AN; [ -z "$AN" ] && { msg_err "Vacio."; sleep 1; continue; }
                        read -rp "  Apunta a: " AT; [ -z "$AT" ] && { msg_err "Vacio."; sleep 1; continue; }
                        [[ ! "$AT" =~ \.$ ]] && AT="${AT}."
                        grep -qE "^${AN}\s+IN\s+CNAME\s+" "$ZF" && sed -i "/^${AN}\s\+IN\s\+CNAME\s/d" "$ZF"
                        echo "${AN}     IN      CNAME   ${AT}" >> "$ZF"
                        local SER; SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                        [ -n "$SER" ] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"
                        systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                        msg_ok "CNAME: ${AN}.${ZS} -> $AT"; sleep 2
                        ;;
                    3)
                        echo ""; grep -E "IN\s+(A|CNAME)\s+" "$ZF" | grep -v "^\s*;" | awk '{print $1}' | sort -u | sed 's/^/    /'
                        echo ""; read -rp "  Nombre a eliminar: " RD; [ -z "$RD" ] && { msg_err "Vacio."; sleep 1; continue; }
                        if grep -qE "^${RD}\s+IN\s+" "$ZF"; then
                            sed -i "/^${RD}\s\+IN\s/d" "$ZF"
                            local SER; SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                            [ -n "$SER" ] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"
                            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                            msg_ok "Registro '$RD' eliminado."
                        else
                            msg_err "No se encontro '$RD'."
                        fi; sleep 2
                        ;;
                    4)
                        local NI
                        while true; do
                            read -rp "  Nueva IP para $ZS (@): " NI
                            validar_ip "$NI" && break; msg_err "IP invalida."
                        done
                        sed -i "/^@\s\+IN\s\+A\s/c\\@       IN      A       ${NI}" "$ZF"
                        local SER; SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                        [ -n "$SER" ] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"
                        systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                        msg_ok "IP raiz actualizada a $NI"; sleep 2
                        ;;
                    0) break ;;
                esac
            done
            unset ZM
            ;;
        4)
            clear; echo ""
            echo "=== Eliminar dominio ==="
            echo ""
            local ZONAS
            ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr" | awk -F'"' '{print $2}')
            [ -z "$ZONAS" ] && { msg_warn "No hay zonas."; pausar; continue; }
            local n=1; declare -A ZM
            while IFS= read -r z; do echo "  $n) $z"; ZM[$n]="$z"; n=$((n+1)); done <<< "$ZONAS"
            echo ""; read -rp "  Zona a eliminar: " sel
            local ZD="${ZM[$sel]}"
            [ -z "$ZD" ] && { msg_err "Seleccion invalida."; unset ZM; pausar; continue; }
            echo ""
            echo -e "  ${R}Seguro de eliminar '$ZD'?${N}"
            read -rp "  Escriba SI para confirmar: " CONF
            if [ "$CONF" != "SI" ]; then msg_info "Cancelado."; unset ZM; pausar; continue; fi
            sed -i "/\/\/ Zona: ${ZD}/d" "$NAMED_CONF"
            sed -i "/zone \"${ZD}\"/,/^};/d" "$NAMED_CONF"
            [ -f "${ZONA_DIR}/db.${ZD}" ] && rm -f "${ZONA_DIR}/db.${ZD}"
            named-checkconf "$NAMED_CONF" 2>&1
            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
            msg_ok "Zona '$ZD' eliminada."
            unset ZM; pausar
            ;;
        0) return ;;
        esac
    done
}

# ─────────────────────────────────────────
# VALIDAR Y PROBAR
# ─────────────────────────────────────────
dns_validar() {
    clear; echo ""
    echo "=== Validacion y pruebas ==="
    echo ""
    mkdir -p "$EVIDENCIA_DIR"
    local EVID="${EVIDENCIA_DIR}/validacion_$(date +%Y%m%d_%H%M%S).txt"

    echo "=== REPORTE DNS - $(date) ===" > "$EVID"
    echo "" >> "$EVID"

    echo "  Sintaxis:"
    named-checkconf "$NAMED_CONF" 2>&1 | tee -a "$EVID"
    [ ${PIPESTATUS[0]} -eq 0 ] && msg_ok "named-checkconf OK" || msg_err "Error en named.conf"

    local ZONAS
    ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr" | awk -F'"' '{print $2}')

    while IFS= read -r z; do
        [ -z "$z" ] && continue
        local ZF="${ZONA_DIR}/db.${z}"
        [ -f "$ZF" ] && { named-checkzone "$z" "$ZF" 2>&1 | tee -a "$EVID"; msg_ok "checkzone $z: OK"; }
    done <<< "$ZONAS"

    echo ""
    echo "  Estado del servicio:"
    systemctl status named --no-pager 2>&1 | tee -a "$EVID" | head -6 | sed 's/^/    /'

    echo ""
    echo "  Pruebas de resolucion:"
    while IFS= read -r z; do
        [ -z "$z" ] && continue
        echo ""; echo "  --- $z ---"
        local R1 IP_R
        R1=$(nslookup "$z" 127.0.0.1 2>&1); echo "$R1" >> "$EVID"
        IP_R=$(echo "$R1" | grep -A2 "Name:" | grep "Address" | awk '{print $2}' | head -1)
        [ -n "$IP_R" ] && msg_ok "nslookup $z -> $IP_R" || msg_warn "nslookup $z: sin respuesta"
        local D1
        D1=$(dig @127.0.0.1 "$z" A +short 2>&1); echo "dig $z: $D1" >> "$EVID"
        [ -n "$D1" ] && msg_ok "dig $z -> $D1" || msg_warn "dig $z: sin resultado"
    done <<< "$ZONAS"

    echo ""
    msg_ok "Evidencias: $EVID"
    pausar
}