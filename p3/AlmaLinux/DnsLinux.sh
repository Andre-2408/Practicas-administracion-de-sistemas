#!/bin/bash
# =========================================================
# Script de configuracion de servidor DNS (BIND) - AlmaLinux
# Dominio: reprobados.com | Interfaz: ens224
# =========================================================

DOMINIO_BASE="reprobados.com"
INTERFAZ="ens224"
NAMED_CONF="/etc/named.conf"
ZONA_DIR="/var/named"
EVIDENCIA_DIR="/root/evidencias_dns"
LOG="/var/log/dns_script.log"
IP_SERVIDOR=""
IP_CLIENTE=""

# -- colores basicos --
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

pausar() { echo ""; read -rp "  Presione ENTER para continuar... " _; }

validar_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a o <<< "$ip"
        for oct in "${o[@]}"; do
            (( oct < 0 || oct > 255 )) && return 1
        done
        return 0
    fi
    return 1
}

obtener_ip() {
    IP_SERVIDOR=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
}

# verificar que se ejecute como root
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
    obtener_ip

    # estado rapido
    if rpm -q bind &>/dev/null; then EST_PKG="Instalado"; else EST_PKG="No instalado"; fi
    if systemctl is-active --quiet named 2>/dev/null; then EST_SVC="Activo"; else EST_SVC="Inactivo"; fi

    echo ""
    echo -e "  ${B}SERVIDOR DNS (BIND) - AlmaLinux${N}"
    echo "  ================================================"
    echo "  BIND: $EST_PKG | Servicio: $EST_SVC | IP: ${IP_SERVIDOR:-N/A}"
    echo "  ================================================"
    echo ""
    echo "  1) Verificar instalacion"
    echo "  2) Instalar DNS"
    echo "  3) Configurar (zona $DOMINIO_BASE)"
    echo "  4) Reconfigurar"
    echo "  5) Administrar dominios (ABC)"
    echo "  6) Validar y probar resolucion"
    echo "  0) Salir"
    echo ""
    read -rp "  Opcion: " opc

    case $opc in

# =========================================================
# 1) VERIFICAR INSTALACION
# =========================================================
    1)
        clear
        echo ""
        echo "  -- VERIFICACION DE INSTALACION --"
        echo ""

        echo "  Paquetes:"
        for pkg in bind bind-utils; do
            if rpm -q "$pkg" &>/dev/null; then
                msg_ok "$pkg: $(rpm -q $pkg)"
            else
                msg_err "$pkg: no instalado"
            fi
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
        echo "  Interfaz $INTERFAZ:"
        if ip link show "$INTERFAZ" &>/dev/null; then
            EST=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
            IP_A=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
            msg_ok "$EST | $IP_A"

            CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
            if [[ -n "$CON" ]]; then
                MET=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
                [[ "$MET" == "manual" ]] && msg_ok "IP estatica" || msg_warn "DHCP (se necesita IP fija)"
            fi
        else
            msg_err "no encontrada"
        fi

        echo ""
        echo "  Zonas configuradas:"
        if [[ -f "$NAMED_CONF" ]]; then
            ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')
            if [[ -n "$ZONAS" ]]; then
                while IFS= read -r z; do echo "    - $z"; done <<< "$ZONAS"
            else
                msg_warn "ninguna zona personalizada"
            fi
        fi

        echo ""
        echo "  Firewall:"
        if systemctl is-active --quiet firewalld; then
            if firewall-cmd --list-services --permanent 2>/dev/null | grep -q "dns"; then
                msg_ok "puerto 53 permitido"
            else
                msg_warn "puerto 53 NO permitido"
            fi
        else
            msg_warn "firewalld no activo"
        fi

        pausar
        ;;

