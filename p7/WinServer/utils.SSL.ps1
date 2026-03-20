# utils.SSL.ps1 -- Constantes globales y helpers compartidos para SSL/TLS (Windows)

if ($Script:_SSL_UTILS_LOADED) { return }
$Script:_SSL_UTILS_LOADED = $true

# ------------------------------------------------------------
# Constantes de certificado
# ------------------------------------------------------------
$Script:SSL_DIR      = "C:\ssl\reprobados"
$Script:SSL_CERT     = "$Script:SSL_DIR\reprobados.crt"
$Script:SSL_KEY      = "$Script:SSL_DIR\reprobados.key"
$Script:SSL_PFX      = "$Script:SSL_DIR\reprobados.pfx"
$Script:SSL_DOMAIN   = "reprobados.com"
$Script:SSL_DAYS     = 365
$Script:SSL_KEY_BITS = 2048
$Script:SSL_SUBJ     = "/C=MX/ST=Mexico/L=Mexico City/O=Administracion de Sistemas/OU=Practica7/CN=reprobados.com"
$Script:SSL_PFX_PASS = "reprobados123"

# ------------------------------------------------------------
# Constantes del repositorio FTP
# ------------------------------------------------------------
$Script:SSL_FTP_ROOT       = "C:\FTP"                                    # debe coincidir con $FTP_ROOT de ftp-win.ps1
$Script:SSL_FTP_USER       = "repo"
$Script:SSL_FTP_CHROOT     = "$Script:SSL_FTP_ROOT\LocalUser\$Script:SSL_FTP_USER"  # donde IIS FTP user isolation busca el home
$Script:SSL_FTP_RED_INTERNA = "192.168.100"

function _ssl_detectar_ip {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -ne "127.0.0.1" -and
            $_.IPAddress -notlike "$Script:SSL_FTP_RED_INTERNA.*" -and
            $_.PrefixOrigin -ne "WellKnown"
        } | Sort-Object InterfaceIndex | Select-Object -First 1
    if ($ip) { return $ip.IPAddress }
    return "127.0.0.1"
}
$Script:SSL_FTP_IP = _ssl_detectar_ip

$Script:SSL_REPO_ROOT    = "$Script:SSL_FTP_CHROOT\repositorio"
$Script:SSL_REPO_WINDOWS = "$Script:SSL_REPO_ROOT\http\Windows"
$Script:SSL_REPO_APACHE  = "$Script:SSL_REPO_WINDOWS\Apache"
$Script:SSL_REPO_NGINX   = "$Script:SSL_REPO_WINDOWS\Nginx"
$Script:SSL_REPO_TOMCAT  = "$Script:SSL_REPO_WINDOWS\Tomcat"
$Script:SSL_REPO_IIS     = "$Script:SSL_REPO_WINDOWS\IIS"

# ------------------------------------------------------------
# Constantes de puertos SSL
# ------------------------------------------------------------
$Script:SSL_PUERTO_HTTPS_APACHE = 9443   # Apache HTTPS (IIS ocupa 443 via http.sys)
$Script:SSL_PUERTO_HTTPS_ALT    = 8443   # Nginx HTTPS
$Script:SSL_PUERTO_HTTPS_TOMCAT = 8444   # Tomcat HTTPS
$Script:SSL_PUERTO_HTTPS_IIS    = 443    # IIS HTTPS (http.sys, siempre 443)

# ------------------------------------------------------------
# Rutas dinamicas de configuracion de servicios
# ------------------------------------------------------------

