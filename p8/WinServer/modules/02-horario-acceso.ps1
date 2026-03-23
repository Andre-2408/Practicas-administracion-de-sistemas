# 02-horario-acceso.ps1 -- Control de Acceso Temporal (Logon Hours)
# Requiere: utils.AD.ps1 cargado previamente
#
# Cuates:   8:00 AM  - 3:00 PM  (horario local, UTC-6 = 14:00-20:00 UTC)
# NoCuates: 3:00 PM  - 2:00 AM  (horario local, cruza medianoche)

# ------------------------------------------------------------
# Aplicar horario a todos los usuarios de un grupo
# ------------------------------------------------------------

function _horario_aplicar_grupo {
    param(
        [string] $NombreGrupo,
        [byte[]] $BytesHorario,
        [string] $Descripcion
    )

    aputs_info "Aplicando horario '$Descripcion' al grupo: $NombreGrupo"

    $miembros = Get-ADGroupMember -Identity $NombreGrupo -ErrorAction SilentlyContinue |
        Where-Object { $_.objectClass -eq "user" }

    if (-not $miembros) {
        aputs_warning "El grupo '$NombreGrupo' no tiene miembros o no existe"
        return
    }

    $exito   = 0
    $errores = 0

    foreach ($m in $miembros) {
        try {
            Set-ADUser -Identity $m.SamAccountName `
                -Replace @{ logonHours = $BytesHorario } `
                -ErrorAction Stop
            aputs_ok "Horario aplicado: $($m.SamAccountName)"
            $exito++
        } catch {
            aputs_error "Error en $($m.SamAccountName): $_"
            $errores++
        }
    }

    aputs_info "$exito aplicados, $errores errores en grupo '$NombreGrupo'"
}

# ------------------------------------------------------------
# Aplicar horarios para ambos grupos
# ------------------------------------------------------------

function horario_aplicar_cuates {
    $bytes = ad_calcular_bytes_horario `
        -HoraInicioLocal $Script:AD_CUATES_HORA_INICIO `
        -HoraFinLocal    $Script:AD_CUATES_HORA_FIN `
        -OffsetUTC       $Script:AD_UTC_OFFSET

    _horario_aplicar_grupo `
        -NombreGrupo  $Script:AD_GRUPO_CUATES `
        -BytesHorario $bytes `
        -Descripcion  "8:00 AM - 3:00 PM"
}

function horario_aplicar_nocuates {
    $bytes = ad_calcular_bytes_horario `
        -HoraInicioLocal $Script:AD_NOCUATES_HORA_INICIO `
        -HoraFinLocal    $Script:AD_NOCUATES_HORA_FIN `
        -OffsetUTC       $Script:AD_UTC_OFFSET

    _horario_aplicar_grupo `
        -NombreGrupo  $Script:AD_GRUPO_NOCUATES `
        -BytesHorario $bytes `
        -Descripcion  "3:00 PM - 2:00 AM"
}

# ------------------------------------------------------------
# Mostrar horario actual de un usuario (para verificacion)
# ------------------------------------------------------------

function horario_mostrar_usuario {
    param([string]$Usuario)

    $u = Get-ADUser -Identity $Usuario -Properties logonHours -ErrorAction SilentlyContinue
    if (-not $u) {
        aputs_error "Usuario no encontrado: $Usuario"
        return
    }

    if (-not $u.logonHours) {
        aputs_info "$Usuario : Sin restriccion de horario (acceso 24/7)"
        return
    }

    # Contar horas permitidas
    $horasPermitidas = 0
    for ($i = 0; $i -lt 21; $i++) {
        $byte = $u.logonHours[$i]
        for ($b = 0; $b -lt 8; $b++) {
            if ($byte -band (1 -shl $b)) { $horasPermitidas++ }
        }
    }

    aputs_info "$Usuario : $horasPermitidas horas/semana permitidas ($($u.logonHours.Count) bytes de logonHours configurados)"
}

# ------------------------------------------------------------
# Verificar horarios de todos los usuarios
# ------------------------------------------------------------

function horario_verificar {
    Write-Host ""
    aputs_info "--- Verificacion de horarios de acceso ---"
    Write-Host ""

    $diasNombres = @("Dom","Lun","Mar","Mie","Jue","Vie","Sab")

    foreach ($grupo in @($Script:AD_GRUPO_CUATES, $Script:AD_GRUPO_NOCUATES)) {
        Write-Host "  Grupo: $grupo"

        $miembros = Get-ADGroupMember -Identity $grupo -ErrorAction SilentlyContinue |
            Where-Object { $_.objectClass -eq "user" }

        if (-not $miembros) {
            aputs_warning "    Sin miembros"
            continue
        }

        foreach ($m in $miembros) {
            $u = Get-ADUser -Identity $m.SamAccountName -Properties logonHours `
                -ErrorAction SilentlyContinue
            if ($u -and $u.logonHours) {
                # Contar bits activos
                $bits = 0
                foreach ($b in $u.logonHours) {
                    for ($i = 0; $i -lt 8; $i++) {
                        if ($b -band (1 -shl $i)) { $bits++ }
                    }
                }
                Write-Host ("    {0,-15} : {1,3} horas/semana permitidas" -f $m.SamAccountName, $bits)
            } else {
                Write-Host ("    {0,-15} : Sin restriccion (24/7)" -f $m.SamAccountName)
            }
        }
        Write-Host ""
    }
}

# ------------------------------------------------------------
# Orquestador: aplicar horarios a ambos grupos
# ------------------------------------------------------------

function horario_configurar_completo {
    Clear-Host
    ad_mostrar_banner "Paso 2 -- Control de Acceso Temporal (Logon Hours)"

    if (-not (ad_verificar_modulo_ad)) { pause; return }

    Write-Host ""
    Write-Host "  Configuracion de horarios:"
    Write-Host ("    {0,-12} : {1}:00 - {2}:00 (hora local, UTC{3})" -f `
        $Script:AD_GRUPO_CUATES,
        $Script:AD_CUATES_HORA_INICIO,
        $Script:AD_CUATES_HORA_FIN,
        $Script:AD_UTC_OFFSET)
    Write-Host ("    {0,-12} : {1}:00 - {2}:00 (hora local, cruza medianoche)" -f `
        $Script:AD_GRUPO_NOCUATES,
        $Script:AD_NOCUATES_HORA_INICIO,
        $Script:AD_NOCUATES_HORA_FIN)
    Write-Host ""
    draw_line
    Write-Host ""

    try {
        horario_aplicar_cuates
        Write-Host ""
        horario_aplicar_nocuates
        Write-Host ""
        horario_verificar
        draw_line
        aputs_ok "Horarios de acceso configurados"
        aputs_info "NOTA: La politica 'Forzar cierre de sesion' se configura en el Paso 5"
    } catch {
        aputs_error "Error al configurar horarios: $_"
    }

    pause
}
