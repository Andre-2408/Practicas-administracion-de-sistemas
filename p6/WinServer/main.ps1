#
# main.ps1
# Punto de entrada — Gestor de Servicios HTTP en Windows Server
#
# Estructura del proyecto:
#   main.ps1               <- este archivo (dot-source + menu principal)
#   utils.ps1              <- utilidades base (colores, aputs_*, draw_*, pause, agets)
#   utilsHTTP.ps1          <- constantes globales y helpers HTTP
#   validators.ps1         <- validaciones de entrada
#   FunctionsHTTP-A.ps1    <- Grupo A: Verificacion de estado
#   FunctionsHTTP-B.ps1    <- Grupo B: Instalacion de servicios
#   FunctionsHTTP-C.ps1    <- Grupo C: Configuracion y seguridad
#   FunctionsHTTP-D.ps1    <- Grupo D: Gestion de versiones
#   FunctionsHTTP-E.ps1    <- Grupo E: Monitoreo
#

#Requires -Version 5.1
#Requires -RunAsAdministrator

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Capa 1: Base
. "$SCRIPT_DIR\utils.ps1"

# Capa 2: HTTP
. "$SCRIPT_DIR\utilsHTTP.ps1"

# Capa 3: Validacion
. "$SCRIPT_DIR\validators.ps1"

# Capa 4: Logica por grupos
. "$SCRIPT_DIR\FunctionsHTTP-A.ps1"
. "$SCRIPT_DIR\FunctionsHTTP-B.ps1"
. "$SCRIPT_DIR\FunctionsHTTP-C.ps1"
. "$SCRIPT_DIR\FunctionsHTTP-D.ps1"
. "$SCRIPT_DIR\FunctionsHTTP-E.ps1"

function main_menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
        Write-Host "  ${CYAN}║${NC}   Gestor de Servicios HTTP — Windows Server  ${CYAN}║${NC}"
        Write-Host "  ${CYAN}║${NC}   $env:COMPUTERNAME — $(Get-Date -Format 'HH:mm')                     ${CYAN}║${NC}"
        Write-Host "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Verificar estado de servicios HTTP"
        Write-Host "  ${BLUE}2)${NC} Instalar servicio HTTP"
        Write-Host "  ${BLUE}3)${NC} Configurar servicio"
        Write-Host "  ${BLUE}4)${NC} Monitoreo"
        Write-Host "  ${BLUE}5)${NC} Salir"
        Write-Host ""

        $op = Read-Host "  Opcion"

        if (-not (http_validar_opcion_menu $op 5)) {
            Start-Sleep -Seconds 2
            continue
        }

        switch ($op) {
            "1" { http_menu_verificar }
            "2" { http_menu_instalar }
            "3" { http_menu_configurar }
            "4" { http_menu_monitoreo }
            "5" {
                Clear-Host
                Write-Host ""
                aputs_info "Saliendo del Gestor HTTP..."
                Write-Host ""
                exit 0
            }
        }

        Write-Host ""
        pause_menu
    }
}

# Punto de entrada

if (-not (check_privileges)) {
    Write-Host ""
    aputs_error "Este script requiere permisos de Administrador."
    aputs_info  "Haga clic derecho en PowerShell y seleccione 'Ejecutar como administrador'."
    Write-Host ""
    exit 1
}

if (-not (http_verificar_dependencias)) {
    Write-Host ""
    aputs_error "Dependencias faltantes. Resuelva los errores antes de continuar."
    Write-Host ""
    pause_menu
    exit 1
}

Write-Host ""
pause_menu

http_detectar_rutas_reales

main_menu