# =========================================================
# 2) INSTALAR DNS
# =========================================================
    2)
        clear
        echo ""
        echo "  -- INSTALACION DE DNS (BIND) --"
        echo ""

        # idempotencia: no reinstalar si ya esta
        if rpm -q bind bind-utils &>/dev/null; then
            msg_ok "BIND ya esta instalado, no hay nada que hacer."
            rpm -q bind bind-utils | sed 's/^/    /'
            if systemctl is-active --quiet named; then
                msg_ok "Servicio named activo."
            fi
            pausar
            continue
        fi

        msg_info "Instalando bind y bind-utils..."
        echo ""
        dnf install -y bind bind-utils 2>&1 | tee -a "$LOG"

        if [[ $? -eq 0 ]]; then
            echo ""
            msg_ok "Paquetes instalados."
            systemctl enable named 2>&1 | tee -a "$LOG"
            msg_ok "Servicio habilitado al inicio."
            echo ""
            msg_info "Ahora use la opcion 3 para configurar la zona."
        else
            echo ""
            msg_err "Fallo en la instalacion."
        fi

        pausar
        ;;

# =========================================================
# 3) CONFIGURAR (IP ESTATICA + ZONA BASE)
# =========================================================
    3)
        clear
        echo ""
        echo "  -- CONFIGURACION INICIAL --"
        echo ""

        if ! rpm -q bind &>/dev/null; then
            msg_err "BIND no esta instalado. Use la opcion 2 primero."
            pausar
            continue
        fi

        # --- IP estatica ---
        msg_info "Verificando IP en $INTERFAZ..."

        if ! ip link show "$INTERFAZ" &>/dev/null; then
            msg_err "Interfaz $INTERFAZ no existe."
            pausar
            continue
        fi

        # activar si esta abajo
        EST=$(ip link show "$INTERFAZ" | grep -o "state [A-Z]*" | awk '{print $2}')
        if [[ "$EST" != "UP" ]]; then
            msg_warn "Activando $INTERFAZ..."
            nmcli device connect "$INTERFAZ" 2>/dev/null || ip link set "$INTERFAZ" up
            sleep 2
        fi

        CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
        if [[ -z "$CON" ]]; then
            nmcli connection add type ethernet ifname "$INTERFAZ" con-name "red-interna-${INTERFAZ}" 2>/dev/null
            CON="red-interna-${INTERFAZ}"
        fi

        MET=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)

        if [[ "$MET" == "manual" ]]; then
            IP_SERVIDOR=$(nmcli -g ipv4.addresses connection show "$CON" | head -1 | cut -d/ -f1)
            msg_ok "Ya tiene IP estatica: $IP_SERVIDOR"
        else
            msg_warn "Interfaz en DHCP, se necesita IP fija."
            IP_ACT=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
            echo ""

            while true; do
                read -rp "  IP del servidor [$IP_ACT]: " IN_IP
                IN_IP="${IN_IP:-$IP_ACT}"
                validar_ip "$IN_IP" && break
                msg_err "IP invalida."
            done

            PREF=$(ip -4 addr show "$INTERFAZ" 2>/dev/null | grep inet | awk '{print $2}' | head -1 | cut -d/ -f2)
            PREF="${PREF:-24}"
            read -rp "  Prefijo CIDR [$PREF]: " IN_PREF
            IN_PREF="${IN_PREF:-$PREF}"

            GW=$(ip route | grep default | awk '{print $3}' | head -1)
            while true; do
                read -rp "  Gateway [$GW]: " IN_GW
                IN_GW="${IN_GW:-$GW}"
                validar_ip "$IN_GW" && break
                msg_err "IP invalida."
            done

            read -rp "  DNS de respaldo [8.8.8.8]: " IN_DNS
            IN_DNS="${IN_DNS:-8.8.8.8}"

            nmcli connection modify "$CON" ipv4.addresses "${IN_IP}/${IN_PREF}"
            nmcli connection modify "$CON" ipv4.gateway "$IN_GW"
            nmcli connection modify "$CON" ipv4.dns "127.0.0.1 ${IN_DNS}"
            nmcli connection modify "$CON" ipv4.method manual
            nmcli connection down "$CON" 2>/dev/null && nmcli connection up "$CON" 2>/dev/null
            sleep 3
            IP_SERVIDOR="$IN_IP"
            msg_ok "IP configurada: $IP_SERVIDOR/$IN_PREF"
        fi

        # --- IP del cliente ---
        echo ""
        msg_info "Los registros A apuntaran a la IP del cliente."
        while true; do
            read -rp "  IP de la maquina cliente: " IP_CLIENTE
            validar_ip "$IP_CLIENTE" && break
            msg_err "IP invalida."
        done

        # --- named.conf ---
        echo ""
        msg_info "Configurando named.conf..."
        cp "$NAMED_CONF" "${NAMED_CONF}.bak.$(date +%s)" 2>/dev/null

        sed -i 's/listen-on port 53 {.*};/listen-on port 53 { any; };/' "$NAMED_CONF"
        sed -i 's/listen-on-v6 port 53 {.*};/listen-on-v6 port 53 { none; };/' "$NAMED_CONF"
        sed -i 's/allow-query {.*};/allow-query { any; };/' "$NAMED_CONF"

        # quitar zona vieja si existe
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

        # --- archivo de zona ---
        obtener_ip
        SERIAL=$(date +%Y%m%d%H)
        cat > "${ZONA_DIR}/db.${DOMINIO_BASE}" <<EOF
