# 06-clientes.ps1 -- Gestion de Clientes (Linux / Windows)
# Requiere: utils.AD.ps1 cargado previamente. FSRM recomendado (Paso 3).
#
# Funcionalidad:
#   - Crear usuarios locales para clientes (Linux "andre" y Windows client)
#   - Horarios de acceso configurables con GUI grafica (7 dias x 24 horas)
#   - Cuotas FSRM modificables con GUI grafica (slider + numerico)
#   - Recurso compartido SMB para montar el disco en los clientes
#   - Barra visual de uso de disco por cliente
#   - Bloqueo de Notepad via AppLocker (solo cliente Windows)

if ($Script:_CLIENTES_LOADED) { return }
$Script:_CLIENTES_LOADED = $true

# ------------------------------------------------------------
# Verificar FSRM disponible
# ------------------------------------------------------------

function _clientes_verificar_fsrm {
    $feature = Get-WindowsFeature -Name FS-Resource-Manager -ErrorAction SilentlyContinue
    if (-not ($feature -and $feature.Installed)) {
        aputs_error "FSRM no instalado -- ejecute el Paso 3 primero"
        return $false
    }
    try {
        Import-Module FileServerResourceManager -ErrorAction Stop | Out-Null
        return $true
    } catch {
        aputs_error "No se pudo cargar el modulo FSRM: $_"
        return $false
    }
}

# ------------------------------------------------------------
# Crear usuario local + directorio + cuota FSRM
# ------------------------------------------------------------

