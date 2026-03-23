# 05-gpo-cierre-sesion.ps1 -- GPO: Forzar cierre de sesion al expirar el horario
# Requiere: utils.AD.ps1 cargado previamente
#
# Configura la politica:
#   "Seguridad de red: cerrar la sesion de los usuarios cuando expire el
#    tiempo de inicio de sesion"
#
# Esta politica se almacena en el GptTmpl.inf de la GPO (Security Settings)
# y corresponde a la opcion: ForceLogoffWhenHourExpire = 1

# ------------------------------------------------------------
# Obtener o crear la GPO de seguridad
# ------------------------------------------------------------

function _gpo_obtener_o_crear {
    $gpo = Get-GPO -Name $Script:AD_GPO_SEGURIDAD -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $Script:AD_GPO_SEGURIDAD -Domain $Script:AD_DOMINIO -ErrorAction Stop
        aputs_ok "GPO de seguridad creada: $Script:AD_GPO_SEGURIDAD"
    } else {
        aputs_info "GPO de seguridad ya existe: $Script:AD_GPO_SEGURIDAD"
    }
    return $gpo
}

# ------------------------------------------------------------
# Escribir GptTmpl.inf con la configuracion de cierre de sesion
# ------------------------------------------------------------

function _gpo_escribir_gpt_tmpl {
    param([System.Guid]$GpoId)

    $domainDNS = (Get-ADDomain).DNSRoot
    $gpoGuid   = $GpoId.ToString().ToUpper()

    # Ruta SYSVOL donde se almacena la plantilla de seguridad de la GPO
    $sysvol = "\\$domainDNS\SYSVOL\$domainDNS\Policies\{$gpoGuid}\Machine\Microsoft\Windows NT\SecEdit"

    # Crear el directorio si no existe
    if (-not (Test-Path $sysvol)) {
        New-Item -ItemType Directory -Path $sysvol -Force | Out-Null
        aputs_ok "Directorio SecEdit creado en SYSVOL"
    }

    $gptTmplPath = "$sysvol\GptTmpl.inf"

    # Leer GptTmpl.inf existente o partir de plantilla base
    if (Test-Path $gptTmplPath) {
        $contenido = Get-Content $gptTmplPath -Raw -Encoding Unicode

        # Actualizar ForceLogoffWhenHourExpire si ya existe la seccion
        if ($contenido -match '\[System Access\]') {
            if ($contenido -match 'ForceLogoffWhenHourExpire') {
                # Reemplazar valor existente
                $contenido = $contenido -replace 'ForceLogoffWhenHourExpire\s*=\s*\d+', 'ForceLogoffWhenHourExpire = 1'
            } else {
                # Insertar despues de [System Access]
                $contenido = $contenido -replace '\[System Access\]', "[System Access]`r`nForceLogoffWhenHourExpire = 1"
            }
        } else {
            # Agregar seccion completa al final
            $contenido += "`r`n[System Access]`r`nForceLogoffWhenHourExpire = 1`r`n"
        }

        $contenido | Out-File -FilePath $gptTmplPath -Encoding Unicode -Force
        aputs_ok "GptTmpl.inf actualizado: ForceLogoffWhenHourExpire = 1"

    } else {
        # Crear GptTmpl.inf desde cero
        $nuevo = @"
[Unicode]
Unicode=yes

[Version]
signature="`$CHICAGO`$"
Revision=1

[System Access]
ForceLogoffWhenHourExpire = 1
"@
        $nuevo | Out-File -FilePath $gptTmplPath -Encoding Unicode -Force
        aputs_ok "GptTmpl.inf creado con ForceLogoffWhenHourExpire = 1"
    }

    return $gptTmplPath
}

# ------------------------------------------------------------
# Actualizar el version counter de la GPO (GPT.INI)
# Esto notifica a los clientes que deben recargar la politica
# ------------------------------------------------------------

function _gpo_incrementar_version {
    param([System.Guid]$GpoId)

    $domainDNS = (Get-ADDomain).DNSRoot
    $gpoGuid   = $GpoId.ToString().ToUpper()
    $gptIni    = "\\$domainDNS\SYSVOL\$domainDNS\Policies\{$gpoGuid}\GPT.INI"

    if (-not (Test-Path $gptIni)) {
        # Crear GPT.INI basico
        @"
[General]
Version=1
displayName=New Group Policy Object
"@ | Out-File -FilePath $gptIni -Encoding ASCII -Force
        aputs_info "GPT.INI creado"
        return
    }

    $contenido = Get-Content $gptIni
    $versionLinea = $contenido | Where-Object { $_ -match '^Version=' }

    if ($versionLinea) {
        $versionActual = [int]($versionLinea -replace 'Version=', '')
        # El numero de version: bits 0-15 = version usuario, bits 16-31 = version maquina
        # Incrementar la parte de maquina (upper 16 bits)
        $nuevaVersion = $versionActual + 65536   # +1 en la parte alta (maquina)
        $contenido = $contenido -replace "^Version=.*", "Version=$nuevaVersion"
        $contenido | Out-File -FilePath $gptIni -Encoding ASCII -Force
        aputs_ok "Version GPT.INI incrementada: $versionActual -> $nuevaVersion"
    }
}