; Zona: ${DOMINIO_BASE}
\$TTL    86400
@       IN      SOA     ns1.${DOMINIO_BASE}. admin.${DOMINIO_BASE}. (
                        ${SERIAL}   ; Serial
                        3600        ; Refresh
                        1800        ; Retry
                        604800      ; Expire
                        86400 )     ; Minimum TTL

@       IN      NS      ns1.${DOMINIO_BASE}.
ns1     IN      A       ${IP_SERVIDOR}
@       IN      A       ${IP_CLIENTE}
www     IN      CNAME   ${DOMINIO_BASE}.
EOF
        chown named:named "${ZONA_DIR}/db.${DOMINIO_BASE}"
        chmod 640 "${ZONA_DIR}/db.${DOMINIO_BASE}"
        msg_ok "Archivo de zona creado"

        # --- SELinux ---
        if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
            restorecon -Rv /var/named/ &>/dev/null
            setsebool -P named_write_master_zones 1 2>/dev/null
            msg_ok "SELinux ajustado"
        fi

        # --- Firewall ---
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=dns &>/dev/null
            firewall-cmd --permanent --add-port=53/tcp &>/dev/null
            firewall-cmd --permanent --add-port=53/udp &>/dev/null
            firewall-cmd --reload &>/dev/null
            msg_ok "Firewall configurado"
        fi

        # --- Validar ---
        echo ""
        named-checkconf "$NAMED_CONF" 2>&1
        [[ $? -eq 0 ]] && msg_ok "named-checkconf: OK" || { msg_err "Error en named.conf"; pausar; continue; }

        named-checkzone "$DOMINIO_BASE" "${ZONA_DIR}/db.${DOMINIO_BASE}" 2>&1
        [[ $? -eq 0 ]] && msg_ok "named-checkzone: OK" || { msg_err "Error en zona"; pausar; continue; }

        # --- Iniciar ---
        systemctl restart named 2>&1
        sleep 2
        if systemctl is-active --quiet named; then
            msg_ok "Servicio named activo"
        else
            msg_err "No pudo iniciar. Revise: journalctl -u named"
        fi

        echo ""
        echo "  Resumen:"
        echo "    $DOMINIO_BASE      -> A     $IP_CLIENTE"
        echo "    www.$DOMINIO_BASE  -> CNAME $DOMINIO_BASE"
        echo "    ns1.$DOMINIO_BASE  -> A     $IP_SERVIDOR"

        pausar
        ;;

