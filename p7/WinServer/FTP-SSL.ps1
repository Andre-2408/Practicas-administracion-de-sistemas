# FTP-SSL.ps1 -- Configuracion de FTPS/TLS en IIS FTP (Windows)

if ($Script:_FTP_SSL_LOADED) { return }
$Script:_FTP_SSL_LOADED = $true

# ------------------------------------------------------------
# Verificar que IIS FTP este instalado
# ------------------------------------------------------------

function _ftp_ssl_verificar_iis {
    $ftpSvc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if ($null -eq $ftpSvc) {
        aputs_error "IIS FTP (ftpsvc) no esta instalado"
        aputs_info  "Ejecute primero el Paso 1 -- Instalar FTP (Practica 5)"
        return $false
    }
    return $true
}

# ------------------------------------------------------------
# Obtener nombre del sitio FTP activo en IIS
# ------------------------------------------------------------

function _ftp_ssl_obtener_sitio {
    $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"

    # 1) Listar sitios con appcmd y buscar el que tenga binding ftp
    if (Test-Path $appcmd) {
        try {
            $salida = & $appcmd list site 2>$null
            foreach ($linea in $salida) {
                # formato: SITE "nombre" (id:X,bindings:ftp/*:21:,state:Started)
                if ($linea -match 'SITE "([^"]+)".*ftp/') {
                    return $matches[1]
                }
            }
        } catch { }
    }

    # 2) Buscar en applicationHost.config un sitio con binding ftp
    try {
        $appHost = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
        if (Test-Path $appHost) {
            $xml = [xml](Get-Content $appHost -Raw -ErrorAction Stop)
            $sitioFTP = $xml.configuration.'system.applicationHost'.sites.site |
                Where-Object {
                    $_.bindings.binding | Where-Object { $_.protocol -eq "ftp" }
                } | Select-Object -First 1
            if ($sitioFTP) { return $sitioFTP.name }
        }
    } catch { }

    # 3) Nombre por defecto usado en ftp-win.ps1
    return "FTP_Servidor"
}

# ------------------------------------------------------------
# Aplicar FTPS/TLS a IIS FTP
# ------------------------------------------------------------

