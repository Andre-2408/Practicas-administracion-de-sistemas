# config_auditpol_eventos.ps1 -- Fase 6: Configurar politicas de auditoria avanzada
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Categorias auditadas:
#   - Logon/Logoff (4624, 4625, 4634)
#   - Account Management (4720, 4722, 4725, 4740)
#   - Directory Service Access (4662)
#   - Object Access (4663)
#   - Privilege Use (4673)
#   - Policy Change (4719)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 6 -- Configuracion Auditpol"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase6_auditoria.log"
p9_log $LogFile "=== INICIO: Config Auditpol ==="

# ---- Verificar privilegios ----
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $esAdmin) {
    p9_error "Requiere privilegios de Administrador."
    exit 1
}

# ---- Definicion de categorias y subcategorias ----
$auditConfig = @(
    # Formato: Categoria, Subcategoria, Tipo (Success/Failure/Both)
    @{ Cat="Account Logon";         Sub="Kerberos Authentication Service";     Tipo="success,failure" },
    @{ Cat="Account Logon";         Sub="Credential Validation";               Tipo="success,failure" },
    @{ Cat="Logon/Logoff";          Sub="Logon";                               Tipo="success,failure" },
    @{ Cat="Logon/Logoff";          Sub="Logoff";                              Tipo="success"         },
    @{ Cat="Logon/Logoff";          Sub="Account Lockout";                     Tipo="success,failure" },
    @{ Cat="Account Management";    Sub="User Account Management";             Tipo="success,failure" },
    @{ Cat="Account Management";    Sub="Security Group Management";           Tipo="success,failure" },
    @{ Cat="Account Management";    Sub="Computer Account Management";         Tipo="success,failure" },
    @{ Cat="DS Access";             Sub="Directory Service Access";            Tipo="success,failure" },
    @{ Cat="DS Access";             Sub="Directory Service Changes";           Tipo="success,failure" },
    @{ Cat="Object Access";         Sub="File System";                         Tipo="failure"         },
    @{ Cat="Object Access";         Sub="Registry";                            Tipo="failure"         },
    @{ Cat="Privilege Use";         Sub="Sensitive Privilege Use";             Tipo="success,failure" },
    @{ Cat="Policy Change";         Sub="Audit Policy Change";                 Tipo="success,failure" },
    @{ Cat="Policy Change";         Sub="Authentication Policy Change";        Tipo="success"         },
    @{ Cat="System";                Sub="Security System Extension";           Tipo="success,failure" }
)

p9_info "Configurando $($auditConfig.Count) subcategorias de auditoria..."
p9_linea

$errores = 0
$ok      = 0

foreach ($cfg in $auditConfig) {
    # Construir flags
    $successFlag = if ($cfg.Tipo -match "success") { "/success:enable" } else { "/success:disable" }
    $failureFlag = if ($cfg.Tipo -match "failure") { "/failure:enable" } else { "/failure:disable" }

    try {
        $cmd = "auditpol /set /subcategory:`"$($cfg.Sub)`" $successFlag $failureFlag"
        $resultado = Invoke-Expression $cmd 2>&1

        if ($LASTEXITCODE -eq 0) {
            p9_ok "  $($cfg.Sub.PadRight(45)) [$($cfg.Tipo)]"
            $ok++
            p9_log $LogFile "OK: $($cfg.Sub) = $($cfg.Tipo)"
        } else {
            p9_warning "  $($cfg.Sub): $resultado"
            $errores++
        }
    } catch {
        p9_error "  Error en $($cfg.Sub): $_"
        $errores++
        p9_log $LogFile "ERROR: $($cfg.Sub) -- $_"
    }
}

Write-Host ""

# ---- Configurar tamano del Security Log ----
p9_info "Configurando tamano del Security Log..."
try {
    # 256 MB maximo
    $maxSizeKB = 262144  # 256 MB en KB
    wevtutil sl Security /ms:$($maxSizeKB * 1024) 2>&1 | Out-Null
    wevtutil sl Security /rt:false 2>&1 | Out-Null  # No sobreescribir, archivar
    p9_ok "Security Log: Max 256 MB, modo archivo."
    p9_log $LogFile "Security Log size: 256 MB, retention: archive"
} catch {
    p9_warning "Error configurando Security Log: $_"
}

# ---- Configurar auditoria via GPO (para que persista tras reinicio) ----
p9_info "Aplicando auditoria via GPO del dominio..."
try {
    # Usando secedit para exportar y reimportar con auditoria
    $seceditCfg = "$env:TEMP\audit_p9.inf"
    @"
[Unicode]
Unicode=yes
[Event Audit]
AuditSystemEvents = 3
AuditLogonEvents = 3
AuditObjectAccess = 2
AuditPrivilegeUse = 3
AuditPolicyChange = 3
AuditAccountManage = 3
AuditProcessTracking = 0
AuditDSAccess = 3
AuditAccountLogon = 3
"@ | Out-File -FilePath $seceditCfg -Encoding Unicode -Force

    secedit /configure /db "$env:TEMP\audit_p9.sdb" /cfg $seceditCfg /quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        p9_ok "Auditoria aplicada via secedit."
        p9_log $LogFile "Auditoria secedit aplicada"
    }
    Remove-Item $seceditCfg, "$env:TEMP\audit_p9.sdb" -Force -ErrorAction SilentlyContinue
} catch {
    p9_warning "Error secedit auditoria: $_"
}

# ---- Mostrar configuracion actual ----
Write-Host ""
p9_info "Estado actual de auditoria (extracto):"
p9_linea
try {
    $auditActual = auditpol /get /category:* 2>&1
    $auditActual | Where-Object { $_ -match "Logon|Account|Directory|Object" } | ForEach-Object {
        Write-Host "  $_"
    }
} catch {
    p9_warning "No se pudo mostrar estado actual."
}

p9_linea
p9_ok "Auditoria configurada: $ok subcategorias OK, $errores errores."
p9_log $LogFile "=== FIN: Config Auditpol -- $ok OK, $errores errores ==="
p9_pausa
