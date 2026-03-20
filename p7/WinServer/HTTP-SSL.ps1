# HTTP-SSL.ps1 -- Configuracion de SSL/HTTPS para Apache, Nginx y Tomcat (Windows)

if ($Script:_HTTP_SSL_LOADED) { return }
$Script:_HTTP_SSL_LOADED = $true

# ------------------------------------------------------------
# Apache SSL (Windows)
# ------------------------------------------------------------

function _ssl_apache_aplicar {
    aputs_info "Configurando SSL en Apache (httpd)..."

    $httpConf = ssl_conf_apache
    if (-not (Test-Path $httpConf)) {
        aputs_error "httpd.conf no encontrado: $httpConf"
        return $false
    }

    # Verificar que mod_ssl este disponible
    $apacheDir  = Split-Path (Split-Path $httpConf)
    $modSslPath = Join-Path $apacheDir "modules\mod_ssl.so"
    if (-not (Test-Path $modSslPath)) {
        aputs_warning "mod_ssl.so no encontrado en $apacheDir\modules\"
        aputs_info    "Verifique que Apache este instalado con soporte SSL"
    }

    $sslConf = ssl_conf_apache_ssl
    ssl_hacer_backup $sslConf

    $httpPort  = [int](ssl_leer_puerto_http "apache")
    $httpsPort = $Script:SSL_PUERTO_HTTPS_APACHE
    $serverIp  = $Script:SSL_FTP_IP

    # Verificar que LoadModule ssl_module este habilitado en httpd.conf
    $confContent = Get-Content $httpConf -Raw
    if ($confContent -notmatch 'LoadModule ssl_module') {
        aputs_warning "LoadModule ssl_module no esta habilitado en httpd.conf"
        aputs_info    "Descomente: LoadModule ssl_module modules/mod_ssl.so"
    }

    # Asegurar que el modulo socache_shmcb este habilitado (requerido por ssl)
    if ($confContent -match '#\s*LoadModule socache_shmcb_module') {
        $confContent = $confContent -replace '#(\s*LoadModule socache_shmcb_module)', '$1'
        aputs_success "socache_shmcb_module habilitado en httpd.conf"
    }

    # Comentar httpd-ssl.conf si esta activo -- define Listen 443 que conflicta con http.sys de IIS
    if ($confContent -match '(?m)^Include conf/extra/httpd-ssl\.conf') {
        $confContent = $confContent -replace '(?m)^(Include conf/extra/httpd-ssl\.conf)', '# $1  # desactivado por P7 (IIS ocupa 443)'
        aputs_info "httpd-ssl.conf desactivado (IIS retiene el puerto 443)"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($httpConf, $confContent, $utf8NoBom)

    # Rutas con barras hacia adelante (Apache en Windows requiere /)
    $sslCertFwd   = $Script:SSL_CERT -replace '\\', '/'
    $sslKeyFwd    = $Script:SSL_KEY  -replace '\\', '/'
    $apacheDirFwd = $apacheDir       -replace '\\', '/'

    $sslConfContent = @"
# === Practica7 SSL Apache (Windows) ===
Listen $httpsPort

<VirtualHost *:${httpPort}>
    ServerName $serverIp
    ServerAlias $Script:SSL_DOMAIN
    Redirect permanent / https://${serverIp}:${httpsPort}/
</VirtualHost>

<VirtualHost *:${httpsPort}>
    ServerName $serverIp
    ServerAlias $Script:SSL_DOMAIN
    DocumentRoot "$apacheDirFwd/htdocs"

    SSLEngine on
    SSLCertificateFile    "$sslCertFwd"
    SSLCertificateKeyFile "$sslKeyFwd"

    SSLProtocol all -SSLv2 -SSLv3
    SSLCipherSuite HIGH:!aNULL:!MD5

    <Directory "$apacheDirFwd/htdocs">
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog  logs/ssl_error.log
    CustomLog logs/ssl_access.log combined
</VirtualHost>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($sslConf, $sslConfContent, $utf8NoBom)
    aputs_success "Configuracion SSL escrita en $sslConf"

    # Asegurar que ssl.conf este incluido en httpd.conf
    $confContent = Get-Content $httpConf -Raw
    $sslConfRelativo = Split-Path $sslConf -Leaf
    # Asegurar que el Include este activo (puede estar comentado de ejecuciones anteriores)
    $confContent = Get-Content $httpConf -Raw
    if ($confContent -match '(?m)^#\s*(Include conf/ssl_reprobados\.conf)') {
        $confContent = $confContent -replace '(?m)^#\s*(Include conf/ssl_reprobados\.conf)', '$1'
        [System.IO.File]::WriteAllText($httpConf, $confContent, $utf8NoBom)
        aputs_success "Include ssl_reprobados.conf reactivado en httpd.conf"
    } elseif ($confContent -notmatch 'Include conf/ssl_reprobados\.conf') {
        Add-Content -Path $httpConf -Value "`nInclude conf/ssl_reprobados.conf"
        aputs_success "Include ssl_reprobados.conf agregado a httpd.conf"
    } else {
        aputs_info "Include para ssl_reprobados.conf ya existe en httpd.conf"
    }

    ssl_abrir_puerto_firewall $httpsPort

    # Generar index.html personalizado para Apache
    $apacheVerRaw  = & "$apacheDir\bin\httpd.exe" -v 2>&1 | Select-String 'Apache/' | Select-Object -First 1
    $apacheVersion = if ($apacheVerRaw -match 'Apache/([^\s]+)') { $Matches[1] } else { "2.4" }
    _generar_index_html -NginxDir $apacheDir -Puerto $httpPort -Version $apacheVersion `
        -Servidor "Apache httpd" -Webroot "$apacheDir\htdocs"

    # Reiniciar Apache
    $winsvc = ssl_nombre_winsvc "apache"
    try {
        Restart-Service -Name $winsvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name $winsvc
        if ($svc.Status -eq "Running") {
            aputs_success "Apache reiniciado con SSL en puerto $httpsPort"
        } else {
            aputs_error "Apache no esta activo despues del reinicio"
            return $false
        }
    } catch {
        aputs_error "Error al reiniciar Apache: $_"
        return $false
    }
    return $true
}

# ------------------------------------------------------------
# Generar index.html personalizado
# ------------------------------------------------------------

function _generar_index_html {
    param([string]$NginxDir, [string]$Puerto, [string]$Version, [string]$Servidor = "nginx", [string]$Webroot = "")

    if (-not $Webroot) { $Webroot = "$NginxDir\html" }
    $outFile  = "$Webroot\index.html"
    New-Item -ItemType Directory -Path $Webroot -Force -ErrorAction SilentlyContinue | Out-Null

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>nginx</title>
  <style>
    body { background:#0d0d0d; color:#00e5ff; font-family:monospace;
           display:flex; justify-content:center; align-items:center; height:100vh; margin:0; }
    .box { border:2px solid #00e5ff; padding:40px 60px; text-align:center; }
    h1   { margin-bottom:24px; font-size:1.6em; }
    p    { margin:6px 0; font-size:1em; }
    span { color:#ffffff; }
  </style>
</head>
<body>
  <div class="box">
    <h1>Servidor HTTP - Windows</h1>
    <p>Servidor desplegado exitosamente</p>
    <p>Servidor : <span>$Servidor</span></p>
    <p>Version  : <span>$Version</span></p>
    <p>Puerto   : <span>$Puerto</span></p>
    <p>Webroot  : <span>$webroot</span></p>
    <p>Usuario  : <span>$env:USERNAME</span></p>
  </div>
</body>
</html>
"@
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($outFile, $html, $utf8NoBom)
    aputs_success "index.html generado en $outFile"
}

function _generar_index_jsp {
    param([string]$Webroot, [string]$Puerto, [string]$Version)

    New-Item -ItemType Directory -Path $Webroot -Force -ErrorAction SilentlyContinue | Out-Null
    # Usar HTML puro -- evita el compilador JSP de Tomcat
    Remove-Item "$Webroot\index.jsp" -Force -ErrorAction SilentlyContinue
    $outFile = "$Webroot\index.html"

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>tomcat</title>
  <style>
    body { background:#0d0d0d; color:#00e5ff; font-family:monospace;
           display:flex; justify-content:center; align-items:center; height:100vh; margin:0; }
    .box { border:2px solid #00e5ff; padding:40px 60px; text-align:center; }
    h1   { margin-bottom:24px; font-size:1.6em; }
    p    { margin:6px 0; font-size:1em; }
    span { color:#ffffff; }
  </style>
</head>
<body>
  <div class="box">
    <h1>Servidor HTTP - Windows</h1>
    <p>Servidor desplegado exitosamente</p>
    <p>Servidor : <span>Apache Tomcat</span></p>
    <p>Version  : <span>$Version</span></p>
    <p>Puerto   : <span>$Puerto</span></p>
    <p>Webroot  : <span>$Webroot</span></p>
    <p>Usuario  : <span>SERVICIO LOCAL</span></p>
  </div>
</body>
</html>
"@
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($outFile, $html, $utf8NoBom)
    aputs_success "index.html generado en $outFile"
}

# ------------------------------------------------------------
# Nginx SSL (Windows)
# ------------------------------------------------------------

function _ssl_nginx_aplicar {
    aputs_info "Configurando SSL en Nginx..."

    $nginxConf = ssl_conf_nginx
    if (-not (Test-Path $nginxConf)) {
        aputs_error "nginx.conf no encontrado: $nginxConf"
        return $false
    }

    $httpPort  = [int](ssl_leer_puerto_http "nginx")
    $httpsPort = $Script:SSL_PUERTO_HTTPS_ALT
    $serverIp  = $Script:SSL_FTP_IP

    # Rutas con barras hacia adelante (Nginx en Windows requiere /)
    $sslCertFwd = $Script:SSL_CERT -replace '\\', '/'
    $sslKeyFwd  = $Script:SSL_KEY  -replace '\\', '/'

    # Crear directorio conf.d si no existe
    $confDir = Join-Path (Split-Path $nginxConf) "conf.d"
    if (-not (Test-Path $confDir)) {
        New-Item -ItemType Directory -Path $confDir -Force | Out-Null
    }

    # Asegurar que nginx.conf incluya conf.d
    $nginxContent = Get-Content $nginxConf -Raw
    if ($nginxContent -notmatch 'conf\.d/') {
        # Insertar include dentro del bloque http
        $nginxContent = $nginxContent -replace '(http\s*\{)', "`$1`n    include conf.d/*.conf;"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($nginxConf, $nginxContent, $utf8NoBom)
        aputs_success "include conf.d/*.conf; agregado a nginx.conf"
    }

    $sslConf = ssl_conf_nginx_ssl
    ssl_hacer_backup $sslConf

    $sslConfContent = @"
# === Practica7 SSL Nginx (Windows) ===
server {
    listen $httpPort;
    server_name $serverIp $Script:SSL_DOMAIN;
    return 301 https://${serverIp}:${httpsPort}`$request_uri;
}

server {
    listen $httpsPort ssl;
    server_name $serverIp $Script:SSL_DOMAIN;

    ssl_certificate     "$sslCertFwd";
    ssl_certificate_key "$sslKeyFwd";
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    root  html;
    index index.html;

    access_log logs/ssl_access.log;
    error_log  logs/ssl_error.log;
}
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($sslConf, $sslConfContent, $utf8NoBom)
    aputs_success "Configuracion SSL escrita en $sslConf"

    ssl_abrir_puerto_firewall $httpsPort

    # Generar index.html personalizado
    $nginxDir = Split-Path (Split-Path $nginxConf)
    $verRaw   = & "$nginxDir\nginx.exe" -v 2>&1 | Select-String 'nginx/' | Select-Object -First 1
    $version  = if ($verRaw -match 'nginx/(.+)') { $Matches[1] } else { "?" }
    _generar_index_html -NginxDir $nginxDir -Puerto $httpPort -Version $version

    # Reiniciar Nginx (corre como proceso, no como servicio Windows)
    if (ssl_nginx_reiniciar) {
        aputs_success "Nginx reiniciado con SSL en puerto $httpsPort"
    } else {
        aputs_error "Nginx no pudo reiniciarse -- revise la configuracion"
        return $false
    }
    return $true
}