# =========================================================
# 4) RECONFIGURAR
# =========================================================
    4)
        clear
        echo ""
        echo "  -- RECONFIGURAR --"
        echo ""
        echo "  1) Cambiar IP estatica de $INTERFAZ"
        echo "  2) Cambiar IP cliente en zona $DOMINIO_BASE"
        echo "  3) Reiniciar servicio named"
        echo "  0) Volver"
        echo ""
        read -rp "  Opcion: " sub4

        case $sub4 in
            1)
                CON=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${INTERFAZ}$" | cut -d: -f1)
                if [[ -n "$CON" ]]; then
                    echo ""
                    while true; do
                        read -rp "  Nueva IP: " IN_IP
                        validar_ip "$IN_IP" && break
                        msg_err "IP invalida."
                    done
                    read -rp "  Prefijo [24]: " IN_P; IN_P="${IN_P:-24}"
                    while true; do
                        read -rp "  Gateway: " IN_GW
                        validar_ip "$IN_GW" && break
                        msg_err "IP invalida."
                    done
                    read -rp "  DNS respaldo [8.8.8.8]: " IN_D; IN_D="${IN_D:-8.8.8.8}"

                    nmcli connection modify "$CON" ipv4.addresses "${IN_IP}/${IN_P}"
                    nmcli connection modify "$CON" ipv4.gateway "$IN_GW"
                    nmcli connection modify "$CON" ipv4.dns "127.0.0.1 ${IN_D}"
                    nmcli connection modify "$CON" ipv4.method manual
                    nmcli connection down "$CON" 2>/dev/null && nmcli connection up "$CON" 2>/dev/null
                    sleep 3
                    IP_SERVIDOR="$IN_IP"
                    msg_ok "IP reconfigurada: $IP_SERVIDOR"

                    systemctl is-active --quiet named && { systemctl restart named; msg_ok "named reiniciado"; }
                else
                    msg_err "No hay conexion para $INTERFAZ"
                fi
                pausar
                ;;
            2)
                obtener_ip
                [[ -z "$IP_SERVIDOR" ]] && { msg_err "Sin IP en $INTERFAZ"; pausar; continue; }

                while true; do
                    read -rp "  Nueva IP del cliente: " IP_CLIENTE
                    validar_ip "$IP_CLIENTE" && break
                    msg_err "IP invalida."
                done

                SERIAL=$(date +%Y%m%d%H)
                cat > "${ZONA_DIR}/db.${DOMINIO_BASE}" <<EOF
; Zona: ${DOMINIO_BASE}
\$TTL    86400
@       IN      SOA     ns1.${DOMINIO_BASE}. admin.${DOMINIO_BASE}. (
                        ${SERIAL}   ; Serial
                        3600        ; Refresh
                        1800        ; Retry
                        604800      ; Expire
                        86400 )     ; Minimum TTL

@       IN      NS      ns1.${DOMINIO_BASE}.
ns1     IN      A       ${IP_SERVIDOR}
@       IN      A       ${IP_CLIENTE}
www     IN      CNAME   ${DOMINIO_BASE}.
EOF
                chown named:named "${ZONA_DIR}/db.${DOMINIO_BASE}"
                chmod 640 "${ZONA_DIR}/db.${DOMINIO_BASE}"

                named-checkzone "$DOMINIO_BASE" "${ZONA_DIR}/db.${DOMINIO_BASE}" 2>&1
                systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                msg_ok "Zona actualizada, servicio recargado."
                pausar
                ;;
            3)
                systemctl restart named 2>&1; sleep 2
                systemctl is-active --quiet named && msg_ok "named activo" || msg_err "no pudo iniciar"
                pausar
                ;;
        esac
        ;;