function _clientes_crear_usuario {
    param(
        [string]$Usuario,
        [string]$Password,
        [string]$Descripcion,
        [int]   $CuotaMB
    )

    # Directorio raiz del cliente
    $dir = "$Script:AD_CLIENTES_DIR\$Usuario"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        aputs_ok "Directorio creado: $dir"
    } else {
        aputs_info "Directorio ya existe: $dir"
    }

    # Crear usuario local de Windows
    $existente = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
    if ($existente) {
        aputs_info "Usuario local ya existe: $Usuario"
    } else {
        try {
            $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
            New-LocalUser `
                -Name                 $Usuario `
                -Password             $secPass `
                -FullName             $Descripcion `
                -Description          "Cliente P8 -- $Descripcion" `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -ErrorAction Stop | Out-Null
            aputs_ok "Usuario local creado: $Usuario"
        } catch {
            aputs_error "Error creando '$Usuario': $($_.Exception.Message)"
            aputs_info  "  Recuerde: min 8 chars, mayuscula, minuscula, numero y simbolo."
            return $false
        }
    }

    # Permisos NTFS sobre el directorio
    try {
        $acl   = Get-Acl $dir
        $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Usuario, "Modify",
            "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($regla)
        Set-Acl -Path $dir -AclObject $acl
        aputs_ok "Permisos NTFS Modify asignados a $Usuario"
    } catch {
        aputs_warning "No se pudieron asignar permisos NTFS: $_"
    }

    # Cuota FSRM
    if (_clientes_verificar_fsrm) {
        _clientes_cuota_aplicar -Usuario $Usuario -MB $CuotaMB
    }

    return $true
}

# ------------------------------------------------------------
# Cuota FSRM -- crear o actualizar
# ------------------------------------------------------------

function _clientes_cuota_aplicar {
    param([string]$Usuario, [int]$MB)

    $ruta  = "$Script:AD_CLIENTES_DIR\$Usuario"
    $bytes = [long]$MB * 1MB

    if (-not (Test-Path $ruta)) {
        New-Item -ItemType Directory -Path $ruta -Force | Out-Null
    }

    try {
        $existe = Get-FsrmQuota -Path $ruta -ErrorAction SilentlyContinue
        if ($existe) {
            Set-FsrmQuota -Path $ruta -Size $bytes -ErrorAction Stop
            aputs_ok "Cuota actualizada: $Usuario -> $MB MB"
        } else {
            New-FsrmQuota -Path $ruta -Size $bytes -ErrorAction Stop | Out-Null
            aputs_ok "Cuota creada: $Usuario -> $MB MB"
        }
    } catch {
        aputs_error "Error configurando cuota FSRM para $Usuario : $_"
    }
}

# ------------------------------------------------------------
# Barra visual de uso de cuota (estilo df -h)
# ------------------------------------------------------------

function _clientes_barra_cuota {
    param([string]$Usuario)

    $ruta  = "$Script:AD_CLIENTES_DIR\$Usuario"
    $cuota = Get-FsrmQuota -Path $ruta -ErrorAction SilentlyContinue

    if (-not $cuota) {
        Write-Host ("  {0,-15}: Sin cuota FSRM configurada" -f $Usuario)
        return
    }

    $totalMB = [Math]::Round($cuota.Size  / 1MB, 1)
    $usadoMB = [Math]::Round($cuota.Usage / 1MB, 2)
    $libreMB = [Math]::Round(($cuota.Size - $cuota.Usage) / 1MB, 2)
    $pctNum  = if ($cuota.Size -gt 0) { [Math]::Round($cuota.Usage * 100 / $cuota.Size, 1) } else { 0 }
    $llenos  = if ($cuota.Size -gt 0) { [Math]::Min([int]($cuota.Usage * 36 / $cuota.Size), 36) } else { 0 }
    $vacios  = 36 - $llenos
    $barra   = "[" + ("=" * $llenos) + ("-" * $vacios) + "]"
    $color   = if ($pctNum -ge 90) { "Red" } elseif ($pctNum -ge 70) { "Yellow" } else { "Cyan" }

    Write-Host ""
    Write-Host "  +----------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ("  |  Disco virtual  --  Cliente: {0,-16}|" -f $Usuario) -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ("  |  Total  : {0,8} MB                         |" -f $totalMB)
    Write-Host ("  |  Usado  : {0,8} MB  {1}  {2,5}% |" -f $usadoMB, $barra, $pctNum) -ForegroundColor $color
    Write-Host ("  |  Libre  : {0,8} MB                         |" -f $libreMB)
    Write-Host "  +----------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ("  |  Ruta   : {0,-37}|" -f $ruta)
    Write-Host "  +----------------------------------------------+" -ForegroundColor DarkGray
    Write-Host ""
}

# ------------------------------------------------------------
# Recurso compartido SMB para montar el disco en los clientes
# ------------------------------------------------------------

function cliente_crear_share {
    aputs_info "Configurando share SMB: \\$env:COMPUTERNAME\$Script:AD_CLIENTES_SHARE"

    if (-not (Test-Path $Script:AD_CLIENTES_DIR)) {
        New-Item -ItemType Directory -Path $Script:AD_CLIENTES_DIR -Force | Out-Null
    }

    $share = Get-SmbShare -Name $Script:AD_CLIENTES_SHARE -ErrorAction SilentlyContinue
    if (-not $share) {
        # Win32_Share evita el bug de resolucion de "Everyone"/"Todos" en Windows ES
        $wmiShare  = [wmiclass]"Win32_Share"
        $resultado = $wmiShare.Create(
            $Script:AD_CLIENTES_DIR,
            $Script:AD_CLIENTES_SHARE,
            [uint32]0, $null,
            "Disco compartido de clientes con cuotas -- Practica 8"
        )
        if ($resultado.ReturnValue -ne 0) {
            aputs_error "Error creando share (codigo $($resultado.ReturnValue))"
            return $false
        }
        aputs_ok "Share creado: \\$env:COMPUTERNAME\$Script:AD_CLIENTES_SHARE"
    } else {
        aputs_info "Share ya existe: $Script:AD_CLIENTES_SHARE"
    }

    # Puerto 445 en firewall
    if (-not (Get-NetFirewallRule -DisplayName "P8-SMB-Clientes" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "P8-SMB-Clientes" `
            -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow | Out-Null
        aputs_ok "Puerto 445/TCP abierto en firewall"
    }

    # Instrucciones para el cliente
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
           Sort-Object InterfaceIndex | Select-Object -First 1).IPAddress

    Write-Host ""
    Write-Host "  =========================================" -ForegroundColor DarkGray
    Write-Host "  Montar el disco en el cliente:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [ Windows ]" -ForegroundColor Cyan
    Write-Host "    net use Z: \\$ip\$Script:AD_CLIENTES_SHARE /user:<usuario> <password>"
    Write-Host "    -- o desde Explorador: \\$ip\$Script:AD_CLIENTES_SHARE"
    Write-Host ""
    Write-Host "  [ Linux   ]" -ForegroundColor Cyan
    Write-Host "    sudo mount -t cifs //$ip/$Script:AD_CLIENTES_SHARE /mnt/clientes \"
    Write-Host "         -o username=<usuario>,password=<pass>,vers=3.0"
    Write-Host "  =========================================" -ForegroundColor DarkGray
    Write-Host ""

    return $true
}

# ------------------------------------------------------------
# Horarios -- aplicar via "net user /times:"
# ------------------------------------------------------------