# ------------------------------------------------------------
# Tomcat SSL (Windows)
# ------------------------------------------------------------

function _ssl_tomcat_aplicar {
    aputs_info "Configurando SSL en Tomcat..."

    $serverXml = ssl_conf_tomcat
    $keystore  = ssl_keystore_tomcat

    if (-not (Test-Path $serverXml)) {
        aputs_error "server.xml no encontrado: $serverXml"
        return $false
    }

    # Verificar keytool -- buscar en rutas conocidas de JDK antes de instalar
    $keytoolExe = $null
    if (Get-Command keytool -ErrorAction SilentlyContinue) {
        $keytoolExe = "keytool"
    } else {
        $jdkBases = @(
            "C:\Program Files\Eclipse Adoptium",
            "C:\Program Files\Java",
            "C:\Program Files\OpenJDK",
            "C:\Program Files\Microsoft",
            "$env:ProgramFiles\Eclipse Adoptium"
        )
        foreach ($base in $jdkBases) {
            if (Test-Path $base) {
                $found = Get-ChildItem $base -Filter "keytool.exe" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { $keytoolExe = $found.FullName; break }
            }
        }
        if ($keytoolExe) {
            aputs_info "keytool encontrado: $keytoolExe"
            # Agregar su directorio al PATH de sesion
            $env:Path = (Split-Path $keytoolExe) + ";" + $env:Path
        } else {
            aputs_info "keytool no encontrado -- actualizando PATH y buscando de nuevo..."
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
            if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
                aputs_error "keytool no disponible -- instale JDK (choco install temurin17)"
                return $false
            }
            $keytoolExe = "keytool"
        }
    }

    $httpsPort = $Script:SSL_PUERTO_HTTPS_TOMCAT

    # Buscar openssl.exe
    $opensslExe = $null
    foreach ($p in @(
        "C:\Program Files\OpenSSL\bin\openssl.exe",
        "C:\Program Files\Git\mingw64\bin\openssl.exe",
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
    )) {
        if (Test-Path $p) { $opensslExe = $p; break }
    }
    if (-not $opensslExe) {
        $found = Get-Command openssl -ErrorAction SilentlyContinue
        if ($found) { $opensslExe = $found.Source }
    }
    if (-not $opensslExe) {
        aputs_error "openssl.exe no encontrado -- no se puede generar keystore"
        return $false
    }

    # Generar keystore PKCS12
    aputs_info "Generando keystore PKCS12 para Tomcat..."
    $pfxArgs = @(
        "pkcs12", "-export",
        "-in",      $Script:SSL_CERT,
        "-inkey",   $Script:SSL_KEY,
        "-out",     $keystore,
        "-name",    "reprobados",
        "-passout", "pass:$Script:SSL_PFX_PASS"
    )
    & $opensslExe @pfxArgs 2>$null
    if ($LASTEXITCODE -eq 0) {
        aputs_success "Keystore generado: $keystore"
    } else {
        aputs_error "Error al generar keystore PKCS12"
        return $false
    }

    ssl_hacer_backup $serverXml

    # Insertar Connector SSL en server.xml via manipulacion XML
    try {
        $xmlContent = Get-Content $serverXml -Raw -Encoding UTF8

        if ($xmlContent -notmatch "Practica7 SSL") {
            $keystoreFwd = $keystore -replace '\\', '/'
            $connectorXml = @"

    <!-- Practica7 SSL Tomcat (Windows) -->
    <Connector port="$httpsPort" protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150" SSLEnabled="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="$keystoreFwd"
                         certificateKeystorePassword="$Script:SSL_PFX_PASS"
                         certificateKeystoreType="PKCS12" />
        </SSLHostConfig>
    </Connector>
"@
            $xmlContent = $xmlContent -replace '</Service>', ($connectorXml + "`n    </Service>")
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($serverXml, $xmlContent, $utf8NoBom)
            aputs_success "Connector SSL agregado a server.xml (puerto $httpsPort)"
        } else {
            aputs_info "Connector SSL ya existe en server.xml"
        }
    } catch {
        aputs_error "Error al modificar server.xml: $_"
        return $false
    }

    ssl_abrir_puerto_firewall $httpsPort

    # Generar index.jsp personalizado
    $tomcatWebroot = Join-Path (Split-Path $serverXml) "..\webapps\ROOT"
    $tomcatWebroot = [System.IO.Path]::GetFullPath($tomcatWebroot)
    $httpPortTomcat = ssl_leer_puerto_http "tomcat"
    _generar_index_jsp -Webroot $tomcatWebroot -Puerto $httpPortTomcat -Version "9.0.115"

    # Reiniciar Tomcat
    $winsvc = ssl_nombre_winsvc "tomcat"
    try {
        Restart-Service -Name $winsvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name $winsvc
        if ($svc.Status -eq "Running") {
            aputs_success "Tomcat reiniciado con SSL en puerto $httpsPort"
        } else {
            aputs_error "Tomcat no esta activo despues del reinicio"
            return $false
        }
    } catch {
        aputs_error "Error al reiniciar Tomcat: $_"
        return $false
    }
    return $true
}

