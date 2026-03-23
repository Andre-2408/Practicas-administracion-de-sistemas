# 01-ad-estructura.ps1 -- Estructura Organizativa: OUs, Grupos y Usuarios desde CSV
# Requiere: utils.AD.ps1 cargado previamente

# ------------------------------------------------------------
# Crear las Unidades Organizativas (OUs)
# ------------------------------------------------------------

function ad_crear_ous {
    aputs_info "Creando Unidades Organizativas..."

    $ous = @(
        @{ Nombre = "Cuates";   OU = $Script:AD_OU_CUATES;   Desc = "Usuarios con acceso 8AM-3PM"  },
        @{ Nombre = "NoCuates"; OU = $Script:AD_OU_NOCUATES; Desc = "Usuarios con acceso 3PM-2AM" }
    )

    foreach ($ou in $ous) {
        $existe = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$($ou.OU)'" `
            -ErrorAction SilentlyContinue

        if ($existe) {
            aputs_info "OU ya existe: $($ou.Nombre)"
        } else {
            New-ADOrganizationalUnit `
                -Name                  $ou.Nombre `
                -Path                  $Script:AD_DN_DOMINIO `
                -Description           $ou.Desc `
                -ProtectedFromAccidentalDeletion $false `
                -ErrorAction Stop
            aputs_ok "OU creada: $($ou.Nombre)"
        }
    }
}

# ------------------------------------------------------------
# Crear los Grupos de Seguridad
# ------------------------------------------------------------

function ad_crear_grupos {
    aputs_info "Creando grupos de seguridad..."

    $grupos = @(
        @{ Nombre = $Script:AD_GRUPO_CUATES;   OU = $Script:AD_OU_CUATES;   Desc = "Grupo Cuates -- acceso 8AM a 3PM"  },
        @{ Nombre = $Script:AD_GRUPO_NOCUATES; OU = $Script:AD_OU_NOCUATES; Desc = "Grupo NoCuates -- acceso 3PM a 2AM" }
    )

    foreach ($g in $grupos) {
        $existe = Get-ADGroup -Filter "Name -eq '$($g.Nombre)'" -ErrorAction SilentlyContinue
        if ($existe) {
            aputs_info "Grupo ya existe: $($g.Nombre)"
        } else {
            New-ADGroup `
                -Name          $g.Nombre `
                -GroupScope    Global `
                -GroupCategory Security `
                -Path          $g.OU `
                -Description   $g.Desc `
                -ErrorAction   Stop
            aputs_ok "Grupo creado: $($g.Nombre)"
        }
    }
}

# ------------------------------------------------------------
# Crear el recurso compartido para directorios personales
# ------------------------------------------------------------

function ad_crear_share_homes {
    aputs_info "Configurando directorio raiz de homes: $Script:AD_HOME_RAIZ"

    # Crear la carpeta raiz si no existe
    if (-not (Test-Path $Script:AD_HOME_RAIZ)) {
        New-Item -ItemType Directory -Path $Script:AD_HOME_RAIZ -Force | Out-Null
        aputs_ok "Carpeta creada: $Script:AD_HOME_RAIZ"
    } else {
        aputs_info "Carpeta ya existe: $Script:AD_HOME_RAIZ"
    }

    # Crear el recurso compartido si no existe
    $share = Get-SmbShare -Name $Script:AD_HOME_SHARE -ErrorAction SilentlyContinue
    if (-not $share) {
        # Usar WMI Win32_Share en lugar de New-SmbShare para evitar el error
        # "No mapping between account names and security identifiers" que ocurre
        # en Windows en español porque New-SmbShare internamente resuelve "Everyone"
        # por nombre (falla con "Todos"). Win32_Share.Create() no necesita resolver
        # ningun nombre de cuenta -- crea el share con permisos por defecto.
        $wmiShare  = [wmiclass]"Win32_Share"
        $resultado = $wmiShare.Create(
            $Script:AD_HOME_RAIZ,
            $Script:AD_HOME_SHARE,
            [uint32]0,   # 0 = Disco
            $null,
            "Directorios personales de usuarios AD (Practica 8)"
        )
        if ($resultado.ReturnValue -ne 0) {
            throw "No se pudo crear el recurso compartido (Win32_Share codigo $($resultado.ReturnValue))"
        }
        aputs_ok "Recurso compartido creado: \\$env:COMPUTERNAME\$Script:AD_HOME_SHARE"
    } else {
        aputs_info "Recurso compartido ya existe: $Script:AD_HOME_SHARE"
    }
}

# ------------------------------------------------------------
# Crear un usuario de AD con su directorio personal
# ------------------------------------------------------------

function _ad_crear_usuario {
    param(
        [string]$Nombre,
        [string]$NombrePropio,
        [string]$Apellido,
        [string]$Usuario,
        [string]$Contrasena,
        [string]$Departamento,
        [string]$Email
    )

    # Determinar OU y grupo segun el departamento del CSV
    if ($Departamento -eq "Cuates") {
        $ouDestino    = $Script:AD_OU_CUATES
        $grupoDestino = $Script:AD_GRUPO_CUATES
    } else {
        $ouDestino    = $Script:AD_OU_NOCUATES
        $grupoDestino = $Script:AD_GRUPO_NOCUATES
    }

    # Directorio personal del usuario
    $homeDir = "$Script:AD_HOME_RAIZ\$Usuario"
    $homeUNC = "$Script:AD_HOME_UNC\$Usuario"

    # Crear carpeta personal local
    if (-not (Test-Path $homeDir)) {
        New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
    }

    # Convertir contrasena a SecureString
    $securePass = ConvertTo-SecureString $Contrasena -AsPlainText -Force

    # Verificar si el usuario ya existe
    $existente = Get-ADUser -Filter "SamAccountName -eq '$Usuario'" -ErrorAction SilentlyContinue

    if ($existente) {
        aputs_info "Usuario ya existe: $Usuario (verificando OU y grupo)"
        # Mover a la OU correcta si es necesario
        if ($existente.DistinguishedName -notlike "*$ouDestino") {
            Move-ADObject -Identity $existente.DistinguishedName -TargetPath $ouDestino
            aputs_ok "Usuario movido a OU correcta: $Usuario -> $Departamento"
        }
    } else {
        New-ADUser `
            -Name              $Nombre `
            -GivenName         $NombrePropio `
            -Surname           $Apellido `
            -SamAccountName    $Usuario `
            -UserPrincipalName "$Usuario@$Script:AD_DOMINIO" `
            -EmailAddress      $Email `
            -Department        $Departamento `
            -AccountPassword   $securePass `
            -Path              $ouDestino `
            -HomeDirectory     $homeUNC `
            -HomeDrive         "H:" `
            -Enabled           $true `
            -PasswordNeverExpires $true `
            -ErrorAction Stop
        aputs_ok "Usuario creado: $Usuario [$Departamento]"
    }

    # Aplicar permisos NTFS DESPUES de crear el usuario, para que su SID ya exista en AD
    $acl   = Get-Acl $homeDir
    $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$Script:AD_NETBIOS\$Usuario",
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )
    $acl.SetAccessRule($regla)
    Set-Acl -Path $homeDir -AclObject $acl

    # Agregar al grupo correspondiente si no es miembro
    $esMiembro = Get-ADGroupMember -Identity $grupoDestino -ErrorAction SilentlyContinue |
        Where-Object { $_.SamAccountName -eq $Usuario }

    if (-not $esMiembro) {
        Add-ADGroupMember -Identity $grupoDestino -Members $Usuario -ErrorAction Stop
        aputs_ok "Agregado al grupo: $Usuario -> $grupoDestino"
    }
}

# ------------------------------------------------------------
# Importar usuarios desde el archivo CSV
# ------------------------------------------------------------

function ad_importar_usuarios {
    aputs_info "Importando usuarios desde CSV: $Script:AD_CSV_PATH"
    Write-Host ""

    if (-not (Test-Path $Script:AD_CSV_PATH)) {
        aputs_error "Archivo CSV no encontrado: $Script:AD_CSV_PATH"
        return $false
    }

    $usuarios = Import-Csv -Path $Script:AD_CSV_PATH -Encoding UTF8
    $total    = $usuarios.Count
    $exito    = 0
    $errores  = 0

    foreach ($u in $usuarios) {
        try {
            _ad_crear_usuario `
                -Nombre       $u.Nombre `
                -NombrePropio $u.NombrePropio `
                -Apellido     $u.Apellido `
                -Usuario      $u.Usuario `
                -Contrasena   $u.Contrasena `
                -Departamento $u.Departamento `
                -Email        $u.Email
            $exito++
        } catch {
            aputs_error "Error al procesar '$($u.Usuario)': $_"
            $errores++
        }
    }

    Write-Host ""
    draw_line
    aputs_info "Importacion completada: $exito/$total exitosos, $errores errores"
    return ($errores -eq 0)
}

