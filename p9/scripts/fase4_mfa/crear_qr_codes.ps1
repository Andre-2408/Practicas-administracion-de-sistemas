# crear_qr_codes.ps1 -- Fase 4: Generar codigos QR para Google Authenticator
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Genera un archivo HTML con codigos QR para cada usuario
# Los QR se generan via API de QR libre (o localmente si no hay red)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 4 -- Generacion de Codigos QR (MFA)"
Ensure-OutputDir

$LogFile   = "$($Global:OutputDir)\fase4_mfa.log"
$QRDir     = "C:\P9\TOTP\QR"
$SecretsFile = "$($Global:OutputDir)\totp_secrets.csv"
$HTMLOutput  = "$($Global:OutputDir)\qr_codes.html"
p9_log $LogFile "=== INICIO: Generacion QR Codes ==="

if (-not (Test-Path $QRDir)) {
    New-Item -ItemType Directory -Path $QRDir -Force | Out-Null
}

# ---- Verificar que existen secretos ----
if (-not (Test-Path $SecretsFile)) {
    p9_error "No se encontro archivo de secretos: $SecretsFile"
    p9_info "Ejecute primero: generar_secrets_totp.ps1"
    exit 1
}

$secrets = Import-Csv -Path $SecretsFile -ErrorAction Stop
p9_ok "Secretos cargados: $($secrets.Count) usuarios"
Write-Host ""

# ---- Generar URL TOTP para cada usuario (otpauth://) ----
# Formato estandar RFC 6238 compatible con Google Authenticator
function Get-TOTPUri {
    param(
        [string]$Usuario,
        [string]$Secreto,
        [string]$Emisor = "P8.local"
    )
    $label  = [Uri]::EscapeDataString("$Emisor`:$Usuario")
    $params = "secret=$Secreto&issuer=$([Uri]::EscapeDataString($Emisor))&algorithm=SHA1&digits=6&period=30"
    return "otpauth://totp/$label`?$params"
}

# ---- Generar HTML con QR codes via Google Charts API (o alternativa sin internet) ----
p9_info "Generando pagina HTML con codigos QR..."

$htmlHeader = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Codigos QR MFA -- Practica 09</title>
    <style>
        body { font-family: Arial, sans-serif; background: #1e1e2e; color: #cdd6f4; padding: 20px; }
        h1   { color: #89b4fa; border-bottom: 2px solid #313244; padding-bottom: 10px; }
        .user-card {
            background: #313244; border-radius: 8px; padding: 20px;
            margin: 15px 0; display: inline-block; width: 280px;
            vertical-align: top; margin-right: 15px;
        }
        .user-card h3 { color: #a6e3a1; margin-top: 0; }
        .secret { font-family: monospace; font-size: 11px; color: #f38ba8;
                  word-break: break-all; background: #1e1e2e; padding: 5px; border-radius: 4px; }
        img { border: 3px solid #89b4fa; border-radius: 4px; }
        .instrucciones { background: #45475a; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
        .warning { color: #f38ba8; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Codigos QR -- MFA Google Authenticator</h1>
    <div class="instrucciones">
        <strong>Instrucciones:</strong>
        <ol>
            <li>Instalar Google Authenticator en su movil</li>
            <li>Abrir la app y pulsar "+" -> "Escanear codigo QR"</li>
            <li>Escanear el QR correspondiente a su usuario</li>
            <li>Al iniciar sesion, introducir el codigo de 6 digitos que muestra la app</li>
        </ol>
        <p class="warning">ADVERTENCIA: Este documento es CONFIDENCIAL. No compartir.</p>
        <p>Generado: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Dominio: $($Global:Dominio)</p>
    </div>
    <div>
"@

$htmlFooter = @"
    </div>
</body>
</html>
"@

$htmlCards = ""

foreach ($u in $secrets) {
    $totpUri = Get-TOTPUri -Usuario $u.Usuario -Secreto $u.Secreto_TOTP -Emisor $Global:Dominio

    # URL de QR via Google Charts API
    $qrUrl = "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=" +
              [Uri]::EscapeDataString($totpUri)

    # Alternativamente intentar descarga del QR como imagen local
    $imgPath = "$QRDir\$($u.Usuario)_qr.png"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $qrUrl -OutFile $imgPath -TimeoutSec 10 -ErrorAction Stop
        p9_ok "  QR descargado: $($u.Usuario)"
        $imgSrc = "file:///$($imgPath.Replace('\','/'))"
    } catch {
        p9_warning "  Sin red para QR local ($($u.Usuario)) -- usando URL externa."
        $imgSrc = $qrUrl
    }

    $htmlCards += @"
        <div class="user-card">
            <h3>$($u.Usuario)</h3>
            <img src="$imgSrc" alt="QR $($u.Usuario)" width="200" height="200"><br><br>
            <strong>Secreto:</strong><br>
            <div class="secret">$($u.Secreto_TOTP)</div><br>
            <strong>Codigo actual:</strong> $($u.CodigoActual)<br>
            <small>Valido 30 segundos desde generacion</small>
        </div>
"@

    p9_log $LogFile "QR URI generada para: $($u.Usuario)"
}

# ---- Escribir HTML ----
($htmlHeader + $htmlCards + $htmlFooter) | Out-File -FilePath $HTMLOutput -Encoding UTF8 -Force
p9_ok "Pagina HTML con QR generada: $HTMLOutput"

# ---- Generar tambien archivo de texto con URIs ----
$uriFile = "$($Global:OutputDir)\totp_uris.txt"
"# TOTP URIs -- Practica 09 -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" |
    Out-File -FilePath $uriFile -Encoding UTF8 -Force
foreach ($u in $secrets) {
    $totpUri = Get-TOTPUri -Usuario $u.Usuario -Secreto $u.Secreto_TOTP -Emisor $Global:Dominio
    "$($u.Usuario): $totpUri" | Add-Content -Path $uriFile -Encoding UTF8
}
p9_ok "URIs TOTP guardadas en: $uriFile"

Write-Host ""
p9_info "Para ver los QR, abrir en navegador:"
p9_info "  $HTMLOutput"
p9_info "O copiar el archivo al cliente Windows y abrirlo con Edge/Chrome."

p9_log $LogFile "=== FIN: QR Codes generados ($($secrets.Count) usuarios) ==="
p9_pausa
