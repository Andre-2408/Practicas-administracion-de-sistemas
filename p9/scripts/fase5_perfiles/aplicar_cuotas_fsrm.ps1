# aplicar_cuotas_fsrm.ps1 -- Fase 5: Cuotas FSRM para perfiles moviles
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Cuotas:
#   Usuarios estandar: 100 MB (hard limit)
#   Administradores:   500 MB (hard limit)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 5 -- Cuotas FSRM para Perfiles"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase5_perfiles.log"
p9_log $LogFile "=== INICIO: Cuotas FSRM Perfiles ==="

# Verificar FSRM instalado
try {
    Import-Module FileServerResourceManager -ErrorAction Stop
    p9_ok "Modulo FSRM cargado."
} catch {
    p9_error "FSRM no disponible. Instale: Install-WindowsFeature FS-Resource-Manager"
    p9_info "Ejecute: Install-WindowsFeature FS-Resource-Manager -IncludeManagementTools"
    exit 1
}

# ---- Crear plantillas de cuota ----
$plantillas = @(
    @{
        Nombre      = "P9_Perfil_Usuarios_100MB"
        Descripcion = "Practica 09 -- Cuota perfiles usuarios estandar 100 MB"
        LimiteMB    = 100
        TipoLimite  = "HardLimit"
    },
    @{
        Nombre      = "P9_Perfil_Admins_500MB"
        Descripcion = "Practica 09 -- Cuota perfiles administradores 500 MB"
        LimiteMB    = 500
        TipoLimite  = "HardLimit"
    }
)

foreach ($plantilla in $plantillas) {
    $limiteBytes = $plantilla.LimiteMB * 1MB
    p9_info "Creando plantilla: $($plantilla.Nombre) ($($plantilla.LimiteMB) MB)"

    try {
        $existePlantilla = Get-FsrmQuotaTemplate -Name $plantilla.Nombre -ErrorAction SilentlyContinue
        if ($existePlantilla) {
            Set-FsrmQuotaTemplate -Name $plantilla.Nombre `
                -Size $limiteBytes -SoftLimit:$false `
                -Description $plantilla.Descripcion -ErrorAction Stop
            p9_ok "  Plantilla actualizada: $($plantilla.Nombre)"
        } else {
            # Accion de notificacion al 85% y 95%
            $acc85 = New-FsrmAction Email `
                -MailTo "[Admin Email]" `
                -Subject "ALERTA: Usuario [Source Io Owner] al 85% del limite" `
                -Body "El usuario [Source Io Owner] ha alcanzado el 85% de su cuota en [Quota Path]." `
                -ErrorAction SilentlyContinue

            $thresh85 = New-FsrmQuotaThreshold -Percentage 85 -Action $acc85 -ErrorAction SilentlyContinue
            $thresh95 = New-FsrmQuotaThreshold -Percentage 95 -ErrorAction SilentlyContinue

            $params = @{
                Name        = $plantilla.Nombre
                Description = $plantilla.Descripcion
                Size        = $limiteBytes
                SoftLimit   = $false
            }
            if ($thresh85 -and $thresh95) {
                $params.Threshold = @($thresh85, $thresh95)
            }

            New-FsrmQuotaTemplate @params -ErrorAction Stop
            p9_ok "  Plantilla creada: $($plantilla.Nombre) -- $($plantilla.LimiteMB) MB Hard Limit"
            p9_log $LogFile "Plantilla FSRM creada: $($plantilla.Nombre)"
        }
    } catch {
        p9_warning "  Error con plantilla $($plantilla.Nombre): $_"
        p9_log $LogFile "ERROR plantilla: $($plantilla.Nombre) -- $_"
    }
}

Write-Host ""

# ---- Aplicar cuotas a carpetas de perfiles ----
$rutasPerfiles = @(
    @{ Ruta = "C:\Perfiles";   Plantilla = "P9_Perfil_Usuarios_100MB"; Tipo = "Usuarios" },
    @{ Ruta = "C:\Documentos"; Plantilla = "P9_Perfil_Usuarios_100MB"; Tipo = "Usuarios" }
)

p9_info "Aplicando cuotas a rutas de perfiles..."
foreach ($r in $rutasPerfiles) {
    if (-not (Test-Path $r.Ruta)) {
        p9_warning "  Ruta no existe (crear con Fase 5 scripts previos): $($r.Ruta)"
        continue
    }
    try {
        $existe = Get-FsrmQuota -Path $r.Ruta -ErrorAction SilentlyContinue
        if ($existe) {
            Update-FsrmQuota -Path $r.Ruta -ErrorAction Stop
            p9_info "  Cuota actualizada en: $($r.Ruta)"
        } else {
            New-FsrmQuota -Path $r.Ruta -Template $r.Plantilla -ErrorAction Stop
            p9_ok "  Cuota aplicada: $($r.Ruta) -> $($r.Plantilla) [$($r.Tipo)]"
            p9_log $LogFile "Cuota $($r.Plantilla) aplicada en $($r.Ruta)"
        }
    } catch {
        p9_warning "  Error en $($r.Ruta): $_"
    }
}

Write-Host ""

# ---- Cuotas especificas para carpetas admin (500 MB) ----
p9_info "Aplicando cuota 500 MB a carpetas de administradores..."
try {
    $admins = Get-ADUser -Filter * -SearchBase $Global:OU_Admins -ErrorAction SilentlyContinue
    foreach ($a in $admins) {
        $carpetaAdmin = "C:\Perfiles\$($a.SamAccountName)"
        if (Test-Path $carpetaAdmin) {
            try {
                $existe = Get-FsrmQuota -Path $carpetaAdmin -ErrorAction SilentlyContinue
                if ($existe) {
                    Set-FsrmQuota -Path $carpetaAdmin -Template "P9_Perfil_Admins_500MB" -ErrorAction Stop
                } else {
                    New-FsrmQuota -Path $carpetaAdmin -Template "P9_Perfil_Admins_500MB" -ErrorAction Stop
                }
                p9_ok "  500 MB para: $($a.SamAccountName)"
                p9_log $LogFile "Cuota 500MB admin: $($a.SamAccountName)"
            } catch {
                p9_warning "  Error admin $($a.SamAccountName): $_"
            }
        }
    }
} catch {
    p9_warning "Error procesando admins: $_"
}

# ---- Resumen cuotas ----
Write-Host ""
p9_info "Cuotas FSRM configuradas:"
p9_linea
try {
    Get-FsrmQuota | Select-Object Path, Size, SoftLimit, Usage | Format-Table -AutoSize
} catch {
    p9_warning "No se pudo listar cuotas."
}

p9_log $LogFile "=== FIN: Cuotas FSRM Perfiles ==="
p9_ok "Cuotas FSRM aplicadas. Usuarios: 100 MB | Admins: 500 MB."
p9_pausa
