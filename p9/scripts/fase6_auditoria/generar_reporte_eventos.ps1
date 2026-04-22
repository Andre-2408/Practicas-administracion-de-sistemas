# generar_reporte_eventos.ps1 -- Fase 6: Reporte final de auditoria (Test 5 formal)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Test 5: Ejecutar extraccion -> genera accesos_denegados.txt con ultimos 10 eventos 4625
# Compila TODOS los archivos de evidencia en un reporte final

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 6 -- Reporte Final de Eventos (Test 5)"
Ensure-OutputDir

$LogFile       = "$($Global:OutputDir)\fase6_auditoria.log"
$ReporteFinal  = "$($Global:OutputDir)\REPORTE_FINAL_P9.txt"
$EvidenciaFile = "$($Global:OutputDir)\test_auditoria_evidencia.txt"
p9_log $LogFile "=== INICIO: Reporte Final ==="

# ============================================================
# TEST 5: Extraccion formal de eventos 4625
# ============================================================
p9_linea
Write-Host "  TEST 5: Auditoria Automatizada (EventID 4625)"
p9_linea

# Llamar al script de extraccion
try {
    & "$PSScriptRoot\script_extraccion_4625.ps1"
    $accesosDenegados = "$($Global:OutputDir)\accesos_denegados.txt"
    $passTest5 = Test-Path $accesosDenegados
    if ($passTest5) {
        p9_ok "Test 5: accesos_denegados.txt generado. [PASS]"
    }
} catch {
    p9_error "Error ejecutando extraccion 4625: $_"
    $passTest5 = $false
}

Write-Host ""

# ============================================================
# Compilar reporte final con TODA la evidencia
# ============================================================
p9_info "Generando reporte final compilado..."

$separador = "=" * 60

$reporteContent = @"
$separador
  REPORTE FINAL -- PRACTICA 09
  Seguridad de Identidad, Delegacion y MFA

  Generado:  $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina:   $($env:COMPUTERNAME)
  Dominio:   $($Global:Dominio)
  Operador:  $($env:USERNAME)
$separador

"@

# ---- Estado de cada fase ----
$fases = @(
    @{ Nombre="Fase 1 - Auditoria Base";         Archivo="diagnostico_baseline.txt"       },
    @{ Nombre="Fase 2 - RBAC Delegacion";        Archivo="test_delegacion_evidencia.txt"  },
    @{ Nombre="Fase 3 - FGPP";                   Archivo="test_fgpp_evidencia.txt"        },
    @{ Nombre="Fase 4 - MFA";                    Archivo="test_mfa_evidencia.txt"         },
    @{ Nombre="Fase 5 - Perfiles Moviles";       Archivo="test_perfiles_evidencia.txt"    },
    @{ Nombre="Fase 6 - Auditoria Avanzada";     Archivo="accesos_denegados.txt"          }
)

$reporteContent += "--- ESTADO POR FASE ---`n`n"
foreach ($fase in $fases) {
    $ruta   = "$($Global:OutputDir)\$($fase.Archivo)"
    $existe = Test-Path $ruta
    $estado = if ($existe) { "[COMPLETADO]" } else { "[PENDIENTE] " }
    $reporteContent += "$estado $($fase.Nombre)`n"
    if ($existe) {
        $reporteContent += "           Evidencia: $ruta`n"
        $lines = (Get-Content $ruta -ErrorAction SilentlyContinue).Count
        $reporteContent += "           Lineas: $lines`n"
    }
    $reporteContent += "`n"
}

# ---- Incluir contenido de cada archivo de evidencia ----
foreach ($fase in $fases) {
    $ruta = "$($Global:OutputDir)\$($fase.Archivo)"
    if (Test-Path $ruta) {
        $reporteContent += "`n$separador`n"
        $reporteContent += "  $($fase.Nombre.ToUpper())`n"
        $reporteContent += "$separador`n`n"
        $reporteContent += (Get-Content $ruta -ErrorAction SilentlyContinue | Out-String)
        $reporteContent += "`n"
    }
}

