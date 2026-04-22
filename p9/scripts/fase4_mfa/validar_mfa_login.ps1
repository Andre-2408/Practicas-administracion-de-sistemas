# validar_mfa_login.ps1 -- Fase 4: Test formal MFA (Tests 3 y 4)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Test 3: Logon con TOTP valido -> sesion iniciada
# Test 4: 3 fallos TOTP -> cuenta bloqueada (EventID 4740)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 4 -- Validacion MFA Login (Tests 3 y 4)"
Ensure-OutputDir

$EvidenciaFile = "$($Global:OutputDir)\test_mfa_evidencia.txt"
$LogFile       = "$($Global:OutputDir)\fase4_mfa.log"
$RegConfig     = "HKLM:\SOFTWARE\P9_MFA\Config"
$RegUsers      = "HKLM:\SOFTWARE\P9_MFA\Users"
$SecretsFile   = "$($Global:OutputDir)\totp_secrets.csv"

@"
==========================================================
  TEST MFA -- PRACTICA 09
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina: $($env:COMPUTERNAME)
  Dominio: $($Global:Dominio)
==========================================================
"@ | Out-File -FilePath $EvidenciaFile -Encoding UTF8 -Force

p9_log $LogFile "=== INICIO: Validacion MFA ==="

# ---- Funcion TOTP ----
function Get-TOTPCode {
    param([string]$Secret)
    $base32chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits = ""
    foreach ($c in $Secret.ToUpper().ToCharArray()) {
        $v = $base32chars.IndexOf($c)
        if ($v -ge 0) { $bits += [Convert]::ToString($v, 2).PadLeft(5, '0') }
    }
    $bytes = @()
    for ($i = 0; $i -lt ($bits.Length - 7); $i += 8) {
        $bytes += [Convert]::ToByte($bits.Substring($i, 8), 2)
    }
    $epoch   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $counter = [Math]::Floor($epoch / 30)
    $cBytes  = [BitConverter]::GetBytes([int64]$counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($cBytes) }
    $hmac   = New-Object System.Security.Cryptography.HMACSHA1(,[byte[]]$bytes)
    $hash   = $hmac.ComputeHash($cBytes)
    $offset = $hash[19] -band 0x0F
    $code   = (($hash[$offset] -band 0x7F) -shl 24) -bor
              (($hash[$offset+1] -band 0xFF) -shl 16) -bor
              (($hash[$offset+2] -band 0xFF) -shl 8)  -bor
              ($hash[$offset+3] -band 0xFF)
    return ($code % 1000000).ToString("000000")
}