# ------------------------------------------------------------
# Verificar la estructura creada
# ------------------------------------------------------------

function ad_verificar_estructura {
    Write-Host ""
    aputs_info "--- Verificacion de estructura AD ---"

    # OUs
    foreach ($ouDN in @($Script:AD_OU_CUATES, $Script:AD_OU_NOCUATES)) {
        $ou = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" `
            -ErrorAction SilentlyContinue
        if ($ou) {
            aputs_ok "OU: $($ou.Name)"
        } else {
            aputs_error "OU no encontrada: $ouDN"
        }
    }

    # Grupos
    foreach ($grpNombre in @($Script:AD_GRUPO_CUATES, $Script:AD_GRUPO_NOCUATES)) {
        $g = Get-ADGroup -Filter "Name -eq '$grpNombre'" -ErrorAction SilentlyContinue
        if ($g) {
            $miembros = (Get-ADGroupMember -Identity $grpNombre -ErrorAction SilentlyContinue).Count
            aputs_ok "Grupo: $grpNombre ($miembros miembros)"
        } else {
            aputs_error "Grupo no encontrado: $grpNombre"
        }
    }

    # Usuarios en cada OU
    $cuates   = @(Get-ADUser -Filter * -SearchBase $Script:AD_OU_CUATES   -ErrorAction SilentlyContinue)
    $nocuates = @(Get-ADUser -Filter * -SearchBase $Script:AD_OU_NOCUATES -ErrorAction SilentlyContinue)

    aputs_info "Usuarios en Cuates:   $($cuates.Count)"
    aputs_info "Usuarios en NoCuates: $($nocuates.Count)"
}

# ------------------------------------------------------------
# Orquestador: ejecutar todos los pasos de estructura
# ------------------------------------------------------------

function ad_estructura_completa {
    Clear-Host
    ad_mostrar_banner "Paso 1 -- Estructura Organizativa AD"

    if (-not (ad_verificar_modulo_ad)) { pause; return }

    Write-Host ""
    draw_line

    aputs_info "Iniciando configuracion de estructura AD..."
    Write-Host ""

    try {
        ad_crear_ous
        Write-Host ""
        ad_crear_grupos
        Write-Host ""
        ad_crear_share_homes
        Write-Host ""
        ad_importar_usuarios
        Write-Host ""
        ad_verificar_estructura
        Write-Host ""
        draw_line
        aputs_ok "Estructura AD configurada correctamente"
    } catch {
        aputs_error "Error durante la configuracion: $_"
    }

    pause
}
