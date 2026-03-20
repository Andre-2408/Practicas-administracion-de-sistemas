# installFTP.ps1 -- Instalacion de servicios HTTP desde el repositorio FTP propio (Windows)

if ($Script:_INSTALL_FTP_LOADED) { return }
$Script:_INSTALL_FTP_LOADED = $true

# ------------------------------------------------------------
# Configuracion de sesion FTP
# ------------------------------------------------------------

$Script:_FTP_HOST      = ""
$Script:_FTP_USER      = $Script:SSL_FTP_USER
$Script:_FTP_PASS      = ""
$Script:_FTP_REPO_PATH = "/repositorio/http/Windows"
$Script:_FTP_TMP       = "$env:TEMP\ftp_install_p7"

# ------------------------------------------------------------
# Conectar al servidor FTP
# ------------------------------------------------------------

function _ftp_conectar {
    Clear-Host
    ssl_mostrar_banner "Conexion al Repositorio FTP"

    $Script:_FTP_HOST = $Script:SSL_FTP_IP
    $Script:_FTP_USER = $Script:SSL_FTP_USER

    Write-Host ""
    Write-Host ("  {0,-12} ftp://{1}" -f "Servidor:", $Script:_FTP_HOST)
    Write-Host ("  {0,-12} {1}"       -f "Usuario:",  $Script:_FTP_USER)
    Write-Host ""

    $secPass = Read-Host "  Contrasena" -AsSecureString
    $Script:_FTP_PASS = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))
    Write-Host ""

    aputs_info "Verificando conexion a ftp://$Script:_FTP_HOST..."

    $listaRaw = _ftp_listar_dir $Script:_FTP_REPO_PATH
    if ($null -eq $listaRaw -or $listaRaw.Count -eq 0) {
        aputs_error "No se pudo conectar o autenticar al servidor FTP"
        aputs_info  "Verifique que IIS FTP esta activo y la contrasena es correcta"
        return $false
    }

    aputs_success "Conexion establecida con ftp://$Script:_FTP_HOST"
    Write-Host ""
    return $true
}

# ------------------------------------------------------------
# Listar contenido de directorio FTP via .NET
# ------------------------------------------------------------

function _ftp_listar_dir {
    param([string]$Dir)
    try {
        $uri = "ftp://$Script:_FTP_HOST$Dir"
        $req = [System.Net.FtpWebRequest]::Create($uri)
        $req.Method      = [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $req.Credentials = New-Object System.Net.NetworkCredential($Script:_FTP_USER, $Script:_FTP_PASS)
        $req.EnableSsl   = $true
        $req.UsePassive  = $true
        $req.KeepAlive   = $false
        $req.Timeout     = 10000
        # Aceptar cualquier certificado (autofirmado)
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        $resp    = $req.GetResponse()
        $stream  = $resp.GetResponseStream()
        $reader  = New-Object System.IO.StreamReader($stream)
        $listing = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()

        # Parsear listado FTP (formato Unix o Windows)
        $entradas = $listing -split "`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
            $line = $_.Trim()
            # Extraer ultimo campo (nombre)
            ($line -split '\s+')[-1]
        }
        return $entradas
    } catch {
        return @()
    }
}

# ------------------------------------------------------------
# Descargar archivos de un directorio FTP
# ------------------------------------------------------------

function _ftp_descargar_dir {
    param([string]$RemoteDir, [string]$LocalDest)

    New-Item -ItemType Directory -Path $LocalDest -Force | Out-Null

    aputs_info "Descargando desde ftp://$Script:_FTP_HOST$RemoteDir..."

    $archivos = _ftp_listar_dir "$RemoteDir/" | Where-Object { $_ -match '\.(nupkg|zip|msi)$' }

    if ($archivos.Count -eq 0) {
        aputs_error "No se encontraron paquetes en $RemoteDir"
        return $false
    }

    $descargados = 0
    foreach ($archivo in $archivos) {
        $remoteFile = "$RemoteDir/$archivo"
        $localFile  = Join-Path $LocalDest $archivo
        try {
            $uri = "ftp://$Script:_FTP_HOST$remoteFile"
            $req = [System.Net.FtpWebRequest]::Create($uri)
            $req.Method      = [System.Net.WebRequestMethods+Ftp]::DownloadFile
            $req.Credentials = New-Object System.Net.NetworkCredential($Script:_FTP_USER, $Script:_FTP_PASS)
            $req.EnableSsl   = $true
            $req.UsePassive  = $true
            $req.Timeout     = 120000
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

            $resp   = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $fs     = [System.IO.File]::Create($localFile)
            $stream.CopyTo($fs)
            $fs.Close(); $resp.Close()
            $descargados++
            aputs_success "Descargado: $archivo"
        } catch {
            aputs_warning "Error descargando ${archivo}: $_"
        }
    }

    if ($descargados -eq 0) {
        aputs_error "No se descargaron paquetes desde $RemoteDir"
        return $false
    }

    aputs_success "$descargados paquete(s) descargados en $LocalDest"
    return $true
}

