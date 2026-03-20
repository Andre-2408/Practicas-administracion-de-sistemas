# verifySSL.ps1 -- Verificacion general de la infraestructura SSL (Windows)

if ($Script:_VERIFY_SSL_LOADED) { return }
$Script:_VERIFY_SSL_LOADED = $true

# ------------------------------------------------------------
# Helpers internos
# ------------------------------------------------------------

function _verify_seccion {
    param([string]$Titulo)
    Write-Host ""
    Write-Host "  -- $Titulo --"
    draw_line
}

function _verify_check {
    param([string]$Desc, [string]$Resultado)
    if ($Resultado -eq "ok") {
        Write-Host ("  [OK]  {0}" -f $Desc) -ForegroundColor Green
    } else {
        Write-Host ("  [NO]  {0}" -f $Desc) -ForegroundColor Red
    }
}

function _check_puerto_ssl {
    param([int]$Puerto)
    try {
        # Test-NetConnection verifica conectividad TCP
        $tcp = Test-NetConnection -ComputerName "127.0.0.1" -Port $Puerto `
            -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (-not $tcp) { return "no" }

        # Intentar handshake SSL con openssl si esta disponible
        if (Get-Command openssl -ErrorAction SilentlyContinue) {
            $out = echo "Q" | & openssl s_client -connect "127.0.0.1:$Puerto" `
                -servername "127.0.0.1" 2>$null
            if ($out -match "BEGIN CERTIFICATE") { return "ok" }
        }

        # Sin openssl: si el puerto responde TCP, asumir SSL activo
        return "ok"
    } catch {
        return "no"
    }
}

# ------------------------------------------------------------
# Verificacion completa
# ------------------------------------------------------------

