#Requires -RunAsAdministrator
#
# MenuCliente.ps1 -- Menu interactivo para el cliente Windows (Practica 8)
# Ejecutar en el equipo CLIENTE despues de conectarlo a la red del DC.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File "MenuCliente.ps1"
#

$Script:WC_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $Script:WC_DIR "FunCliente.ps1")

# ------------------------------------------------------------
# Indicadores de estado
# ------------------------------------------------------------

function _icono { param([bool]$c) if ($c) { "[*]" } else { "[ ]" } }

function _estado_dominio {
    try {
        $eq = Get-WmiObject Win32_ComputerSystem
        return ($eq.PartOfDomain -and $eq.Domain -eq $Global:WC_DomainName)
    } catch { return $false }
}

function _estado_applocker {
    try {
        $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
        $pol = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
        return ($svc -and $svc.Status -eq "Running" -and $null -ne $pol)
    } catch { return $false }
}

# ------------------------------------------------------------
# Dibujar menu
# ------------------------------------------------------------

function _dibujar_menu {
    Clear-Host

    $sDom  = _icono (_estado_dominio)
    $sAppL = _icono (_estado_applocker)

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    Practica 08 -- Cliente Windows"
    Write-Host "  =========================================================="
    Write-Host ""
    Write-Host "  Dominio objetivo : $Global:WC_DomainName"
    Write-Host ""
    Write-Host "  -- Fases Principales -----------------------------------------"
    Write-Host "  1) $sDom  FASE 1 - Unirse al dominio  ** REINICIA EL EQUIPO **" -ForegroundColor Yellow
    Write-Host "  2) $sAppL  FASE 2 - Configurar AppLocker (post-reinicio)"
    Write-Host ""
    Write-Host "  -- Pasos Individuales ----------------------------------------"
    Write-Host "  3)  Solo: Detectar interfaz de red"
    Write-Host "  4)  Solo: Configurar DNS hacia el DC"
    Write-Host "  5)  Solo: Verificar resolucion DNS"
    Write-Host "  6)  Solo: Obtener hashes de notepad.exe"
    Write-Host "  7)  Solo: Generar XML de AppLocker"
    Write-Host "  8)  Solo: Aplicar politica AppLocker"
    Write-Host "  9)  Solo: Habilitar AppIDSvc"
    Write-Host ""
    Write-Host "  -- Utiles ----------------------------------------------------"
    Write-Host "  10) Ver resumen y politica efectiva"
    Write-Host "  r)  Refrescar estado del menu"
    Write-Host ""
    Write-Host "  0)  Salir"
    Write-Host ""
}

# ------------------------------------------------------------
# Menu principal
# ------------------------------------------------------------

do {
    _dibujar_menu
    $opcion = Read-Host "  Opcion"

    switch ($opcion.Trim().ToLower()) {
        "1" {
            Write-Host ""
            Write-Host "  >> El equipo se REINICIARA al unirse al dominio." -ForegroundColor Yellow
            $confirmar = Read-Host "  Confirmar? (S/N)"
            if ($confirmar -match '^[sS]$') { Invoke-UnirDominio }
        }
        "2" {
            Write-Host ""
            Write-Host "  >> Configurando AppLocker (post-reinicio)..." -ForegroundColor Cyan
            Invoke-ConfigAppLocker
        }
        "3" {
            Write-Host ""
            Write-Host "  >> Detectando interfaz de red..." -ForegroundColor Cyan
            Get-InterfazRed | Out-Null
        }
        "4" {
            Write-Host ""
            Write-Host "  >> Configurando DNS hacia el DC..." -ForegroundColor Cyan
            $ip = Read-Host "  IP del controlador de dominio"
            Set-DnsHaciasDC -IpDC $ip
        }
        "5" {
            Write-Host ""
            Write-Host "  >> Verificando resolucion DNS..." -ForegroundColor Cyan
            Test-ResolucionDominio | Out-Null
        }
        "6" {
            Write-Host ""
            Write-Host "  >> Obteniendo hashes de notepad.exe..." -ForegroundColor Cyan
            Get-HashesNotepad | Out-Null
        }
        "7" {
            Write-Host ""
            Write-Host "  >> Generando XML de AppLocker..." -ForegroundColor Cyan
            $hashes = Get-HashesNotepad
            New-AppLockerXml -Hashes $hashes | Out-Null
        }
        "8" {
            Write-Host ""
            Write-Host "  >> Aplicando politica AppLocker..." -ForegroundColor Cyan
            if (-not (Test-Path $Global:WC_AppLockerXml)) {
                Write-Host "  ERROR: XML no encontrado. Ejecuta opcion [7] primero." -ForegroundColor Red
            } else {
                Enable-AppIDSvc
                Set-AppLockerPolicyLocal
            }
        }
        "9" {
            Write-Host ""
            Write-Host "  >> Habilitando AppIDSvc..." -ForegroundColor Cyan
            Enable-AppIDSvc
        }
        "10" {
            Write-Host ""
            Write-Host "  >> Mostrando resumen y politica efectiva..." -ForegroundColor Green
            Show-ResumenAppLocker
        }
        "r" {
            # Solo redibujar el menu
        }
        "0" {
            Write-Host ""
            Write-Host "  Saliendo..." -ForegroundColor Red
            break
        }
        default {
            Write-Host ""
            Write-Host "  Opcion no valida." -ForegroundColor Red
        }
    }

    if ($opcion -ne "0") {
        Write-Host ""
        Write-Host "  Presione ENTER para volver al menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

} while ($opcion -ne "0")
