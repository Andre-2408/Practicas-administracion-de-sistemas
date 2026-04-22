# aplicar_acls_auditoria.ps1 -- Fase 2: Delegar permisos al Security Auditor (admin_auditoria)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Permisos:
#   + Acceso Read-Only en TODO el arbol AD
#   + Acceso lectura Security Logs
#   + Ejecutar scripts de extraccion
#   - Sin permisos de escritura en ningun objeto

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 2 -- ACLs: Security Auditor (admin_auditoria)"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase2_rbac.log"
p9_log $LogFile "=== INICIO: ACLs Security Auditor ==="

$identity = "$($Global:NetBIOS)\admin_auditoria"
$iden     = New-Object System.Security.Principal.NTAccount($identity)

# ---- ALLOW: GenericRead en todo el dominio (heredado) ----
p9_info "Aplicando Read-Only en todo el arbol AD..."

$OUs_ReadOnly = @(
    $Global:DominioDN,
    $Global:OU_Cuates,
    $Global:OU_NoCuates,
    $Global:OU_Admins,
    "CN=Users,$($Global:DominioDN)",
    "CN=Computers,$($Global:DominioDN)"
)

foreach ($ruta in $OUs_ReadOnly) {
    $nombre = ($ruta -split ",")[0] -replace "OU=|CN=|DC=",""
    try {
        $path = "AD:\$ruta"
        $acl  = Get-Acl -Path $path

        $aceRead = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $iden,
            [System.DirectoryServices.ActiveDirectoryRights]"GenericRead",
            [System.Security.AccessControl.AccessControlType]::Allow,
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All,
            [GUID]::Empty
        )
        $acl.AddAccessRule($aceRead)
        Set-Acl -Path $path -AclObject $acl
        p9_ok "  + Read-Only en: $nombre"
        p9_log $LogFile "GenericRead aplicado en $ruta para admin_auditoria"
    } catch {
        p9_warning "  Error en $nombre : $_"
        p9_log $LogFile "WARN Read-Only $ruta : $_"
    }
}

Write-Host ""

# ---- ALLOW: Leer Security Event Log ----
p9_info "Configurando acceso a Security Log..."
try {
    # Agregar admin_auditoria al grupo "Event Log Readers"
    Add-ADGroupMember -Identity "Event Log Readers" -Members "admin_auditoria" -ErrorAction Stop
    p9_ok "admin_auditoria agregado a 'Event Log Readers'."
    p9_log $LogFile "admin_auditoria agregado a Event Log Readers"
} catch {
    p9_warning "No se pudo agregar a Event Log Readers: $_"
    p9_log $LogFile "WARN Event Log Readers: $_"
}

# Configurar permisos del Security Log via wevtutil / registry
try {
    # El SDDL por defecto del Security Log ya permite a Event Log Readers leer
    # Verificamos el estado actual
    $logInfo = wevtutil gl Security 2>&1
    p9_info "Security Log configuracion:"
    $logInfo | Where-Object { $_ -match "access:|enabled:" } | ForEach-Object {
        p9_info "  $_"
    }
    p9_ok "Acceso al Security Log verificado."
} catch {
    p9_warning "No se pudo verificar Security Log: $_"
}

Write-Host ""

# ---- Crear carpeta de output accesible para admin_auditoria ----
p9_info "Configurando permisos en directorio de output: $($Global:OutputDir)..."
try {
    if (-not (Test-Path $Global:OutputDir)) {
        New-Item -ItemType Directory -Path $Global:OutputDir -Force | Out-Null
    }

    $acl      = Get-Acl -Path $Global:OutputDir
    $aceWrite = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $iden,
        [System.Security.AccessControl.FileSystemRights]"Modify, ReadAndExecute, Write",
        [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($aceWrite)
    Set-Acl -Path $Global:OutputDir -AclObject $acl
    p9_ok "admin_auditoria puede escribir en: $($Global:OutputDir)"
    p9_log $LogFile "Permisos escritura en OutputDir para admin_auditoria"
} catch {
    p9_warning "Error configurando output dir: $_"
}

Write-Host ""

# ---- DENY: Cualquier escritura en AD ----
p9_info "Aplicando DENY de escritura en el dominio para admin_auditoria..."
try {
    $domainPath = "AD:\$($Global:DominioDN)"
    $acl        = Get-Acl -Path $domainPath

    $aceDeny = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $iden,
        [System.DirectoryServices.ActiveDirectoryRights]"WriteProperty, WriteDacl, WriteOwner, GenericWrite",
        [System.Security.AccessControl.AccessControlType]::Deny,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All,
        [GUID]::Empty
    )
    $acl.AddAccessRule($aceDeny)
    Set-Acl -Path $domainPath -AclObject $acl
    p9_ok "DENY escritura en dominio aplicado para admin_auditoria."
    p9_log $LogFile "DENY escritura AD para admin_auditoria"
} catch {
    p9_warning "Error aplicando DENY escritura: $_"
    p9_log $LogFile "WARN DENY escritura: $_"
}

p9_linea
p9_log $LogFile "=== FIN: ACLs Security Auditor ==="
p9_ok "ACLs Security Auditor (Read-Only) aplicadas."
p9_pausa