# ------------------------------------------------------------
# Mapeos de nombres de servicio
# ------------------------------------------------------------

function _ftp_svc_choco {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "apache" { return "apache-httpd" }
        "nginx"  { return "nginx"  }
        "tomcat" { return "tomcat" }
    }
}

function _ftp_svc_winsvc {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "apache" { return ssl_nombre_winsvc "apache" }
        "nginx"  { return "nginx" }
        "tomcat" { return ssl_nombre_winsvc "tomcat" }
    }
}

function _ftp_puerto_default {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "apache" { return "80"   }
        "nginx"  { return "8080" }
        "tomcat" { return "8080" }
        default  { return "80"   }
    }
}

function _ftp_esta_instalado {
    param([string]$Servicio)
    if ($Servicio.ToLower() -eq "nginx") {
        $nginxConf = ssl_conf_nginx
        if ($nginxConf -and (Test-Path $nginxConf)) { return $true }
        foreach ($d in @("C:\tools\nginx","C:\nginx")) {
            if (Test-Path "$d\nginx.exe") { return $true }
        }
        return $false
    }
    $winsvc = _ftp_svc_winsvc $Servicio
    return ($null -ne (Get-Service -Name $winsvc -ErrorAction SilentlyContinue))
}

# ------------------------------------------------------------
# Reiniciar servicio con diagnostico
# ------------------------------------------------------------

function _ftp_reiniciar_servicio {
    param([string]$Servicio, [string]$WinSvc)

    # Intentar como servicio de Windows
    $svcObj = Get-Service -Name $WinSvc -ErrorAction SilentlyContinue
    if ($svcObj) {
        aputs_info "Reiniciando servicio $WinSvc..."
        try {
            Restart-Service -Name $WinSvc -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
            $svcObj = Get-Service -Name $WinSvc
            if ($svcObj.Status -eq "Running") {
                aputs_success "$Servicio reiniciado correctamente"
                return $true
            } else {
                aputs_error "$Servicio no esta activo despues del reinicio"
            }
        } catch {
            aputs_error "Error al reiniciar ${WinSvc}: $_"
        }
        return $false
    }

    # Nginx: no es servicio Windows -- iniciar como proceso
    if ($Servicio.ToLower() -eq "nginx") {
        return (ssl_nginx_reiniciar)
    }

    aputs_error "Servicio '$WinSvc' no encontrado"
    return $false
}

# ------------------------------------------------------------
# Desinstalar un servicio
# ------------------------------------------------------------

function _ftp_desinstalar {
    param([string]$Servicio)
    $winsvc   = _ftp_svc_winsvc $Servicio
    $chocoPkg = _ftp_svc_choco $Servicio

    Write-Host ""
    $conf = Read-Host "  Confirmar desinstalacion de $Servicio? [s/N]"
    if ($conf -notmatch '^[sS]$') { aputs_info "Cancelado"; return }

    # Detener y desinstalar
    Stop-Service -Name $winsvc -Force -ErrorAction SilentlyContinue

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        choco uninstall $chocoPkg -y --no-progress 2>$null | Out-Null
        aputs_success "$Servicio desinstalado via Chocolatey"
    } else {
        aputs_warning "Chocolatey no disponible -- desinstale $Servicio manualmente"
    }
}

# ------------------------------------------------------------
# Reconfigurar puerto de un servicio instalado
# ------------------------------------------------------------

