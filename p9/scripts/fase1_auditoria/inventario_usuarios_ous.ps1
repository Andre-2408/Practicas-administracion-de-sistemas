# inventario_usuarios_ous.ps1 -- Fase 1: Inventario de usuarios y OUs
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 1 -- Inventario de Usuarios y OUs"
Ensure-OutputDir

$CsvUsuarios = "$($Global:OutputDir)\inventario_usuarios.csv"
$CsvOUs      = "$($Global:OutputDir)\inventario_ous.csv"
$OutputFile  = "$($Global:OutputDir)\diagnostico_baseline.txt"

# ---- Usuarios ----
p9_info "Obteniendo todos los usuarios del dominio..."
try {
    $usuarios = Get-ADUser -Filter * -Properties DisplayName, Department, Enabled,
        PasswordLastSet, PasswordNeverExpires, LockedOut, LastLogonDate,
        DistinguishedName -ErrorAction Stop

    $usuarios | Select-Object SamAccountName, DisplayName, Department, Enabled,
        PasswordLastSet, PasswordNeverExpires, LockedOut, LastLogonDate,
        DistinguishedName |
        Export-Csv -Path $CsvUsuarios -NoTypeInformation -Encoding UTF8

    p9_ok "Usuarios exportados ($($usuarios.Count)): $CsvUsuarios"

    Write-Host ""
    Write-Host "  --- Usuarios en el dominio ---"
    p9_linea
    $usuarios | Sort-Object SamAccountName | ForEach-Object {
        $estado = if ($_.Enabled) { "Activo  " } else { "Inactivo" }
        $bloq   = if ($_.LockedOut) { "[LOCKED]" } else { "        " }
        Write-Host "    $($_.SamAccountName.PadRight(20)) $estado $bloq  $($_.Department)"
    }

} catch {
    p9_error "Error al obtener usuarios: $_"
    exit 1
}

Write-Host ""

# ---- OUs ----
p9_info "Obteniendo Unidades Organizativas..."
try {
    $ous = Get-ADOrganizationalUnit -Filter * -Properties Description, DistinguishedName -ErrorAction Stop

    $ous | Select-Object Name, Description, DistinguishedName |
        Export-Csv -Path $CsvOUs -NoTypeInformation -Encoding UTF8

    p9_ok "OUs exportadas ($($ous.Count)): $CsvOUs"

    Write-Host ""
    Write-Host "  --- Unidades Organizativas ---"
    p9_linea
    $ous | Sort-Object Name | ForEach-Object {
        Write-Host "    $($_.Name.PadRight(25)) -- $($_.DistinguishedName)"
    }

} catch {
    p9_error "Error al obtener OUs: $_"
    exit 1
}

# ---- Append al baseline ----
$seccion = @"

--- INVENTARIO USUARIOS ($($usuarios.Count) total) ---
$(($usuarios | ForEach-Object { "  $($_.SamAccountName) | $($_.Department) | Enabled:$($_.Enabled) | Locked:$($_.LockedOut)" }) -join "`n")

--- INVENTARIO OUs ($($ous.Count) total) ---
$(($ous | ForEach-Object { "  $($_.Name) -- $($_.DistinguishedName)" }) -join "`n")
"@
Add-Content -Path $OutputFile -Value $seccion -Encoding UTF8

p9_linea
p9_ok "Inventario completado. Archivos generados:"
p9_info "  $CsvUsuarios"
p9_info "  $CsvOUs"
p9_pausa