# ------------------------------------------------------------
# Vincular la GPO al dominio
# ------------------------------------------------------------

function _gpo_vincular_dominio {
    param([string]$NombreGPO)

    $domainDN = (Get-ADDomain).DistinguishedName

    $enlaceExiste = Get-GPInheritance -Target $domainDN -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty GpoLinks |
        Where-Object { $_.DisplayName -eq $NombreGPO }

    if (-not $enlaceExiste) {
        New-GPLink -Name $NombreGPO -Target $domainDN -Enforced Yes -ErrorAction Stop | Out-Null
        aputs_ok "GPO '$NombreGPO' vinculada al dominio (Enforced)"
    } else {
        aputs_info "GPO '$NombreGPO' ya esta vinculada al dominio"
    }
}

# ------------------------------------------------------------
# Forzar actualizacion de politicas en el DC (gpupdate)
# ------------------------------------------------------------

function gpo_forzar_actualizacion {
    aputs_info "Forzando actualizacion de politicas de grupo (gpupdate /force)..."
    try {
        $output = gpupdate /force 2>&1
        aputs_ok "gpupdate completado"
        Write-Host ""
        $output | ForEach-Object { Write-Host "    $_" }
    } catch {
        aputs_warning "gpupdate fallo: $_"
    }
}

# ------------------------------------------------------------
# Verificar que la politica esta aplicada
# ------------------------------------------------------------

function gpo_verificar_cierre_sesion {
    Write-Host ""
    aputs_info "--- Verificacion GPO Cierre de Sesion ---"
    Write-Host ""

    $gpo = Get-GPO -Name $Script:AD_GPO_SEGURIDAD -ErrorAction SilentlyContinue
    if ($gpo) {
        Write-Host ("    {0,-30} : {1}" -f "GPO", $Script:AD_GPO_SEGURIDAD)
        Write-Host ("    {0,-30} : {1}" -f "ID", $gpo.Id)
        Write-Host ("    {0,-30} : {1}" -f "Estado", $gpo.GpoStatus)
    } else {
        aputs_error "GPO '$Script:AD_GPO_SEGURIDAD' no encontrada"
        return
    }

    # Verificar el valor en SYSVOL
    $domainDNS = (Get-ADDomain).DNSRoot
    $gpoGuid   = $gpo.Id.ToString().ToUpper()
    $gptPath   = "\\$domainDNS\SYSVOL\$domainDNS\Policies\{$gpoGuid}\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"

    if (Test-Path $gptPath) {
        $contenido = Get-Content $gptPath -Raw
        if ($contenido -match 'ForceLogoffWhenHourExpire\s*=\s*1') {
            Write-Host ("    {0,-30} : {1}" -f "ForceLogoffWhenHourExpire", "1 (ACTIVO)")
        } else {
            aputs_warning "ForceLogoffWhenHourExpire no encontrado o no es 1 en GptTmpl.inf"
        }
    } else {
        aputs_warning "GptTmpl.inf no encontrado en SYSVOL"
    }

    Write-Host ""
    aputs_info "Para probar: espere a que venza el horario de un usuario -- debe cerrarse la sesion"
    aputs_info "Evento en el Visor de Eventos: Security > Event ID 4634 (An account was logged off)"
}

# ------------------------------------------------------------
# Orquestador: configuracion completa GPO cierre de sesion
# ------------------------------------------------------------

function gpo_configurar_cierre_sesion_completo {
    Clear-Host
    ad_mostrar_banner "Paso 5 -- GPO: Forzar Cierre de Sesion por Horario"

    Write-Host ""
    Write-Host "  Esta GPO habilita la politica:"
    Write-Host "    'Seguridad de red: cerrar la sesion de los usuarios"
    Write-Host "     cuando expire el tiempo de inicio de sesion'"
    Write-Host ""
    Write-Host "  Efecto: el sistema cierra automaticamente la sesion activa"
    Write-Host "  al cumplirse el horario configurado (Paso 2)."
    Write-Host ""
    draw_line
    Write-Host ""

    try {
        if (-not (ad_verificar_modulo_ad)) { pause; return }

        # 1. Obtener o crear GPO
        $gpo = _gpo_obtener_o_crear
        Write-Host ""

        # 2. Escribir plantilla de seguridad en SYSVOL
        $tmplPath = _gpo_escribir_gpt_tmpl -GpoId $gpo.Id
        Write-Host ""

        # 3. Incrementar version para notificar a clientes
        _gpo_incrementar_version -GpoId $gpo.Id
        Write-Host ""

        # 4. Vincular GPO al dominio
        _gpo_vincular_dominio -NombreGPO $Script:AD_GPO_SEGURIDAD
        Write-Host ""

        # 5. Forzar actualizacion en el DC
        gpo_forzar_actualizacion
        Write-Host ""

        # 6. Verificar resultado
        gpo_verificar_cierre_sesion
        Write-Host ""
        draw_line
        aputs_ok "GPO de cierre de sesion configurada y vinculada"
        aputs_info "Los clientes deben ejecutar 'gpupdate /force' para recibir la politica"

    } catch {
        aputs_error "Error durante configuracion de GPO: $_"
    }

    pause
}
