#Requires -RunAsAdministrator
#
# MenuSrv.ps1 -- Menu interactivo servidor Practica 8
# Logica: YuckierOlive370/Tarea8GCC  |  Diseno visual: estilo del proyecto
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File "MenuSrv.ps1"
#

$Script:SRV_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Script:SRV_DIR "FunSrv.ps1")

# ============================================================
# INDICADORES DE ESTADO
# ============================================================

function _icono { param([bool]$c) if ($c) {"[*]"} else {"[ ]"} }

function _st_csv {
    return (Test-Path $Global:CsvPath)
}
function _st_ad {
    try { return ((Get-WmiObject Win32_ComputerSystem).DomainRole -eq 5) } catch { return $false }
}
function _st_ous {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop | Out-Null
        $c  = Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'"   -ErrorAction SilentlyContinue
        $nc = Get-ADOrganizationalUnit -Filter "Name -eq 'NoCuates'" -ErrorAction SilentlyContinue
        return ($null -ne $c -and $null -ne $nc)
    } catch { return $false }
}
function _st_usuarios {
    try {
        $total = @(Get-ADUser -Filter * -SearchBase "OU=Cuates,DC=p8,DC=local"   -EA SilentlyContinue).Count +
                 @(Get-ADUser -Filter * -SearchBase "OU=NoCuates,DC=p8,DC=local" -EA SilentlyContinue).Count
        return ($total -gt 0)
    } catch { return $false }
}
function _st_horarios {
    try {
        $u = Get-ADGroupMember -Identity "GRP_Cuates" -EA SilentlyContinue | Select-Object -First 1
        if (-not $u) { return $false }
        return ($null -ne (Get-ADUser $u.SamAccountName -Properties logonHours -EA SilentlyContinue).logonHours)
    } catch { return $false }
}
function _st_fsrm {
    try { return ((Get-WindowsFeature -Name FS-Resource-Manager -EA SilentlyContinue).Installed) } catch { return $false }
}
function _st_cuotas {
    try {
        Import-Module FileServerResourceManager -EA SilentlyContinue | Out-Null
        return (@(Get-FsrmQuota -EA SilentlyContinue).Count -gt 0)
    } catch { return $false }
}
function _st_screens {
    try {
        Import-Module FileServerResourceManager -EA SilentlyContinue | Out-Null
        return (@(Get-FsrmFileScreen -EA SilentlyContinue).Count -gt 0)
    } catch { return $false }
}
function _st_applocker {
    try { return ((Get-Service AppIDSvc -EA SilentlyContinue).Status -eq "Running") } catch { return $false }
}
function _st_gpo {
    try {
        Import-Module GroupPolicy -EA SilentlyContinue | Out-Null
        return ($null -ne (Get-GPO -Name "GPO-CierreHorario" -EA SilentlyContinue))
    } catch { return $false }
}

function _refrescar {
    $Script:_csv  = _st_csv
    $Script:_ad   = _st_ad
    $Script:_ous  = _st_ous
    $Script:_us   = _st_usuarios
    $Script:_hor  = _st_horarios
    $Script:_fsrm = _st_fsrm
    $Script:_cut  = _st_cuotas
    $Script:_scr  = _st_screens
    $Script:_apl  = _st_applocker
    $Script:_gpo  = _st_gpo
}

# ============================================================
# MENU PRINCIPAL
# ============================================================

