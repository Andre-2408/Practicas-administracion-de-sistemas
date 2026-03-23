#!/bin/bash
#
# utils.AD.sh -- Constantes globales y helpers compartidos para Active Directory (Practica 8)
#

[[ -n "${_AD_UTILS_CARGADO:-}" ]] && return 0
readonly _AD_UTILS_CARGADO=1

# ------------------------------------------------------------
# Configuracion del dominio -- AJUSTAR SEGUN EL ENTORNO
# ------------------------------------------------------------

readonly AD_DOMINIO="p8.local"
readonly AD_REALM="P8.LOCAL"
readonly AD_NETBIOS="P8"
readonly AD_DC="dc01.p8.local"             # FQDN del controlador de dominio
readonly AD_DC_IP="192.168.92.132"          # IP del DC (opcional, para forzar DNS)
readonly AD_ADMIN="Administrador"           # Usuario administrador del dominio

# ------------------------------------------------------------
# Rutas de configuracion
# ------------------------------------------------------------

readonly AD_SSSD_CONF="/etc/sssd/sssd.conf"
readonly AD_SSSD_CONF_BACKUP="/etc/sssd/sssd.conf.bak"
readonly AD_SUDOERS_FILE="/etc/sudoers.d/ad-admins"
readonly AD_KRB5_CONF="/etc/krb5.conf"
readonly AD_PAM_SYSAUTH="/etc/pam.d/system-auth"

# Plantilla para el directorio home de los usuarios de AD
# %u = nombre de usuario, %d = nombre del dominio
readonly AD_FALLBACK_HOMEDIR="/home/%u@%d"

# Shell por defecto para usuarios de AD
readonly AD_DEFAULT_SHELL="/bin/bash"

# Grupo de administradores del dominio que tendra sudo
readonly AD_GRUPO_ADMINS="domain admins"

# ------------------------------------------------------------
# Helpers de output (estilo p7)
# ------------------------------------------------------------

aputs_info() {
    echo "  [INFO]    $1"
}

aputs_ok() {
    echo "  [OK]      $1"
}

aputs_success() {
    echo "  [OK]      $1"
}

aputs_error() {
    echo "  [ERROR]   $1"
}

aputs_warning() {
    echo "  [AVISO]   $1"
}

draw_line() {
    echo "  ----------------------------------------------------------"
}

pause() {
    echo ""
    echo "  Presione ENTER para continuar..."
    read -r _pausa_tmp
}

ad_mostrar_banner() {
    local titulo="${1:-Practica 08 -- Gobernanza y Control AD (Linux)}"
    echo ""
    echo "  =========================================================="
    echo "    ${titulo}"
    echo "  =========================================================="
    echo ""
}

# ------------------------------------------------------------
# Helper: verificar que el equipo ya esta unido al dominio
# ------------------------------------------------------------

ad_verificar_dominio_unido() {
    if realm list 2>/dev/null | grep -q "${AD_DOMINIO}"; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# Helper: detectar distribucion Linux
# ------------------------------------------------------------

ad_detectar_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "${ID:-unknown}"
    elif command -v rpm &>/dev/null; then
        echo "rhel"
    elif command -v dpkg &>/dev/null; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# Helper: determinar gestor de paquetes
# ------------------------------------------------------------

ad_gestor_paquetes() {
    if command -v dnf  &>/dev/null; then echo "dnf";  return; fi
    if command -v yum  &>/dev/null; then echo "yum";  return; fi
    if command -v apt  &>/dev/null; then echo "apt";  return; fi
    if command -v zypper &>/dev/null; then echo "zypper"; return; fi
    echo "desconocido"
}

# ------------------------------------------------------------
# Helper: instalar paquete segun distro
# ------------------------------------------------------------

ad_instalar_paquete() {
    local paquete="$1"
    local gestor
    gestor=$(ad_gestor_paquetes)

    case "${gestor}" in
        dnf|yum)
            "${gestor}" install -y "${paquete}" &>/dev/null
            ;;
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${paquete}" &>/dev/null
            ;;
        zypper)
            zypper install -y "${paquete}" &>/dev/null
            ;;
        *)
            aputs_error "Gestor de paquetes no reconocido: ${gestor}"
            return 1
            ;;
    esac
}
