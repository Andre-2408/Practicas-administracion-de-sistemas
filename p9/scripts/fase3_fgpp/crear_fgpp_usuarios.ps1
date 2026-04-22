# crear_fgpp_usuarios.ps1 -- Fase 3: Fine-Grained Password Policy para usuarios estandar
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# FGPP Usuarios:
#   - Minimo 8 caracteres
#   - Complejidad habilitada
#   - Historial: 3 contrasenas
#   - Bloqueo: 5 intentos / 30 min
#   - Precedencia: 20 (menor prioridad que admins)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 3 -- FGPP Usuarios Estandar"
Ensure-OutputDir

$LogFile    = "$($Global:OutputDir)\fase3_fgpp.log"
$PolicyName = "PSO_Usuarios_P9"
p9_log $LogFile "=== INICIO: FGPP Usuarios ==="

p9_info "Verificando politica FGPP existente: $PolicyName..."
$existe = Get-ADFineGrainedPasswordPolicy -Filter { Name -eq $PolicyName } -ErrorAction SilentlyContinue

if ($existe) {
    p9_warning "La politica '$PolicyName' ya existe. Actualizando..."
    try {
        Set-ADFineGrainedPasswordPolicy -Identity $PolicyName `
            -MinPasswordLength           8 `
            -ComplexityEnabled           $true `
            -PasswordHistoryCount        3 `
            -LockoutThreshold            5 `
            -LockoutDuration             "0:30:00" `
            -LockoutObservationWindow    "0:30:00" `
            -MinPasswordAge              "0.00:00:00" `
            -MaxPasswordAge              "90.00:00:00" `
            -ReversibleEncryptionEnabled $false `
            -ErrorAction Stop
        p9_ok "Politica '$PolicyName' actualizada."
        p9_log $LogFile "FGPP Usuarios actualizada"
    } catch {
        p9_error "Error actualizando FGPP usuarios: $_"
        exit 1
    }
} else {
    p9_info "Creando nueva politica FGPP para usuarios estandar..."
    try {
        New-ADFineGrainedPasswordPolicy `
            -Name                        $PolicyName `
            -DisplayName                 "PSO Usuarios Estandar -- Practica 09" `
            -Description                 "Politica de contrasena para usuarios del dominio" `
            -Precedence                  20 `
            -MinPasswordLength           8 `
            -ComplexityEnabled           $true `
            -PasswordHistoryCount        3 `
            -LockoutThreshold            5 `
            -LockoutDuration             "0:30:00" `
            -LockoutObservationWindow    "0:30:00" `
            -MinPasswordAge              "0.00:00:00" `
            -MaxPasswordAge              "90.00:00:00" `
            -ReversibleEncryptionEnabled $false `
            -ErrorAction Stop
        p9_ok "Politica '$PolicyName' creada exitosamente."
        p9_log $LogFile "FGPP Usuarios creada (Precedencia: 20)"
    } catch {
        p9_error "Error creando FGPP usuarios: $_"
        exit 1
    }
}

Write-Host ""

# ---- Aplicar a OUs de usuarios estandar ----
p9_info "Aplicando politica a grupos de usuarios (Cuates, NoCuates)..."

# Obtener todos los usuarios de OU Cuates y NoCuates
$usuariosStd = @()
try {
    $usuariosStd += Get-ADUser -Filter * -SearchBase $Global:OU_Cuates   -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SamAccountName
    $usuariosStd += Get-ADUser -Filter * -SearchBase $Global:OU_NoCuates -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty SamAccountName
} catch {
    p9_warning "Error obteniendo usuarios estandar: $_"
}

# Crear grupo para aplicar PSO si no existe
try {
    $grpExiste = Get-ADGroup -Filter { Name -eq "GRP_Usuarios_Estandar" } -ErrorAction SilentlyContinue
    if (-not $grpExiste) {
        New-ADGroup -Name "GRP_Usuarios_Estandar" -GroupScope Global -GroupCategory Security `
            -Description "Usuarios estandar del dominio para PSO" `
            -Path $Global:DominioDN -ErrorAction Stop
        p9_ok "Grupo GRP_Usuarios_Estandar creado."
        p9_log $LogFile "Grupo GRP_Usuarios_Estandar creado"
    }

    # Agregar usuarios al grupo
    if ($usuariosStd.Count -gt 0) {
        Add-ADGroupMember -Identity "GRP_Usuarios_Estandar" -Members $usuariosStd -ErrorAction SilentlyContinue
        p9_ok "$($usuariosStd.Count) usuarios agregados a GRP_Usuarios_Estandar"
    }

    # Aplicar PSO al grupo
    Add-ADFineGrainedPasswordPolicySubject -Identity $PolicyName `
        -Subjects "GRP_Usuarios_Estandar" -ErrorAction Stop
    p9_ok "PSO_Usuarios aplicado a GRP_Usuarios_Estandar"
    p9_log $LogFile "PSO_Usuarios aplicado a GRP_Usuarios_Estandar con $($usuariosStd.Count) miembros"

} catch {
    if ($_ -match "already") {
        p9_info "PSO ya aplicado al grupo."
    } else {
        p9_warning "Error aplicando PSO: $_"
    }
}

Write-Host ""

# ---- Mostrar resumen de ambas politicas ----
p9_info "Comparativa de politicas FGPP:"
p9_linea
Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Parametro", "PSO_Admins", "PSO_Usuarios"
Write-Host "  {0,-30} {1,-15} {2,-15}" -f "---------", "----------", "------------"
try {
    $psoA = Get-ADFineGrainedPasswordPolicy -Identity "PSO_Admins_P9"   -ErrorAction SilentlyContinue
    $psoU = Get-ADFineGrainedPasswordPolicy -Identity "PSO_Usuarios_P9" -ErrorAction SilentlyContinue
    if ($psoA -and $psoU) {
        Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Min Longitud Contrasena", $psoA.MinPasswordLength,  $psoU.MinPasswordLength
        Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Complejidad",             $psoA.ComplexityEnabled,  $psoU.ComplexityEnabled
        Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Historial",              $psoA.PasswordHistoryCount,$psoU.PasswordHistoryCount
        Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Bloqueo (intentos)",     $psoA.LockoutThreshold,    $psoU.LockoutThreshold
        Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Duracion Bloqueo",       $psoA.LockoutDuration,     $psoU.LockoutDuration
        Write-Host "  {0,-30} {1,-15} {2,-15}" -f "Precedencia",            $psoA.Precedence,          $psoU.Precedence
    }
} catch {
    p9_warning "No se pudo mostrar comparativa."
}

p9_linea
p9_log $LogFile "=== FIN: FGPP Usuarios ==="
p9_ok "FGPP Usuarios Estandar configurada."
p9_pausa