# ------------------------------------------------------------
# IIS HTTPS (Windows nativo)
# ------------------------------------------------------------

function _ssl_iis_aplicar {
    aputs_info "Configurando SSL/HTTPS en IIS..."

    $iisWinsvc = "W3SVC"
    if (-not (Get-Service -Name $iisWinsvc -ErrorAction SilentlyContinue)) {
        aputs_warning "IIS (W3SVC) no esta instalado -- omitiendo"
        return $false
    }

    # Importar certificado al store
    $thumbprint = ssl_importar_cert_store
    if (-not $thumbprint) {
        aputs_error "No se pudo importar el certificado para IIS"
        return $false
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop

        # Agregar binding HTTPS al Default Web Site
        $sitio = "Default Web Site"
        $httpsPort = $Script:SSL_PUERTO_HTTPS_IIS

        # Eliminar binding HTTPS existente si lo hay en el mismo puerto
        Get-WebBinding -Name $sitio -Protocol "https" -Port $httpsPort -ErrorAction SilentlyContinue |
            Remove-WebBinding -ErrorAction SilentlyContinue

        New-WebBinding -Name $sitio -Protocol "https" -Port $httpsPort -IPAddress "*" | Out-Null

        # Asignar certificado al binding
        $bindPath = "IIS:\SslBindings\0.0.0.0!$httpsPort"
        if (Test-Path $bindPath) { Remove-Item $bindPath -Force }

        $cert = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Thumbprint -eq $thumbprint }
        $cert | New-Item $bindPath | Out-Null

        aputs_success "HTTPS configurado en IIS puerto $httpsPort"
    } catch {
        aputs_error "Error al configurar HTTPS en IIS: $_"
        return $false
    }

    ssl_abrir_puerto_firewall $Script:SSL_PUERTO_HTTPS_APACHE

    try {
        Restart-Service -Name $iisWinsvc -Force -ErrorAction Stop
        aputs_success "IIS reiniciado con HTTPS activo"
    } catch {
        aputs_error "Error al reiniciar IIS: $_"
    }
    return $true
}

# ------------------------------------------------------------
# Aplicar SSL a todos los servicios HTTP instalados
# ------------------------------------------------------------

function ssl_http_aplicar_todos {
    $aplicado = 0

    if (ssl_servicio_instalado "apache") {
        Write-Host ""
        draw_line
        if (_ssl_apache_aplicar) { $aplicado++ }
    }

    if (ssl_servicio_instalado "nginx") {
        Write-Host ""
        draw_line
        if (_ssl_nginx_aplicar) { $aplicado++ }
    }

    if (ssl_servicio_instalado "tomcat") {
        Write-Host ""
        draw_line
        if (_ssl_tomcat_aplicar) { $aplicado++ }
    }

    if (ssl_servicio_instalado "iis") {
        Write-Host ""
        draw_line
        if (_ssl_iis_aplicar) { $aplicado++ }
    }

    Write-Host ""
    draw_line
    Write-Host ""

    if ($aplicado -eq 0) {
        aputs_warning "No se aplico SSL a ningun servicio"
    } else {
        aputs_success "SSL aplicado a $aplicado servicio(s)"
    }
}
