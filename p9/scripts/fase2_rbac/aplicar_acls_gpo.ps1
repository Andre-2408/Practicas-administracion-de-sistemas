# aplicar_acls_gpo.ps1 -- Fase 2: Delegar permisos al GPO Compliance (admin_politicas)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Permisos:
#   + Vincular/desvincular GPOs
#   + Modificar AppLocker, Logon Hours, FGPP
#   + Lectura en todo el dominio
#   - Escritura solo en objetos GPO (no en usuarios ni grupos)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 2 -- ACLs: GPO Compliance (admin_politicas)"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase2_rbac.log"
p9_log $LogFile "=== INICIO: ACLs GPO Compliance ==="

# Verificar modulo GroupPolicy
if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
    p9_error "Modulo GroupPolicy no disponible. Instale GPMC (RSAT)."
    exit 1
}
Import-Module GroupPolicy -ErrorAction SilentlyContinue

$identity = "$($Global:NetBIOS)\admin_politicas"

# ---- ALLOW: Lectura de todo el dominio ----
p9_info "Aplicando ALLOW Lectura en todo el dominio..."
try {
    $domainPath = "AD:\$($Global:DominioDN)"
    $acl        = Get-Acl -Path $domainPath
    $iden       = New-Object System.Security.Principal.NTAccount($identity)

    $aceRead = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $iden,
        [System.DirectoryServices.ActiveDirectoryRights]"GenericRead",
        [System.Security.AccessControl.AccessControlType]::Allow,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All,
        [GUID]::Empty
    )
    $acl.AddAccessRule($aceRead)
    Set-Acl -Path $domainPath -AclObject $acl
    p9_ok "ALLOW GenericRead en todo el dominio aplicado."
    p9_log $LogFile "ALLOW GenericRead dominio para admin_politicas"
} catch {
    p9_error "Error en GenericRead dominio: $_"
    p9_log $LogFile "ERROR GenericRead: $_"
}

Write-Host ""

# ---- ALLOW: Delegar link GPO en OUs ----
p9_info "Delegando gestion de GPOs en OUs..."

# GUID para gpLink y gpOptions (vinculacion de GPOs a OUs)
$GUID_gpLink = [GUID]"f30e3bc2-9ff0-11d1-b603-0000f80367c1"

$OUs_Delegar = @($Global:OU_Cuates, $Global:OU_NoCuates, $Global:OU_Admins, $Global:DominioDN)

foreach ($ou in $OUs_Delegar) {
    $ouNombre = ($ou -split ",")[0] -replace "OU=|DC=",""
    try {
        $ouPath = "AD:\$ou"
        $acl    = Get-Acl -Path $ouPath
        $iden   = New-Object System.Security.Principal.NTAccount($identity)

        # ALLOW WriteProperty gpLink (vincular/desvincular GPOs)
        $aceGPLink = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $iden,
            [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
            [System.Security.AccessControl.AccessControlType]::Allow,
            [GUID]"f30e3bbe-9ff0-11d1-b603-0000f80367c1",  # gpLink attribute
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None,
            [GUID]::Empty
        )
        $acl.AddAccessRule($aceGPLink)
        Set-Acl -Path $ouPath -AclObject $acl
        p9_ok "  + ALLOW gpLink/gpOptions en: $ouNombre"
        p9_log $LogFile "ALLOW gpLink en $ou para admin_politicas"
    } catch {
        p9_warning "  No se pudo aplicar gpLink en $ou : $_"
    }
}

Write-Host ""

# ---- ALLOW: Editar GPOs existentes ----
p9_info "Delegando permisos de edicion en GPOs existentes..."
try {
    $gpos = Get-GPO -All -Domain $Global:Dominio -ErrorAction Stop
    p9_info "GPOs encontradas: $($gpos.Count)"

    foreach ($gpo in $gpos) {
        try {
            # GPEdit permission = Read + Edit Settings (no link, no modify security)
            $gpo.SetSecurityInfo(
                (New-Object Microsoft.GroupPolicy.GPPermissionType "GpoEdit"),
                $identity,
                $false
            )
            p9_ok "  + Permiso GpoEdit en: $($gpo.DisplayName)"
            p9_log $LogFile "GpoEdit en GPO '$($gpo.DisplayName)' para admin_politicas"
        } catch {
            p9_warning "  Error en GPO '$($gpo.DisplayName)': $_"
        }
    }
} catch {
    p9_warning "No se pudo enumerar GPOs: $_"
    p9_log $LogFile "WARN: Enumeracion GPOs -- $_"
}

Write-Host ""

# ---- ALLOW: Crear nuevas GPOs en el dominio ----
p9_info "Delegando creacion de GPOs en el dominio..."
try {
    Set-GPPermission -All -PermissionLevel GpoEdit -TargetName $identity `
        -TargetType User -DomainName $Global:Dominio -ErrorAction SilentlyContinue
    p9_ok "Permiso de creacion/edicion de GPOs aplicado."
    p9_log $LogFile "Permiso GpoEdit global aplicado para admin_politicas"
} catch {
    p9_warning "No se pudo aplicar permiso global de GPO: $_"
}

p9_linea
p9_log $LogFile "=== FIN: ACLs GPO Compliance ==="
p9_ok "ACLs GPO Compliance aplicadas."
p9_pausa
