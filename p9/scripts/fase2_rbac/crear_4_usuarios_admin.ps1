# crear_4_usuarios_admin.ps1 -- Fase 2: Crear los 4 usuarios administradores delegados
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
# Roles: admin_identidad, admin_storage, admin_politicas, admin_auditoria

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 2 -- Creacion de Administradores Delegados"
Ensure-OutputDir

$LogFile = "$($Global:OutputDir)\fase2_rbac.log"
p9_log $LogFile "=== INICIO: Creacion de 4 usuarios admin ==="

# Crear OU de Administradores si no existe
p9_info "Verificando OU Administradores..."
try {
    $ouAdmin = Get-ADOrganizationalUnit -Filter { Name -eq "Administradores" } -ErrorAction SilentlyContinue
    if (-not $ouAdmin) {
        New-ADOrganizationalUnit -Name "Administradores" -Path $Global:DominioDN -ProtectedFromAccidentalDeletion $false
        p9_ok "OU Administradores creada."
        p9_log $LogFile "OU Administradores creada en $($Global:DominioDN)"
    } else {
        p9_info "OU Administradores ya existe."
    }
} catch {
    p9_error "Error con OU Administradores: $_"
    exit 1
}

Write-Host ""

# Crear grupo de seguridad para cada rol
$grupos = @(
    @{ Nombre="GRP_IAM_Operators";    Desc="Operadores de Identidad y Acceso"  },
    @{ Nombre="GRP_Storage_Operators"; Desc="Operadores de Almacenamiento"      },
    @{ Nombre="GRP_GPO_Compliance";    Desc="Administradores de Politicas GPO"  },
    @{ Nombre="GRP_Security_Auditors"; Desc="Auditores de Seguridad"            }
)

p9_info "Creando grupos de seguridad..."
foreach ($grp in $grupos) {
    try {
        $existe = Get-ADGroup -Filter { Name -eq $grp.Nombre } -ErrorAction SilentlyContinue
        if (-not $existe) {
            New-ADGroup -Name $grp.Nombre -GroupScope Global -GroupCategory Security `
                -Description $grp.Desc -Path $Global:OU_Admins -ErrorAction Stop
            p9_ok "Grupo creado: $($grp.Nombre)"
            p9_log $LogFile "Grupo creado: $($grp.Nombre)"
        } else {
            p9_info "Grupo ya existe: $($grp.Nombre)"
        }
    } catch {
        p9_error "Error al crear grupo $($grp.Nombre): $_"
    }
}

Write-Host ""

# Definicion de usuarios con sus grupos y contrasenas
$adminDefs = @(
    @{
        Usuario    = "admin_identidad"
        Nombre     = "Admin"
        Apellido   = "Identidad"
        Rol        = "IAM Operator"
        Grupo      = "GRP_IAM_Operators"
        Password   = "AdminIAM@2024!"
        Descripcion= "Administrador delegado -- Gestion de identidad y acceso"
    },
    @{
        Usuario    = "admin_storage"
        Nombre     = "Admin"
        Apellido   = "Storage"
        Rol        = "Storage Operator"
        Grupo      = "GRP_Storage_Operators"
        Password   = "AdminSTO@2024!"
        Descripcion= "Administrador delegado -- Gestion de almacenamiento FSRM"
    },
    @{
        Usuario    = "admin_politicas"
        Nombre     = "Admin"
        Apellido   = "Politicas"
        Rol        = "GPO Compliance"
        Grupo      = "GRP_GPO_Compliance"
        Password   = "AdminGPO@2024!"
        Descripcion= "Administrador delegado -- Gestion de politicas GPO"
    },
    @{
        Usuario    = "admin_auditoria"
        Nombre     = "Admin"
        Apellido   = "Auditoria"
        Rol        = "Security Auditor"
        Grupo      = "GRP_Security_Auditors"
        Password   = "AdminAUD@2024!"
        Descripcion= "Administrador delegado -- Auditor de seguridad (Read-Only)"
    }
)

p9_info "Creando usuarios administradores..."
p9_linea

foreach ($admin in $adminDefs) {
    try {
        $existe = Get-ADUser -Filter { SamAccountName -eq $admin.Usuario } -ErrorAction SilentlyContinue
        if ($existe) {
            p9_warning "Usuario ya existe: $($admin.Usuario) -- Omitiendo creacion."
        } else {
            $secPass = ConvertTo-SecureString $admin.Password -AsPlainText -Force
            New-ADUser `
                -SamAccountName    $admin.Usuario `
                -GivenName         $admin.Nombre `
                -Surname           $admin.Apellido `
                -Name              "$($admin.Nombre) $($admin.Apellido)" `
                -DisplayName       "$($admin.Rol)" `
                -Description       $admin.Descripcion `
                -UserPrincipalName "$($admin.Usuario)@$($Global:Dominio)" `
                -AccountPassword   $secPass `
                -Enabled           $true `
                -PasswordNeverExpires $false `
                -ChangePasswordAtLogon $false `
                -Path              $Global:OU_Admins `
                -ErrorAction Stop

            p9_ok "Usuario creado: $($admin.Usuario)  [$($admin.Rol)]"
            p9_log $LogFile "Usuario creado: $($admin.Usuario) | Rol: $($admin.Rol)"
        }

        # Agregar al grupo correspondiente
        try {
            Add-ADGroupMember -Identity $admin.Grupo -Members $admin.Usuario -ErrorAction Stop
            p9_ok "  -> Agregado a grupo: $($admin.Grupo)"
            p9_log $LogFile "$($admin.Usuario) agregado a $($admin.Grupo)"
        } catch {
            p9_warning "  Error al agregar a grupo: $_"
        }

    } catch {
        p9_error "Error al crear $($admin.Usuario): $_"
        p9_log $LogFile "ERROR: $($admin.Usuario) -- $_"
    }

    Write-Host ""
}

# Resumen final
p9_linea
p9_info "Resumen de usuarios creados:"
Get-ADUser -Filter { DistinguishedName -like "*Administradores*" } -Properties Description |
    Select-Object SamAccountName, Enabled, Description |
    Format-Table -AutoSize

p9_log $LogFile "=== FIN: Creacion de usuarios admin ==="
p9_ok "Fase 2 - Creacion de usuarios completada."
p9_pausa