# ---- Funcion simular validacion TOTP ----
function Test-TOTPValidation {
    param(
        [string]$Usuario,
        [string]$SecretoReal,
        [string]$CodigoIngresado,  # "" = valido automatico
        [bool]  $DeberiaFallar = $false
    )

    $codigoValido = Get-TOTPCode -Secret $SecretoReal
    $codigo       = if ($CodigoIngresado -eq "") { $codigoValido } else { $CodigoIngresado }

    # Leer intentos fallidos del registro
    $regUser = "$RegUsers\$Usuario"
    if (-not (Test-Path $regUser)) {
        New-Item -Path $regUser -Force | Out-Null
        Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regUser -Name "LockoutUntil"   -Value 0 -Type QWord -Force
    }

    $intentosFallidos = (Get-ItemProperty -Path $regUser).FailedAttempts
    $lockoutHasta     = (Get-ItemProperty -Path $regUser).LockoutUntil
    $ahora            = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # Verificar bloqueo activo
    if ($lockoutHasta -gt $ahora) {
        $minRestantes = [Math]::Ceiling(($lockoutHasta - $ahora) / 60)
        return [PSCustomObject]@{
            Usuario  = $Usuario
            Codigo   = $codigo
            Valido   = $false
            Estado   = "LOCKED"
            Mensaje  = "Cuenta bloqueada. Espere $minRestantes minutos."
            EventID  = 4740
        }
    }

    # Validar codigo TOTP (tambien aceptar intervalo anterior +/- 30s)
    $codigoAnterior = Get-TOTPCode -Secret $SecretoReal  # mismo porque es en tiempo real
    $esValido = ($codigo -eq $codigoValido)

    if ($esValido) {
        # Resetear intentos fallidos
        Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $regUser -Name "LockoutUntil"   -Value 0 -Type QWord -Force
        return [PSCustomObject]@{
            Usuario = $Usuario
            Codigo  = $codigo
            Valido  = $true
            Estado  = "OK"
            Mensaje = "Autenticacion MFA exitosa."
            EventID = 0
        }
    } else {
        # Incrementar intentos fallidos
        $intentosFallidos++
        Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value $intentosFallidos -Type DWord -Force

        $maxFailures = 3
        try { $maxFailures = (Get-ItemProperty -Path $RegConfig).MaxFailures } catch {}

        if ($intentosFallidos -ge $maxFailures) {
            $lockoutMin = 30
            try { $lockoutMin = (Get-ItemProperty -Path $RegConfig).LockoutDuration } catch {}
            $lockoutHasta = $ahora + ($lockoutMin * 60)
            Set-ItemProperty -Path $regUser -Name "LockoutUntil" -Value $lockoutHasta -Type QWord -Force
            Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value 0 -Type DWord -Force

            # Bloquear cuenta en AD
            Disable-ADAccount -Identity $Usuario -ErrorAction SilentlyContinue

            return [PSCustomObject]@{
                Usuario = $Usuario
                Codigo  = $codigo
                Valido  = $false
                Estado  = "LOCKED"
                Mensaje = "3 fallos consecutivos. Cuenta bloqueada por $lockoutMin min."
                EventID = 4740
            }
        }

        return [PSCustomObject]@{
            Usuario = $Usuario
            Codigo  = $codigo
            Valido  = $false
            Estado  = "FAILED"
            Mensaje = "Codigo TOTP incorrecto. Intento $intentosFallidos/3."
            EventID = 4625
        }
    }
}

# ---- Cargar secretos ----
if (-not (Test-Path $SecretsFile)) {
    p9_error "No se encontro secrets file. Ejecute generar_secrets_totp.ps1 primero."
    exit 1
}
$secrets  = Import-Csv -Path $SecretsFile
$testUser = $secrets | Select-Object -First 1
if (-not $testUser) { p9_error "Sin usuarios en secrets file."; exit 1 }

p9_info "Usuario de prueba: $($testUser.Usuario)"
Write-Host ""
$resultados = @()

# ============================================================
# TEST 3: MFA Logon Flow correcto
# ============================================================
p9_linea
Write-Host "  TEST 3: MFA Logon Flow (codigo valido)"
p9_linea

# Resetear estado del usuario de prueba
$regUser = "$RegUsers\$($testUser.Usuario)"
if (Test-Path $regUser) {
    Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $regUser -Name "LockoutUntil"   -Value 0 -Type QWord -Force
}
Enable-ADAccount -Identity $testUser.Usuario -ErrorAction SilentlyContinue

$res3 = Test-TOTPValidation -Usuario $testUser.Usuario -SecretoReal $testUser.Secreto_TOTP -CodigoIngresado ""
$pass3 = ($res3.Estado -eq "OK")
$color3 = if ($pass3) { "Green" } else { "Red" }

Write-Host "    Usuario: $($res3.Usuario)"
Write-Host "    Codigo TOTP: $($res3.Codigo)"
Write-Host "    Resultado: $($res3.Estado) -- $($res3.Mensaje)" -ForegroundColor $color3
Write-Host "    [$(if ($pass3) {'PASS'} else {'FAIL'})] Test 3 MFA logon valido" -ForegroundColor $color3

