# crear_compartidas_home.ps1 -- Fase 5: Crear carpeta compartida Home Folder
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Ruta: \\servidor\documentos\%username%
# Home Folder mapeada como unidad de red (letra H:)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 5 -- Compartida Home Folders"
Ensure-OutputDir

$LogFile    = "$($Global:OutputDir)\fase5_perfiles.log"
$RutaLocal  = "C:\Documentos"
$NombreComp = "documentos"
$Servidor   = $env:COMPUTERNAME
p9_log $LogFile "=== INICIO: Crear Compartida Home ==="

# ---- Crear directorio local ----
p9_info "Creando directorio: $RutaLocal"
try {
    if (-not (Test-Path $RutaLocal)) {
        New-Item -ItemType Directory -Path $RutaLocal -Force | Out-Null
        p9_ok "Directorio creado: $RutaLocal"
    } else {
        p9_info "Ya existe: $RutaLocal"
    }
} catch {
    p9_error "Error: $_"; exit 1
}

# ---- Permisos NTFS base ----
p9_info "Configurando NTFS base en $RutaLocal ..."
try {
    $acl = Get-Acl -Path $RutaLocal
    $acl.SetAccessRuleProtection($true, $false)

    $aceAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators",
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $aceSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM",
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($aceAdmin)
    $acl.AddAccessRule($aceSys)
    Set-Acl -Path $RutaLocal -AclObject $acl
    p9_ok "NTFS base configurado."
} catch {
    p9_error "Error NTFS: $_"
}

# ---- Crear SMB Share ----
p9_info "Creando compartida SMB: $NombreComp"
try {
    $shareExiste = Get-SmbShare -Name $NombreComp -ErrorAction SilentlyContinue
    if (-not $shareExiste) {
        New-SmbShare -Name $NombreComp -Path $RutaLocal `
            -Description "Home Folders usuarios -- Practica 09" `
            -FolderEnumerationMode AccessBased `
            -FullAccess "BUILTIN\Administrators","NT AUTHORITY\SYSTEM" `
            -ChangeAccess "$($Global:NetBIOS)\Domain Users" `
            -ErrorAction Stop
        p9_ok "SMB Share creada: \\$Servidor\$NombreComp"
    } else {
        p9_info "SMB Share ya existe: $NombreComp"
    }
} catch {
    p9_error "Error SMB: $_"
}

# ---- Crear Home Folder por usuario y configurar en AD ----
p9_info "Creando carpetas home y configurando en AD..."

try {
    $usuarios = @()
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_Cuates   -ErrorAction SilentlyContinue
    $usuarios += Get-ADUser -Filter * -SearchBase $Global:OU_NoCuates -ErrorAction SilentlyContinue

    foreach ($u in $usuarios) {
        $carpetaHome = "$RutaLocal\$($u.SamAccountName)"
        if (-not (Test-Path $carpetaHome)) {
            New-Item -ItemType Directory -Path $carpetaHome -Force | Out-Null
        }

        # NTFS: Full Control al usuario
        $aclUser = New-Object System.Security.AccessControl.DirectorySecurity
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
        Set-Acl -Path $carpetaHome -AclObject $aclUser

        # Configurar HomeDirectory y HomeDrive en AD
        Set-ADUser -Identity $u.SamAccountName `
            -HomeDirectory "\\$Servidor\$NombreComp\$($u.SamAccountName)" `
            -HomeDrive "H:" `
            -ErrorAction SilentlyContinue

        p9_ok "  Home configurado: $($u.SamAccountName) -> H:"
        p9_log $LogFile "Home: $($u.SamAccountName) -> \\$Servidor\$NombreComp\$($u.SamAccountName)"
    }

    p9_log $LogFile "Home folders creados para $($usuarios.Count) usuarios"

} catch {
    p9_warning "Error en home folders: $_"
}

# ---- Resumen ----
p9_linea
p9_ok "Home Folders configuradas: \\$Servidor\$NombreComp"
p9_info "Unidad de red mapeada: H:"
p9_log $LogFile "=== FIN: Crear Compartida Home ==="
p9_pausa
