# crear_fgpp_admins.ps1 -- Fase 3: Fine-Grained Password Policy para administradores
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# FGPP Admins:
#   - Minimo 12 caracteres
#   - Complejidad habilitada
#   - Historial: 5 contrasenas
#   - Bloqueo: 5 intentos / 15 min
#   - Precedencia: 10 (alta prioridad)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 3 -- FGPP Administradores"
Ensure-OutputDir

$LogFile     = "$($Global:OutputDir)\fase3_fgpp.log"
$PolicyName  = "PSO_Admins_P9"
p9_log $LogFile "=== INICIO: FGPP Admins ==="

p9_info "Verificando politica FGPP existente: $PolicyName..."
$existe = Get-ADFineGrainedPasswordPolicy -Filter { Name -eq $PolicyName } -ErrorAction SilentlyContinue

if ($existe) {
    p9_warning "La politica '$PolicyName' ya existe. Actualizando parametros..."
    try {
        Set-ADFineGrainedPasswordPolicy -Identity $PolicyName `
            -MinPasswordLength           12 `
            -ComplexityEnabled           $true `
            -PasswordHistoryCount        5 `
            -LockoutThreshold            5 `
            -LockoutDuration             "0:15:00" `
            -LockoutObservationWindow    "0:15:00" `
            -MinPasswordAge              "1.00:00:00" `
            -MaxPasswordAge              "60.00:00:00" `
            -ReversibleEncryptionEnabled $false `
            -ErrorAction Stop
        p9_ok "Politica '$PolicyName' actualizada."
        p9_log $LogFile "FGPP Admins actualizada"
    } catch {
        p9_error "Error actualizando FGPP: $_"
        p9_log $LogFile "ERROR update FGPP: $_"
        exit 1
    }
} else {
    p9_info "Creando nueva politica FGPP para administradores..."
    try {
        New-ADFineGrainedPasswordPolicy `
            -Name                        $PolicyName `
            -DisplayName                 "PSO Administradores -- Practica 09" `
            -Description                 "Politica de contrasena reforzada para roles admin delegados" `
            -Precedence                  10 `
            -MinPasswordLength           12 `
            -ComplexityEnabled           $true `
            -PasswordHistoryCount        5 `
            -LockoutThreshold            5 `
            -LockoutDuration             "0:15:00" `
            -LockoutObservationWindow    "0:15:00" `
            -MinPasswordAge              "1.00:00:00" `
            -MaxPasswordAge              "60.00:00:00" `
            -ReversibleEncryptionEnabled $false `
            -ErrorAction Stop
        p9_ok "Politica '$PolicyName' creada exitosamente."
        p9_log $LogFile "FGPP Admins creada (Precedencia: 10)"
    } catch {
        p9_error "Error creando FGPP: $_"
        p9_log $LogFile "ERROR creacion FGPP: $_"
        exit 1
    }
}

Write-Host ""

# ---- Aplicar a grupo de administradores ----
p9_info "Aplicando politica al grupo GRP_IAM_Operators y usuarios admin..."

$objetivos = @("GRP_IAM_Operators", "GRP_Storage_Operators", "GRP_GPO_Compliance", "GRP_Security_Auditors",
               "admin_identidad", "admin_storage", "admin_politicas", "admin_auditoria")

foreach ($obj in $objetivos) {
    try {
        # Verificar si el objeto existe (grupo o usuario)
        $adObj = Get-ADObject -Filter { SamAccountName -eq $obj -or Name -eq $obj } -ErrorAction SilentlyContinue
        if ($adObj) {
            Add-ADFineGrainedPasswordPolicySubject -Identity $PolicyName -Subjects $obj -ErrorAction Stop
            p9_ok "  + Politica aplicada a: $obj"
            p9_log $LogFile "PSO_Admins aplicado a: $obj"
        } else {
            p9_warning "  Objeto no encontrado: $obj (crear primero con Fase 2)"
        }
    } catch {
        if ($_ -match "already") {
            p9_info "  Ya aplicado: $obj"
        } else {
            p9_warning "  Error aplicando a $obj : $_"
        }
    }
}

Write-Host ""

# ---- Mostrar politica creada ----
p9_info "Detalle de la politica creada:"
p9_linea
try {
    $pso = Get-ADFineGrainedPasswordPolicy -Identity $PolicyName
    Write-Host "    Nombre:          $($pso.Name)"
    Write-Host "    Precedencia:     $($pso.Precedence)"
    Write-Host "    Min Longitud:    $($pso.MinPasswordLength)"
    Write-Host "    Complejidad:     $($pso.ComplexityEnabled)"
    Write-Host "    Historial:       $($pso.PasswordHistoryCount)"
    Write-Host "    Bloqueo tras:    $($pso.LockoutThreshold) intentos"
    Write-Host "    Duracion bloqueo:$($pso.LockoutDuration)"
    Write-Host "    Max edad pass:   $($pso.MaxPasswordAge.Days) dias"
} catch {
    p9_warning "No se pudo mostrar la politica: $_"
}

p9_linea
p9_log $LogFile "=== FIN: FGPP Admins ==="
p9_ok "FGPP Administradores configurada."
p9_pausa