function _ftp_reconfigurar_puerto {
    param([string]$Servicio)

    $puertoActual = ssl_leer_puerto_http $Servicio
    Write-Host ""
    $nuevoPuerto = Read-Host "  Nuevo puerto HTTP [$puertoActual]"
    if ([string]::IsNullOrEmpty($nuevoPuerto)) { $nuevoPuerto = $puertoActual }

    # Llamar a las funciones de P6 si estan disponibles
    if (Get-Command http_aplicar_puerto -ErrorAction SilentlyContinue) {
        http_aplicar_puerto $Servicio $nuevoPuerto
    } else {
        # Edicion directa de archivos de configuracion
        switch ($Servicio.ToLower()) {
            "apache" {
                $conf = ssl_conf_apache
                if (Test-Path $conf) {
                    $contenido = (Get-Content $conf -Raw) -replace '(?m)^Listen\s+\d+', "Listen $nuevoPuerto"
                    [System.IO.File]::WriteAllText($conf, $contenido, [System.Text.UTF8Encoding]::new($false))
                    aputs_success "Puerto Apache actualizado a $nuevoPuerto"
                }
            }
            "nginx" {
                $conf = ssl_conf_nginx
                if (Test-Path $conf) {
                    $contenido = (Get-Content $conf -Raw) -replace 'listen\s+\d+', "listen $nuevoPuerto"
                    [System.IO.File]::WriteAllText($conf, $contenido, [System.Text.UTF8Encoding]::new($false))
                    aputs_success "Puerto Nginx actualizado a $nuevoPuerto"
                }
            }
            "tomcat" {
                $conf = ssl_conf_tomcat
                if (Test-Path $conf) {
                    [xml]$xml = Get-Content $conf
                    $conn = $xml.Server.Service.Connector |
                        Where-Object { $_.protocol -match 'HTTP' } | Select-Object -First 1
                    if ($conn) {
                        $conn.SetAttribute("port", $nuevoPuerto)
                        $xml.Save($conf)
                        aputs_success "Puerto Tomcat actualizado a $nuevoPuerto"
                    }
                }
            }
        }
    }

    ssl_abrir_puerto_firewall ([int]$nuevoPuerto)
    $winsvc = _ftp_svc_winsvc $Servicio
    _ftp_reiniciar_servicio $Servicio $winsvc | Out-Null
}

# ------------------------------------------------------------
# Instalar paquetes descargados
# ------------------------------------------------------------