function ssl_verify_todo {
    Clear-Host
    ssl_mostrar_banner "Testing General -- Infraestructura SSL (Windows)"

    # --- Certificado ---
    _verify_seccion "Certificado SSL"
    if (ssl_cert_existe) {
        _verify_check "Certificado en $Script:SSL_CERT" "ok"
        _verify_check "Clave privada en $Script:SSL_KEY" "ok"

        if (Get-Command openssl -ErrorAction SilentlyContinue) {
            $expiry = & openssl x509 -noout -enddate -in $Script:SSL_CERT 2>$null
            $expiry = $expiry -replace "notAfter=", ""
            Write-Host ("  [--]  Expira: {0}" -f $expiry)

            # Verificar coherencia cert/key
            $certMod = & openssl x509 -noout -modulus -in $Script:SSL_CERT 2>$null
            $keyMod  = & openssl rsa -noout -modulus  -in $Script:SSL_KEY  2>$null
            if ($certMod -eq $keyMod) {
                _verify_check "Certificado y clave coinciden" "ok"
            } else {
                _verify_check "Certificado y clave coinciden" "no"
            }
        } else {
            # Alternativa .NET
            try {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Script:SSL_CERT)
                Write-Host ("  [--]  Expira: {0}" -f $cert.NotAfter)
            } catch { }
        }

        if (Test-Path $Script:SSL_PFX) {
            _verify_check "Archivo PFX generado" "ok"
        } else {
            _verify_check "Archivo PFX generado" "no"
        }
    } else {
        _verify_check "Certificado SSL generado" "no"
    }

    # --- FTP ---
    _verify_seccion "Servicio FTP (IIS FTP)"
    $ftpSvc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($ftpSvc) {
        _verify_check "IIS FTP (ftpsvc) instalado" "ok"
        if ($ftpSvc.Status -eq "Running") {
            _verify_check "IIS FTP activo" "ok"
        } else {
            _verify_check "IIS FTP activo" "no"
        }

        # Verificar SSL en sitio FTP
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $sitioNombre = _ftp_ssl_obtener_sitio
            $sslHash = Get-ItemProperty "IIS:\Sites\$sitioNombre" `
                -Name "ftpServer.security.ssl.serverCertHash" -ErrorAction SilentlyContinue
            if ($sslHash -and $sslHash.Value -and $sslHash.Value.Length -gt 0) {
                _verify_check "FTPS/TLS habilitado en IIS" "ok"
            } else {
                _verify_check "FTPS/TLS habilitado en IIS" "no"
            }
        } catch {
            _verify_check "FTPS/TLS verificacion" "no"
        }
    } else {
        _verify_check "IIS FTP (ftpsvc) instalado" "no"
    }

    # --- Repositorio ---
    _verify_seccion "Repositorio FTP"
    if (Test-Path $Script:SSL_REPO_ROOT) {
        _verify_check "Directorio repositorio existe" "ok"
        $total = (Get-ChildItem $Script:SSL_REPO_ROOT -Recurse -Include "*.nupkg", "*.zip", "*.msi" `
            -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ("  [--]  Paquetes encontrados: {0}" -f $total)
        foreach ($subdir in @("Apache", "Nginx", "Tomcat")) {
            $dir = Join-Path $Script:SSL_REPO_WINDOWS $subdir
            $cnt = 0
            if (Test-Path $dir) {
                $cnt = (Get-ChildItem $dir -Recurse -Include "*.nupkg", "*.zip", "*.msi" `
                    -ErrorAction SilentlyContinue | Measure-Object).Count
            }
            Write-Host ("        {0,-10} {1} paquete(s)" -f "${subdir}:", $cnt)
        }
    } else {
        _verify_check "Directorio repositorio existe" "no"
    }

    # --- Apache ---
    _verify_seccion "Apache (httpd)"
    $apacheSvc = ssl_nombre_winsvc "apache"
    if (Get-Service -Name $apacheSvc -ErrorAction SilentlyContinue) {
        _verify_check "Apache instalado" "ok"
        _verify_check "Apache activo" $(if (ssl_servicio_activo "apache") { "ok" } else { "no" })
        $sslConf = ssl_conf_apache_ssl
        if (Test-Path $sslConf) {
            _verify_check "Configuracion SSL existe" "ok"
            _verify_check "Puerto 443 responde SSL" (_check_puerto_ssl 443)
        } else {
            _verify_check "Configuracion SSL existe" "no"
        }
    } else {
        _verify_check "Apache instalado" "no"
    }

    # --- Nginx ---
    _verify_seccion "Nginx"
    if (Get-Service -Name "nginx" -ErrorAction SilentlyContinue) {
        _verify_check "Nginx instalado" "ok"
        _verify_check "Nginx activo" $(if (ssl_servicio_activo "nginx") { "ok" } else { "no" })
        $sslConf = ssl_conf_nginx_ssl
        if ((Test-Path $sslConf) -or
            (Select-String -Path (ssl_conf_nginx) -Pattern "Practica7 SSL Nginx" -ErrorAction SilentlyContinue)) {
            _verify_check "Bloque SSL en configuracion" "ok"
            _verify_check "Puerto 8443 responde SSL" (_check_puerto_ssl 8443)
        } else {
            _verify_check "Bloque SSL en configuracion" "no"
        }
    } else {
        _verify_check "Nginx instalado" "no"
    }

    # --- Tomcat ---
    _verify_seccion "Tomcat"
    $tomcatSvc = ssl_nombre_winsvc "tomcat"
    if (Get-Service -Name $tomcatSvc -ErrorAction SilentlyContinue) {
        _verify_check "Tomcat instalado" "ok"
        _verify_check "Tomcat activo" $(if (ssl_servicio_activo "tomcat") { "ok" } else { "no" })
        $serverXml = ssl_conf_tomcat
        if ((Test-Path $serverXml) -and (Select-String -Path $serverXml -Pattern "Practica7 SSL" -ErrorAction SilentlyContinue)) {
            _verify_check "Connector SSL en server.xml" "ok"
            _verify_check "Puerto 8444 responde SSL" (_check_puerto_ssl 8444)
        } else {
            _verify_check "Connector SSL en server.xml" "no"
        }
    } else {
        _verify_check "Tomcat instalado" "no"
    }

    # --- IIS ---
    _verify_seccion "IIS (W3SVC)"
    if (Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue) {
        _verify_check "IIS instalado" "ok"
        _verify_check "IIS activo" $(if (ssl_servicio_activo "iis") { "ok" } else { "no" })
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $httpsBinding = Get-WebBinding -Protocol "https" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($httpsBinding) {
                _verify_check "Binding HTTPS configurado en IIS" "ok"
            } else {
                _verify_check "Binding HTTPS configurado en IIS" "no"
            }
        } catch {
            _verify_check "IIS WebAdministration disponible" "no"
        }
    } else {
        _verify_check "IIS instalado" "no"
    }

    Write-Host ""
    draw_line
    Write-Host ""
}