function _dibujar_menu {
    Clear-Host
    $i1 = _icono $Script:_csv
    $i2 = _icono $Script:_ad
    $i3 = _icono $Script:_ous
    $i4 = _icono $Script:_us
    $i5 = _icono $Script:_hor
    $i6 = _icono $Script:_fsrm
    $i7 = _icono $Script:_cut
    $i8 = _icono $Script:_scr
    $i9 = _icono $Script:_apl
    $i10= _icono $Script:_gpo

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    Practica 08 -- Servidor AD  (MenuSrv)"
    Write-Host "  =========================================================="
    Write-Host ""
    Write-Host "  Dominio: $Global:Dominio   NetBIOS: $Global:NetBIOS"
    Write-Host "  Homes  : $Global:HomesBase   CSV: $Global:CsvPath"
    Write-Host ""
    Write-Host "  -- Fase 1: Preparacion previa al reinicio -------------------"
    Write-Host "  1) $i1  Crear CSV de usuarios en C:\Scripts"
    Write-Host "  2) $i2  Instalar AD DS  ** REINICIA EL SERVIDOR **" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  -- Fase 3: Configurar dominio (post-reinicio) ---------------"
    Write-Host "  3) Ejecutar TODA la Fase 3 en orden (recomendado)"
    Write-Host "  ----------------------------------------------------------"
    Write-Host "  4) $i3  Solo: Crear OUs (Cuates / NoCuates) y Grupos"
    Write-Host "  5)     Solo: Crear Share Homes"
    Write-Host "  6) $i4  Solo: Importar usuarios desde CSV"
    Write-Host "  7) $i5  Solo: Aplicar horarios de acceso (Logon Hours)"
    Write-Host "  8) $i10  Solo: Crear GPO de cierre por horario"
    Write-Host "  9) $i7  Solo: Configurar cuotas FSRM"
    Write-Host "  10)$i8  Solo: Configurar apantallamiento de archivos"
    Write-Host "  11)$i9  Solo: Habilitar AppIDSvc"
    Write-Host ""
    Write-Host "  -- Utiles ---------------------------------------------------"
    Write-Host "  v)  Verificacion final del dominio"
    Write-Host "  r)  Refrescar indicadores de estado"
    Write-Host "  0)  Salir"
    Write-Host ""
}

# ============================================================
# LOOP PRINCIPAL
# ============================================================

_refrescar

do {
    _dibujar_menu
    $op = Read-Host "  Opcion"

    switch ($op.Trim().ToLower()) {

        "1" {
            Invoke-Preparacion
            _refrescar
        }
        "2" {
            Write-Host ""
            srv_warning "El servidor se REINICIARA al completar la instalacion."
            $c = Read-Host "  Confirmar? (S/N)"
            if ($c -match '^[sS]$') { Invoke-InstalarAD }
        }
        "3" {
            Invoke-ConfigurarDominio
            _refrescar
        }
        "4" {
            Write-Host ""
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null
            New-OUsYGrupos
            _refrescar
        }
        "5" {
            Write-Host ""
            New-ShareHomes
        }
        "6" {
            Write-Host ""
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null
            $usuarios = Import-Csv $Global:CsvPath -Encoding UTF8
            New-UsuariosDesdeCSV -Usuarios $usuarios
            _refrescar
        }
        "7" {
            Write-Host ""
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null
            $usuarios = Import-Csv $Global:CsvPath -Encoding UTF8
            Set-HorariosLogon -Usuarios $usuarios
            _refrescar
        }
        "8" {
            Write-Host ""
            Import-Module GroupPolicy -ErrorAction SilentlyContinue | Out-Null
            New-GPOCierreHorario
            _refrescar
        }
        "9" {
            Write-Host ""
            Import-Module FileServerResourceManager -ErrorAction SilentlyContinue | Out-Null
            $usuarios = Import-Csv $Global:CsvPath -Encoding UTF8
            New-CuotasFSRM -Usuarios $usuarios
            _refrescar
        }
        "10" {
            Write-Host ""
            Import-Module FileServerResourceManager -ErrorAction SilentlyContinue | Out-Null
            $usuarios = Import-Csv $Global:CsvPath -Encoding UTF8
            New-FileScreeningFSRM -Usuarios $usuarios
            _refrescar
        }
        "11" {
            Write-Host ""
            Enable-AppIDSvc
            _refrescar
        }
        "v" {
            Import-Module ActiveDirectory, GroupPolicy, FileServerResourceManager `
                -ErrorAction SilentlyContinue | Out-Null
            Invoke-VerificacionFinal
        }
        "r" { _refrescar }
        "0" {
            Write-Host ""
            srv_info "Saliendo..."
            Write-Host ""
        }
        default {
            srv_error "Opcion no valida"
            Start-Sleep -Seconds 1
        }
    }

    if ($op -ne "0") {
        Write-Host ""
        Write-Host "  Presione ENTER para volver al menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

} while ($op -ne "0")