function _clientes_aplicar_horario {
    param([string]$Usuario, [string]$HorasStr)

    if (-not (Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue)) {
        aputs_error "Usuario local no encontrado: $Usuario"
        return $false
    }

    try {
        if ([string]::IsNullOrWhiteSpace($HorasStr) -or $HorasStr -eq "ALL") {
            & net user $Usuario /times:ALL 2>&1 | Out-Null
            aputs_ok "Horario $Usuario : Sin restriccion (acceso 24/7)"
        } else {
            & net user $Usuario /times:"$HorasStr" 2>&1
            if ($LASTEXITCODE -ne 0) {
                aputs_error "Formato invalido. Ejemplo: M-F,08:00-17:00;Sa,09:00-13:00"
                return $false
            }
            aputs_ok "Horario $Usuario : $HorasStr"
        }
        return $true
    } catch {
        aputs_error "Error aplicando horario a $Usuario : $_"
        return $false
    }
}

function _clientes_leer_horario {
    param([string]$Usuario)
    try {
        $salida = & net user $Usuario 2>&1
        $linea  = $salida | Where-Object { $_ -match "Logon hours allowed|Horas de inicio de sesion" } |
                  Select-Object -First 1
        if ($linea) { return ($linea -split "  +", 2)[-1].Trim() }
    } catch {}
    return "(no disponible)"
}

# ------------------------------------------------------------
# GUI -- Grilla grafica 7 dias x 24 horas
# ------------------------------------------------------------

