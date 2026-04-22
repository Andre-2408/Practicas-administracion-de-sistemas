# crear_compartidas_perfil.ps1 -- Fase 5: Crear carpeta compartida de perfiles moviles
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Ruta: \\servidor\perfiles\%username%
# Permisos NTFS: Full Control al usuario propietario + Administrators

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 5 -- Compartida de Perfiles Moviles"
Ensure-OutputDir

$LogFile    = "$($Global:OutputDir)\fase5_perfiles.log"
$RutaLocal  = "C:\Perfiles"
$NombreComp = "perfiles"
$Servidor   = $env:COMPUTERNAME
p9_log $LogFile "=== INICIO: Crear Compartida Perfiles ==="

# ---- Crear directorio local ----
p9_info "Creando directorio local: $RutaLocal"
try {
    if (-not (Test-Path $RutaLocal)) {
        New-Item -ItemType Directory -Path $RutaLocal -Force | Out-Null
        p9_ok "Directorio creado: $RutaLocal"
    } else {
        p9_info "Directorio ya existe: $RutaLocal"
    }
    p9_log $LogFile "Directorio $RutaLocal verificado/creado"
} catch {
    p9_error "Error creando directorio: $_"
    exit 1
}

# ---- Configurar permisos NTFS ----
p9_info "Configurando permisos NTFS en $RutaLocal ..."
try {
    $acl = Get-Acl -Path $RutaLocal

    # Limpiar herencias
    $acl.SetAccessRuleProtection($true, $false)

    # Admins: Full Control
    $aceAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators",
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($aceAdmin)

    # SYSTEM: Full Control
    $aceSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM",
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($aceSys)

    # Domain Users: ListDirectory + ReadAttributes + CreateDirectories
    # (no pueden ver carpetas de otros usuarios)
    $aceDU = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$($Global:NetBIOS)\Domain Users",
        [System.Security.AccessControl.FileSystemRights]"ReadAndExecute, ListDirectory, CreateDirectories",
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($aceDU)

    Set-Acl -Path $RutaLocal -AclObject $acl
    p9_ok "Permisos NTFS configurados en: $RutaLocal"
    p9_log $LogFile "NTFS permisos OK en $RutaLocal"
} catch {
    p9_error "Error configurando NTFS: $_"
    p9_log $LogFile "ERROR NTFS: $_"
}

# ---- Crear carpeta compartida SMB ----
p9_info "Creando recurso compartido SMB: $NombreComp"
try {
    $shareExiste = Get-SmbShare -Name $NombreComp -ErrorAction SilentlyContinue
    if ($shareExiste) {
        p9_warning "Compartida '$NombreComp' ya existe. Actualizando..."
        Set-SmbShare -Name $NombreComp -Description "Perfiles moviles -- Practica 09" `
            -FolderEnumerationMode AccessBased -Force -ErrorAction Stop
    } else {
        New-SmbShare -Name $NombreComp -Path $RutaLocal `
            -Description "Perfiles moviles -- Practica 09" `
            -FolderEnumerationMode AccessBased `
            -FullAccess "BUILTIN\Administrators","NT AUTHORITY\SYSTEM" `
            -ChangeAccess "$($Global:NetBIOS)\Domain Users" `
            -ErrorAction Stop
        p9_ok "Compartida SMB creada: \\$Servidor\$NombreComp"
    }
    p9_log $LogFile "SMB Share $NombreComp creada en $Servidor"
} catch {
    p9_error "Error creando SMB share: $_"
    p9_log $LogFile "ERROR SMB share: $_"
}

# ---- Crear subcarpetas por usuario ----
p9_info "Creando subcarpetas de perfil por usuario..."
try {
    $usuarios = @()
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_Cuates   -ErrorAction SilentlyContinue
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_NoCuates -ErrorAction SilentlyContinue

    foreach ($u in $usuarios) {
        $carpetaUser = "$RutaLocal\$($u.SamAccountName)"
        if (-not (Test-Path $carpetaUser)) {
            New-Item -ItemType Directory -Path $carpetaUser -Force | Out-Null
        }

        # NTFS: Full Control al usuario propietario
        $aclUser = Get-Acl -Path $carpetaUser
        $aclUser.SetAccessRuleProtection($true, $false)

        $aceUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$($Global:NetBIOS)\$($u.SamAccountName)",
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $aclUser.AddAccessRule($aceUser)
        $aclUser.AddAccessRule($aceAdmin)
        $aclUser.AddAccessRule($aceSys)
        Set-Acl -Path $carpetaUser -AclObject $aclUser

        # Configurar atributo profilePath en AD
        Set-ADUser -Identity $u.SamAccountName `
            -ProfilePath "\\$Servidor\$NombreComp\$($u.SamAccountName)" `
            -ErrorAction SilentlyContinue

        p9_ok "  Perfil configurado: $($u.SamAccountName)"
    }
    p9_log $LogFile "Carpetas de perfil creadas para $($usuarios.Count) usuarios"
} catch {
    p9_warning "Error creando subcarpetas: $_"
}

# ---- Resumen ----
p9_linea
p9_ok "Compartida de perfiles configurada: \\$Servidor\$NombreComp"
p9_info "Ruta local:  $RutaLocal"
p9_info "Ruta UNC:    \\\\$Servidor\\$NombreComp"
p9_log $LogFile "=== FIN: Crear Compartida Perfiles ==="
p9_pausa
