# validar_aplicacion_fgpp.ps1 -- Fase 3: Test formal de FGPP
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Test 2:
#   admin_identidad intenta password de 8 chars en admin_politicas -> ERROR (necesita 12)
#   admin_identidad intenta password de 12 chars en admin_politicas -> OK

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 3 -- Validacion FGPP (Test 2)"
Ensure-OutputDir

$EvidenciaFile = "$($Global:OutputDir)\test_fgpp_evidencia.txt"
$LogFile       = "$($Global:OutputDir)\fase3_fgpp.log"

@"
==========================================================
  TEST FGPP -- PRACTICA 09
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina: $($env:COMPUTERNAME)
  Dominio: $($Global:Dominio)
==========================================================
"@ | Out-File -FilePath $EvidenciaFile -Encoding UTF8 -Force

p9_log $LogFile "=== INICIO: Validacion FGPP ==="

$resultados = @()

function Test-PasswordPolicy {
    param(
        [string]$Usuario,
        [string]$NuevaPassword,
        [string]$EsperadoResultado,  # "OK" o "ERROR"
        [string]$Descripcion
    )

    p9_info "Test: $Descripcion"
    p9_info "  Usuario: $Usuario | Password (longitud): $($NuevaPassword.Length) chars"

    $resultado = ""
    $pass      = $false

    try {
        # Obtener PSO efectivo para el usuario
        $psoEfectivo = Get-ADUserResultantPasswordPolicy -Identity $Usuario -ErrorAction Stop

        $minLen = if ($psoEfectivo) { $psoEfectivo.MinPasswordLength } else { 7 }  # Default domain policy
        p9_info "  PSO efectivo: MinPasswordLength = $minLen"

        if ($NuevaPassword.Length -lt $minLen) {
            $resultado = "ERROR: Password muy corta ($($NuevaPassword.Length) < $minLen requeridos)"
            $pass      = ($EsperadoResultado -eq "ERROR")
            p9_warning "  RESULTADO: $resultado"
        } else {
            # Intentar cambio real de password
            try {
                $secPass = ConvertTo-SecureString $NuevaPassword -AsPlainText -Force
                Set-ADAccountPassword -Identity $Usuario -NewPassword $secPass `
                    -Reset -ErrorAction Stop
                $resultado = "OK: Password cambiada exitosamente"
                $pass      = ($EsperadoResultado -eq "OK")
                p9_ok "  RESULTADO: $resultado"

                # Restaurar password original para no dejar cuenta en estado desconocido
                $passOriginal = ConvertTo-SecureString "AdminGPO@2024!" -AsPlainText -Force
                Set-ADAccountPassword -Identity $Usuario -NewPassword $passOriginal -Reset -ErrorAction SilentlyContinue

            } catch {
                $resultado = "ERROR: $_"
                $pass      = ($EsperadoResultado -eq "ERROR")
                p9_warning "  RESULTADO: $resultado"
            }
        }

    } catch {
        $resultado = "ERROR obteniendo PSO: $_"
        p9_error "  $resultado"
    }

    $estado = if ($pass) { "PASS" } else { "FAIL" }
    $color  = if ($pass) { "Green" } else { "Red" }
    Write-Host "  -> [$estado] $Descripcion" -ForegroundColor $color
    Write-Host ""

    $resultados += [PSCustomObject]@{
        Test        = $Descripcion
        Usuario     = $Usuario
        LongPass    = $NuevaPassword.Length
        Resultado   = $resultado
        Esperado    = $EsperadoResultado
        Pass        = $pass
    }

    p9_log $LogFile "[$estado] $Descripcion | $resultado"
}

# ---- Verificar PSOs configuradas ----
p9_info "PSOs configuradas en el dominio:"
p9_linea
try {
    Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {
        Write-Host "    $($_.Name) | Prec:$($_.Precedence) | MinLen:$($_.MinPasswordLength) | Hist:$($_.PasswordHistoryCount)"
    }
} catch {
    p9_warning "No se pudo listar PSOs: $_"
}
Write-Host ""

# ---- PSO resultante por usuario ----
p9_info "PSO efectivo por usuario:"
p9_linea
foreach ($u in @("admin_identidad", "admin_storage", "admin_politicas", "admin_auditoria")) {
    try {
        $pso = Get-ADUserResultantPasswordPolicy -Identity $u -ErrorAction SilentlyContinue
        if ($pso) {
            Write-Host "    $($u.PadRight(25)) PSO: $($pso.Name) | MinLen: $($pso.MinPasswordLength)"
        } else {
            Write-Host "    $($u.PadRight(25)) PSO: Default Domain Policy"
        }
    } catch {
        Write-Host "    $($u.PadRight(25)) Error: $_"
    }
}
Write-Host ""
p9_linea

# ---- TESTS FORMALES ----
Write-Host "  Ejecutando Test 2: FGPP"
p9_linea
Write-Host ""

# Test A: 8 chars en admin_politicas -> debe fallar (requiere 12)
Test-PasswordPolicy `
    -Usuario           "admin_politicas" `
    -NuevaPassword     "Short8!A" `
    -EsperadoResultado "ERROR" `
    -Descripcion       "admin_politicas: password 8 chars -> debe fallar (min 12)"

# Test B: 12 chars en admin_politicas -> debe pasar
Test-PasswordPolicy `
    -Usuario           "admin_politicas" `
    -NuevaPassword     "LargePolicY@24!" `
    -EsperadoResultado "OK" `
    -Descripcion       "admin_politicas: password 15 chars -> debe pasar (min 12)"

# Test C: 8 chars en usuario estandar -> debe pasar (min 8)
$usuarioStd = Get-ADUser -Filter * -SearchBase $Global:OU_Cuates -ResultSetSize 1 |
    Select-Object -ExpandProperty SamAccountName
if ($usuarioStd) {
    Test-PasswordPolicy `
        -Usuario           $usuarioStd `
        -NuevaPassword     "Pass8!Ab" `
        -EsperadoResultado "OK" `
        -Descripcion       "$usuarioStd (usuario std): password 8 chars -> debe pasar (min 8)"
}

# ---- Resumen ----
p9_linea
Write-Host "  RESUMEN TEST 2:"
p9_linea
$resultados | ForEach-Object {
    $s = if ($_.Pass) { "[PASS]" } else { "[FAIL]" }
    $c = if ($_.Pass) { "Green" } else { "Red" }
    Write-Host "    $s $($_.Test)" -ForegroundColor $c
}

# Exportar evidencia
"`n--- RESULTADOS TEST 2 (FGPP) ---" | Add-Content -Path $EvidenciaFile -Encoding UTF8
$resultados | ForEach-Object {
    $s = if ($_.Pass) { "PASS" } else { "FAIL" }
    "[$s] $($_.Test)" | Add-Content -Path $EvidenciaFile -Encoding UTF8
    "     Usuario: $($_.Usuario) | Longitud: $($_.LongPass) | Resultado: $($_.Resultado)" |
        Add-Content -Path $EvidenciaFile -Encoding UTF8
    "     Esperado: $($_.Esperado)" | Add-Content -Path $EvidenciaFile -Encoding UTF8
    "" | Add-Content -Path $EvidenciaFile -Encoding UTF8
}

$total = $resultados.Count
$pass  = ($resultados | Where-Object Pass).Count
"`nTotal: $total  |  PASS: $pass  |  FAIL: $($total - $pass)" |
    Add-Content -Path $EvidenciaFile -Encoding UTF8

p9_log $LogFile "=== FIN: Validacion FGPP -- $pass/$total PASS ==="
p9_ok "Evidencia guardada en: $EvidenciaFile"
p9_pausa