function clientes_gui_horario {
    param([string]$Usuario)

    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {
        aputs_error "Windows Forms no disponible -- use la configuracion por texto"
        return $null
    }
    Add-Type -AssemblyName System.Drawing

    $diasNombre = @("Lunes","Martes","Miercoles","Jueves","Viernes","Sabado","Domingo")
    $diasNet    = @("M",    "T",     "W",        "Th",    "F",      "Sa",    "Su")

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Horarios de Acceso  --  $Usuario"
    $form.Size            = New-Object System.Drawing.Size(910, 400)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.BackColor       = [System.Drawing.Color]::WhiteSmoke

    # Panel encabezado
    $panelTop = New-Object System.Windows.Forms.Panel
    $panelTop.Location = New-Object System.Drawing.Point(0, 0)
    $panelTop.Size     = New-Object System.Drawing.Size(910, 28)
    $panelTop.BackColor = [System.Drawing.Color]::SteelBlue
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text      = "  Seleccione las horas en que $Usuario puede iniciar sesion"
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location  = New-Object System.Drawing.Point(0, 5)
    $lblTitle.Size      = New-Object System.Drawing.Size(900, 20)
    $panelTop.Controls.Add($lblTitle)
    $form.Controls.Add($panelTop)

    # Etiquetas de hora (fila encabezado)
    $lblDay = New-Object System.Windows.Forms.Label
    $lblDay.Text = "Dia \ Hora"
    $lblDay.Location = New-Object System.Drawing.Point(5, 34)
    $lblDay.Size     = New-Object System.Drawing.Size(80, 18)
    $lblDay.Font     = New-Object System.Drawing.Font("Consolas", 7, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblDay)

    for ($h = 0; $h -lt 24; $h++) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text     = ("{0:D2}" -f $h)
        $lbl.Location = New-Object System.Drawing.Point((90 + $h * 33), 34)
        $lbl.Size     = New-Object System.Drawing.Size(30, 18)
        $lbl.Font     = New-Object System.Drawing.Font("Consolas", 7)
        $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $form.Controls.Add($lbl)
    }

    # Grilla de checkboxes
    $checks = @{}
    for ($d = 0; $d -lt 7; $d++) {
        $color = if ($d -ge 5) { [System.Drawing.Color]::LightYellow } else { [System.Drawing.Color]::WhiteSmoke }

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text      = $diasNombre[$d]
        $lbl.Location  = New-Object System.Drawing.Point(5, (55 + $d * 28))
        $lbl.Size      = New-Object System.Drawing.Size(82, 24)
        $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
        $lbl.BackColor = $color
        $form.Controls.Add($lbl)

        for ($h = 0; $h -lt 24; $h++) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Size      = New-Object System.Drawing.Size(30, 24)
            $cb.Location  = New-Object System.Drawing.Point((90 + $h * 33), (55 + $d * 28))
            $cb.BackColor = $color
            $form.Controls.Add($cb)
            $checks["${d}_${h}"] = $cb
        }
    }

    # Botones de preset
    $y = 260
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = "Todo el dia"
    $btnAll.Location = New-Object System.Drawing.Point(10, $y)
    $btnAll.Size     = New-Object System.Drawing.Size(100, 26)
    $btnAll.Add_Click({ foreach ($k in $checks.Keys) { $checks[$k].Checked = $true } })
    $form.Controls.Add($btnAll)

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = "Limpiar"
    $btnNone.Location = New-Object System.Drawing.Point(120, $y)
    $btnNone.Size     = New-Object System.Drawing.Size(80, 26)
    $btnNone.Add_Click({ foreach ($k in $checks.Keys) { $checks[$k].Checked = $false } })
    $form.Controls.Add($btnNone)

    $btnLV = New-Object System.Windows.Forms.Button
    $btnLV.Text = "Lun-Vie 8-17h"
    $btnLV.Location = New-Object System.Drawing.Point(210, $y)
    $btnLV.Size     = New-Object System.Drawing.Size(120, 26)
    $btnLV.Add_Click({
        foreach ($k in $checks.Keys) { $checks[$k].Checked = $false }
        for ($d = 0; $d -lt 5; $d++) {
            for ($h = 8; $h -lt 17; $h++) { $checks["${d}_${h}"].Checked = $true }
        }
    })
    $form.Controls.Add($btnLV)

    $btnOffice = New-Object System.Windows.Forms.Button
    $btnOffice.Text = "8-15h (P8)"
    $btnOffice.Location = New-Object System.Drawing.Point(340, $y)
    $btnOffice.Size     = New-Object System.Drawing.Size(100, 26)
    $btnOffice.Add_Click({
        foreach ($k in $checks.Keys) { $checks[$k].Checked = $false }
        for ($d = 0; $d -lt 7; $d++) {
            for ($h = 8; $h -lt 15; $h++) { $checks["${d}_${h}"].Checked = $true }
        }
    })
    $form.Controls.Add($btnOffice)

    $btnNight = New-Object System.Windows.Forms.Button
    $btnNight.Text = "15h-02h (P8)"
    $btnNight.Location = New-Object System.Drawing.Point(450, $y)
    $btnNight.Size     = New-Object System.Drawing.Size(110, 26)
    $btnNight.Add_Click({
        foreach ($k in $checks.Keys) { $checks[$k].Checked = $false }
        for ($d = 0; $d -lt 7; $d++) {
            for ($h = 15; $h -lt 24; $h++) { $checks["${d}_${h}"].Checked = $true }
            for ($h = 0;  $h -lt 2;  $h++) { $checks["${d}_${h}"].Checked = $true }
        }
    })
    $form.Controls.Add($btnNight)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text         = "Aplicar"
    $btnOK.Location     = New-Object System.Drawing.Point(690, $y)
    $btnOK.Size         = New-Object System.Drawing.Size(90, 26)
    $btnOK.BackColor    = [System.Drawing.Color]::LightGreen
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = "Cancelar"
    $btnCancel.Location     = New-Object System.Drawing.Point(790, $y)
    $btnCancel.Size         = New-Object System.Drawing.Size(90, 26)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    # Convertir checks a formato "net user /times:"
    $partes = @()
    for ($d = 0; $d -lt 7; $d++) {
        $horas = @()
        for ($h = 0; $h -lt 24; $h++) {
            if ($checks["${d}_${h}"].Checked) { $horas += $h }
        }
        if ($horas.Count -eq 0) { continue }

        # Agrupar horas consecutivas en rangos
        $ini = $horas[0]; $fin = $horas[0]
        for ($i = 1; $i -lt $horas.Count; $i++) {
            if ($horas[$i] -eq $fin + 1) {
                $fin = $horas[$i]
            } else {
                $partes += "$($diasNet[$d]),{0:D2}:00-{1:D2}:00" -f $ini, ($fin + 1)
                $ini = $horas[$i]; $fin = $horas[$i]
            }
        }
        $partes += "$($diasNet[$d]),{0:D2}:00-{1:D2}:00" -f $ini, (if ($fin -eq 23) { 24 } else { $fin + 1 })
    }

    if ($partes.Count -eq 0) { return "ALL" }
    return ($partes -join ";")
}

# ------------------------------------------------------------
# GUI -- Dialogo grafico para modificar cuota
# ------------------------------------------------------------