function ssl_ftp_aplicar {
    aputs_info "Configurando FTPS/TLS en IIS FTP..."
    Write-Host ""

    if (-not (_ftp_ssl_verificar_iis)) { return $false }

    if (-not (ssl_cert_existe)) {
        aputs_error "No hay certificado SSL -- ejecute primero la gestion de certificados"
        return $false
    }

    # Importar certificado al store de Windows (necesario para IIS FTP)
    $thumbprint = ssl_importar_cert_store
    if (-not $thumbprint) {
        aputs_error "No se pudo importar el certificado al store de Windows"
        return $false
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
    } catch {
        aputs_error "No se pudo cargar el modulo WebAdministration"
        aputs_info  "Instale IIS con: Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole"
        return $false
    }

    $sitioNombre = _ftp_ssl_obtener_sitio
    aputs_info "Configurando SSL en sitio FTP: $sitioNombre"

    # Ruta de configuracion en applicationHost.config
    $cfgPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
    ssl_hacer_backup $cfgPath

    $appcmd  = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
    $aplicado = $false

    # Metodo 1: appcmd.exe (mas fiable que el provider IIS:\)
    if (Test-Path $appcmd) {
        try {
            & $appcmd set site /site.name:"$sitioNombre" `
                /ftpServer.security.ssl.serverCertHash:"$thumbprint" `
                /ftpServer.security.ssl.serverCertStoreName:"My" `
                /ftpServer.security.ssl.controlChannelPolicy:"SslRequire" `
                /ftpServer.security.ssl.dataChannelPolicy:"SslRequire" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                aputs_success "Politica SSL aplicada via appcmd: TLS requerido"
                $aplicado = $true
            }
        } catch { }
    }

    # Metodo 2: provider IIS:\ (WebAdministration)
    if (-not $aplicado) {
        try {
            Set-ItemProperty "IIS:\Sites\$sitioNombre" `
                -Name "ftpServer.security.ssl.serverCertHash" -Value $thumbprint -ErrorAction Stop
            Set-ItemProperty "IIS:\Sites\$sitioNombre" `
                -Name "ftpServer.security.ssl.serverCertStoreName" -Value "My" -ErrorAction Stop
            Set-ItemProperty "IIS:\Sites\$sitioNombre" `
                -Name "ftpServer.security.ssl.controlChannelPolicy" -Value 2 -ErrorAction Stop
            Set-ItemProperty "IIS:\Sites\$sitioNombre" `
                -Name "ftpServer.security.ssl.dataChannelPolicy" -Value 2 -ErrorAction Stop
            aputs_success "Politica SSL aplicada via WebAdministration"
            $aplicado = $true
        } catch {
            aputs_warning "WebAdministration: $_"
        }
    }

    # Metodo 3: editar applicationHost.config directamente
    if (-not $aplicado) {
        aputs_info "Intentando configuracion directa en applicationHost.config..."
        if (_ftp_ssl_editar_config $cfgPath $sitioNombre $thumbprint) {
            aputs_success "Configuracion aplicada via applicationHost.config"
            $aplicado = $true
        }
    }

    if (-not $aplicado) {
        aputs_error "No se pudo configurar SSL: el sitio FTP '$sitioNombre' no existe en IIS"
        aputs_info  "Sitios IIS disponibles:"
        if (Test-Path $appcmd) {
            & $appcmd list site 2>$null | ForEach-Object { Write-Host "    $_" }
        }
        aputs_info  "Ejecute el Paso 1 (ftp-win.ps1) y complete la opcion 3-Configurar FTP"
        return $false
    }

    # Abrir puerto 21 en firewall
    ssl_abrir_puerto_firewall 21

    # Reiniciar servicio FTP
    try {
        Restart-Service -Name "ftpsvc" -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name "ftpsvc"
        if ($svc.Status -eq "Running") {
            aputs_success "IIS FTP reiniciado con FTPS/TLS activo"
        } else {
            aputs_error "El servicio FTP no esta activo despues del reinicio"
            return $false
        }
    } catch {
        aputs_error "Error al reiniciar IIS FTP: $_"
        return $false
    }

    Write-Host ""
    draw_line
    Write-Host ""
    aputs_success "FTPS/TLS configurado correctamente"
    Write-Host ("  {0,-22} {1}" -f "Puerto:",      "21 (TLS explicito - AUTH TLS)")
    Write-Host ("  {0,-22} {1}" -f "Certificado:", $Script:SSL_CERT)
    Write-Host ("  {0,-22} {1}" -f "Thumbprint:",  $thumbprint)
    Write-Host ("  {0,-22} {1}" -f "Sitio FTP:",   $sitioNombre)
    Write-Host ""
    return $true
}

# ------------------------------------------------------------
# Editar applicationHost.config directamente
# ------------------------------------------------------------

function _ftp_ssl_editar_config {
    param([string]$CfgPath, [string]$SitioNombre, [string]$Thumbprint)

    try {
        [xml]$cfg = Get-Content $CfgPath -Encoding UTF8

        $sitio = $cfg.configuration.'system.applicationHost'.sites.site |
            Where-Object { $_.name -eq $SitioNombre } | Select-Object -First 1

        if (-not $sitio) {
            aputs_error "Sitio FTP '$SitioNombre' no encontrado en applicationHost.config"
            return $false
        }

        # Buscar o crear nodo ftpServer/security/ssl
        $ftpServer = $sitio.ftpServer
        if (-not $ftpServer) {
            $ftpServer = $cfg.CreateElement("ftpServer")
            $sitio.AppendChild($ftpServer) | Out-Null
        }

        $security = $ftpServer.security
        if (-not $security) {
            $security = $cfg.CreateElement("security")
            $ftpServer.AppendChild($security) | Out-Null
        }

        $ssl = $security.ssl
        if (-not $ssl) {
            $ssl = $cfg.CreateElement("ssl")
            $security.AppendChild($ssl) | Out-Null
        }

        $ssl.SetAttribute("serverCertHash",       $Thumbprint)
        $ssl.SetAttribute("serverCertStoreName",  "My")
        $ssl.SetAttribute("controlChannelPolicy", "SslRequire")
        $ssl.SetAttribute("dataChannelPolicy",    "SslRequire")

        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($CfgPath, $cfg.OuterXml, $utf8NoBom)
        return $true
    } catch {
        aputs_error "Error al editar applicationHost.config: $_"
        return $false
    }
}
