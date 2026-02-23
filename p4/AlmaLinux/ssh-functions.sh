#!/bin/bash
# lib/ssh_functions.sh
# Depende de: common_functions.sh

SSHD_CONFIG="/etc/ssh/sshd_config"

# ─────────────────────────────────────────
# VERIFICAR INSTALACION
# ─────────────────────────────────────────
ssh_verificar() {
    echo ""
    echo "=== Verificando SSH ==="
    if dpkg -l | grep -qw openssh-server; then
        msg_ok "openssh-server instalado: $(dpkg -l openssh-server | awk '/openssh/{print $3}')"
    else
        msg_warn "openssh-server NO instalado"
    fi
    echo ""
    if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
        msg_ok "Servicio: ACTIVO"
    else
        msg_warn "Servicio: INACTIVO"
    fi
    echo ""
    echo "  IPs del servidor:"
    hostname -I | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$' | while read -r ip; do
        echo "    ssh usuario@$ip"
    done
    pausar
}

# ─────────────────────────────────────────
# INSTALAR
# ─────────────────────────────────────────
ssh_instalar() {
    echo ""
    echo "=== Instalacion OpenSSH Server ==="

    if dpkg -l | grep -qw openssh-server; then
        msg_warn "Ya instalado."
        read -rp "  ¿Reinstalar? (s/n): " r
        [[ ! "$r" =~ ^[sS]$ ]] && return
    fi

    apt-get update &>/dev/null
    apt-get install -y openssh-server &>/dev/null \
        && msg_ok "openssh-server instalado." \
        || { msg_err "Error en instalacion."; pausar; return; }

    systemctl enable ssh &>/dev/null
    systemctl start ssh
    systemctl is-active --quiet ssh \
        && msg_ok "Servicio activo y habilitado en el arranque." \
        || msg_err "El servicio no pudo iniciar."
    pausar
}

# ─────────────────────────────────────────
# CONFIGURAR SEGURIDAD
# ─────────────────────────────────────────
ssh_configurar() {
    echo ""
    echo "=== Configuracion de seguridad SSH ==="
    [ ! -f "$SSHD_CONFIG" ] && msg_err "No existe $SSHD_CONFIG" && pausar && return

    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak" && msg_ok "Backup: ${SSHD_CONFIG}.bak"

    read -rp "  Puerto SSH [22]: " puerto; puerto=${puerto:-22}

    _set() { sed -i "/^\s*#\?\s*${1}/d" "$SSHD_CONFIG"; echo "$1 $2" >> "$SSHD_CONFIG"; }

    _set Port               "$puerto"
    _set PermitRootLogin    "no"
    _set PermitEmptyPasswords "no"
    _set MaxAuthTries       "3"
    _set LoginGraceTime     "30"
    _set LogLevel           "VERBOSE"

    msg_ok "Configuracion aplicada (puerto $puerto)."
    msg_warn "Reinicia el servicio para aplicar cambios."
    pausar
}

# ─────────────────────────────────────────
# REINICIAR
# ─────────────────────────────────────────
ssh_reiniciar() {
    echo ""
    echo "Reiniciando SSH..."
    systemctl restart ssh
    sleep 1
    systemctl is-active --quiet ssh \
        && msg_ok "SSH activo." \
        || { msg_err "Fallo al reiniciar."; sshd -t 2>&1; }
    pausar
}