function clientes_gui_cuota {
    param([string]$Usuario, [int]$ActualMB = 50)

    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {
        aputs_error "Windows Forms no disponible"
        $val = Read-Host "  Nueva cuota en MB para $Usuario [$ActualMB]"
        if ([string]::IsNullOrEmpty($val)) { return $ActualMB }
        return [int]$val
    }
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Modificar Cuota de Disco  --  $Usuario"
    $form.Size            = New-Object System.Drawing.Size(380, 220)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.BackColor       = [System.Drawing.Color]::WhiteSmoke

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Cuota de disco para $Usuario (MB):"
    $lbl.Location = New-Object System.Drawing.Point(15, 20)
    $lbl.Size     = New-Object System.Drawing.Size(340, 20)
    $lbl.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($lbl)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum   = 5
    $num.Maximum   = 10240
    $num.Value     = $ActualMB
    $num.Increment = 5
    $num.Location  = New-Object System.Drawing.Point(15, 48)
    $num.Size      = New-Object System.Drawing.Size(200, 30)
    $num.Font      = New-Object System.Drawing.Font("Segoe UI", 13)
    $form.Controls.Add($num)

    $lblMB = New-Object System.Windows.Forms.Label
    $lblMB.Text     = "MB"
    $lblMB.Location = New-Object System.Drawing.Point(225, 54)
    $lblMB.Size     = New-Object System.Drawing.Size(35, 20)
    $lblMB.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($lblMB)

    $bar = New-Object System.Windows.Forms.TrackBar
    $bar.Minimum        = 5
    $bar.Maximum        = 500
    $bar.Value          = [Math]::Min($ActualMB, 500)
    $bar.TickFrequency  = 50
    $bar.Location       = New-Object System.Drawing.Point(15, 88)
    $bar.Size           = New-Object System.Drawing.Size(340, 36)
    $bar.Add_Scroll({ $num.Value = $bar.Value })
    $num.Add_ValueChanged({
        if ($bar.Value -ne [int]$num.Value) {
            try { $bar.Value = [Math]::Min([int]$num.Value, 500) } catch {}
        }
    })
    $form.Controls.Add($bar)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text         = "Aplicar"
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOK.Location     = New-Object System.Drawing.Point(170, 140)
    $btnOK.Size         = New-Object System.Drawing.Size(90, 28)
    $btnOK.BackColor    = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = "Cancelar"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location     = New-Object System.Drawing.Point(270, 140)
    $btnCancel.Size         = New-Object System.Drawing.Size(90, 28)
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return [int]$num.Value
    }
    return $null
}

# ------------------------------------------------------------
# AppLocker -- bloquear Notepad para usuario local (Windows client)
# ------------------------------------------------------------