# ---- Estado del sistema al momento del reporte ----
$reporteContent += "`n$separador`n"
$reporteContent += "  ESTADO DEL SISTEMA`n"
$reporteContent += "$separador`n`n"

# Usuarios admin creados
try {
    $admins = Get-ADUser -Filter * -SearchBase $Global:OU_Admins `
        -Properties Enabled, LockedOut -ErrorAction SilentlyContinue
    $reporteContent += "--- ADMINISTRADORES DELEGADOS ---`n"
    if ($admins) {
        foreach ($a in $admins) {
            $reporteContent += "  $($a.SamAccountName.PadRight(25)) Enabled:$($a.Enabled) Locked:$($a.LockedOut)`n"
        }
    }
} catch {}

# PSOs activas
$reporteContent += "`n--- FINE-GRAINED PASSWORD POLICIES ---`n"
try {
    $psos = Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction SilentlyContinue
    foreach ($p in $psos) {
        $reporteContent += "  $($p.Name.PadRight(30)) Prec:$($p.Precedence) MinLen:$($p.MinPasswordLength)`n"
    }
} catch { $reporteContent += "  No disponible`n" }

# Estado MFA
$reporteContent += "`n--- CONFIGURACION MFA ---`n"
try {
    $mfaConfig = Get-ItemProperty -Path "HKLM:\SOFTWARE\P9_MFA\Config" -ErrorAction Stop
    $reporteContent += "  TOTPEnabled:    $($mfaConfig.TOTPEnabled)`n"
    $reporteContent += "  MaxFailures:    $($mfaConfig.MaxFailures)`n"
    $reporteContent += "  LockoutDuration:$($mfaConfig.LockoutDuration) min`n"
} catch { $reporteContent += "  MFA config no encontrada (WinOTP no instalado o en modo alternativo)`n" }

# AppLocker
$reporteContent += "`n--- APPLOCKER ---`n"
try {
    $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    $reporteContent += "  AppIDSvc: $($svc.Status)`n"
    $pol = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
    $totalReglas = ($pol.RuleCollections | ForEach-Object { $_ } | Measure-Object).Count
    $reporteContent += "  Total reglas: $totalReglas`n"
} catch { $reporteContent += "  AppLocker info no disponible`n" }

$reporteContent += "`n$separador`n"
$reporteContent += "  FIN DEL REPORTE`n"
$reporteContent += "$separador`n"

# Escribir reporte final
$reporteContent | Out-File -FilePath $ReporteFinal -Encoding UTF8 -Force
p9_ok "Reporte final generado: $ReporteFinal"

# Evidencia Test 5
@"
==========================================================
  TEST 5: AUDITORIA AUTOMATIZADA -- PRACTICA 09
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
==========================================================

$(if ($passTest5) {"[PASS] accesos_denegados.txt generado correctamente."} else {"[FAIL] accesos_denegados.txt no generado."})

Archivos de evidencia generados:
$(($fases | Where-Object { Test-Path "$($Global:OutputDir)\$($_.Archivo)" } | ForEach-Object { "  [OK] $($_.Archivo)" }) -join "`n")

Archivos pendientes:
$(($fases | Where-Object { -not (Test-Path "$($Global:OutputDir)\$($_.Archivo)") } | ForEach-Object { "  [--] $($_.Archivo)" }) -join "`n")
"@ | Out-File -FilePath $EvidenciaFile -Encoding UTF8 -Force

# ---- Resumen final en pantalla ----
Write-Host ""
p9_linea
Write-Host "  ARCHIVOS GENERADOS EN: $($Global:OutputDir)"
p9_linea
Get-ChildItem -Path $Global:OutputDir -File | ForEach-Object {
    $size = [Math]::Round($_.Length / 1KB, 1)
    Write-Host "    $($_.Name.PadRight(45)) $($size) KB"
}

p9_linea
p9_log $LogFile "=== FIN: Reporte Final generado ==="
p9_ok "Practica 09 -- Todos los scripts ejecutados."
p9_info "Reporte final: $ReporteFinal"
p9_pausa