# =========================================================
# 5) ADMINISTRAR DOMINIOS (ABC)
# =========================================================
    5)
        while true; do
            clear
            echo ""
            echo "  -- ADMINISTRACION DE DOMINIOS --"
            echo "  Dominio -> IP -> Funcionamiento: Comunicaciones entre IP"
            echo ""
            echo "  1) Consultar  (listar zonas y registros)"
            echo "  2) Agregar    (nueva zona)"
            echo "  3) Configurar (editar registros)"
            echo "  4) Eliminar   (quitar zona)"
            echo "  0) Volver"
            echo ""
            read -rp "  Opcion: " sub5

            case $sub5 in

            # --- CONSULTAR ---
            1)
                clear
                echo ""
                echo "  -- ZONAS CONFIGURADAS --"
                echo ""

                ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')

                if [[ -z "$ZONAS" ]]; then
                    msg_warn "No hay zonas personalizadas."
                    pausar
                    continue
                fi

                n=1
                while IFS= read -r z; do
                    ZF="${ZONA_DIR}/db.${z}"
                    echo "  [$n] $z"
                    if [[ -f "$ZF" ]]; then
                        echo "      Archivo: $ZF"
                        # registros A
                        RA=$(grep -E "IN\s+A\s+" "$ZF" | grep -v "^\s*;")
                        if [[ -n "$RA" ]]; then
                            echo "      Registros A:"
                            while IFS= read -r r; do
                                NM=$(echo "$r" | awk '{print $1}')
                                IP=$(echo "$r" | awk '{print $NF}')
                                [[ "$NM" == "@" ]] && echo "        $z -> $IP" || echo "        ${NM}.${z} -> $IP"
                            done <<< "$RA"
                        fi
                        # registros CNAME
                        RC=$(grep -E "IN\s+CNAME\s+" "$ZF" | grep -v "^\s*;")
                        if [[ -n "$RC" ]]; then
                            echo "      Registros CNAME:"
                            while IFS= read -r r; do
                                NM=$(echo "$r" | awk '{print $1}')
                                AL=$(echo "$r" | awk '{print $NF}')
                                echo "        ${NM}.${z} -> $AL"
                            done <<< "$RC"
                        fi
                    else
                        msg_warn "      archivo de zona no encontrado"
                    fi
                    echo ""
                    n=$((n+1))
                done <<< "$ZONAS"
                pausar
                ;;

            # --- AGREGAR ---
            2)
                clear
                echo ""
                echo "  -- AGREGAR DOMINIO --"
                echo ""

                obtener_ip
                [[ -z "$IP_SERVIDOR" ]] && { msg_err "Sin IP en $INTERFAZ"; pausar; continue; }

                read -rp "  Nombre del dominio (ej: ejemplo.com): " ND
                [[ -z "$ND" || ! "$ND" =~ \. ]] && { msg_err "Nombre invalido."; pausar; continue; }

                if grep -q "zone \"${ND}\"" "$NAMED_CONF" 2>/dev/null; then
                    msg_err "Ya existe '$ND'. Use Configurar para editarla."
                    pausar
                    continue
                fi

                while true; do
                    read -rp "  IP destino para $ND: " IP_D
                    validar_ip "$IP_D" && break
                    msg_err "IP invalida."
                done

                cat >> "$NAMED_CONF" <<EOF

// Zona: ${ND}
zone "${ND}" IN {
    type master;
    file "${ZONA_DIR}/db.${ND}";
    allow-update { none; };
};
EOF

                SERIAL=$(date +%Y%m%d%H)
                cat > "${ZONA_DIR}/db.${ND}" <<EOF
; Zona: ${ND}
\$TTL    86400
@       IN      SOA     ns1.${ND}. admin.${ND}. (
                        ${SERIAL}   ; Serial
                        3600        ; Refresh
                        1800        ; Retry
                        604800      ; Expire
                        86400 )     ; Minimum TTL