function _ftp_instalar_paquetes {
    param([string]$Dir, [string]$Servicio, [string]$Version)

    $paquetes = Get-ChildItem $Dir -Include "*.nupkg", "*.zip", "*.msi" -Recurse `
        -ErrorAction SilentlyContinue | Sort-Object Name

    if ($paquetes.Count -eq 0) {
        aputs_error "No hay paquetes en $Dir"
        return $false
    }

    Write-Host ""
    aputs_info "Paquetes a instalar:"
    $paquetes | ForEach-Object { Write-Host "    $($_.Name)" }
    Write-Host ""

    $puertoDefault = _ftp_puerto_default $Servicio
    $puerto = Read-Host "  Puerto HTTP [$puertoDefault]"
    if ([string]::IsNullOrEmpty($puerto)) { $puerto = $puertoDefault }

    Write-Host ""
    $conf = Read-Host "  Confirmar instalacion de $Servicio $Version en puerto $puerto? [S/n]"
    if ($conf -match '^[nN]$') { aputs_info "Instalacion cancelada"; return $false }

    Write-Host ""

    # Asegurar Chocolatey en PATH o instalarlo
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        if (Test-Path $chocoExe) {
            # Chocolatey instalado pero no en PATH de esta sesion
            $env:Path += ";$env:ProgramData\chocolatey\bin"
        } else {
            aputs_info "Instalando Chocolatey..."
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                $chocoScript = (New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
                Invoke-Expression $chocoScript 2>&1 | Out-Null
                $env:Path += ";$env:ProgramData\chocolatey\bin"
                if (-not (Test-Path $chocoExe)) {
                    aputs_error "No se pudo instalar Chocolatey -- verifique conexion a internet"
                    return $false
                }
                aputs_success "Chocolatey instalado correctamente"
            } catch {
                aputs_error "Error instalando Chocolatey: $_"
                return $false
            }
        }
    }

    # Instalar via Chocolatey
    # Los nupkgs de Chocolatey community contienen el script de instalacion
    # que descarga los binarios -- se intenta primero con nupkg local como referencia
    # y si falla (URL antigua/no accesible) se instala directamente desde Chocolatey
    $chocoPkg = _ftp_svc_choco $Servicio
    aputs_info "Instalando $Servicio $Version via Chocolatey..."

    choco install $chocoPkg --version=$Version `
        --source="'$Dir';https://community.chocolatey.org/api/v2/" `
        -y --no-progress --force 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        aputs_info "Instalando $Servicio desde Chocolatey online..."
        choco install $chocoPkg --version=$Version -y --no-progress --force 2>&1 | Out-Null
    }

    # Refrescar PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Para Tomcat: registrar servicio Windows si no existe despues de instalar
    if ($Servicio.ToLower() -eq "tomcat") {
        $tomcatSvc = ssl_nombre_winsvc "tomcat"
        if (-not (Get-Service -Name $tomcatSvc -ErrorAction SilentlyContinue)) {
            aputs_info "Registrando Tomcat como servicio Windows..."
            $catHome = Get-ChildItem "C:\ProgramData\chocolatey\lib\tomcat\tools" -Filter "apache-tomcat-*" -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($catHome) {
                $catBase = "C:\ProgramData\Tomcat9"
                if (-not (Test-Path $catBase)) { New-Item -ItemType Directory -Path $catBase -Force | Out-Null }
                $env:CATALINA_HOME = $catHome.FullName
                $env:CATALINA_BASE = $catBase
                $javaHome = $null
                foreach ($jb in @("C:\Program Files\Eclipse Adoptium", "C:\Program Files\Java", "C:\Program Files\OpenJDK")) {
                    $found = Get-ChildItem $jb -Filter "jdk*" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) { $javaHome = $found.FullName; break }
                }
                if (-not $javaHome) {
                    $javaExe = Get-Command java -ErrorAction SilentlyContinue
                    if ($javaExe) { $javaHome = Split-Path (Split-Path $javaExe.Source) }
                }
                if ($javaHome) { $env:JAVA_HOME = $javaHome }
                $serviceBat = "$($catHome.FullName)\bin\service.bat"
                if (Test-Path $serviceBat) {
                    & cmd.exe /c "`"$serviceBat`" install Tomcat9" 2>&1 | ForEach-Object { Write-Host "    $_" }
                    if (Get-Service -Name "Tomcat9" -ErrorAction SilentlyContinue) {
                        aputs_success "Servicio Tomcat9 registrado correctamente"
                    } else {
                        aputs_warning "No se pudo registrar el servicio Tomcat9"
                    }
                }
            }
        }
    }

    # Para nginx: verificar instalacion y hacer fallback a descarga directa si fallo
    if ($Servicio.ToLower() -eq "nginx") {
        $nginxConf = ssl_conf_nginx
        $nginxExe  = if ($nginxConf) { Join-Path (Split-Path (Split-Path $nginxConf)) "nginx.exe" } else { $null }
        if (-not $nginxExe -or -not (Test-Path $nginxExe)) {
            aputs_info "Chocolatey no instalo nginx -- descargando ZIP oficial desde nginx.org..."
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = `
                    [System.Net.SecurityProtocolType]::Tls12 -bor `
                    [System.Net.SecurityProtocolType]::Tls11 -bor `
                    [System.Net.SecurityProtocolType]::Tls
                $zipUrl  = "https://nginx.org/download/nginx-$Version.zip"
                $zipFile = "$env:TEMP\nginx-$Version.zip"
                $destDir = "C:\tools"
                New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue | Out-Null

                # Intentar descarga con multiples metodos
                $descargaOk = $false
                # Metodo 1: curl.exe (nativo en Windows Server 2022)
                if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                    curl.exe -L -s -o "$zipFile" "$zipUrl" 2>$null
                    $descargaOk = ($LASTEXITCODE -eq 0) -and (Test-Path $zipFile) -and ((Get-Item $zipFile).Length -gt 100000)
                }
                # Metodo 2: WebClient
                if (-not $descargaOk) {
                    try {
                        $wc = New-Object System.Net.WebClient
                        $wc.DownloadFile($zipUrl, $zipFile)
                        $descargaOk = (Test-Path $zipFile) -and ((Get-Item $zipFile).Length -gt 100000)
                    } catch { }
                }
                # Metodo 3: Invoke-WebRequest
                if (-not $descargaOk) {
                    Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
                    $descargaOk = (Test-Path $zipFile) -and ((Get-Item $zipFile).Length -gt 100000)
                }

                if (-not $descargaOk) { throw "No se pudo descargar el ZIP de nginx" }

                Expand-Archive -Path $zipFile -DestinationPath $destDir -Force -ErrorAction Stop
                $extracted = Join-Path $destDir "nginx-$Version"
                $targetDir = Join-Path $destDir "nginx"
                if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue }
                Rename-Item -Path $extracted -NewName "nginx" -ErrorAction Stop
                Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
                aputs_success "nginx $Version instalado en C:\tools\nginx"
            } catch {
                aputs_error "Descarga directa fallo: $_"
                return $false
            }
        }
    }

    aputs_success "$Servicio instalado"
    Write-Host ""

    # Aplicar configuracion de puerto
    _ftp_reconfigurar_puerto $Servicio | Out-Null

    # Habilitar servicio
    $winsvc = _ftp_svc_winsvc $Servicio
    Set-Service -Name $winsvc -StartupType Automatic -ErrorAction SilentlyContinue

    Write-Host ""
    _ftp_reiniciar_servicio $Servicio $winsvc | Out-Null
    Write-Host ""

    # Preguntar SSL
    $confSsl = Read-Host "  Desea configurar SSL/HTTPS para $Servicio? [s/N]"
    if ($confSsl -match '^[sS]$') {
        _ftp_configurar_ssl $Servicio
    }

    return $true
}

# ------------------------------------------------------------
# Configurar SSL para el servicio instalado
# ------------------------------------------------------------

function _ftp_configurar_ssl {
    param([string]$Servicio)

    Write-Host ""
    draw_line
    Write-Host ""
    aputs_info "Configuracion SSL para $Servicio"
    Write-Host ""

    if (-not (ssl_cert_existe)) {
        aputs_warning "No hay certificado SSL -- generando uno ahora..."
        Write-Host ""
        if (-not (ssl_cert_generar)) {
            aputs_error "No se pudo generar el certificado"
            return $false
        }
        Write-Host ""
    } else {
        aputs_success "Certificado existente: $Script:SSL_CERT"
        ssl_cert_mostrar_info | Out-Null
    }

    Write-Host ""
    aputs_info "Aplicando SSL en $Servicio..."
    Write-Host ""

    switch ($Servicio.ToLower()) {
        "apache" { _ssl_apache_aplicar }
        "nginx"  { _ssl_nginx_aplicar  }
        "tomcat" { _ssl_tomcat_aplicar }
    }
}

# ------------------------------------------------------------
# Menu de versiones FTP
# ------------------------------------------------------------

function _ftp_menu_versiones {
    param([string]$Servicio)

    $remoteBase = "$Script:_FTP_REPO_PATH/$Servicio"

    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Repo FTP -- $Servicio"

        if (_ftp_esta_instalado $Servicio) {
            $winsvc = _ftp_svc_winsvc $Servicio
            $svc    = Get-Service -Name $winsvc -ErrorAction SilentlyContinue
            $estado = if ($svc -and $svc.Status -eq "Running") { "activo" } else { "inactivo" }

            aputs_warning "$Servicio ya instalado  ($estado)"
            Write-Host ""
            Write-Host "  1) Reinstalar desde FTP (elegir version)"
            Write-Host "  2) Reconfigurar puerto HTTP"
            Write-Host "  3) Configurar / reconfigurar SSL"
            Write-Host "  4) Desinstalar $Servicio"
            Write-Host "  0) Volver"
            Write-Host ""

            $op = Read-Host "  Opcion"
            switch ($op) {
                "2" { _ftp_reconfigurar_puerto $Servicio; pause; continue }
                "3" { _ftp_configurar_ssl $Servicio;      pause; continue }
                "4" { _ftp_desinstalar $Servicio;         pause; continue }
                "0" { return }
                "1" { }   # continuar al listado de versiones
                default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1; continue }
            }
        }

        # Listar versiones disponibles en FTP
        Write-Host ""
        aputs_info "Conectado a ftp://$Script:_FTP_HOST"
        aputs_info "Directorio: $remoteBase"
        Write-Host ""
        aputs_info "Versiones disponibles:"
        Write-Host ""

        $versiones = @(_ftp_listar_dir "$remoteBase/" | Where-Object { $_ -ne "" })

        if ($versiones.Count -eq 0) {
            aputs_warning "No hay versiones en $remoteBase"
            aputs_info   "Descargue paquetes primero desde el Paso 4"
            pause
            return
        }

        $i = 1
        foreach ($v in $versiones) {
            Write-Host ("  {0,2}) {1}" -f $i, $v)
            $i++
        }
        Write-Host ""
        Write-Host "  0) Volver"
        Write-Host ""

        $op = Read-Host "  Seleccione version"
        if ($op -eq "0") { return }

        $n = 0
        if ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le $versiones.Count) {
            $version   = $versiones[$n - 1]
            $remoteDir = "$remoteBase/$version"
            $localDir  = Join-Path $Script:_FTP_TMP "$Servicio\$version"

            Write-Host ""
            draw_line

            aputs_info "Contenido de ${remoteDir}:"
            Write-Host ""
            _ftp_listar_dir "$remoteDir/" | Where-Object { $_ -match '\.(nupkg|zip|msi)$' } |
                ForEach-Object { Write-Host "    $_" }
            Write-Host ""

            if (_ftp_descargar_dir $remoteDir $localDir) {
                Write-Host ""
                draw_line
                _ftp_instalar_paquetes $localDir $Servicio $version
            }

            pause
        } else {
            aputs_error "Opcion invalida"
            Start-Sleep -Seconds 1
        }
    }
}

# ------------------------------------------------------------
# Menu de servicios
# ------------------------------------------------------------

function _ftp_menu_servicios {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Instalar desde Repositorio FTP"

        aputs_success "Sesion activa: ftp://$Script:_FTP_HOST  usuario: $Script:_FTP_USER"
        Write-Host ""

        foreach ($svc in @("Apache", "Nginx", "Tomcat")) {
            $winsvc = _ftp_svc_winsvc $svc
            if ($svc.ToLower() -eq "nginx") {
                $proc   = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
                $icono  = if ($proc) { "[*]" } else { "[ ]" }
                $estado = if ($proc) { "activo (proceso)" } else { "no instalado/inactivo" }
            } else {
                $servObj = Get-Service -Name $winsvc -ErrorAction SilentlyContinue
                if ($servObj) {
                    $estado = if ($servObj.Status -eq "Running") { "activo" } else { "instalado/inactivo" }
                    $icono  = "[*]"
                } else {
                    $estado = "no instalado"
                    $icono  = "[ ]"
                }
            }
            Write-Host ("  $icono {0,-8} {1}" -f "${svc}:", $estado)
        }
        # IIS: estado por Windows Feature
        $iisInstalado = (Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue).Installed
        $iisSvc       = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
        $iisIcono     = if ($iisInstalado) { "[*]" } else { "[ ]" }
        $iisEstado    = if ($iisSvc -and $iisSvc.Status -eq "Running") { "activo" } elseif ($iisInstalado) { "instalado/inactivo" } else { "no instalado" }
        Write-Host ("  $iisIcono {0,-8} {1}" -f "IIS:", $iisEstado)

        Write-Host ""
        Write-Host "  1) Apache  (httpd)"
        Write-Host "  2) Nginx"
        Write-Host "  3) Tomcat"
        Write-Host "  4) IIS     (caracteristica Windows)"
        Write-Host "  0) Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { _ftp_menu_versiones "Apache" }
            "2" { _ftp_menu_versiones "Nginx"  }
            "3" { _ftp_menu_versiones "Tomcat" }
            "4" { Write-Host ""; _repo_instalar_iis | Out-Null; pause }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ------------------------------------------------------------
# Punto de entrada principal
# ------------------------------------------------------------

function ssl_instalar_desde_ftp {
    if (-not (_ftp_conectar)) { pause; return $false }
    _ftp_menu_servicios
    Remove-Item $Script:_FTP_TMP -Force -Recurse -ErrorAction SilentlyContinue
}
