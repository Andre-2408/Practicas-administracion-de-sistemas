#Requires -RunAsAdministrator
#
# pruebas.ps1 -- Pruebas de la Practica 8
# Logica: YuckierOlive370/Tarea8GCC  |  Diseno visual: estilo del proyecto
#
# Ejecutar en el cliente Windows (con sesion de usuario de dominio activa).
# Uso: powershell -ExecutionPolicy Bypass -File "pruebas.ps1"
#

# ============================================================
# VARIABLES
# ============================================================
$Global:ServidorIP  = "192.168.92.132"
$Global:HomesShare  = "Homes"

# ============================================================
# HELPERS
# ============================================================
function p_info    { param($m) Write-Host "  [INFO]    $m" }
function p_ok      { param($m) Write-Host "  [OK]      $m" -ForegroundColor Green }
function p_error   { param($m) Write-Host "  [ERROR]   $m" -ForegroundColor Red }
function p_warning { param($m) Write-Host "  [AVISO]   $m" -ForegroundColor Yellow }
function p_linea   { Write-Host "  ----------------------------------------------------------" }
function p_banner  {
    param([string]$t = "Practica 08 -- Pruebas")
    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    $t"
    Write-Host "  =========================================================="
    Write-Host ""
}
function p_pausa {
    Write-Host ""
    Write-Host "  Presione ENTER para continuar..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ============================================================
# MONTAR / DESMONTAR UNIDAD H:
# ============================================================

function Mount-UnidadHomes {
    param([Parameter(Mandatory)][string]$Usuario)

    $ruta = "\\$Global:ServidorIP\$Global:HomesShare\$Usuario"
    p_info "Montando H: -> $ruta"

    net use H: $ruta /persistent:yes 2>&1 | Out-Null

    if (Get-PSDrive H -ErrorAction SilentlyContinue) {
        p_ok "H: montada correctamente en $ruta"
        return $true
    } else {
        p_error "No se pudo montar H:"
        return $false
    }
}

function Dismount-UnidadHomes {
    p_info "Desmontando H:..."
    net use H: /delete /yes 2>&1 | Out-Null
    p_ok "H: desmontada"
}

function Show-EstadoH {
    p_info "Estado de la unidad H:"
    $drive = Get-PSDrive H -ErrorAction SilentlyContinue
    if ($drive) {
        $usadoMB = [Math]::Round($drive.Used  / 1MB, 2)
        $libreMB = [Math]::Round($drive.Free  / 1MB, 2)
        Write-Host ("    {0,-20} : {1}" -f "Montada en",  $drive.Root)
        Write-Host ("    {0,-20} : {1} MB" -f "Usado",    $usadoMB)
        Write-Host ("    {0,-20} : {1} MB" -f "Libre",    $libreMB)
    } else {
        p_warning "H: no esta montada"
    }
}

# ============================================================
# PRUEBA 1: CUOTA FSRM
# Escribe un archivo del tamano indicado en H:
# smendez  -> limite 5 MB  -> probar con 6 MB
# cramirez -> limite 10 MB -> probar con 11 MB
# ============================================================

function Test-CuotaFSRM {
    param(
        [Parameter(Mandatory)][string]$Usuario,
        [Parameter(Mandatory)][int]   $TamanoMB
    )

    $archivo = "H:\prueba_cuota_${TamanoMB}mb.dat"
    p_info "Cuota FSRM: intentando escribir ${TamanoMB} MB en H: (usuario: $Usuario)"

    try {
        $buf = New-Object byte[] ($TamanoMB * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($archivo, $buf)
        p_warning "RESULTADO: Archivo escrito -- la cuota NO bloqueo (revisar configuracion)"
    } catch {
        p_ok "RESULTADO: BLOQUEADO por cuota FSRM (correcto para $Usuario)"
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    } finally {
        Remove-Item $archivo -ErrorAction SilentlyContinue
    }
}

# ============================================================
# PRUEBA 2: APANTALLAMIENTO DE ARCHIVOS (File Screening)
# Copia un archivo con extension prohibida a H:
# Extensiones bloqueadas: .mp3 .mp4 .exe .msi
# ============================================================

function Test-FileScreening {
    param([Parameter(Mandatory)][string]$Extension)

    $origen  = "$env:SystemRoot\System32\notepad.exe"
    $destino = "H:\prueba_screen.$Extension"

    p_info "File Screening: copiando notepad.exe como .$Extension a H:"

    try {
        Copy-Item $origen $destino -ErrorAction Stop
        p_warning "RESULTADO: Archivo copiado -- el apantallamiento NO bloqueo (revisar configuracion)"
        Remove-Item $destino -ErrorAction SilentlyContinue
    } catch {
        p_ok "RESULTADO: BLOQUEADO por File Screening FSRM (correcto)"
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ============================================================
# PRUEBA 3: APPLOCKER
# Intenta abrir notepad.exe y verifica si fue bloqueado
# NoCuates (smendez)  -> debe BLOQUEARSE
# Cuates   (cramirez) -> debe ABRIRSE
# ============================================================

function Test-AppLocker {
    param([Parameter(Mandatory)][string]$Usuario)

    $notepad = "$env:SystemRoot\System32\notepad.exe"
    p_info "AppLocker: intentando abrir notepad como sesion de $Usuario"

    try {
        $proc = Start-Process $notepad -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        if (-not $proc.HasExited) {
            p_ok "RESULTADO: notepad ABIERTO (esperado para GRP_Cuates)"
            $proc.Kill()
        } else {
            p_warning "RESULTADO: notepad se cerro inmediatamente (posible bloqueo AppLocker)"
        }
    } catch {
        p_ok "RESULTADO: BLOQUEADO por AppLocker (correcto para GRP_NoCuates)"
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ============================================================
# PRUEBA COMPLETA PARA UN USUARIO
# ============================================================

function Invoke-PruebaCompleta {
    param(
        [Parameter(Mandatory)][string]$Usuario,
        [Parameter(Mandatory)][int]   $TamanoMB
    )

    p_banner "Prueba Completa: $Usuario"

    p_linea
    p_info "PASO 1: Montar H:"
    if (-not (Mount-UnidadHomes -Usuario $Usuario)) { p_pausa; return }
    Show-EstadoH

    p_linea
    p_info "PASO 2: Cuota FSRM (limite esperado: $($TamanoMB - 1) MB)"
    Test-CuotaFSRM -Usuario $Usuario -TamanoMB $TamanoMB

    p_linea
    p_info "PASO 3: Apantallamiento -- .mp3"
    Test-FileScreening -Extension "mp3"

    p_linea
    p_info "PASO 4: Apantallamiento -- .mp4"
    Test-FileScreening -Extension "mp4"

    p_linea
    p_info "PASO 5: AppLocker -- notepad.exe"
    Test-AppLocker -Usuario $Usuario

    p_linea
    Dismount-UnidadHomes
    p_linea
    p_ok "Prueba completa para '$Usuario' finalizada"
}

# ============================================================
# DIBUJAR MENU
# ============================================================

function _dibujar_menu {
    Clear-Host

    $hMontada = $null -ne (Get-PSDrive H -ErrorAction SilentlyContinue)
    $iH = if ($hMontada) {"[*]"} else {"[ ]"}

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    Practica 08 -- Pruebas y Validacion"
    Write-Host "  =========================================================="
    Write-Host ""
    Write-Host "  Servidor : $Global:ServidorIP   Share: \\$Global:ServidorIP\$Global:HomesShare"
    Write-Host "  Unidad H : $iH  $(if ($hMontada) { (Get-PSDrive H).Root } else { 'no montada' })"
    Write-Host ""
    Write-Host "  -- Pruebas Completas -----------------------------------------"
    Write-Host "  1)  smendez  (NoCuates) -- cuota 5 MB  | screen | AppLocker bloqueado"
    Write-Host "  2)  cramirez (Cuates)   -- cuota 10 MB | screen | AppLocker permitido"
    Write-Host ""
    Write-Host "  -- Pruebas Individuales --------------------------------------"
    Write-Host "  3)  Montar H:  (pide usuario)"
    Write-Host "  4)  Desmontar H:"
    Write-Host "  5)  Ver estado de H:"
    Write-Host "  6)  Probar cuota FSRM  (pide usuario y MB)"
    Write-Host "  7)  Probar File Screening .mp3"
    Write-Host "  8)  Probar File Screening .mp4"
    Write-Host "  9)  Probar AppLocker  (pide usuario)"
    Write-Host ""
    Write-Host "  -- Utiles ----------------------------------------------------"
    Write-Host "  r)  Refrescar menu"
    Write-Host "  0)  Salir"
    Write-Host ""
}

# ============================================================
# LOOP PRINCIPAL
# ============================================================

do {
    _dibujar_menu
    $op = Read-Host "  Opcion"

    switch ($op.Trim().ToLower()) {
        "1" {
            p_banner "Prueba Completa: smendez (NoCuates, limite 5 MB)"
            Invoke-PruebaCompleta -Usuario "smendez" -TamanoMB 6
        }
        "2" {
            p_banner "Prueba Completa: cramirez (Cuates, limite 10 MB)"
            Invoke-PruebaCompleta -Usuario "cramirez" -TamanoMB 11
        }
        "3" {
            $usr = Read-Host "  Nombre de usuario"
            Mount-UnidadHomes -Usuario $usr
        }
        "4" {
            Dismount-UnidadHomes
        }
        "5" {
            Show-EstadoH
        }
        "6" {
            $usr = Read-Host "  Nombre de usuario"
            $mb  = [int](Read-Host "  Tamano en MB a escribir")
            Mount-UnidadHomes -Usuario $usr | Out-Null
            Test-CuotaFSRM -Usuario $usr -TamanoMB $mb
        }
        "7" {
            Test-FileScreening -Extension "mp3"
        }
        "8" {
            Test-FileScreening -Extension "mp4"
        }
        "9" {
            $usr = Read-Host "  Usuario logueado actualmente"
            Test-AppLocker -Usuario $usr
        }
        "r" { }
        "0" {
            Write-Host ""
            p_info "Saliendo..."
            Write-Host ""
        }
        default {
            p_error "Opcion no valida"
            Start-Sleep -Seconds 1
        }
    }

    if ($op -ne "0") {
        Write-Host ""
        Write-Host "  Presione ENTER para volver al menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

} while ($op -ne "0")
