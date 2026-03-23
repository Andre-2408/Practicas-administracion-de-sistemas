#Requires -RunAsAdministrator
#
# main.ps1 -- Orquestador principal Practica 8 (Windows Server)
# Gobernanza, Cuotas y Control de Aplicaciones en Active Directory
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File "main.ps1"
#

$ErrorActionPreference = "Stop"

$Script:P8_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# ------------------------------------------------------------
# Verificar privilegios de administrador
# ------------------------------------------------------------

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$esAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    Write-Host ""
    Write-Host "  [ERROR] Este script requiere privilegios de Administrador."
    Write-Host "  Ejecute PowerShell como Administrador y vuelva a lanzar:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------
# Verificar estructura de archivos
# ------------------------------------------------------------

function _verificar_estructura {
    $errores = 0

    $archivosReq = @(
        (Join-Path $Script:P8_DIR "utils.AD.ps1"),
        (Join-Path $Script:P8_DIR "data\usuarios.csv")
    )

    foreach ($archivo in $archivosReq) {
        if (-not (Test-Path $archivo)) {
            Write-Host "  [ERROR] Archivo no encontrado: $archivo"
            $errores++
        }
    }

    $modulos = @(
        "modules\01-ad-estructura.ps1",
        "modules\02-horario-acceso.ps1",
        "modules\03-fsrm-cuotas.ps1",
        "modules\04-applocker.ps1",
        "modules\05-gpo-cierre-sesion.ps1"
    )

    foreach ($mod in $modulos) {
        $ruta = Join-Path $Script:P8_DIR $mod
        if (-not (Test-Path $ruta)) {
            Write-Host "  [AVISO] Modulo no encontrado: $ruta"
        }
    }

    if ($errores -gt 0) {
        Write-Host ""
        Write-Host "  Verifique la estructura de la Practica 8:"
        Write-Host "  p8\WinServer\main.ps1"
        Write-Host "  p8\WinServer\utils.AD.ps1"
        Write-Host "  p8\WinServer\data\usuarios.csv"
        Write-Host "  p8\WinServer\modules\0x-*.ps1"
        Write-Host ""
        exit 1
    }
}

# ------------------------------------------------------------
# Cargar utils y modulos (dot-source)
# ------------------------------------------------------------

function _cargar_modulos {
    . (Join-Path $Script:P8_DIR "utils.AD.ps1")

    $modulos = @(
        "modules\01-ad-estructura.ps1",
        "modules\02-horario-acceso.ps1",
        "modules\03-fsrm-cuotas.ps1",
        "modules\04-applocker.ps1",
        "modules\05-gpo-cierre-sesion.ps1"
    )

    foreach ($mod in $modulos) {
        $ruta = Join-Path $Script:P8_DIR $mod
        if (Test-Path $ruta) { . $ruta }
    }
}

# ------------------------------------------------------------
# Indicadores de estado
# ------------------------------------------------------------

function _icono_estado {
    param([bool]$Condicion)
    if ($Condicion) { return "[*]" } else { return "[ ]" }
}

function _estado_ad_dominio {
    try {
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null
        $dom = Get-ADDomain -ErrorAction SilentlyContinue
        return ($null -ne $dom)
    } catch { return $false }
}

function _estado_ous {
    try {
        $c = Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'" -ErrorAction SilentlyContinue
        $nc = Get-ADOrganizationalUnit -Filter "Name -eq 'NoCuates'" -ErrorAction SilentlyContinue
        return ($null -ne $c -and $null -ne $nc)
    } catch { return $false }
}

function _estado_usuarios {
    try {
        $total = @(Get-ADUser -Filter * -SearchBase $Script:AD_OU_CUATES -ErrorAction SilentlyContinue).Count +
                 @(Get-ADUser -Filter * -SearchBase $Script:AD_OU_NOCUATES -ErrorAction SilentlyContinue).Count
        return ($total -gt 0)
    } catch { return $false }
}

