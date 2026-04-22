# gpo_redirecciones.ps1 -- Fase 5: GPO de redireccion de carpetas
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Carpetas redirigidas:
#   Documents  -> \\servidor\documentos\%username%\Documents
#   Desktop    -> \\servidor\perfiles\%username%\Desktop
#   AppData    -> \\servidor\perfiles\%username%\AppData (selectiva)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 5 -- GPO Redireccion de Carpetas"
Ensure-OutputDir

$LogFile  = "$($Global:OutputDir)\fase5_perfiles.log"
$Servidor = $env:COMPUTERNAME
$GPOName  = "P9_FolderRedirection"
p9_log $LogFile "=== INICIO: GPO Redirecciones ==="

# ---- Verificar modulo GPO ----
if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
    p9_error "Modulo GroupPolicy no disponible. Instale RSAT-GroupPolicy."
    exit 1
}
Import-Module GroupPolicy -ErrorAction SilentlyContinue

# ---- Crear GPO ----
p9_info "Creando GPO: $GPOName"
try {
    $gpo = Get-GPO -Name $GPOName -Domain $Global:Dominio -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $GPOName -Domain $Global:Dominio `
            -Comment "Redireccion de carpetas perfiles moviles -- P09" -ErrorAction Stop
        p9_ok "GPO creada: $GPOName (ID: $($gpo.Id))"
        p9_log $LogFile "GPO $GPOName creada: $($gpo.Id)"
    } else {
        p9_info "GPO ya existe: $GPOName"
    }
} catch {
    p9_error "Error creando GPO: $_"
    exit 1
}

# ---- Vincular GPO a OUs de usuarios ----
p9_info "Vinculando GPO a OUs de usuarios..."
$OUs_Link = @($Global:OU_Cuates, $Global:OU_NoCuates)

foreach ($ou in $OUs_Link) {
    $ouNombre = ($ou -split ",")[0] -replace "OU=",""
    try {
        New-GPLink -Name $GPOName -Target $ou -LinkEnabled Yes `
            -Domain $Global:Dominio -ErrorAction Stop
        p9_ok "  GPO vinculada a: $ouNombre"
        p9_log $LogFile "GPO vinculada a $ou"
    } catch {
        if ($_ -match "already") {
            p9_info "  GPO ya vinculada a: $ouNombre"
        } else {
            p9_warning "  Error vinculando a $ou : $_"
        }
    }
}

Write-Host ""

# ---- Configurar redireccion via registro GPO (User Config) ----
# Las redirecciones de carpetas se configuran en:
# HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders
# Pero se aplican via GPO en la rama Software\Policies\...

p9_info "Configurando redirecciones en GPO via Set-GPRegistryValue..."

$gpoId = $gpo.Id.ToString()

$redirecciones = @(
    @{
        Carpeta = "Personal"  # Documents
        RegKey  = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        RegVal  = "Personal"
        Ruta    = "\\$Servidor\documentos\%USERNAME%\Documents"
    },
    @{
        Carpeta = "Desktop"
        RegKey  = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        RegVal  = "Desktop"
        Ruta    = "\\$Servidor\perfiles\%USERNAME%\Desktop"
    },
    @{
        Carpeta = "AppData"
        RegKey  = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        RegVal  = "AppData"
        Ruta    = "\\$Servidor\perfiles\%USERNAME%\AppData\Roaming"
    },
    @{
        Carpeta = "Downloads"
        RegKey  = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        RegVal  = "{374DE290-123F-4565-9164-39C4925E467B}"
        Ruta    = "\\$Servidor\documentos\%USERNAME%\Downloads"
    }
)

foreach ($redir in $redirecciones) {
    try {
        Set-GPRegistryValue -Name $GPOName -Domain $Global:Dominio `
            -Key    $redir.RegKey `
            -ValueName $redir.RegVal `
            -Value  $redir.Ruta `
            -Type   ExpandString `
            -ErrorAction Stop
        p9_ok "  Redireccion $($redir.Carpeta): $($redir.Ruta)"
        p9_log $LogFile "Redireccion $($redir.Carpeta) -> $($redir.Ruta)"
    } catch {
        p9_warning "  Error redireccion $($redir.Carpeta): $_"
        p9_log $LogFile "WARN redireccion $($redir.Carpeta): $_"
    }
}

Write-Host ""

# ---- Habilitar Folder Redirection en GPO ----
# Configuracion adicional: no redirigir si red no disponible
p9_info "Configurando comportamiento offline (redireccion solo con red)..."
try {
    Set-GPRegistryValue -Name $GPOName -Domain $Global:Dominio `
        -Key "HKCU\Software\Policies\Microsoft\Windows\System" `
        -ValueName "FolderRedirectionEnableBFCache" `
        -Value 1 -Type DWord -ErrorAction Stop
    p9_ok "FolderRedirectionEnableBFCache = 1 (cache local activo)"
} catch {
    p9_warning "Error config cache: $_"
}

# ---- Forzar actualizacion de GPO ----
p9_info "Forzando actualizacion de GPO..."
try {
    Invoke-GPUpdate -Force -RandomDelayInMinutes 0 -ErrorAction SilentlyContinue
    p9_ok "gpupdate ejecutado."
} catch {
    p9_warning "gpupdate no disponible en este contexto."
}

# ---- Resumen ----
p9_linea
p9_info "Detalle de la GPO configurada:"
try {
    $gpoDetalle = Get-GPO -Name $GPOName -Domain $Global:Dominio
    Write-Host "    Nombre:  $($gpoDetalle.DisplayName)"
    Write-Host "    ID:      $($gpoDetalle.Id)"
    Write-Host "    Estado:  $($gpoDetalle.GpoStatus)"
    Write-Host "    Modif:   $($gpoDetalle.ModificationTime)"
} catch {}

p9_log $LogFile "=== FIN: GPO Redirecciones ==="
p9_ok "GPO de redireccion de carpetas configurada."
p9_pausa