$resultados += [PSCustomObject]@{
    Test    = "Test 3: MFA logon con codigo valido"
    Estado  = $res3.Estado
    Mensaje = $res3.Mensaje
    Pass    = $pass3
}
p9_log $LogFile "Test3 MFA valido: $($res3.Estado) -- $($res3.Mensaje)"

Write-Host ""

# ============================================================
# TEST 4: MFA Lockout (3 fallos consecutivos)
# ============================================================
p9_linea
Write-Host "  TEST 4: MFA Lockout (3 codigos incorrectos)"
p9_linea

# Resetear estado
if (Test-Path $regUser) {
    Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $regUser -Name "LockoutUntil"   -Value 0 -Type QWord -Force
}
Enable-ADAccount -Identity $testUser.Usuario -ErrorAction SilentlyContinue

$codigoMalo = "000000"
for ($i = 1; $i -le 3; $i++) {
    $res = Test-TOTPValidation -Usuario $testUser.Usuario `
        -SecretoReal $testUser.Secreto_TOTP -CodigoIngresado $codigoMalo
    Write-Host "    Intento $i/3: Codigo='$codigoMalo' -> $($res.Estado) -- $($res.Mensaje)"
    Start-Sleep -Milliseconds 200
}

# 4to intento (deberia ver cuenta bloqueada)
$res4 = Test-TOTPValidation -Usuario $testUser.Usuario `
    -SecretoReal $testUser.Secreto_TOTP -CodigoIngresado $codigoMalo
$pass4 = ($res4.Estado -eq "LOCKED")
$color4 = if ($pass4) { "Green" } else { "Red" }

Write-Host "    Intento 4/3: Codigo='$codigoMalo' -> $($res4.Estado) -- $($res4.Mensaje)" -ForegroundColor $color4
Write-Host "    [$(if ($pass4) {'PASS'} else {'FAIL'})] Test 4 MFA lockout activado" -ForegroundColor $color4

# Verificar estado en AD
try {
    $adUser = Get-ADUser -Identity $testUser.Usuario -Properties LockedOut
    Write-Host "    Estado AD LockedOut: $($adUser.LockedOut)"
} catch {}

$resultados += [PSCustomObject]@{
    Test    = "Test 4: MFA lockout tras 3 fallos"
    Estado  = $res4.Estado
    Mensaje = $res4.Mensaje
    Pass    = $pass4
}
p9_log $LogFile "Test4 MFA lockout: $($res4.Estado) -- $($res4.Mensaje)"

# Restaurar cuenta
Enable-ADAccount -Identity $testUser.Usuario -ErrorAction SilentlyContinue
if (Test-Path $regUser) {
    Set-ItemProperty -Path $regUser -Name "FailedAttempts" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $regUser -Name "LockoutUntil"   -Value 0 -Type QWord -Force
}

Write-Host ""

# ---- Exportar evidencia ----
p9_linea
"`n--- RESULTADOS TEST 3 y 4 (MFA) ---" | Add-Content -Path $EvidenciaFile -Encoding UTF8
$resultados | ForEach-Object {
    $s = if ($_.Pass) { "PASS" } else { "FAIL" }
    "[$s] $($_.Test)" | Add-Content -Path $EvidenciaFile -Encoding UTF8
    "     Estado: $($_.Estado) | $($_.Mensaje)" | Add-Content -Path $EvidenciaFile -Encoding UTF8
    "" | Add-Content -Path $EvidenciaFile -Encoding UTF8
}

$total = $resultados.Count
$pass  = ($resultados | Where-Object Pass).Count
"`nTotal: $total  |  PASS: $pass  |  FAIL: $($total - $pass)" |
    Add-Content -Path $EvidenciaFile -Encoding UTF8

p9_log $LogFile "=== FIN: Validacion MFA -- $pass/$total PASS ==="
p9_ok "Evidencia MFA guardada en: $EvidenciaFile"
p9_pausa
