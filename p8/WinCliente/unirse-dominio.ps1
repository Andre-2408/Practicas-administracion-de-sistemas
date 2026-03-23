#Requires -RunAsAdministrator
#
# unirse-dominio.ps1 -- Une automaticamente el cliente Windows al dominio (Practica 8)
# Ejecutar en el equipo CLIENTE, no en el servidor.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File "unirse-dominio.ps1"
#   powershell -ExecutionPolicy Bypass -File "unirse-dominio.ps1" -DominioNombre "p8.local" -DCIp "192.168.1.10"
#

param(
    [string]$DominioNombre = "p8.local",
    [string]$DCIp          = "",          # IP del controlador de dominio (opcional, para ajustar DNS)
    [string]$AdminUsuario  = "Administrator",
    [switch]$ReiniciarAuto                # Si se especifica, reinicia sin preguntar
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Helpers de salida
# ------------------------------------------------------------

function _info    { param($m) Write-Host "  [INFO]    $m" }
function _ok      { param($m) Write-Host "  [OK]      $m" }
function _error   { param($m) Write-Host "  [ERROR]   $m" }
function _aviso   { param($m) Write-Host "  [AVISO]   $m" }

function _banner {
    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    Practica 08 -- Union al Dominio (Cliente Windows)"
    Write-Host "  =========================================================="
    Write-Host ""
}

function _linea { Write-Host "  ----------------------------------------------------------" }

# ------------------------------------------------------------
# Verificar si ya esta unido al dominio
# ------------------------------------------------------------

function _verificar_estado_dominio {
    $equipo = Get-WmiObject -Class Win32_ComputerSystem
    if ($equipo.PartOfDomain) {
        _info "Este equipo ya pertenece al dominio: $($equipo.Domain)"
        return $true
    }
    _info "Este equipo no esta unido a ningun dominio (workgroup: $($equipo.Domain))"
    return $false
}

# ------------------------------------------------------------
# Configurar DNS para apuntar al controlador de dominio
# ------------------------------------------------------------

function _configurar_dns {
    param([string]$IpDC)

    if ([string]::IsNullOrWhiteSpace($IpDC)) {
        _aviso "No se especifico IP del DC -- omitiendo configuracion de DNS"
        _aviso "Asegurese de que DNS ya apunta a $DominioNombre"
        return
    }

    _info "Configurando DNS primario hacia el DC: $IpDC ..."

    $adaptadores = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }

    foreach ($adaptador in $adaptadores) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adaptador.InterfaceIndex `
                -ServerAddresses @($IpDC) -ErrorAction Stop
            _ok "DNS configurado en adaptador: $($adaptador.Name)"
        } catch {
            _aviso "No se pudo configurar DNS en $($adaptador.Name): $_"
        }
    }

    # Verificar resolucion del dominio
    Start-Sleep -Seconds 2
    try {
        $resolucion = Resolve-DnsName -Name $DominioNombre -ErrorAction Stop
        _ok "Resolucion DNS exitosa para $DominioNombre -> $($resolucion[0].IPAddress)"
    } catch {
        _aviso "No se pudo resolver $DominioNombre -- verifique conectividad con el DC"
    }
}

# ------------------------------------------------------------
# Unirse al dominio via Add-Computer
# ------------------------------------------------------------

function _unirse_dominio {
    _info "Iniciando proceso de union al dominio: $DominioNombre"
    Write-Host ""

    # Solicitar credenciales del administrador del dominio
    Write-Host "  Ingrese las credenciales del administrador del dominio:"
    $usuarioInput = Read-Host "  Usuario [$DominioNombre\$AdminUsuario]"
    if (-not $usuarioInput) { $usuarioInput = "$DominioNombre\$AdminUsuario" }
    $passwordInput = Read-Host "  Contrasena" -AsSecureString
    $credenciales = New-Object System.Management.Automation.PSCredential($usuarioInput, $passwordInput)

    if (-not $credenciales) {
        _error "No se proporcionaron credenciales -- operacion cancelada"
        return $false
    }

    Write-Host ""
    _info "Ejecutando Add-Computer..."

    try {
        Add-Computer `
            -DomainName   $DominioNombre `
            -Credential   $credenciales `
            -Force        `
            -ErrorAction  Stop

        _ok "Union al dominio '$DominioNombre' exitosa"
        return $true

    } catch {
        _error "Error al unirse al dominio: $_"
        Write-Host ""
        Write-Host "  Causas comunes:"
        Write-Host "    - El DC no es accesible (verifique IP y firewall)"
        Write-Host "    - DNS no apunta al DC (use -DCIp para configurarlo)"
        Write-Host "    - Credenciales incorrectas"
        Write-Host "    - La cuenta del equipo ya existe en AD con otro estado"
        return $false
    }
}

# ------------------------------------------------------------
# Solicitar reinicio
# ------------------------------------------------------------

function _solicitar_reinicio {
    Write-Host ""
    _linea
    _ok "Union al dominio completada"
    Write-Host ""
    Write-Host "  IMPORTANTE: Se requiere reiniciar el equipo para completar"
    Write-Host "  la union al dominio."
    Write-Host ""

    if ($ReiniciarAuto) {
        _info "Reiniciando automaticamente en 10 segundos..."
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        $respuesta = Read-Host "  Desea reiniciar ahora? [S/n]"
        if ($respuesta -notmatch '^[nN]$') {
            _info "Reiniciando..."
            Restart-Computer -Force
        } else {
            _aviso "Reinicio pospuesto -- recuerde reiniciar manualmente"
        }
    }
}

# ------------------------------------------------------------
# Punto de entrada
# ------------------------------------------------------------

_banner

# 1. Verificar si ya esta unido
if (_verificar_estado_dominio) {
    Write-Host ""
    $continuar = Read-Host "  Ya esta unido a un dominio. Desea continuar de todos modos? [s/N]"
    if ($continuar -notmatch '^[sS]$') {
        _info "Operacion cancelada"
        exit 0
    }
}

Write-Host ""
_linea

# 2. Configurar DNS (si se proporciono IP del DC)
_configurar_dns -IpDC $DCIp

Write-Host ""
_linea

# 3. Unirse al dominio
$exito = _unirse_dominio

if ($exito) {
    _solicitar_reinicio
} else {
    Write-Host ""
    _error "No se pudo completar la union al dominio"
    Write-Host "  Revise los errores anteriores y vuelva a intentarlo"
    Write-Host ""
    exit 1
}
