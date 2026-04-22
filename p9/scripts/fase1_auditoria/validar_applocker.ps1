# validar_applocker.ps1 -- Fase 1: Validar que AppLocker sigue activo (notepad bloqueado)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 1 -- Validacion AppLocker"
Ensure-OutputDir

$OutputFile = "$($Global:OutputDir)\diagnostico_baseline.txt"

p9_info "Verificando estado del servicio AppIDSvc..."
try {
    $svc = Get-Service -Name AppIDSvc -ErrorAction Stop
    if ($svc.Status -eq "Running") {
        p9_ok "Servicio AppIDSvc: RUNNING"
    } else {
        p9_warning "Servicio AppIDSvc estado: $($svc.Status)"
        p9_info "Intentando iniciar AppIDSvc..."
        Start-Service AppIDSvc -ErrorAction SilentlyContinue
    }
} catch {
    p9_error "No se pudo consultar AppIDSvc: $_"
}

Write-Host ""
p9_info "Obteniendo politicas AppLocker activas..."
try {
    $politicas = Get-AppLockerPolicy -Effective -ErrorAction Stop

    $reglas = @()
    foreach ($coleccion in $politicas.RuleCollections) {
        foreach ($regla in $coleccion) {
            $reglas += [PSCustomObject]@{
                Tipo        = $coleccion.GetType().Name
                Nombre      = $regla.Name
                Accion      = $regla.Action
                Descripcion = $regla.Description
            }
        }
    }

    if ($reglas.Count -gt 0) {
        p9_ok "Se encontraron $($reglas.Count) reglas AppLocker."
        Write-Host ""
        Write-Host "  --- Reglas AppLocker activas ---"
        p9_linea
        $reglas | ForEach-Object {
            $color = if ($_.Accion -eq "Deny") { "Red" } else { "Green" }
            Write-Host "    [$($_.Accion.ToUpper())] $($_.Nombre)" -ForegroundColor $color
        }
    } else {
        p9_warning "No se encontraron reglas AppLocker configuradas."
    }

    # Verificar regla especifica de notepad
    $notepadReg = $reglas | Where-Object { $_.Nombre -like "*notepad*" -or $_.Nombre -like "*Notepad*" }
    Write-Host ""
    if ($notepadReg) {
        p9_ok "CONFIRMADO: Regla de bloqueo para Notepad encontrada."
        $notepadReg | ForEach-Object { p9_info "  Regla: $($_.Nombre) -- Accion: $($_.Accion)" }
    } else {
        p9_warning "No se encontro regla explicita para Notepad. Verificar GPO de AppLocker."
    }

    # Append al baseline
    $seccion = @"

--- ESTADO APPLOCKER ---
Servicio AppIDSvc: $($svc.Status)
Total reglas: $($reglas.Count)
Regla Notepad: $(if ($notepadReg) { "ENCONTRADA -- Accion: $($notepadReg.Accion)" } else { "NO ENCONTRADA" })

Reglas detalladas:
$(($reglas | ForEach-Object { "  [$($_.Accion)] $($_.Nombre)" }) -join "`n")
"@
    Add-Content -Path $OutputFile -Value $seccion -Encoding UTF8

} catch {
    p9_error "Error al obtener politica AppLocker: $_"
    p9_warning "Asegurese de que AppLocker este configurado via GPO."
}

p9_linea
p9_ok "Validacion AppLocker completada."
p9_pausa
