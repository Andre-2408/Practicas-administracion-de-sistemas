# 03-fsrm-cuotas.ps1 -- FSRM: Cuotas de disco y Apantallamiento Activo de Archivos
# Requiere: utils.AD.ps1 cargado previamente
#
# Cuotas:
#   Cuates   -> 10 MB (hard limit)
#   NoCuates ->  5 MB (hard limit)
#
# Apantallamiento Activo (Active Screening):
#   Bloquea: *.mp3, *.mp4, *.exe, *.msi

# ------------------------------------------------------------
# Instalar la caracteristica FSRM si no esta presente
# ------------------------------------------------------------

function fsrm_instalar {
    aputs_info "Verificando caracteristica FSRM..."

    $feature = Get-WindowsFeature -Name FS-Resource-Manager -ErrorAction SilentlyContinue

    if ($feature -and $feature.Installed) {
        aputs_info "FSRM ya esta instalado"
        return $true
    }

    aputs_info "Instalando FSRM (File Server Resource Manager)..."
    $resultado = Install-WindowsFeature `
        -Name FS-Resource-Manager `
        -IncludeManagementTools `
        -ErrorAction Stop

    if ($resultado.Success) {
        aputs_ok "FSRM instalado correctamente"
        if ($resultado.RestartNeeded -eq "Yes") {
            aputs_warning "Se requiere reiniciar el servidor para completar la instalacion"
        }
        return $true
    } else {
        aputs_error "Fallo la instalacion de FSRM"
        return $false
    }
}

# ------------------------------------------------------------
# Crear plantillas de cuota (5 MB y 10 MB, hard limit)
# ------------------------------------------------------------

function fsrm_crear_plantillas_cuota {
    aputs_info "Creando plantillas de cuota FSRM..."

    $plantillas = @(
        @{
            Nombre      = $Script:AD_FSRM_TPL_CUOTAS_NOCUATES
            Tamano      = $Script:AD_CUOTA_NOCUATES     # 5 MB
            Descripcion = "Cuota 5 MB - Grupo NoCuates (limite estricto)"
        },
        @{
            Nombre      = $Script:AD_FSRM_TPL_CUOTAS_CUATES
            Tamano      = $Script:AD_CUOTA_CUATES        # 10 MB
            Descripcion = "Cuota 10 MB - Grupo Cuates (limite estricto)"
        }
    )

    foreach ($p in $plantillas) {
        $existe = Get-FsrmQuotaTemplate -Name $p.Nombre -ErrorAction SilentlyContinue

        if ($existe) {
            aputs_info "Plantilla ya existe: $($p.Nombre) -- actualizando..."
            Set-FsrmQuotaTemplate `
                -Name        $p.Nombre `
                -Size        $p.Tamano `
                -Description $p.Descripcion `
                -ErrorAction Stop
        } else {
            New-FsrmQuotaTemplate `
                -Name        $p.Nombre `
                -Size        $p.Tamano `
                -Description $p.Descripcion `
                -ErrorAction Stop | Out-Null
        }

        $mb = [Math]::Round($p.Tamano / 1MB, 0)
        aputs_ok "Plantilla configurada: $($p.Nombre) ($mb MB, limite estricto)"
    }
}

# ------------------------------------------------------------
# Crear grupo de archivos bloqueados
# ------------------------------------------------------------

function fsrm_crear_grupo_archivos {
    aputs_info "Creando grupo de archivos prohibidos: $Script:AD_FSRM_GRUPO_BLOQUEADOS"

    $existe = Get-FsrmFileGroup -Name $Script:AD_FSRM_GRUPO_BLOQUEADOS -ErrorAction SilentlyContinue

    if ($existe) {
        aputs_info "Grupo de archivos ya existe -- actualizando..."
        Set-FsrmFileGroup `
            -Name           $Script:AD_FSRM_GRUPO_BLOQUEADOS `
            -IncludePattern $Script:AD_FSRM_EXTENSIONES_BLOQUEADAS `
            -ErrorAction    Stop
    } else {
        New-FsrmFileGroup `
            -Name           $Script:AD_FSRM_GRUPO_BLOQUEADOS `
            -IncludePattern $Script:AD_FSRM_EXTENSIONES_BLOQUEADAS `
            -ErrorAction    Stop | Out-Null
    }

    aputs_ok "Grupo configurado con extensiones: $($Script:AD_FSRM_EXTENSIONES_BLOQUEADAS -join ', ')"
}

# ------------------------------------------------------------
# Crear plantilla de apantallamiento activo
# ------------------------------------------------------------

function fsrm_crear_plantilla_pantalla {
    aputs_info "Creando plantilla de apantallamiento activo: $Script:AD_FSRM_TPL_PANTALLA"

    $existe = Get-FsrmFileScreenTemplate -Name $Script:AD_FSRM_TPL_PANTALLA -ErrorAction SilentlyContinue

    if ($existe) {
        aputs_info "Plantilla de pantalla ya existe -- actualizando..."
        Set-FsrmFileScreenTemplate `
            -Name         $Script:AD_FSRM_TPL_PANTALLA `
            -Active       `
            -IncludeGroup @($Script:AD_FSRM_GRUPO_BLOQUEADOS) `
            -ErrorAction  Stop
    } else {
        New-FsrmFileScreenTemplate `
            -Name         $Script:AD_FSRM_TPL_PANTALLA `
            -Active       `
            -IncludeGroup @($Script:AD_FSRM_GRUPO_BLOQUEADOS) `
            -ErrorAction  Stop | Out-Null
    }

    aputs_ok "Plantilla de apantallamiento activo configurada (bloqueo real, no solo auditoria)"
}

# ------------------------------------------------------------
# Aplicar cuota y apantallamiento a la carpeta de un usuario
# ------------------------------------------------------------

function _fsrm_aplicar_usuario {
    param(
        [string]$Usuario,
        [string]$NombrePlantillaCuota
    )

    $carpeta = "$Script:AD_HOME_RAIZ\$Usuario"

    # Crear carpeta si aun no existe (puede pasar si el usuario no ha iniciado sesion)
    if (-not (Test-Path $carpeta)) {
        New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        aputs_info "Carpeta creada para usuario: $Usuario"
    }

    # --- Cuota ---
    $cuotaExiste = Get-FsrmQuota -Path $carpeta -ErrorAction SilentlyContinue
    if ($cuotaExiste) {
        Set-FsrmQuota -Path $carpeta -Template $NombrePlantillaCuota -ErrorAction Stop
    } else {
        New-FsrmQuota -Path $carpeta -Template $NombrePlantillaCuota -ErrorAction Stop | Out-Null
    }

    # --- Apantallamiento activo ---
    $pantallaExiste = Get-FsrmFileScreen -Path $carpeta -ErrorAction SilentlyContinue
    if ($pantallaExiste) {
        Set-FsrmFileScreen -Path $carpeta -Template $Script:AD_FSRM_TPL_PANTALLA -ErrorAction Stop
    } else {
        New-FsrmFileScreen -Path $carpeta -Template $Script:AD_FSRM_TPL_PANTALLA -ErrorAction Stop | Out-Null
    }

    aputs_ok "$Usuario : cuota=$NombrePlantillaCuota  pantalla=$Script:AD_FSRM_TPL_PANTALLA"
}

# ------------------------------------------------------------
# Aplicar cuotas y pantallas a todos los usuarios segun su grupo
# ------------------------------------------------------------

function fsrm_aplicar_a_usuarios {
    aputs_info "Aplicando cuotas y apantallamiento a usuarios..."
    Write-Host ""

    # Usuarios Cuates -> 10 MB
    $miembrosCuates = Get-ADGroupMember -Identity $Script:AD_GRUPO_CUATES `
        -ErrorAction SilentlyContinue | Where-Object { $_.objectClass -eq "user" }

    if ($miembrosCuates) {
        aputs_info "Grupo Cuates (10 MB):"
        foreach ($u in $miembrosCuates) {
            try {
                _fsrm_aplicar_usuario -Usuario $u.SamAccountName `
                    -NombrePlantillaCuota $Script:AD_FSRM_TPL_CUOTAS_CUATES
            } catch {
                aputs_error "  Error en $($u.SamAccountName): $_"
            }
        }
    } else {
        aputs_warning "Grupo '$Script:AD_GRUPO_CUATES' sin miembros"
    }

    Write-Host ""

    # Usuarios NoCuates -> 5 MB
    $miembrosNoCuates = Get-ADGroupMember -Identity $Script:AD_GRUPO_NOCUATES `
        -ErrorAction SilentlyContinue | Where-Object { $_.objectClass -eq "user" }

    if ($miembrosNoCuates) {
        aputs_info "Grupo NoCuates (5 MB):"
        foreach ($u in $miembrosNoCuates) {
            try {
                _fsrm_aplicar_usuario -Usuario $u.SamAccountName `
                    -NombrePlantillaCuota $Script:AD_FSRM_TPL_CUOTAS_NOCUATES
            } catch {
                aputs_error "  Error en $($u.SamAccountName): $_"
            }
        }
    } else {
        aputs_warning "Grupo '$Script:AD_GRUPO_NOCUATES' sin miembros"
    }
}

# ------------------------------------------------------------
# Verificar cuotas y pantallas aplicadas
# ------------------------------------------------------------

function fsrm_verificar {
    Write-Host ""
    aputs_info "--- Verificacion FSRM ---"
    Write-Host ""

    aputs_info "Cuotas configuradas:"
    Get-FsrmQuota -ErrorAction SilentlyContinue | ForEach-Object {
        $mb = [Math]::Round($_.Size / 1MB, 0)
        $usado = [Math]::Round($_.Usage / 1MB, 2)
        Write-Host ("    {0,-40} Limite: {1,3} MB  Usado: {2} MB" -f $_.Path, $mb, $usado)
    }

    Write-Host ""
    aputs_info "Pantallas de archivos activas:"
    Get-FsrmFileScreen -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("    {0,-40} Tipo: {1}" -f $_.Path, $(if ($_.Active) { "ACTIVO (bloqueo)" } else { "Pasivo (auditoria)" }))
    }
}

# ------------------------------------------------------------
# Orquestador: configuracion completa FSRM
# ------------------------------------------------------------

function fsrm_configurar_completo {
    Clear-Host
    ad_mostrar_banner "Paso 3 -- Gestion de Almacenamiento (FSRM)"

    Write-Host ""
    Write-Host "  Cuotas a aplicar:"
    Write-Host "    Cuates   -> $([Math]::Round($Script:AD_CUOTA_CUATES / 1MB, 0)) MB (limite estricto)"
    Write-Host "    NoCuates -> $([Math]::Round($Script:AD_CUOTA_NOCUATES / 1MB, 0)) MB (limite estricto)"
    Write-Host ""
    Write-Host "  Extensiones bloqueadas: $($Script:AD_FSRM_EXTENSIONES_BLOQUEADAS -join '  ')"
    Write-Host ""
    draw_line
    Write-Host ""

    try {
        if (-not (fsrm_instalar)) { pause; return }
        Write-Host ""

        # Importar modulo FSRM
        Import-Module FileServerResourceManager -ErrorAction Stop | Out-Null
        aputs_ok "Modulo FSRM cargado"
        Write-Host ""

        fsrm_crear_plantillas_cuota
        Write-Host ""
        fsrm_crear_grupo_archivos
        Write-Host ""
        fsrm_crear_plantilla_pantalla
        Write-Host ""
        fsrm_aplicar_a_usuarios
        Write-Host ""
        fsrm_verificar
        Write-Host ""
        draw_line
        aputs_ok "FSRM configurado correctamente"

    } catch {
        aputs_error "Error durante configuracion FSRM: $_"
    }

    pause
}
