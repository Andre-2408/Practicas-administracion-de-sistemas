# certSSL.ps1 -- Gestion de certificados SSL autofirmados (Windows)

if ($Script:_CERT_SSL_LOADED) { return }
$Script:_CERT_SSL_LOADED = $true

# ------------------------------------------------------------
# Generar certificado autofirmado
# ------------------------------------------------------------

function ssl_cert_generar {
    aputs_info "Generando certificado SSL autofirmado..."
    Write-Host ""

    # Crear directorio SSL
    if (-not (Test-Path $Script:SSL_DIR)) {
        New-Item -ItemType Directory -Path $Script:SSL_DIR -Force | Out-Null
        aputs_success "Directorio creado: $Script:SSL_DIR"
    }

    # Generar con New-SelfSignedCertificate (nativo Windows, no requiere openssl)
    try {
        $cert = New-SelfSignedCertificate `
            -DnsName        $Script:SSL_DOMAIN `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -KeyLength      $Script:SSL_KEY_BITS `
            -KeyAlgorithm   RSA `
            -HashAlgorithm  SHA256 `
            -NotAfter       (Get-Date).AddDays($Script:SSL_DAYS) `
            -FriendlyName   "Practica7 SSL" `
            -KeyExportPolicy Exportable `
            -Provider       "Microsoft Enhanced RSA and AES Cryptographic Provider"
        aputs_success "Certificado generado en el store de Windows"
    } catch {
        aputs_error "Error al generar certificado: $_"
        return $false
    }

    # Exportar PFX
    try {
        $pass = ConvertTo-SecureString $Script:SSL_PFX_PASS -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $Script:SSL_PFX -Password $pass | Out-Null
        aputs_success "Archivo PFX exportado: $Script:SSL_PFX"
    } catch {
        aputs_error "Error al exportar PFX: $_"
        return $false
    }

    # Exportar CRT (certificado publico en PEM)
    try {
        $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $b64 = [Convert]::ToBase64String($certBytes, [Base64FormattingOptions]::InsertLineBreaks)
        Set-Content -Path $Script:SSL_CERT -Value "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----"
        aputs_success "Certificado PEM exportado: $Script:SSL_CERT"
    } catch {
        aputs_warning "No se pudo exportar CRT PEM: $_"
    }

    # Exportar clave privada desde PFX
    try {
        $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $Script:SSL_PFX, $Script:SSL_PFX_PASS,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($pfxCert)

        $keyBytes = $null; $pemHeader = ""
        try {
            # Metodo 1: legacy CSP (RSACryptoServiceProvider)
            $keyBytes  = $rsa.ExportRSAPrivateKey()
            $pemHeader = "RSA PRIVATE KEY"
        } catch {
            # Metodo 2: CNG key (RSACng) -- exportar como PKCS#8
            if ($rsa -is [System.Security.Cryptography.RSACng]) {
                $keyBytes  = $rsa.Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
                $pemHeader = "PRIVATE KEY"
            }
        }

        if ($keyBytes) {
            $b64key = [Convert]::ToBase64String($keyBytes, [Base64FormattingOptions]::InsertLineBreaks)
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Script:SSL_KEY,
                "-----BEGIN $pemHeader-----`n$b64key`n-----END $pemHeader-----", $utf8NoBom)
            aputs_success "Clave privada PEM exportada: $Script:SSL_KEY"
        } else {
            throw "No se pudo obtener bytes de la clave"
        }
    } catch {
        # Fallback: usar OpenSSL si esta disponible
        $opensslExe = Get-ChildItem "C:\Program Files\OpenSSL\bin","C:\Program Files\Git\mingw64\bin" `
            -Filter "openssl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($opensslExe) {
            & $opensslExe pkcs12 -in $Script:SSL_PFX -nocerts -nodes `
                -out $Script:SSL_KEY -passin "pass:$Script:SSL_PFX_PASS" 2>$null
            if (Test-Path $Script:SSL_KEY) {
                aputs_success "Clave privada exportada via OpenSSL: $Script:SSL_KEY"
            } else {
                aputs_warning "No se pudo exportar clave privada PEM"
            }
        } else {
            aputs_warning "No se pudo exportar clave privada PEM (sin OpenSSL disponible)"
        }
    }

    Write-Host ""
    aputs_success "Certificado generado exitosamente"
    Write-Host ""
    Write-Host ("  {0,-20} {1}" -f "Certificado:", $Script:SSL_CERT)
    Write-Host ("  {0,-20} {1}" -f "Clave privada:", $Script:SSL_KEY)
    Write-Host ("  {0,-20} {1}" -f "PFX (Windows):", $Script:SSL_PFX)
    Write-Host ("  {0,-20} {1}" -f "Dominio:", $Script:SSL_DOMAIN)
    Write-Host ("  {0,-20} {1} dias" -f "Vigencia:", $Script:SSL_DAYS)
    Write-Host ""
    return $true
}