function ssl_conf_apache {
    $candidatos = @(
        "$env:APPDATA\Apache24\conf\httpd.conf",
        "C:\tools\httpd\conf\httpd.conf",
        "C:\Apache24\conf\httpd.conf",
        "$env:SystemDrive\Apache24\conf\httpd.conf"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { return $c }
    }
    # Busqueda en AppData y C:\tools
    foreach ($base in @("$env:APPDATA", "C:\tools")) {
        $found = Get-ChildItem $base -Filter "httpd.conf" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return "$env:APPDATA\Apache24\conf\httpd.conf"
}

function ssl_conf_apache_ssl {
    $apacheConf = ssl_conf_apache
    $dir = Split-Path $apacheConf
    return (Join-Path $dir "ssl_reprobados.conf")
}

function ssl_conf_nginx {
    $candidatos = @(
        "C:\tools\nginx\conf\nginx.conf",
        "C:\nginx\conf\nginx.conf",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx\conf\nginx.conf",
        "$env:ChocolateyInstall\lib\nginx\tools\nginx\conf\nginx.conf"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { return $c }
    }
    # Busqueda recursiva en rutas comunes
    foreach ($base in @("C:\tools", "C:\nginx", "$env:ChocolateyInstall\lib")) {
        if (Test-Path $base) {
            $found = Get-ChildItem $base -Filter "nginx.conf" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return "C:\tools\nginx\conf\nginx.conf"
}

function ssl_conf_nginx_ssl {
    $nginxConf = ssl_conf_nginx
    $dir = Split-Path $nginxConf
    return (Join-Path $dir "conf.d\ssl_reprobados.conf")
}

function ssl_conf_tomcat {
    $candidatos = @(
        "C:\ProgramData\Tomcat9\conf\server.xml",
        "C:\tools\tomcat9\conf\server.xml",
        "C:\Program Files\Apache Software Foundation\Tomcat 9.0\conf\server.xml",
        "C:\Program Files\Apache Software Foundation\Tomcat 10.0\conf\server.xml"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { return $c }
    }
    foreach ($base in @("C:\ProgramData","C:\tools","C:\Program Files\Apache Software Foundation")) {
        $found = Get-ChildItem $base -Filter "server.xml" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return "C:\ProgramData\Tomcat9\conf\server.xml"
}

function ssl_keystore_tomcat {
    $serverXml = ssl_conf_tomcat
    return (Join-Path (Split-Path $serverXml) "reprobados.p12")
}

# ------------------------------------------------------------
# Helpers de output
# ------------------------------------------------------------

function aputs_info    { param([string]$m); Write-Host "  [INFO]    $m" }
function aputs_success { param([string]$m); Write-Host "  [OK]      $m" -ForegroundColor Green }
function aputs_warning { param([string]$m); Write-Host "  [AVISO]   $m" -ForegroundColor Yellow }
function aputs_error   { param([string]$m); Write-Host "  [ERROR]   $m" -ForegroundColor Red }
function draw_line     { Write-Host "  ----------------------------------------------------------" }

function pause {
    Write-Host ""
    Read-Host "  Presione Enter para continuar..." | Out-Null
}

# ------------------------------------------------------------
# Helpers de estado
# ------------------------------------------------------------

function ssl_cert_existe {
    # Acepta PFX (para IIS) o el par crt+key (para Apache/Nginx)
    return ((Test-Path $Script:SSL_PFX) -or
            ((Test-Path $Script:SSL_CERT) -and (Test-Path $Script:SSL_KEY)))
}

function ssl_nombre_winsvc {
    param([string]$Servicio)
    switch -Regex ($Servicio.ToLower()) {
        'httpd|apache2?' {
            $svc = Get-Service -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Apache' } | Select-Object -First 1
            if ($svc) { return $svc.Name }
            return "Apache2.4"
        }
        'nginx'          { return "nginx" }
        'tomcat' {
            $svc = Get-Service -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Tomcat' } | Select-Object -First 1
            if ($svc) { return $svc.Name }
            return "Tomcat9"
        }
        'iis|w3svc' { return "W3SVC" }
        default     { return $Servicio }
    }
}

function ssl_nginx_reiniciar {
    # Nginx en Windows no es un servicio -- se maneja como proceso
    $nginxConf = ssl_conf_nginx
    $nginxDir  = if ($nginxConf) { Split-Path (Split-Path $nginxConf) } else { $null }
    if (-not $nginxDir) {
        foreach ($base in @("C:\tools\nginx","C:\nginx","$env:ChocolateyInstall\lib\nginx\tools\nginx")) {
            if (Test-Path "$base\nginx.exe") { $nginxDir = $base; break }
        }
    }
    if (-not $nginxDir -or -not (Test-Path "$nginxDir\nginx.exe")) {
        aputs_error "nginx.exe no encontrado"
        return $false
    }
    $nginxExe = "$nginxDir\nginx.exe"
    # Asegurar directorios requeridos por nginx
    foreach ($sub in @("logs", "temp")) {
        New-Item -ItemType Directory -Path "$nginxDir\$sub" -Force -ErrorAction SilentlyContinue | Out-Null
    }

    Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $nginxExe -WorkingDirectory $nginxDir -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $running = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
    if ($running) {
        aputs_success "nginx iniciado (PID: $($running[0].Id))"
        return $true
    }

    # Diagnostico: test de configuracion usando -p para fijar el prefix
    $test = & $nginxExe -p $nginxDir -t 2>&1
    aputs_error "nginx no pudo iniciarse -- test config:"
    $test | ForEach-Object { Write-Host "    $_" }
    return $false
}

function ssl_servicio_instalado {
    param([string]$Servicio)
    # Nginx no es un servicio Windows -- detectar por exe
    if ($Servicio -match 'nginx') {
        $nginxConf = ssl_conf_nginx
        if ($nginxConf -and (Test-Path $nginxConf)) { return $true }
        foreach ($d in @("C:\tools\nginx","C:\nginx")) {
            if (Test-Path "$d\nginx.exe") { return $true }
        }
        return $false
    }
    $winsvc = ssl_nombre_winsvc $Servicio
    $svc = Get-Service -Name $winsvc -ErrorAction SilentlyContinue
    return ($null -ne $svc)
}

function ssl_servicio_activo {
    param([string]$Servicio)
    $winsvc = ssl_nombre_winsvc $Servicio
    $svc = Get-Service -Name $winsvc -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

function ssl_puerto_https {
    param([int]$HttpPort)
    switch ($HttpPort) {
        80      { return 443  }
        8080    { return 8443 }
        default { return ($HttpPort + 363) }
    }
}

function ssl_leer_puerto_http {
    param([string]$Servicio)
    switch -Regex ($Servicio.ToLower()) {
        'httpd|apache' {
            $conf = ssl_conf_apache
            if (Test-Path $conf) {
                $linea = Select-String -Path $conf -Pattern "^Listen\s+\d+" |
                    Select-Object -First 1
                if ($linea) { return ($linea.Line -replace '.*Listen\s+', '').Trim() }
            }
            return "80"
        }
        'nginx' {
            $conf = ssl_conf_nginx
            if (Test-Path $conf) {
                $linea = Select-String -Path $conf -Pattern "^\s+listen\s+\d+" |
                    Where-Object { $_.Line -notmatch 'ssl' } | Select-Object -First 1
                if ($linea -and $linea.Line -match '(\d+)') { return $Matches[1] }
            }
            return "80"
        }
        'tomcat' {
            $conf = ssl_conf_tomcat
            if (Test-Path $conf) {
                [xml]$xml = Get-Content $conf -ErrorAction SilentlyContinue
                $conn = $xml.Server.Service.Connector |
                    Where-Object { $_.protocol -match 'HTTP' } | Select-Object -First 1
                if ($conn) { return $conn.port }
            }
            return "8080"
        }
        default { return "80" }
    }
}

function ssl_leer_puerto_https {
    param([string]$Servicio)
    switch -Regex ($Servicio.ToLower()) {
        'httpd|apache' {
            $conf = ssl_conf_apache_ssl
            if (Test-Path $conf) {
                $linea = Select-String -Path $conf -Pattern "^Listen\s+\d+" |
                    Select-Object -First 1
                if ($linea) { return ($linea.Line -replace '.*Listen\s+', '').Trim() }
            }
        }
        'nginx' {
            $conf = ssl_conf_nginx_ssl
            if (-not (Test-Path $conf)) { $conf = ssl_conf_nginx }
            if (Test-Path $conf) {
                $linea = Select-String -Path $conf -Pattern "^\s+listen\s+\d+\s+ssl" |
                    Select-Object -First 1
                if ($linea -and $linea.Line -match '(\d+)') { return $Matches[1] }
            }
        }
        'tomcat' {
            $conf = ssl_conf_tomcat
            if (Test-Path $conf) {
                [xml]$xml = Get-Content $conf -ErrorAction SilentlyContinue
                $conn = $xml.Server.Service.Connector |
                    Where-Object { $_.SSLEnabled -eq "true" } | Select-Object -First 1
                if ($conn) { return $conn.port }
            }
        }
    }
    return ssl_puerto_https ([int](ssl_leer_puerto_http $Servicio))
}

function ssl_mostrar_banner {
    param([string]$Titulo = "SSL/TLS")
    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    $Titulo"
    Write-Host "  =========================================================="
    Write-Host ""
}

function ssl_verificar_prereqs {
    $faltantes = 0
    aputs_info "Verificando herramientas SSL..."
    Write-Host ""

    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        $ver = (& openssl version 2>$null)
        Write-Host ("  [OK]  openssl    -- {0}" -f $ver)
    } else {
        Write-Host "  [NO]  openssl    -- NO encontrado" -ForegroundColor Red
        aputs_info "        Instalar con: choco install openssl -y"
        $faltantes++
    }

    if (Get-Command keytool -ErrorAction SilentlyContinue) {
        Write-Host "  [OK]  keytool    -- disponible (JDK presente)"
    } else {
        Write-Host "  [--]  keytool    -- no encontrado (necesario para Tomcat SSL)"
        aputs_info "        Instalar con: choco install openjdk -y"
    }

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Write-Host "  [OK]  curl       -- disponible"
    } else {
        Write-Host "  [NO]  curl       -- NO encontrado" -ForegroundColor Red
        $faltantes++
    }

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "  [OK]  chocolatey -- disponible"
    } else {
        Write-Host "  [--]  chocolatey -- no encontrado" -ForegroundColor Yellow
        aputs_info "        Instalar desde: https://chocolatey.org/install"
        $faltantes++
    }

    Write-Host ""
    if ($faltantes -gt 0) {
        aputs_error "$faltantes herramienta(s) critica(s) faltante(s)"
        return $false
    }
    aputs_success "Herramientas SSL verificadas"
    return $true
}

function ssl_abrir_puerto_firewall {
    param([int]$Puerto)
    $ruleName = "SSL_P7_puerto_$Puerto"
    $existe = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existe) {
        try {
            New-NetFirewallRule -DisplayName $ruleName `
                -Direction Inbound -Protocol TCP `
                -LocalPort $Puerto -Action Allow -ErrorAction Stop | Out-Null
            aputs_success "Puerto ${Puerto}/tcp abierto en Windows Firewall"
        } catch {
            aputs_warning "No se pudo abrir puerto $Puerto en Firewall: $_"
        }
    } else {
        aputs_info "Regla de firewall para puerto $Puerto ya existe"
    }
}

function ssl_hacer_backup {
    param([string]$Archivo)
    if (-not (Test-Path $Archivo)) { return }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $backup = "${Archivo}.bak_ssl_${ts}"
    Copy-Item -Path $Archivo -Destination $backup -Force
    aputs_success "Backup: $backup"
}

function ssl_importar_cert_store {
    # Importa el PFX al almacen de certificados de la maquina local
    # Retorna el thumbprint del certificado importado
    if (-not (Test-Path $Script:SSL_PFX)) {
        aputs_error "PFX no encontrado: $Script:SSL_PFX"
        return $null
    }
    $pass = ConvertTo-SecureString $Script:SSL_PFX_PASS -AsPlainText -Force
    try {
        $cert = Import-PfxCertificate -FilePath $Script:SSL_PFX `
            -CertStoreLocation "Cert:\LocalMachine\My" -Password $pass -ErrorAction Stop
        aputs_success "Certificado importado al store (Thumbprint: $($cert.Thumbprint))"
        return $cert.Thumbprint
    } catch {
        aputs_error "No se pudo importar el certificado al store: $_"
        return $null
    }
}
