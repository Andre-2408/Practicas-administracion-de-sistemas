# config_lockout_registry.ps1 -- Fase 4: Configurar bloqueo MFA via registro
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Configura en HKLM:
#   MaxFailures     = 3  (intentos TOTP fallidos antes de bloquear)
#   LockoutDuration = 30 (minutos de bloqueo)
#   TOTPEnabled     = 1

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 4 -- Configuracion Lockout MFA (Registry)"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase4_mfa.log"
p9_log $LogFile "=== INICIO: Config Lockout Registry ==="

# ---- Clave de registro para WinOTP / MFA config ----
$RegBase   = "HKLM:\SOFTWARE\P9_MFA"
$RegConfig = "$RegBase\Config"
$RegUsers  = "$RegBase\Users"

p9_info "Creando estructura de registro MFA en: $RegBase"

try {
    foreach ($ruta in @($RegBase, $RegConfig, $RegUsers)) {
        if (-not (Test-Path $ruta)) {
            New-Item -Path $ruta -Force | Out-Null
            p9_ok "Creada: $ruta"
        }
    }
} catch {
    p9_error "Error creando claves de registro: $_"
    exit 1
}

# ---- Configurar parametros de bloqueo ----
p9_info "Configurando parametros MFA..."

$configParams = @{
    "MaxFailures"      = 3     # Intentos fallidos antes de bloquear
    "LockoutDuration"  = 30    # Minutos de bloqueo
    "TOTPEnabled"      = 1     # MFA activo
    "TOTPPeriod"       = 30    # Segundos de validez del codigo
    "TOTPDigits"       = 6     # Digitos del codigo
    "TOTPAlgorithm"    = "SHA1" # Algoritmo (compatible Google Authenticator)
    "GracePeriod"      = 300   # Segundos de gracia al iniciar MFA
    "LogMFAEvents"     = 1     # Registrar eventos en Event Log
    "FailedEventID"    = 4625  # EventID para fallo MFA
    "LockoutEventID"   = 4740  # EventID para cuenta bloqueada
}

foreach ($param in $configParams.GetEnumerator()) {
    try {
        $tipo = if ($param.Value -is [string]) { "String" } else { "DWord" }
        Set-ItemProperty -Path $RegConfig -Name $param.Key -Value $param.Value -Type $tipo -Force
        p9_ok "  $($param.Key) = $($param.Value)"
        p9_log $LogFile "Registry: $($param.Key) = $($param.Value)"
    } catch {
        p9_error "  Error: $($param.Key) -- $_"
    }
}

Write-Host ""

# ---- Configurar WinOTP Credential Provider registry (si instalado) ----
p9_info "Configurando Credential Provider WinOTP..."
$cpRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}"

if (Test-Path $cpRegPath) {
    try {
        Set-ItemProperty -Path $cpRegPath -Name "MaxFailures"     -Value 3  -Type DWord -Force
        Set-ItemProperty -Path $cpRegPath -Name "LockoutMinutes"  -Value 30 -Type DWord -Force
        Set-ItemProperty -Path $cpRegPath -Name "Enabled"         -Value 1  -Type DWord -Force
        p9_ok "Credential Provider WinOTP configurado."
        p9_log $LogFile "CP WinOTP config aplicada"
    } catch {
        p9_warning "Error configurando CP WinOTP: $_"
    }
} else {
    p9_warning "Credential Provider WinOTP no registrado. Configurando fallback..."

    # Configurar via Group Policy (Local Security Policy alternativa)
    try {
        # Account Lockout Policy via secedit
        $seceditTemp = "$env:TEMP\lockout.inf"
        @"
[Unicode]
Unicode=yes
[System Access]
LockoutBadCount = 3
ResetLockoutCount = 30
LockoutDuration = 30
"@ | Out-File -FilePath $seceditTemp -Encoding Unicode -Force

        secedit /configure /db "$env:TEMP\lockout.sdb" /cfg $seceditTemp /quiet 2>&1 | Out-Null
        p9_ok "Account Lockout Policy configurada via secedit (3 intentos / 30 min)."
        p9_log $LogFile "Lockout policy secedit: 3 intentos / 30 min"
        Remove-Item $seceditTemp -Force -ErrorAction SilentlyContinue

    } catch {
        p9_warning "Error configurando lockout via secedit: $_"
    }
}

Write-Host ""

# ---- Verificar configuracion final ----
p9_info "Configuracion actual en registro:"
p9_linea
try {
    $vals = Get-ItemProperty -Path $RegConfig -ErrorAction Stop
    $vals.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" } | ForEach-Object {
        Write-Host "    $($_.Name.PadRight(22)) = $($_.Value)"
    }
} catch {
    p9_warning "Error leyendo registro: $_"
}

Write-Host ""

# ---- Account Lockout Policy actual (AD) ----
p9_info "Account Lockout Policy del dominio:"
p9_linea
try {
    $policy = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
    Write-Host "    LockoutThreshold:         $($policy.LockoutThreshold)"
    Write-Host "    LockoutDuration:          $($policy.LockoutDuration)"
    Write-Host "    LockoutObservationWindow: $($policy.LockoutObservationWindow)"
} catch {
    p9_warning "No se pudo obtener policy de dominio: $_"
}

p9_linea
p9_log $LogFile "=== FIN: Config Lockout Registry ==="
p9_ok "Configuracion MFA completada. MaxFailures=3, LockoutDuration=30min."
p9_pausa