@       IN      NS      ns1.${ND}.
ns1     IN      A       ${IP_SERVIDOR}
@       IN      A       ${IP_D}
www     IN      CNAME   ${ND}.
EOF
                chown named:named "${ZONA_DIR}/db.${ND}"
                chmod 640 "${ZONA_DIR}/db.${ND}"

                named-checkconf "$NAMED_CONF" 2>&1
                [[ $? -ne 0 ]] && { msg_err "Error en named.conf"; pausar; continue; }

                named-checkzone "$ND" "${ZONA_DIR}/db.${ND}" 2>&1
                [[ $? -ne 0 ]] && { msg_err "Error en zona"; pausar; continue; }

                systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                sleep 1

                msg_ok "Dominio $ND agregado."
                echo "    $ND      -> A     $IP_D"
                echo "    www.$ND  -> CNAME $ND"
                echo "    ns1.$ND  -> A     $IP_SERVIDOR"
                pausar
                ;;

            # --- CONFIGURAR REGISTROS ---
            3)
                clear
                echo ""
                echo "  -- CONFIGURAR REGISTROS --"
                echo ""

                ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')
                [[ -z "$ZONAS" ]] && { msg_warn "No hay zonas."; pausar; continue; }

                n=1
                declare -A ZM
                while IFS= read -r z; do
                    echo "  $n) $z"
                    ZM[$n]="$z"
                    n=$((n+1))
                done <<< "$ZONAS"

                echo ""
                read -rp "  Seleccione zona: " sel
                ZS="${ZM[$sel]}"
                [[ -z "$ZS" ]] && { msg_err "Seleccion invalida."; pausar; continue; }

                ZF="${ZONA_DIR}/db.${ZS}"
                [[ ! -f "$ZF" ]] && { msg_err "Archivo no encontrado: $ZF"; pausar; continue; }

                while true; do
                    clear
                    echo ""
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
                            [[ -z "$SD" ]] && { msg_err "Vacio."; sleep 1; continue; }
                            if grep -qE "^${SD}\s+IN\s+A\s+" "$ZF"; then
                                msg_warn "Ya existe, se actualizara."
                                sed -i "/^${SD}\s\+IN\s\+A\s/d" "$ZF"
                            fi
                            while true; do
                                read -rp "  IP para ${SD}.${ZS}: " IP_S
                                validar_ip "$IP_S" && break
                                msg_err "IP invalida."
                            done
                            echo "${SD}     IN      A       ${IP_S}" >> "$ZF"

                            # incrementar serial
                            SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                            [[ -n "$SER" ]] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"

                            named-checkzone "$ZS" "$ZF" 2>&1
                            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                            msg_ok "Registro A agregado: ${SD}.${ZS} -> $IP_S"
                            sleep 2
                            ;;
                        2)
                            read -rp "  Nombre del alias: " AN
                            [[ -z "$AN" ]] && { msg_err "Vacio."; sleep 1; continue; }
                            read -rp "  Apunta a (ej: mail.${ZS}): " AT
                            [[ -z "$AT" ]] && { msg_err "Vacio."; sleep 1; continue; }
                            [[ ! "$AT" =~ \.$ ]] && AT="${AT}."

                            if grep -qE "^${AN}\s+IN\s+CNAME\s+" "$ZF"; then
                                sed -i "/^${AN}\s\+IN\s\+CNAME\s/d" "$ZF"
                            fi
                            echo "${AN}     IN      CNAME   ${AT}" >> "$ZF"

                            SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                            [[ -n "$SER" ]] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"

                            named-checkzone "$ZS" "$ZF" 2>&1
                            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                            msg_ok "CNAME agregado: ${AN}.${ZS} -> $AT"
                            sleep 2
                            ;;
                        3)
                            echo ""
                            echo "  Registros:"
                            grep -E "IN\s+(A|CNAME)\s+" "$ZF" | grep -v "^\s*;" | awk '{print $1}' | sort -u | sed 's/^/    /'
                            echo ""
                            read -rp "  Nombre a eliminar: " RD
                            [[ -z "$RD" ]] && { msg_err "Vacio."; sleep 1; continue; }
                            if grep -qE "^${RD}\s+IN\s+" "$ZF"; then
                                sed -i "/^${RD}\s\+IN\s/d" "$ZF"
                                SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                                [[ -n "$SER" ]] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"
                                systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                                msg_ok "Registro '$RD' eliminado."
                            else
                                msg_err "No se encontro '$RD'."
                            fi
                            sleep 2
                            ;;
                        4)
                            while true; do
                                read -rp "  Nueva IP para $ZS (@): " NI
                                validar_ip "$NI" && break
                                msg_err "IP invalida."
                            done
                            sed -i "/^@\s\+IN\s\+A\s/c\\@       IN      A       ${NI}" "$ZF"
                            SER=$(grep -oP '\d{10}(?=\s*;\s*Serial)' "$ZF" 2>/dev/null)
                            [[ -n "$SER" ]] && sed -i "s/${SER}\(\s*;\s*Serial\)/$((SER+1))\1/" "$ZF"
                            systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                            msg_ok "IP raiz actualizada a $NI"
                            sleep 2
                            ;;
                        0) break ;;
                    esac
                done
                unset ZM
                ;;

            # --- ELIMINAR ---
            4)
                clear
                echo ""
                echo "  -- ELIMINAR DOMINIO --"
                echo ""

                ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')
                [[ -z "$ZONAS" ]] && { msg_warn "No hay zonas."; pausar; continue; }

                n=1
                declare -A ZM
                while IFS= read -r z; do
                    echo "  $n) $z"
                    ZM[$n]="$z"
                    n=$((n+1))
                done <<< "$ZONAS"

                echo ""
                read -rp "  Zona a eliminar: " sel
                ZD="${ZM[$sel]}"
                [[ -z "$ZD" ]] && { msg_err "Seleccion invalida."; unset ZM; pausar; continue; }

                echo ""
                echo -e "  ${R}Seguro de eliminar '$ZD'?${N}"
                read -rp "  Escriba SI para confirmar: " CONF
                if [[ "$CONF" != "SI" ]]; then
                    msg_info "Cancelado."
                    unset ZM
                    pausar
                    continue
                fi

                sed -i "/\/\/ Zona: ${ZD}/d" "$NAMED_CONF"
                sed -i "/zone \"${ZD}\"/,/^};/d" "$NAMED_CONF"
                [[ -f "${ZONA_DIR}/db.${ZD}" ]] && rm -f "${ZONA_DIR}/db.${ZD}"

                named-checkconf "$NAMED_CONF" 2>&1
                systemctl reload named 2>/dev/null || systemctl restart named 2>/dev/null
                msg_ok "Zona '$ZD' eliminada."
                unset ZM
                pausar
                ;;

            0) break ;;
            esac
        done
        ;;

