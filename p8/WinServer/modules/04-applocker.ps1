# 04-applocker.ps1 -- Control de Ejecucion con AppLocker
# Requiere: utils.AD.ps1 cargado previamente
#
# Reglas:
#   Cuates:   Bloc de Notas PERMITIDO (regla de ruta %WINDIR%)
#   NoCuates: Bloc de Notas BLOQUEADO por hash SHA256 (evita bypass por renombrado)
#
# La politica se aplica mediante GPO al dominio completo.
# Las reglas usan SID del grupo para distinguir entre Cuates y NoCuates.

# ------------------------------------------------------------
# Habilitar y arrancar el servicio Application Identity (requisito)
# ------------------------------------------------------------

function applocker_habilitar_servicio {
    aputs_info "Configurando servicio Application Identity (AppIDSvc)..."

    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    if (-not $svc) {
        aputs_error "Servicio AppIDSvc no encontrado -- verifique que AppLocker esta soportado"
        return $false
    }

    # Configurar inicio automatico (sc.exe evita el bug de Set-Service que modifica la descripcion)
    $sc = sc.exe config AppIDSvc start= auto 2>&1
    if ($LASTEXITCODE -ne 0) {
        aputs_error "No se pudo configurar inicio automatico de AppIDSvc: $sc"
        return $false
    }
    aputs_ok "AppIDSvc configurado como inicio automatico"

    # Iniciar si no esta corriendo
    if ($svc.Status -ne "Running") {
        Start-Service -Name AppIDSvc -ErrorAction Stop
        Start-Sleep -Seconds 2
    }

    $svc = Get-Service -Name AppIDSvc
    if ($svc.Status -eq "Running") {
        aputs_ok "Servicio AppIDSvc activo"
        return $true
    } else {
        aputs_error "No se pudo iniciar AppIDSvc"
        return $false
    }
}

# ------------------------------------------------------------
# Obtener informacion del hash SHA256 de notepad.exe
# ------------------------------------------------------------

function applocker_obtener_info_notepad {
    $rutaNotepad = $Script:AD_APPLOCKER_NOTEPAD

    if (-not (Test-Path $rutaNotepad)) {
        aputs_error "No se encontro notepad.exe en: $rutaNotepad"
        return $null
    }

    $hashObj    = Get-FileHash -Path $rutaNotepad -Algorithm SHA256 -ErrorAction Stop
    $fileInfo   = Get-Item $rutaNotepad

    return @{
        Ruta     = $rutaNotepad
        HashHex  = $hashObj.Hash                        # SHA256 en hexadecimal
        HashData = "0x" + $hashObj.Hash                 # Formato requerido por AppLocker
        Tamano   = $fileInfo.Length
        Nombre   = $fileInfo.Name
    }
}

# ------------------------------------------------------------
# Construir el XML de una regla AppLocker de ruta (Allow)
# ------------------------------------------------------------

function _applocker_xml_regla_ruta {
    param(
        [string]$Id,
        [string]$Nombre,
        [string]$Descripcion,
        [string]$SID,
        [string]$Accion,      # "Allow" o "Deny"
        [string]$Ruta
    )

    return @"
    <FilePathRule Id="{$Id}" Name="$Nombre" Description="$Descripcion" UserOrGroupSid="$SID" Action="$Accion">
      <Conditions>
        <FilePathCondition Path="$Ruta" />
      </Conditions>
    </FilePathRule>
"@
}

# ------------------------------------------------------------
# Construir el XML de una regla AppLocker de hash (Deny)
# ------------------------------------------------------------

function _applocker_xml_regla_hash {
    param(
        [string]$Id,
        [string]$Nombre,
        [string]$Descripcion,
        [string]$SID,
        [string]$HashData,
        [string]$NombreArchivo,
        [long]  $Tamano
    )

    return @"
    <FileHashRule Id="{$Id}" Name="$Nombre" Description="$Descripcion" UserOrGroupSid="$SID" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="$HashData" SourceFileName="$NombreArchivo" SourceFileLength="$Tamano" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
"@
}

# ------------------------------------------------------------
# Crear la GPO de AppLocker con todas las reglas
# ------------------------------------------------------------