function _estado_horarios {
    try {
        $miembros = Get-ADGroupMember -Identity $Script:AD_GRUPO_CUATES -ErrorAction SilentlyContinue |
            Where-Object { $_.objectClass -eq "user" }
        if (-not $miembros) { return $false }
        $primero = Get-ADUser -Identity $miembros[0].SamAccountName -Properties logonHours `
            -ErrorAction SilentlyContinue
        return ($null -ne $primero.logonHours)
    } catch { return $false }
}

function _estado_fsrm {
    try {
        $feature = Get-WindowsFeature -Name FS-Resource-Manager -ErrorAction SilentlyContinue
        return ($null -ne $feature -and $feature.Installed)
    } catch { return $false }
}

function _estado_fsrm_cuotas {
    try {
        Import-Module FileServerResourceManager -ErrorAction SilentlyContinue | Out-Null
        $cuotas = @(Get-FsrmQuota -ErrorAction SilentlyContinue)
        return ($cuotas.Count -gt 0)
    } catch { return $false }
}

function _estado_applocker {
    try {
        Import-Module GroupPolicy -ErrorAction SilentlyContinue | Out-Null
        $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        $gpo = Get-GPO -Name $Script:AD_GPO_APPLOCKER -ErrorAction SilentlyContinue
        return ($null -ne $svc -and $svc.Status -eq "Running" -and $null -ne $gpo)
    } catch { return $false }
}

function _estado_gpo_cierre {
    try {
        Import-Module GroupPolicy -ErrorAction SilentlyContinue | Out-Null
        $gpo = Get-GPO -Name $Script:AD_GPO_SEGURIDAD -ErrorAction SilentlyContinue
        return ($null -ne $gpo)
    } catch { return $false }
}

function _estado_clientes_menu {
    try {
        $linux = $null -ne (Get-LocalUser -Name $Script:AD_CLIENTE_LINUX -ErrorAction SilentlyContinue)
        $win   = (-not [string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) -and
                 ($null -ne (Get-LocalUser -Name $Script:AD_CLIENTE_WIN -ErrorAction SilentlyContinue))
        return ($linux -or $win)
    } catch { return $false }
}

# ------------------------------------------------------------
# Refrescar cache de estados
# ------------------------------------------------------------

function _refrescar_estado {
    $Script:_cDominio   = _estado_ad_dominio
    $Script:_cOUs       = _estado_ous
    $Script:_cUsuarios  = _estado_usuarios
    $Script:_cHorarios  = _estado_horarios
    $Script:_cFSRM      = _estado_fsrm
    $Script:_cCuotas    = _estado_fsrm_cuotas
    $Script:_cAppL      = _estado_applocker
    $Script:_cGPOCierre = _estado_gpo_cierre
    $Script:_cClientes  = _estado_clientes_menu
}

# ------------------------------------------------------------
# Dibujar menu principal
# ------------------------------------------------------------

function _dibujar_menu {
    Clear-Host

    $sDom   = _icono_estado $Script:_cDominio
    $sOUs   = _icono_estado $Script:_cOUs
    $sUs    = _icono_estado $Script:_cUsuarios
    $sHor   = _icono_estado $Script:_cHorarios
    $sFSRM  = _icono_estado $Script:_cFSRM
    $sCuot  = _icono_estado $Script:_cCuotas
    $sAppL  = _icono_estado $Script:_cAppL
    $sGPO   = _icono_estado $Script:_cGPOCierre
    $sCli   = _icono_estado $Script:_cClientes

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    Practica 08 -- Gobernanza, Cuotas y Control AD"
    Write-Host "  =========================================================="
    Write-Host ""
    Write-Host "  Dominio AD: $sDom  $($Script:AD_DOMINIO)"
    Write-Host ""
    Write-Host "  -- Estructura y Usuarios -------------------------------------"
    Write-Host "  1) $sOUs  Crear OUs (Cuates / NoCuates) e importar usuarios CSV"
    Write-Host "             $sUs  Usuarios importados"
    Write-Host ""
    Write-Host "  -- Control de Acceso -----------------------------------------"
    Write-Host "  2) $sHor  Configurar horarios de acceso (Logon Hours)"
    Write-Host "             Cuates: 8:00-15:00  |  NoCuates: 15:00-02:00"
    Write-Host ""
    Write-Host "  -- Gestion de Almacenamiento ---------------------------------"
    Write-Host "  3) $sFSRM  Instalar FSRM"
    Write-Host "             $sCuot  Cuotas (10 MB Cuates / 5 MB NoCuates) + Apantallamiento activo"
    Write-Host ""
    Write-Host "  -- Control de Ejecucion --------------------------------------"
    Write-Host "  4) $sAppL  Configurar AppLocker"
    Write-Host "             Cuates: Notepad permitido | NoCuates: Notepad bloqueado por hash"
    Write-Host ""
    Write-Host "  -- Politica de Cierre de Sesion ------------------------------"
    Write-Host "  5) $sGPO  GPO: Forzar cierre de sesion al vencer el horario"
    Write-Host ""
    Write-Host "  -- Clientes Externos (Linux / Windows) -----------------------"
    Write-Host "  6) $sCli  Gestionar clientes: horarios, cuotas, disco, AppLocker"
    Write-Host "             Linux: $Script:AD_CLIENTE_LINUX  |  Windows: $(if ([string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) { '(sin configurar)' } else { $Script:AD_CLIENTE_WIN })"
    Write-Host ""
    Write-Host "  -- Utiles ----------------------------------------------------"
    Write-Host "  a)  Ejecutar TODOS los pasos en orden (1-5)"
    Write-Host "  v)  Verificacion general del sistema"
    Write-Host "  r)  Refrescar estado del menu"
    Write-Host ""
    Write-Host "  0)  Salir"
    Write-Host ""
}

# ------------------------------------------------------------
# Verificacion general
# ------------------------------------------------------------

function _verificacion_general {
    Clear-Host
    ad_mostrar_banner "Verificacion General -- Practica 8"

    if (-not (ad_verificar_modulo_ad)) { pause; return }

    Write-Host ""
    draw_line

    # AD
    aputs_info "Dominio AD:"
    try {
        $dom = Get-ADDomain
        Write-Host ("    {0,-25} : {1}" -f "DNSRoot",          $dom.DNSRoot)
        Write-Host ("    {0,-25} : {1}" -f "NetBIOS",          $dom.NetBIOSName)
        Write-Host ("    {0,-25} : {1}" -f "PDC Emulator",     $dom.PDCEmulator)
    } catch { aputs_error "  Error leyendo dominio: $_" }

    Write-Host ""
    ad_verificar_estructura 2>$null

    Write-Host ""
    draw_line
    horario_verificar 2>$null

    Write-Host ""
    draw_line
    fsrm_verificar 2>$null

    Write-Host ""
    draw_line
    applocker_verificar 2>$null

    Write-Host ""
    draw_line
    gpo_verificar_cierre_sesion 2>$null

    Write-Host ""
    draw_line

    pause
}

# ------------------------------------------------------------
# Ejecutar todos los pasos en orden
# ------------------------------------------------------------

function _todos_los_pasos {
    Clear-Host
    ad_mostrar_banner "Configuracion Completa -- Pasos 1 al 5"

    Write-Host ""
    Write-Host "  Se ejecutaran todos los pasos de configuracion en orden."
    Write-Host "  Esto puede tardar varios minutos."
    Write-Host ""
    $confirm = Read-Host "  Desea continuar? [S/n]"
    if ($confirm -match '^[nN]$') {
        aputs_info "Operacion cancelada"
        pause
        return
    }

    Write-Host ""

    try {
        aputs_info ">>> Paso 1: Estructura AD"
        ad_estructura_completa
        _refrescar_estado

        aputs_info ">>> Paso 2: Horarios de acceso"
        horario_configurar_completo
        _refrescar_estado

        aputs_info ">>> Paso 3: FSRM"
        fsrm_configurar_completo
        _refrescar_estado

        aputs_info ">>> Paso 4: AppLocker"
        applocker_configurar_completo
        _refrescar_estado

        aputs_info ">>> Paso 5: GPO cierre de sesion"
        gpo_configurar_cierre_sesion_completo
        _refrescar_estado

    } catch {
        aputs_error "Error durante la configuracion: $_"
        pause
    }
}

# ------------------------------------------------------------
# Menu principal
# ------------------------------------------------------------

function main_menu {
    _refrescar_estado

    while ($true) {
        _dibujar_menu

        $Host.UI.RawUI.FlushInputBuffer()
        $op = Read-Host "  Opcion"

        switch ($op.Trim().ToLower()) {
            "1" { ad_estructura_completa;                _refrescar_estado }
            "2" { horario_configurar_completo;           _refrescar_estado }
            "3" { fsrm_configurar_completo;              _refrescar_estado }
            "4" { applocker_configurar_completo;         _refrescar_estado }
            "5" { gpo_configurar_cierre_sesion_completo; _refrescar_estado }
            "6" { clientes_menu_principal;               _refrescar_estado }
            "a" { _todos_los_pasos }
            "v" { _verificacion_general }
            "r" { _refrescar_estado }
            "0" {
                Write-Host ""
                aputs_info "Saliendo de la Practica 8..."
                Write-Host ""
                exit 0
            }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ------------------------------------------------------------
# Punto de entrada
# ------------------------------------------------------------

_verificar_estructura

# Cargar utils y modulos en scope del script
. (Join-Path $Script:P8_DIR "utils.AD.ps1")

foreach ($mod in @(
    "modules\01-ad-estructura.ps1",
    "modules\02-horario-acceso.ps1",
    "modules\03-fsrm-cuotas.ps1",
    "modules\04-applocker.ps1",
    "modules\05-gpo-cierre-sesion.ps1",
    "modules\06-clientes.ps1"
)) {
    $ruta = Join-Path $Script:P8_DIR $mod
    if (Test-Path $ruta) { . $ruta }
}

main_menu