# ------------------------------------------------------------
# Mostrar informacion del certificado
# ------------------------------------------------------------

function ssl_cert_mostrar_info {
    if (-not (ssl_cert_existe)) {
        aputs_warning "No hay certificado en $Script:SSL_DIR"
        return $false
    }

    Write-Host ""
    Write-Host ("  {0,-20} {1}" -f "Archivo:", $Script:SSL_CERT)

    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        $subject   = & openssl x509 -noout -subject   -in $Script:SSL_CERT 2>$null
        $notBefore = & openssl x509 -noout -startdate -in $Script:SSL_CERT 2>$null
        $notAfter  = & openssl x509 -noout -enddate   -in $Script:SSL_CERT 2>$null

        $subject   = $subject   -replace "subject=", "" -replace "subject= ", ""
        $notBefore = $notBefore -replace "notBefore=", ""
        $notAfter  = $notAfter  -replace "notAfter=",  ""

        Write-Host ("  {0,-20} {1}" -f "Subject:",      $subject)
        Write-Host ("  {0,-20} {1}" -f "Valido desde:", $notBefore)
        Write-Host ("  {0,-20} {1}" -f "Valido hasta:", $notAfter)
    } else {
        # Alternativa via .NET
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Script:SSL_CERT)
            Write-Host ("  {0,-20} {1}" -f "Subject:",      $cert.Subject)
            Write-Host ("  {0,-20} {1}" -f "Valido desde:", $cert.NotBefore)
            Write-Host ("  {0,-20} {1}" -f "Valido hasta:", $cert.NotAfter)
        } catch {
            aputs_warning "No se pudo leer la informacion del certificado"
        }
    }
    Write-Host ""
    return $true
}

# ------------------------------------------------------------
# Menu de gestion de certificado
# ------------------------------------------------------------

function ssl_menu_cert {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Gestion de Certificado SSL"

        if (ssl_cert_existe) {
            aputs_success "Certificado instalado en $Script:SSL_DIR"
            ssl_cert_mostrar_info
        } else {
            aputs_warning "No hay certificado generado aun"
            Write-Host ""
        }

        Write-Host "  1) Generar nuevo certificado autofirmado"
        Write-Host "  2) Ver informacion del certificado"
        Write-Host "  3) Verificar herramientas SSL"
        Write-Host "  4) Importar certificado al store de Windows"
        Write-Host "  5) Eliminar certificado actual"
        Write-Host "  0) Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" {
                Write-Host ""
                if (ssl_cert_existe) {
                    $conf = Read-Host "  Ya existe un certificado. Sobreescribir? [s/N]"
                    if ($conf -notmatch '^[sS]$') { pause; continue }
                }
                ssl_cert_generar | Out-Null
                pause
            }
            "2" {
                Write-Host ""
                ssl_cert_mostrar_info
                pause
            }
            "3" {
                Write-Host ""
                ssl_verificar_prereqs | Out-Null
                pause
            }
            "4" {
                Write-Host ""
                if (-not (ssl_cert_existe)) {
                    aputs_warning "No hay certificado. Genere uno primero."
                } else {
                    ssl_importar_cert_store | Out-Null
                }
                pause
            }
            "5" {
                Write-Host ""
                if (ssl_cert_existe) {
                    $conf = Read-Host "  Confirmar eliminacion del certificado? [s/N]"
                    if ($conf -match '^[sS]$') {
                        Remove-Item -Path $Script:SSL_CERT, $Script:SSL_KEY -Force -ErrorAction SilentlyContinue
                        if (Test-Path $Script:SSL_PFX) {
                            Remove-Item -Path $Script:SSL_PFX -Force -ErrorAction SilentlyContinue
                        }
                        aputs_success "Certificado eliminado"
                    } else {
                        aputs_info "Operacion cancelada"
                    }
                } else {
                    aputs_warning "No hay certificado que eliminar"
                }
                pause
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}