function applocker_crear_gpo {
    param([hashtable]$InfoNotepad)

    aputs_info "Configurando GPO de AppLocker: $Script:AD_GPO_APPLOCKER"

    # Obtener SIDs de los grupos
    $sidCuates   = ad_obtener_sid_grupo $Script:AD_GRUPO_CUATES
    $sidNoCuates = ad_obtener_sid_grupo $Script:AD_GRUPO_NOCUATES

    if (-not $sidCuates -or -not $sidNoCuates) {
        aputs_error "No se pudieron obtener los SIDs de los grupos -- verifique que existen en AD"
        return $false
    }

    $sidAdmins     = "S-1-5-32-544"   # BUILTIN\Administrators
    $sidTodos      = "S-1-1-0"        # Everyone

    # Generar GUIDs para cada regla
    $idAdmins          = [System.Guid]::NewGuid().ToString().ToUpper()
    $idTodosWindir     = [System.Guid]::NewGuid().ToString().ToUpper()
    $idTodosProgFiles  = [System.Guid]::NewGuid().ToString().ToUpper()
    $idNoCuatesDeny    = [System.Guid]::NewGuid().ToString().ToUpper()

    # Construir XML completo de la politica AppLocker
    $xmlPolicy = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">

    <!-- Administradores: acceso completo -->
$(_applocker_xml_regla_ruta -Id $idAdmins `
    -Nombre       "Permitir-Administradores" `
    -Descripcion  "Administradores pueden ejecutar cualquier archivo" `
    -SID          $sidAdmins `
    -Accion       "Allow" `
    -Ruta         "*")

    <!-- Todos: pueden ejecutar aplicaciones estandar de Windows y archivos instalados -->
    <!-- Esto garantiza que clientes (Linux/Windows) no sean bloqueados por esta politica -->
$(_applocker_xml_regla_ruta -Id $idTodosWindir `
    -Nombre       "Todos-Permitir-Windows" `
    -Descripcion  "Todos los usuarios pueden ejecutar aplicaciones de Windows (incluye Bloc de Notas salvo NoCuates)" `
    -SID          $sidTodos `
    -Accion       "Allow" `
    -Ruta         "%WINDIR%\*")

$(_applocker_xml_regla_ruta -Id $idTodosProgFiles `
    -Nombre       "Todos-Permitir-ProgramFiles" `
    -Descripcion  "Todos los usuarios pueden ejecutar aplicaciones instaladas" `
    -SID          $sidTodos `
    -Accion       "Allow" `
    -Ruta         "%PROGRAMFILES%\*")

    <!-- NOCUATES: bloquear notepad.exe por HASH (no se puede evadir renombrando) -->
    <!-- Deny tiene precedencia sobre el Allow de Todos, solo afecta a miembros de NoCuates -->
$(_applocker_xml_regla_hash -Id $idNoCuatesDeny `
    -Nombre        "NoCuates-Bloquear-Notepad-Hash" `
    -Descripcion   "Bloqueo de Bloc de Notas por hash SHA256 para evitar bypass por renombrado" `
    -SID           $sidNoCuates `
    -HashData      $InfoNotepad.HashData `
    -NombreArchivo $InfoNotepad.Nombre `
    -Tamano        $InfoNotepad.Tamano)

  </RuleCollection>
</AppLockerPolicy>
"@

    # Crear o recuperar GPO
    $gpo = Get-GPO -Name $Script:AD_GPO_APPLOCKER -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $Script:AD_GPO_APPLOCKER -Domain $Script:AD_DOMINIO -ErrorAction Stop
        aputs_ok "GPO creada: $Script:AD_GPO_APPLOCKER"
    } else {
        aputs_info "GPO ya existe: $Script:AD_GPO_APPLOCKER -- actualizando reglas"
    }

    # Aplicar cada regla como valor de registro en la GPO
    # AppLocker almacena sus reglas en:
    # HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe\{GUID} = <XML de la regla>

    $claveGPO = "HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe"

    # Modo de aplicacion: 1 = Forzar (Enforce), 0 = Solo auditar (AuditOnly)
    Set-GPRegistryValue -Guid $gpo.Id `
        -Key       $claveGPO `
        -ValueName "EnforcementMode" `
        -Type      DWord `
        -Value     1 `
        -ErrorAction Stop | Out-Null
    aputs_ok "Modo: Enforce (bloqueo activo)"

    # Registrar cada regla individual
    $reglas = @(
        @{ Id = $idAdmins;         Xml = (_applocker_xml_regla_ruta -Id $idAdmins -Nombre "Permitir-Administradores" -Descripcion "" -SID $sidAdmins -Accion "Allow" -Ruta "*") },
        @{ Id = $idTodosWindir;    Xml = (_applocker_xml_regla_ruta -Id $idTodosWindir -Nombre "Todos-Permitir-Windows" -Descripcion "" -SID $sidTodos -Accion "Allow" -Ruta "%WINDIR%\*") },
        @{ Id = $idTodosProgFiles; Xml = (_applocker_xml_regla_ruta -Id $idTodosProgFiles -Nombre "Todos-Permitir-ProgramFiles" -Descripcion "" -SID $sidTodos -Accion "Allow" -Ruta "%PROGRAMFILES%\*") },
        @{ Id = $idNoCuatesDeny;   Xml = (_applocker_xml_regla_hash -Id $idNoCuatesDeny -Nombre "NoCuates-Bloquear-Notepad-Hash" -Descripcion "Hash SHA256" -SID $sidNoCuates -HashData $InfoNotepad.HashData -NombreArchivo $InfoNotepad.Nombre -Tamano $InfoNotepad.Tamano) }
    )

    foreach ($regla in $reglas) {
        Set-GPRegistryValue -Guid $gpo.Id `
            -Key       $claveGPO `
            -ValueName "{$($regla.Id)}" `
            -Type      String `
            -Value     $regla.Xml `
            -ErrorAction Stop | Out-Null
    }

    aputs_ok "$($reglas.Count) reglas AppLocker registradas en la GPO"

    # Vincular GPO al dominio (si no esta vinculada)
    $domainDN = (Get-ADDomain).DistinguishedName
    $enlace = Get-GPInheritance -Target $domainDN -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty GpoLinks |
        Where-Object { $_.DisplayName -eq $Script:AD_GPO_APPLOCKER }

    if (-not $enlace) {
        New-GPLink -Name $Script:AD_GPO_APPLOCKER -Target $domainDN -ErrorAction Stop | Out-Null
        aputs_ok "GPO vinculada al dominio: $domainDN"
    } else {
        aputs_info "GPO ya esta vinculada al dominio"
    }

    # Guardar XML completo para referencia / documentacion
    $xmlPath = "$PSScriptRoot\..\data\applocker-policy.xml"
    $xmlPolicy | Out-File -FilePath $xmlPath -Encoding UTF8 -Force
    aputs_info "XML de politica guardado en: $xmlPath"

    return $true
}

# ------------------------------------------------------------
# Verificar estado de AppLocker
# ------------------------------------------------------------

function applocker_verificar {
    Write-Host ""
    aputs_info "--- Verificacion AppLocker ---"
    Write-Host ""

    # Estado del servicio
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host ("    {0,-28} : {1}" -f "Servicio AppIDSvc", $svc.Status)
    } else {
        aputs_error "Servicio AppIDSvc no encontrado"
    }

    # Hash de notepad.exe actual
    if (Test-Path $Script:AD_APPLOCKER_NOTEPAD) {
        $hash = (Get-FileHash $Script:AD_APPLOCKER_NOTEPAD -Algorithm SHA256).Hash
        Write-Host ("    {0,-28} : {1}" -f "Hash notepad.exe (SHA256)", $hash)
    }

    # Estado de GPO
    $gpo = Get-GPO -Name $Script:AD_GPO_APPLOCKER -ErrorAction SilentlyContinue
    if ($gpo) {
        Write-Host ("    {0,-28} : {1}" -f "GPO AppLocker", "Existe (ID: $($gpo.Id))")
    } else {
        aputs_warning "GPO '$Script:AD_GPO_APPLOCKER' no encontrada"
    }

    Write-Host ""
    aputs_info "Para verificar en un cliente: ejecute 'gpupdate /force' y luego intente"
    aputs_info "abrir notepad como usuario NoCuates (debe bloquearse)"
    aputs_info "Renombrar notepad a otro nombre NO debe saltarse el bloqueo (regla por hash)"
}

# ------------------------------------------------------------
# Orquestador: configuracion completa AppLocker
# ------------------------------------------------------------

function applocker_configurar_completo {
    Clear-Host
    ad_mostrar_banner "Paso 4 -- Control de Ejecucion (AppLocker)"

    Write-Host ""
    Write-Host "  Reglas a configurar:"
    Write-Host "    Todos    : %WINDIR% y %PROGRAMFILES% PERMITIDOS (no bloquea clientes)"
    Write-Host "    NoCuates : Bloc de Notas BLOQUEADO por hash SHA256"
    Write-Host "               (Deny tiene precedencia; el bloqueo persiste aunque se renombre el .exe)"
    Write-Host "    Linux/Win client: NO afectados por esta politica"
    Write-Host ""
    draw_line
    Write-Host ""

    try {
        # 1. Habilitar servicio
        if (-not (applocker_habilitar_servicio)) { pause; return }
        Write-Host ""

        # 2. Obtener hash de notepad
        aputs_info "Calculando hash SHA256 de notepad.exe..."
        $infoNotepad = applocker_obtener_info_notepad
        if (-not $infoNotepad) { pause; return }

        Write-Host ""
        Write-Host ("    {0,-20} : {1}" -f "Ruta", $infoNotepad.Ruta)
        Write-Host ("    {0,-20} : {1}" -f "Hash SHA256", $infoNotepad.HashData)
        Write-Host ("    {0,-20} : {1} bytes" -f "Tamano", $infoNotepad.Tamano)
        Write-Host ""

        # 3. Crear GPO con reglas
        if (-not (applocker_crear_gpo -InfoNotepad $infoNotepad)) { pause; return }

        Write-Host ""
        applocker_verificar
        Write-Host ""
        draw_line
        aputs_ok "AppLocker configurado"
        aputs_info "Ejecute 'gpupdate /force' en los clientes para aplicar la politica"

    } catch {
        aputs_error "Error durante configuracion AppLocker: $_"
    }

    pause
}
