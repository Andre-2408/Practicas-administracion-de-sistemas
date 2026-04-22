# generar_secrets_totp.ps1 -- Fase 4: Generar secretos TOTP base32 por usuario
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Genera un secreto TOTP unico por usuario del dominio
# Los secretos se almacenan cifrados en AD (atributo extensionAttribute1)
# y en un CSV local para respaldo

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 4 -- Generacion de Secretos TOTP"
Ensure-OutputDir

$LogFile   = "$($Global:OutputDir)\fase4_mfa.log"
$SecretsFile = "$($Global:OutputDir)\totp_secrets.csv"
$totpDir   = "C:\P9\TOTP"
p9_log $LogFile "=== INICIO: Generacion Secretos TOTP ==="

if (-not (Test-Path $totpDir)) {
    New-Item -ItemType Directory -Path $totpDir -Force | Out-Null
}

# ---- Funcion para generar secreto base32 ----
function New-TOTPSecret {
    # Genera 20 bytes aleatorios y los codifica en base32
    $bytes  = New-Object byte[] 20
    $rng    = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rng.GetBytes($bytes)
    $rng.Dispose()

    # Tabla base32
    $base32chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $result      = ""
    $buffer      = 0
    $bitsLeft    = 0

    foreach ($b in $bytes) {
        $buffer   = ($buffer -shl 8) -bor $b
        $bitsLeft += 8
        while ($bitsLeft -ge 5) {
            $bitsLeft -= 5
            $result   += $base32chars[($buffer -shr $bitsLeft) -band 0x1F]
        }
    }
    return $result
}

# ---- Funcion para calcular TOTP (verificacion) ----
function Get-TOTPCode {
    param([string]$Secret)

    # Decodificar base32
    $base32chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits        = ""
    foreach ($c in $Secret.ToUpper().ToCharArray()) {
        $val  = $base32chars.IndexOf($c)
        if ($val -ge 0) {
            $bits += [Convert]::ToString($val, 2).PadLeft(5, '0')
        }
    }

    $bytes = @()
    for ($i = 0; $i -lt ($bits.Length - 7); $i += 8) {
        $bytes += [Convert]::ToByte($bits.Substring($i, 8), 2)
    }

    # Tiempo actual (intervalo de 30 segundos)
    $epoch    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $counter  = [Math]::Floor($epoch / 30)
    $counterB = [BitConverter]::GetBytes([int64]$counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counterB) }

    # HMAC-SHA1
    $hmac   = New-Object System.Security.Cryptography.HMACSHA1(,[byte[]]$bytes)
    $hash   = $hmac.ComputeHash($counterB)
    $offset = $hash[19] -band 0x0F
    $code   = (($hash[$offset] -band 0x7F) -shl 24) -bor
              (($hash[$offset+1] -band 0xFF) -shl 16) -bor
              (($hash[$offset+2] -band 0xFF) -shl 8)  -bor
              ($hash[$offset+3] -band 0xFF)
    return ($code % 1000000).ToString("000000")
}

# ---- Obtener usuarios del dominio ----
p9_info "Obteniendo usuarios del dominio para generar secretos TOTP..."
$usuarios = @()
try {
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_Cuates   -ErrorAction SilentlyContinue
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_NoCuates -ErrorAction SilentlyContinue
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_Admins   -ErrorAction SilentlyContinue
} catch {
    p9_warning "Error obteniendo usuarios: $_"
}

if ($usuarios.Count -eq 0) {
    p9_error "No se encontraron usuarios. Verifique las OUs."
    exit 1
}

p9_ok "Usuarios encontrados: $($usuarios.Count)"
Write-Host ""

# ---- Generar y almacenar secretos ----
$secretsData = @()
$header      = "Usuario,Secreto_TOTP,CodigoActual,Timestamp"
$header      | Out-File -FilePath $SecretsFile -Encoding UTF8 -Force

p9_info "Generando secretos TOTP..."
p9_linea

foreach ($u in $usuarios) {
    try {
        # Verificar si ya tiene secreto (extensionAttribute1)
        $userDetails = Get-ADUser -Identity $u.SamAccountName `
            -Properties extensionAttribute1 -ErrorAction Stop

        $secreto = if ($userDetails.extensionAttribute1 -match "^[A-Z2-7]{20,}$") {
            p9_info "  $($u.SamAccountName): secreto existente reutilizado."
            $userDetails.extensionAttribute1
        } else {
            $nuevoSecreto = New-TOTPSecret
            # Guardar en AD (extensionAttribute1)
            Set-ADUser -Identity $u.SamAccountName `
                -Replace @{ extensionAttribute1 = $nuevoSecreto } -ErrorAction Stop
            p9_ok "  $($u.SamAccountName): secreto TOTP generado y guardado en AD."
            $nuevoSecreto
        }

        # Calcular codigo actual (para verificacion)
        $codigoActual = Get-TOTPCode -Secret $secreto

        $secretsData += [PSCustomObject]@{
            Usuario      = $u.SamAccountName
            Secreto_TOTP = $secreto
            CodigoActual = $codigoActual
            Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }

        # Guardar en archivo local (CSV)
        "$($u.SamAccountName),$secreto,$codigoActual,$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" |
            Add-Content -Path $SecretsFile -Encoding UTF8

        # Guardar archivo individual por usuario
        $userSecretFile = "$totpDir\$($u.SamAccountName)_secret.txt"
        "SECRET=$secreto" | Out-File -FilePath $userSecretFile -Encoding UTF8 -Force

        p9_log $LogFile "Secreto generado/actualizado para: $($u.SamAccountName)"

    } catch {
        p9_error "  Error con $($u.SamAccountName): $_"
        p9_log $LogFile "ERROR secreto: $($u.SamAccountName) -- $_"
    }
}

Write-Host ""
p9_linea
p9_ok "Secretos TOTP generados: $($secretsData.Count) usuarios"
p9_ok "CSV guardado en: $SecretsFile"
p9_warning "IMPORTANTE: El CSV contiene secretos sensibles. Proteger adecuadamente."

Write-Host ""
p9_info "Muestra de codigos actuales (primeros 5):"
$secretsData | Select-Object -First 5 | ForEach-Object {
    Write-Host "    $($_.Usuario.PadRight(25)) Codigo actual: $($_.CodigoActual)"
}

p9_log $LogFile "=== FIN: Generacion Secretos TOTP -- $($secretsData.Count) secretos ==="
p9_pausa
