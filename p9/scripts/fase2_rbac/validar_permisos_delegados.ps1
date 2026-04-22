# validar_permisos_delegados.ps1 -- Fase 2: Test formal de delegacion RBAC
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Test 1:
#   admin_identidad puede hacer Reset Password en OU Cuates -> OK
#   admin_storage hace Reset Password en OU Cuates          -> DENIED

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 2 -- Validacion de Permisos Delegados (Test 1)"
Ensure-OutputDir

$EvidenciaFile = "$($Global:OutputDir)\test_delegacion_evidencia.txt"
$LogFile       = "$($Global:OutputDir)\fase2_rbac.log"

# Cabecera del archivo de evidencia
@"
==========================================================
  TEST DELEGACION RBAC -- PRACTICA 09
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina: $($env:COMPUTERNAME)
  Dominio: $($Global:Dominio)
==========================================================
"@ | Out-File -FilePath $EvidenciaFile -Encoding UTF8 -Force

$resultados = @()

function Test-ResetPassword {
    param(
        [string]$AdminUser,
        [string]$TargetUser,
        [string]$EsperadoResultado  # "OK" o "DENIED"
    )

    $testNombre = "Reset Password: $AdminUser -> $TargetUser"
    p9_info "Test: $testNombre"

    try {
        # Verificar que el usuario target existe
        $target = Get-ADUser -Identity $TargetUser -ErrorAction Stop

        # Intentar reset password usando credenciales del admin en cuestion
        # En entorno real se usaria Invoke-Command con credenciales; aqui verificamos ACL
        $ouDN    = ($target.DistinguishedName -split ",",2)[1]
        $ouPath  = "AD:\$ouDN"
        $acl     = Get-Acl -Path $ouPath

        $GUID_Reset = "00299570-246d-11d0-a768-00aa006e0529"
        $adminSID   = (Get-ADUser -Identity $AdminUser).SID

        $tienePermiso = $false
        $tieneNegacion = $false

        foreach ($ace in $acl.Access) {
            if ($ace.IdentityReference -like "*$AdminUser*") {
                $guidStr = $ace.ObjectType.ToString()
                if ($guidStr -eq $GUID_Reset) {
                    if ($ace.AccessControlType -eq "Allow") { $tienePermiso  = $true }
                    if ($ace.AccessControlType -eq "Deny")  { $tieneNegacion = $true }
                }
            }
        }

        $resultado = if ($tieneNegacion) {
            "DENIED (ACE Deny encontrado)"
        } elseif ($tienePermiso) {
            "OK (ACE Allow encontrado)"
        } else {
            "INDETERMINATE (no ACE directa, herencia posible)"
        }

        $correcto = ($EsperadoResultado -eq "OK" -and $tienePermiso -and -not $tieneNegacion) -or
                    ($EsperadoResultado -eq "DENIED" -and $tieneNegacion)

        if ($correcto) {
            p9_ok "  RESULTADO: $resultado [ESPERADO: $EsperadoResultado] --> PASS"
        } else {
            p9_warning "  RESULTADO: $resultado [ESPERADO: $EsperadoResultado] --> REVISAR"
        }

        $resultados += [PSCustomObject]@{
            Test        = $testNombre
            Resultado   = $resultado
            Esperado    = $EsperadoResultado
            Pass        = $correcto
        }

    } catch {
        p9_error "  Error en test: $_"
        $resultados += [PSCustomObject]@{
            Test      = $testNombre
            Resultado = "ERROR: $_"
            Esperado  = $EsperadoResultado
            Pass      = $false
        }
    }

    Write-Host ""
}

# ---- Obtener primer usuario de OU Cuates para el test ----
$usuarioCuates = Get-ADUser -Filter * -SearchBase $Global:OU_Cuates -ResultSetSize 1 |
    Select-Object -ExpandProperty SamAccountName

if (-not $usuarioCuates) {
    p9_warning "No se encontraron usuarios en OU Cuates. Usando usuario de prueba 'cramirez'."
    $usuarioCuates = "cramirez"
}

# ---- TESTS ----
p9_linea
Write-Host "  Ejecutando Test 1: Delegacion Reset Password"
p9_linea
Write-Host ""

Test-ResetPassword -AdminUser "admin_identidad" -TargetUser $usuarioCuates -EsperadoResultado "OK"
Test-ResetPassword -AdminUser "admin_storage"   -TargetUser $usuarioCuates -EsperadoResultado "DENIED"

# ---- Verificar Read-Only de admin_auditoria ----
p9_info "Verificando acceso Read-Only de admin_auditoria..."
try {
    $acl    = Get-Acl -Path "AD:\$($Global:DominioDN)"
    $denyWr = $acl.Access | Where-Object {
        $_.IdentityReference -like "*admin_auditoria*" -and
        $_.AccessControlType -eq "Deny"
    }
    if ($denyWr) {
        p9_ok "  admin_auditoria DENY escritura: CONFIRMADO"
        $resultados += [PSCustomObject]@{
            Test      = "admin_auditoria DENY escritura AD"
            Resultado = "DENY ACE presente"
            Esperado  = "DENIED"
            Pass      = $true
        }
    } else {
        p9_warning "  No se encontro DENY explicito para admin_auditoria"
        $resultados += [PSCustomObject]@{
            Test      = "admin_auditoria DENY escritura AD"
            Resultado = "Sin DENY ACE explicita"
            Esperado  = "DENIED"
            Pass      = $false
        }
    }
} catch {
    p9_error "Error verificando auditoria: $_"
}

Write-Host ""

# ---- Resumen y evidencia ----
p9_linea
Write-Host "  RESUMEN DE TESTS:"
p9_linea
$resultados | ForEach-Object {
    $status = if ($_.Pass) { "[PASS]" } else { "[FAIL]" }
    $color  = if ($_.Pass) { "Green" } else { "Red" }
    Write-Host "    $status $($_.Test)" -ForegroundColor $color
}

# Exportar evidencia
"`n--- RESULTADOS DE TESTS ---" | Add-Content -Path $EvidenciaFile -Encoding UTF8
$resultados | ForEach-Object {
    $status = if ($_.Pass) { "PASS" } else { "FAIL" }
    "[$status] $($_.Test) | Resultado: $($_.Resultado) | Esperado: $($_.Esperado)" |
        Add-Content -Path $EvidenciaFile -Encoding UTF8
}

$total  = $resultados.Count
$pass   = ($resultados | Where-Object Pass).Count
"`nTotal: $total  |  PASS: $pass  |  FAIL: $($total - $pass)" |
    Add-Content -Path $EvidenciaFile -Encoding UTF8

p9_log $LogFile "Tests delegacion: $pass/$total PASS"
p9_ok "Evidencia guardada en: $EvidenciaFile"
p9_pausa