# =========================================================
# 6) VALIDAR Y PROBAR
# =========================================================
    6)
        clear
        echo ""
        echo "  -- VALIDACION Y PRUEBAS --"
        echo ""

        EVID="${EVIDENCIA_DIR}/validacion_$(date +%Y%m%d_%H%M%S).txt"

        echo "=== REPORTE DNS - $(date) ===" > "$EVID"
        echo "Servidor: $(hostname) | IP: $IP_SERVIDOR" >> "$EVID"
        echo "" >> "$EVID"

        # sintaxis
        echo "  Sintaxis:"
        named-checkconf "$NAMED_CONF" 2>&1 | tee -a "$EVID"
        [[ ${PIPESTATUS[0]} -eq 0 ]] && msg_ok "named-checkconf OK" || msg_err "Error en named.conf"

        ZONAS=$(grep -E '^\s*zone\s+"' "$NAMED_CONF" | grep -v "localhost\|0.in-addr\|127.in-addr\|255.in-addr\|1.0.0.0.0.0\|0.0.0.0.0.0" | awk -F'"' '{print $2}')

        while IFS= read -r z; do
            [[ -z "$z" ]] && continue
            ZF="${ZONA_DIR}/db.${z}"
            if [[ -f "$ZF" ]]; then
                RES=$(named-checkzone "$z" "$ZF" 2>&1)
                echo "$RES" >> "$EVID"
                echo "$RES" | grep -q "OK" && msg_ok "checkzone $z: OK" || msg_err "checkzone $z: Error"
            fi
        done <<< "$ZONAS"

        # estado servicio
        echo ""
        echo "  Estado del servicio:"
        systemctl status named --no-pager 2>&1 | tee -a "$EVID" | head -6 | sed 's/^/    /'

        # pruebas de resolucion
        echo ""
        echo "  Pruebas de resolucion:"
        while IFS= read -r z; do
            [[ -z "$z" ]] && continue
            echo ""
            echo "  --- $z ---"
            echo "=== $z ===" >> "$EVID"

            # nslookup
            R1=$(nslookup "$z" 127.0.0.1 2>&1)
            echo "$R1" >> "$EVID"
            IP_R=$(echo "$R1" | grep -A2 "Name:" | grep "Address" | awk '{print $2}' | head -1)
            [[ -z "$IP_R" ]] && IP_R=$(echo "$R1" | tail -2 | grep "Address" | awk '{print $2}')
            [[ -n "$IP_R" ]] && msg_ok "nslookup $z -> $IP_R" || msg_warn "nslookup $z: sin respuesta"

            R2=$(nslookup "www.${z}" 127.0.0.1 2>&1)
            echo "$R2" >> "$EVID"
            echo "$R2" | grep -qE "canonical name|Address" && msg_ok "nslookup www.$z -> OK" || msg_warn "nslookup www.$z: sin respuesta"

            # dig
            D1=$(dig @127.0.0.1 "$z" A +short 2>&1)
            echo "dig $z: $D1" >> "$EVID"
            [[ -n "$D1" ]] && msg_ok "dig $z -> $D1" || msg_warn "dig $z: sin resultado"

            # ping
            ping -c 2 "$z" >> "$EVID" 2>&1
            ping -c 2 "www.${z}" >> "$EVID" 2>&1
        done <<< "$ZONAS"

        echo ""
        msg_ok "Evidencias: $EVID"
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