function cliente_win_applocker_notepad {
    param([string]$Usuario)

    $usr = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
    if (-not $usr) {
        aputs_error "Usuario local '$Usuario' no encontrado"
        return $false
    }

    $sid = $usr.SID.Value
    aputs_info "Agregando regla Deny-Notepad para $Usuario (SID: $sid)..."

    try { Import-Module GroupPolicy -ErrorAction Stop | Out-Null } catch {
        aputs_error "Modulo GroupPolicy no disponible"
        return $false
    }

    $gpo = Get-GPO -Name $Script:AD_GPO_APPLOCKER -ErrorAction SilentlyContinue
    if (-not $gpo) {
        aputs_error "GPO '$Script:AD_GPO_APPLOCKER' no encontrada -- ejecute el Paso 4 primero"
        return $false
    }

    if (-not (Test-Path $Script:AD_APPLOCKER_NOTEPAD)) {
        aputs_error "notepad.exe no encontrado en $Script:AD_APPLOCKER_NOTEPAD"
        return $false
    }

    $hash    = Get-FileHash -Path $Script:AD_APPLOCKER_NOTEPAD -Algorithm SHA256
    $hashHex = "0x" + $hash.Hash
    $tamano  = (Get-Item $Script:AD_APPLOCKER_NOTEPAD).Length
    $nombre  = (Get-Item $Script:AD_APPLOCKER_NOTEPAD).Name
    $idRegla = [System.Guid]::NewGuid().ToString().ToUpper()

    $xmlRegla = "    <FileHashRule Id=""{$idRegla}"" Name=""WinClient-Deny-Notepad-$Usuario"" Description=""Bloqueo notepad cliente Windows: $Usuario"" UserOrGroupSid=""$sid"" Action=""Deny"">
      <Conditions>
        <FileHashCondition>
          <FileHash Type=""SHA256"" Data=""$hashHex"" SourceFileName=""$nombre"" SourceFileLength=""$tamano"" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>"

    $claveGPO = "HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2\Exe"
    Set-GPRegistryValue -Guid $gpo.Id `
        -Key       $claveGPO `
        -ValueName "{$idRegla}" `
        -Type      String `
        -Value     $xmlRegla `
        -ErrorAction Stop | Out-Null

    aputs_ok "Regla Deny-Notepad agregada para: $Usuario"
    aputs_info "Ejecute 'gpupdate /force' en el cliente Windows para aplicar"
    return $true
}

# ------------------------------------------------------------
# Panel de estado: muestra resumen de ambos clientes
# ------------------------------------------------------------

function clientes_panel_estado {
    $fsrmOk = $false
    try { Import-Module FileServerResourceManager -ErrorAction SilentlyContinue | Out-Null; $fsrmOk = $true } catch {}

    $clientes = @(
        @{ Nombre = $Script:AD_CLIENTE_LINUX; Tipo = "Linux" },
        @{ Nombre = $Script:AD_CLIENTE_WIN;   Tipo = "Windows" }
    )

    foreach ($c in $clientes) {
        $n = $c.Nombre
        if ([string]::IsNullOrWhiteSpace($n)) {
            Write-Host ("  [ ] Cliente {0,-10}: (no configurado)" -f $c.Tipo)
            continue
        }

        $existeUsr = $null -ne (Get-LocalUser -Name $n -ErrorAction SilentlyContinue)
        $icono     = if ($existeUsr) { "[*]" } else { "[ ]" }
        $ruta      = "$Script:AD_CLIENTES_DIR\$n"

        $infoCuota = ""
        if ($fsrmOk -and (Test-Path $ruta)) {
            $cuota = Get-FsrmQuota -Path $ruta -ErrorAction SilentlyContinue
            if ($cuota) {
                $mb  = [Math]::Round($cuota.Size  / 1MB, 0)
                $uso = [Math]::Round($cuota.Usage / 1MB, 2)
                $infoCuota = "  cuota: $mb MB (usado: $uso MB)"
            }
        }

        $horario = ""
        if ($existeUsr) {
            $horario = "  horario: $(_clientes_leer_horario $n)"
        }

        Write-Host ("  $icono Cliente {0,-10}: {1}{2}{3}" -f $c.Tipo, $n, $infoCuota, $horario)
    }

    $share = Get-SmbShare -Name $Script:AD_CLIENTES_SHARE -ErrorAction SilentlyContinue
    $iconoShare = if ($share) { "[*]" } else { "[ ]" }
    Write-Host "  $iconoShare Share SMB  : \\$env:COMPUTERNAME\$Script:AD_CLIENTES_SHARE"
}

# ------------------------------------------------------------
# Submenu de un cliente individual
# ------------------------------------------------------------

function _clientes_submenu {
    param([string]$Nombre, [bool]$EsWindows)

    while ($true) {
        Clear-Host
        ad_mostrar_banner "Cliente $( if ($EsWindows) { 'Windows' } else { 'Linux' } ): $Nombre"

        $existeUsr = $null -ne (Get-LocalUser -Name $Nombre -ErrorAction SilentlyContinue)
        $icono     = if ($existeUsr) { "[*]" } else { "[ ]" }

        Write-Host "  $icono Usuario local de Windows creado"
        if ($existeUsr) {
            Write-Host ("       Horario : {0}" -f (_clientes_leer_horario $Nombre))
        }
        Write-Host ""
        Write-Host "  1) Crear / reinicializar usuario"
        Write-Host "  2) Configurar horario de acceso  [GUI grafica -- grilla 7x24h]"
        Write-Host "  3) Modificar cuota de disco      [GUI grafica -- slider + numero]"
        Write-Host "  4) Ver uso de disco (barra visual)"
        if ($EsWindows) {
            Write-Host "  5) Bloquear Notepad via AppLocker"
        }
        Write-Host "  0) Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op.Trim()) {
            "1" {
                Write-Host ""
                $pass = Read-Host "  Contrasena para $Nombre (min 8 chars, mayus+minus+num+simbolo)"
                $mbIn = Read-Host "  Cuota inicial en MB [$Script:AD_CUOTA_CLIENTE_MB]"
                if ([string]::IsNullOrEmpty($mbIn)) { $mbIn = $Script:AD_CUOTA_CLIENTE_MB }
                if (_clientes_verificar_fsrm) {
                    $ok = _clientes_crear_usuario -Usuario $Nombre -Password $pass `
                        -Descripcion "Cliente $( if ($EsWindows) { 'Windows' } else { 'Linux' } ) $Nombre" `
                        -CuotaMB ([int]$mbIn)
                    if ($ok) { aputs_ok "Usuario $Nombre listo" }
                }
                pause
            }
            "2" {
                $horas = clientes_gui_horario -Usuario $Nombre
                if ($null -ne $horas) {
                    Write-Host ""
                    _clientes_aplicar_horario -Usuario $Nombre -HorasStr $horas
                    pause
                }
            }
            "3" {
                $ruta   = "$Script:AD_CLIENTES_DIR\$Nombre"
                $actual = $Script:AD_CUOTA_CLIENTE_MB
                if ((_clientes_verificar_fsrm) -and (Test-Path $ruta)) {
                    $cuota = Get-FsrmQuota -Path $ruta -ErrorAction SilentlyContinue
                    if ($cuota) { $actual = [int]($cuota.Size / 1MB) }
                }
                $nuevaMB = clientes_gui_cuota -Usuario $Nombre -ActualMB $actual
                if ($null -ne $nuevaMB) {
                    if (_clientes_verificar_fsrm) {
                        _clientes_cuota_aplicar -Usuario $Nombre -MB $nuevaMB
                    }
                    pause
                }
            }
            "4" {
                Write-Host ""
                if (_clientes_verificar_fsrm) { _clientes_barra_cuota -Usuario $Nombre }
                pause
            }
            "5" {
                if ($EsWindows) {
                    Write-Host ""
                    cliente_win_applocker_notepad -Usuario $Nombre
                    pause
                }
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ------------------------------------------------------------
# Menu principal de clientes
# ------------------------------------------------------------

function clientes_menu_principal {
    while ($true) {
        Clear-Host
        ad_mostrar_banner "Paso 6 -- Gestion de Clientes"

        Write-Host ""
        clientes_panel_estado
        Write-Host ""

        Write-Host "  -- Clientes -----------------------------------------------"
        Write-Host ("  1)  Gestionar cliente Linux   [{0}]" -f $Script:AD_CLIENTE_LINUX)
        Write-Host ("  2)  Gestionar cliente Windows [{0}]" -f $(if ([string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) { "sin configurar" } else { $Script:AD_CLIENTE_WIN }))
        Write-Host ""
        Write-Host "  -- Disco compartido ----------------------------------------"
        Write-Host "  3)  Crear share SMB + instrucciones de montaje"
        Write-Host "  4)  Ver cuotas de todos los clientes (barras visuales)"
        Write-Host ""
        Write-Host "  -- Ajustes --------------------------------------------------"
        Write-Host "  c)  Cambiar nombre usuario cliente Windows"
        Write-Host "  a)  Asistente completo (crea ambos clientes + horarios + cuotas)"
        Write-Host ""
        Write-Host "  0)  Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op.Trim().ToLower()) {
            "1" {
                _clientes_submenu -Nombre $Script:AD_CLIENTE_LINUX -EsWindows $false
            }
            "2" {
                if ([string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) {
                    $Script:AD_CLIENTE_WIN = Read-Host "  Nombre del usuario cliente Windows"
                }
                if (-not [string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) {
                    _clientes_submenu -Nombre $Script:AD_CLIENTE_WIN -EsWindows $true
                }
            }
            "3" {
                Clear-Host
                ad_mostrar_banner "Share SMB -- Disco Compartido"
                cliente_crear_share
                pause
            }
            "4" {
                Clear-Host
                ad_mostrar_banner "Uso de Disco -- Clientes"
                if (_clientes_verificar_fsrm) {
                    foreach ($n in @($Script:AD_CLIENTE_LINUX, $Script:AD_CLIENTE_WIN)) {
                        if (-not [string]::IsNullOrWhiteSpace($n)) {
                            _clientes_barra_cuota -Usuario $n
                        }
                    }
                }
                pause
            }
            "c" {
                $nuevo = Read-Host "  Nuevo nombre usuario cliente Windows"
                if (-not [string]::IsNullOrWhiteSpace($nuevo)) {
                    $Script:AD_CLIENTE_WIN = $nuevo
                    aputs_ok "Cliente Windows configurado como: $nuevo"
                }
            }
            "a" { clientes_configurar_completo }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ------------------------------------------------------------
# Asistente completo de configuracion de clientes
# ------------------------------------------------------------

function clientes_configurar_completo {
    Clear-Host
    ad_mostrar_banner "Asistente -- Configuracion Completa de Clientes"

    if (-not (_clientes_verificar_fsrm)) { pause; return }

    Write-Host ""
    Write-Host "  Este asistente configura:"
    Write-Host "    - Usuario local Linux  ($Script:AD_CLIENTE_LINUX)"
    Write-Host "    - Usuario local Windows (nombre configurable)"
    Write-Host "    - Cuotas FSRM por cliente"
    Write-Host "    - Horarios de acceso via GUI grafica"
    Write-Host "    - Recurso compartido SMB para montar en clientes"
    Write-Host "    - Bloqueo de Notepad para cliente Windows (opcional)"
    Write-Host ""

    $confirm = Read-Host "  Continuar? [S/n]"
    if ($confirm -match '^[nN]$') { aputs_info "Cancelado"; pause; return }

    # Nombre del cliente Windows
    if ([string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) {
        $Script:AD_CLIENTE_WIN = Read-Host "  Nombre del usuario cliente Windows"
        if ([string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) {
            aputs_error "Nombre invalido"; pause; return
        }
    }

    # --- Cliente Linux ---
    Write-Host ""
    draw_line
    aputs_info "Configurando cliente Linux: $Script:AD_CLIENTE_LINUX"
    $passLinux = Read-Host "  Contrasena para $Script:AD_CLIENTE_LINUX"
    $mbLinux   = Read-Host "  Cuota en MB [$Script:AD_CUOTA_CLIENTE_MB]"
    if ([string]::IsNullOrEmpty($mbLinux)) { $mbLinux = $Script:AD_CUOTA_CLIENTE_MB }
    _clientes_crear_usuario -Usuario $Script:AD_CLIENTE_LINUX `
        -Password $passLinux -Descripcion "Cliente Linux" -CuotaMB ([int]$mbLinux) | Out-Null

    # --- Cliente Windows ---
    Write-Host ""
    draw_line
    aputs_info "Configurando cliente Windows: $Script:AD_CLIENTE_WIN"
    $passWin = Read-Host "  Contrasena para $Script:AD_CLIENTE_WIN"
    $mbWin   = Read-Host "  Cuota en MB [$Script:AD_CUOTA_CLIENTE_MB]"
    if ([string]::IsNullOrEmpty($mbWin)) { $mbWin = $Script:AD_CUOTA_CLIENTE_MB }
    _clientes_crear_usuario -Usuario $Script:AD_CLIENTE_WIN `
        -Password $passWin -Descripcion "Cliente Windows" -CuotaMB ([int]$mbWin) | Out-Null

    # --- Horarios via GUI ---
    Write-Host ""
    draw_line
    aputs_info "Abriendo GUI de horarios para $Script:AD_CLIENTE_LINUX ..."
    $horasLinux = clientes_gui_horario -Usuario $Script:AD_CLIENTE_LINUX
    if ($null -ne $horasLinux) {
        _clientes_aplicar_horario -Usuario $Script:AD_CLIENTE_LINUX -HorasStr $horasLinux
    }

    aputs_info "Abriendo GUI de horarios para $Script:AD_CLIENTE_WIN ..."
    $horasWin = clientes_gui_horario -Usuario $Script:AD_CLIENTE_WIN
    if ($null -ne $horasWin) {
        _clientes_aplicar_horario -Usuario $Script:AD_CLIENTE_WIN -HorasStr $horasWin
    }

    # --- AppLocker notepad para cliente Windows ---
    Write-Host ""
    draw_line
    $bloq = Read-Host "  Bloquear Notepad en cliente Windows ($Script:AD_CLIENTE_WIN)? [s/N]"
    if ($bloq -match '^[sS]$') {
        cliente_win_applocker_notepad -Usuario $Script:AD_CLIENTE_WIN
    }

    # --- Share SMB ---
    Write-Host ""
    draw_line
    aputs_info "Configurando recurso compartido SMB..."
    cliente_crear_share | Out-Null

    # --- Resumen ---
    Write-Host ""
    draw_line
    aputs_ok "Clientes configurados correctamente"
    Write-Host ""
    clientes_panel_estado
    Write-Host ""
    _clientes_barra_cuota -Usuario $Script:AD_CLIENTE_LINUX
    _clientes_barra_cuota -Usuario $Script:AD_CLIENTE_WIN

    pause
}

# ------------------------------------------------------------
# Estado para el menu principal (usa el mismo patron que otros modulos)
# ------------------------------------------------------------

function _estado_clientes {
    try {
        $linux = $null -ne (Get-LocalUser -Name $Script:AD_CLIENTE_LINUX -ErrorAction SilentlyContinue)
        $win   = (-not [string]::IsNullOrWhiteSpace($Script:AD_CLIENTE_WIN)) -and
                 ($null -ne (Get-LocalUser -Name $Script:AD_CLIENTE_WIN -ErrorAction SilentlyContinue))
        return ($linux -or $win)
    } catch { return $false }
}
