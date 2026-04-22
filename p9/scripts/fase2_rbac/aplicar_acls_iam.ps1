# aplicar_acls_iam.ps1 -- Fase 2: Delegar permisos al IAM Operator (admin_identidad)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Permisos:
#   + Reset Password en OU Cuates y OU NoCuates
#   + Crear/Modificar/Eliminar usuarios
#   + Modificar atributos basicos (telefono, oficina, email)
#   - DENEGAR: Modificar miembros de Domain Admins
#   - DENEGAR: Modificar GPOs

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 2 -- ACLs: IAM Operator (admin_identidad)"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase2_rbac.log"
p9_log $LogFile "=== INICIO: ACLs IAM Operator ==="

# GUIDs estandar de AD para Reset Password y permisos de usuario
$GUID_Reset_Password    = [GUID]"00299570-246d-11d0-a768-00aa006e0529"
$GUID_User_Class        = [GUID]"bf967aba-0de6-11d0-a285-00aa003049e2"
$GUID_GPO_Class         = [GUID]"f30e3bc2-9ff0-11d1-b603-0000f80367c1"
$GUID_Domain_Admins     = [GUID]"00000000-0000-0000-0000-000000000000"  # Inherited object

$OUs = @($Global:OU_Cuates, $Global:OU_NoCuates)

foreach ($ou in $OUs) {
    $ouNombre = ($ou -split ",")[0] -replace "OU=",""
    p9_info "Aplicando ACLs en OU: $ouNombre"

    try {
        $ouPath    = "AD:\$ou"
        $acl       = Get-Acl -Path $ouPath
        $identity  = New-Object System.Security.Principal.NTAccount("$($Global:NetBIOS)\admin_identidad")

        # --- ALLOW: Reset Password sobre objetos User ---
        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $GUID_Reset_Password,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
            $GUID_User_Class
        )
        $acl.AddAccessRule($ace)
        p9_ok "  + ALLOW Reset Password sobre usuarios en $ouNombre"

        # --- ALLOW: CreateChild / DeleteChild User en OU ---
        $ace2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity,
            [System.DirectoryServices.ActiveDirectoryRights]"CreateChild, DeleteChild",
            [System.Security.AccessControl.AccessControlType]::Allow,
            $GUID_User_Class,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All,
            [GUID]::Empty
        )
        $acl.AddAccessRule($ace2)
        p9_ok "  + ALLOW Crear/Eliminar usuarios en $ouNombre"

        # --- ALLOW: WriteProperty atributos basicos sobre objetos User ---
        $ace3 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity,
            [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
            [System.Security.AccessControl.AccessControlType]::Allow,
            [GUID]::Empty,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
            $GUID_User_Class
        )
        $acl.AddAccessRule($ace3)
        p9_ok "  + ALLOW WriteProperty (atributos) sobre usuarios en $ouNombre"

        Set-Acl -Path $ouPath -AclObject $acl
        p9_log $LogFile "ACLs IAM ALLOW aplicadas en $ou"

    } catch {
        p9_error "Error aplicando ACLs ALLOW en $ou : $_"
        p9_log $LogFile "ERROR ACLs IAM en $ou : $_"
    }
}

Write-Host ""
p9_info "Aplicando DENEGACION: admin_identidad NO puede modificar Domain Admins..."

try {
    $domainAdminsPath = "AD:\CN=Domain Admins,CN=Users,$($Global:DominioDN)"
    $acl  = Get-Acl -Path $domainAdminsPath
    $iden = New-Object System.Security.Principal.NTAccount("$($Global:NetBIOS)\admin_identidad")

    # DENY WriteMembers en Domain Admins
    $aceDeny = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $iden,
        [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
        [System.Security.AccessControl.AccessControlType]::Deny,
        [GUID]::Empty,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None,
        [GUID]::Empty
    )
    $acl.AddAccessRule($aceDeny)
    Set-Acl -Path $domainAdminsPath -AclObject $acl
    p9_ok "  - DENY modificar Domain Admins aplicado."
    p9_log $LogFile "DENY Domain Admins modificacion aplicado para admin_identidad"

} catch {
    p9_warning "No se pudo aplicar DENY en Domain Admins: $_"
    p9_log $LogFile "WARN: DENY Domain Admins -- $_"
}

p9_linea
p9_log $LogFile "=== FIN: ACLs IAM Operator ==="
p9_ok "ACLs IAM Operator aplicadas correctamente."
p9_pausa
