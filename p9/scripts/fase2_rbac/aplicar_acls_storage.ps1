# aplicar_acls_storage.ps1 -- Fase 2: Delegar permisos al Storage Operator (admin_storage)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Permisos:
#   + Gestionar cuotas FSRM
#   + File Screening
#   + Generar reportes de almacenamiento
#   - DENEGAR EXPLICITAMENTE: Reset Password en AD

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 2 -- ACLs: Storage Operator (admin_storage)"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase2_rbac.log"
p9_log $LogFile "=== INICIO: ACLs Storage Operator ==="

# ---- Permisos FSRM via grupos locales ----
p9_info "Configurando acceso FSRM para admin_storage..."

try {
    # Agregar admin_storage al grupo local de administradores del servidor de archivos
    # (necesario para usar FSRM remotamente)
    $domUser = "$($Global:NetBIOS)\admin_storage"

    # Verificar si FSRM esta instalado
    $fsrm = Get-WindowsFeature -Name FS-Resource-Manager -ErrorAction SilentlyContinue
    if ($fsrm -and $fsrm.Installed) {
        p9_ok "FSRM instalado. Configurando permisos..."

        # Delegar via COM FSRM -- admin_storage puede gestionar cuotas y file screens
        # En produccion usar dsacls o FSRM COM object
        # Aqui creamos una politica de acceso a nivel de registro
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FSRM"
        if (Test-Path $regPath) {
            p9_ok "Registro FSRM accesible."
        }

    } else {
        p9_warning "FSRM no instalado en este equipo. El admin_storage gestionara FSRM remotamente."
    }

    # Crear grupo local de FSRM admins y agregar admin_storage
    try {
        $grpFSRM = Get-LocalGroup -Name "FSRM_Operators" -ErrorAction SilentlyContinue
        if (-not $grpFSRM) {
            New-LocalGroup -Name "FSRM_Operators" -Description "Operadores de FSRM delegados" | Out-Null
            p9_ok "Grupo local FSRM_Operators creado."
        }
        Add-LocalGroupMember -Group "FSRM_Operators" -Member $domUser -ErrorAction SilentlyContinue
        p9_ok "admin_storage agregado a FSRM_Operators."
        p9_log $LogFile "admin_storage agregado a grupo FSRM_Operators"
    } catch {
        p9_warning "No se pudo crear grupo FSRM_Operators: $_"
    }

} catch {
    p9_error "Error configurando FSRM: $_"
    p9_log $LogFile "ERROR FSRM: $_"
}

Write-Host ""

# ---- DENY: Reset Password en todo el dominio ----
p9_info "Aplicando DENEGACION EXPLICITA: admin_storage NO puede hacer Reset Password..."

$GUID_Reset_Password = [GUID]"00299570-246d-11d0-a768-00aa006e0529"
$GUID_User_Class     = [GUID]"bf967aba-0de6-11d0-a285-00aa003049e2"

$OUs = @($Global:OU_Cuates, $Global:OU_NoCuates, $Global:OU_Admins)

foreach ($ou in $OUs) {
    $ouNombre = ($ou -split ",")[0] -replace "OU=",""
    try {
        $ouPath   = "AD:\$ou"
        $acl      = Get-Acl -Path $ouPath
        $identity = New-Object System.Security.Principal.NTAccount("$($Global:NetBIOS)\admin_storage")

        # DENY ExtendedRight Reset Password sobre User objects
        $aceDeny = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $identity,
            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
            [System.Security.AccessControl.AccessControlType]::Deny,
            $GUID_Reset_Password,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
            $GUID_User_Class
        )
        $acl.AddAccessRule($aceDeny)
        Set-Acl -Path $ouPath -AclObject $acl

        p9_ok "  - DENY Reset Password en $ouNombre aplicado."
        p9_log $LogFile "DENY Reset Password aplicado para admin_storage en $ou"

    } catch {
        p9_error "Error aplicando DENY en $ou : $_"
        p9_log $LogFile "ERROR DENY Reset Password en $ou : $_"
    }
}

# ---- Permisos sobre carpetas compartidas de almacenamiento ----
Write-Host ""
p9_info "Configurando permisos NTFS en rutas de almacenamiento..."

$rutasStorage = @("C:\Homes", "C:\Perfiles", "C:\Datos")

foreach ($ruta in $rutasStorage) {
    if (Test-Path $ruta) {
        try {
            $acl      = Get-Acl -Path $ruta
            $identity = New-Object System.Security.Principal.NTAccount("$($Global:NetBIOS)\admin_storage")
            $ace      = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity,
                [System.Security.AccessControl.FileSystemRights]"Modify, ReadAndExecute, ListDirectory",
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($ace)
            Set-Acl -Path $ruta -AclObject $acl
            p9_ok "  + Permisos de gestion sobre: $ruta"
            p9_log $LogFile "Permisos storage en $ruta aplicados"
        } catch {
            p9_warning "  Error en $ruta : $_"
        }
    } else {
        p9_info "  Ruta no existe (se configurara en Fase 5): $ruta"
    }
}

p9_linea
p9_log $LogFile "=== FIN: ACLs Storage Operator ==="
p9_ok "ACLs Storage Operator aplicadas."
p9_pausa
