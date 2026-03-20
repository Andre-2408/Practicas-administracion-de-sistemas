# reporHTTP.ps1 -- Gestion del repositorio de paquetes HTTP (Windows / Chocolatey)

if ($Script:_REPO_HTTP_LOADED) { return }
$Script:_REPO_HTTP_LOADED = $true

# ------------------------------------------------------------
# Crear estructura del repositorio
# ------------------------------------------------------------

function ssl_repo_crear_estructura {
    aputs_info "Creando estructura de directorios del repositorio..."
    Write-Host ""

    $dirs = @(
        $Script:SSL_REPO_APACHE,
        $Script:SSL_REPO_NGINX,
        $Script:SSL_REPO_TOMCAT,
        $Script:SSL_REPO_IIS
    )

    foreach ($dir in $dirs) {
        if (New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue) {
            aputs_success "Creado: $dir"
        } else {
            aputs_error "No se pudo crear: $dir"
            return $false
        }
    }

    # Permisos NTFS para el usuario FTP
    foreach ($dir in @($Script:SSL_REPO_ROOT, $Script:SSL_FTP_CHROOT)) {
        if (Test-Path $dir) {
            try {
                & icacls $dir /grant "IIS_IUSRS:(OI)(CI)(RX)" /T /C /Q 2>$null | Out-Null
                & icacls $dir /grant "${env:COMPUTERNAME}\$Script:SSL_FTP_USER:(OI)(CI)(RX)" /T /C /Q 2>$null | Out-Null
            } catch { }
        }
    }

    Write-Host ""
    aputs_success "Estructura del repositorio creada en $Script:SSL_REPO_ROOT"
    Write-Host ("  {0,-14} {1}" -f "Chroot:",  $Script:SSL_FTP_CHROOT)
    Write-Host ("  {0,-14} {1}" -f "Repo:",    $Script:SSL_REPO_ROOT)
    Write-Host ("  {0,-14} {1}" -f "Apache:",  $Script:SSL_REPO_APACHE)
    Write-Host ("  {0,-14} {1}" -f "Nginx:",   $Script:SSL_REPO_NGINX)
    Write-Host ("  {0,-14} {1}" -f "Tomcat:",  $Script:SSL_REPO_TOMCAT)
    Write-Host ("  {0,-14} {1}" -f "IIS:",     $Script:SSL_REPO_IIS)
    Write-Host ""
    aputs_info "Acceso FTP:  ftp://$Script:SSL_FTP_IP  usuario: $Script:SSL_FTP_USER"
    aputs_info "Navegar a:   /repositorio/http/Windows/{Apache,Nginx,Tomcat,IIS}"
    Write-Host ""
    return $true
}

# ------------------------------------------------------------
# Listar contenido del repositorio
# ------------------------------------------------------------

function ssl_repo_listar {
    Write-Host ""
    aputs_info "Contenido actual del repositorio:"
    Write-Host ""

    $total = 0
    foreach ($subdir in @("Apache", "Nginx", "Tomcat")) {
        $dir = Join-Path $Script:SSL_REPO_WINDOWS $subdir
        $cnt = 0
        if (Test-Path $dir) {
            $cnt = (Get-ChildItem $dir -Recurse -Include "*.nupkg", "*.zip" `
                -ErrorAction SilentlyContinue | Measure-Object).Count
        }
        Write-Host ("  {0,-10} {1} paquete(s)" -f "${subdir}:", $cnt)

        # Mostrar versiones descargadas
        if ((Test-Path $dir) -and $cnt -gt 0) {
            Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
                $vcnt = (Get-ChildItem $_.FullName -Recurse -Include "*.nupkg", "*.zip" `
                    -ErrorAction SilentlyContinue | Measure-Object).Count
                Write-Host ("             {0,-14} {1} paquete(s)" -f "$($_.Name):", $vcnt)
            }
        }
        $total += $cnt
    }

    # IIS: caracteristica de Windows, no paquete
    $iisInstalado = (Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue).Installed
    $iisEstado = if ($iisInstalado) { "instalado" } else { "no instalado" }
    Write-Host ("  {0,-10} [{1}] (caracteristica Windows)" -f "IIS:", $iisEstado)

    Write-Host ""
    Write-Host ("  {0,-10} {1} paquete(s) en total" -f "Total:", $total)
    Write-Host ""
    Write-Host ("  {0,-14} ftp://{1}  usuario: {2}" -f "Acceso FTP:", $Script:SSL_FTP_IP, $Script:SSL_FTP_USER)
    Write-Host ("  {0,-14} /repositorio/http/Windows/{{Apache,Nginx,Tomcat,IIS}}/{{version}}/" -f "Ruta FTP:")
    Write-Host ""
}

# ------------------------------------------------------------
# Consultar versiones disponibles en Chocolatey
# ------------------------------------------------------------

function _repo_ordenar_versiones {
    param([string[]]$Versiones)
    return $Versiones | Sort-Object {
        $partes = $_ -split '\.' | ForEach-Object {
            $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
        }
        while ($partes.Count -lt 4) { $partes = @($partes) + @(0) }
        '{0:D5}{1:D5}{2:D5}{3:D5}' -f $partes[0], $partes[1], $partes[2], $partes[3]
    }
}

function _repo_listar_versiones_choco {
    param([string]$Paquete)

    # Intentar con choco CLI si esta disponible
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $salidaRaw = choco search $Paquete --exact --all-versions --limit-output 2>$null
        $versiones = $salidaRaw |
            Where-Object { $_ -match "^${Paquete}\|" } |
            ForEach-Object { ($_ -split '\|')[1] }
        if ($versiones.Count -gt 0) {
            return @(_repo_ordenar_versiones $versiones)
        }
    }

    # Fallback: consultar API de Chocolatey directamente via HTTP
    aputs_info "Consultando API de Chocolatey (sin CLI)..."
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $url  = "https://community.chocolatey.org/api/v2/FindPackagesById()?id='$Paquete'&`$top=50"
        $raw  = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop).Content

        # Extraer versiones con regex (evita problemas de namespaces XML)
        $versiones = [regex]::Matches($raw, '<d:Version[^>]*>([^<]+)</d:Version>') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -match '^\d+\.\d+' } |
            Select-Object -Unique

        if ($versiones.Count -gt 0) {
            return @(_repo_ordenar_versiones $versiones)
        }

        aputs_info "Respuesta API: $($raw.Length) bytes (0 versiones encontradas para '$Paquete')"
    } catch {
        aputs_error "No se pudo consultar la API de Chocolatey: $_"
    }

    return @()
}

# ------------------------------------------------------------
# Descargar una version especifica con Chocolatey
# ------------------------------------------------------------

function _repo_descargar_version {
    param([string]$Paquete, [string]$Version, [string]$Destdir)

    if (-not (New-Item -ItemType Directory -Path $Destdir -Force -ErrorAction SilentlyContinue)) {
        aputs_error "No se pudo crear directorio: $Destdir"
        return $false
    }

    aputs_info "Descargando ${Paquete} v${Version}..."

    # choco download descarga el nupkg sin instalarlo
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $result = choco download $Paquete --version=$Version `
            --output-directory="$Destdir" --no-progress 2>&1
        if ($LASTEXITCODE -eq 0) {
            $cnt = (Get-ChildItem $Destdir -Filter "*.nupkg" -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($cnt -gt 0) {
                aputs_success "$cnt nupkg(s) en $Destdir"
                # Generar SHA256SUMS
                _repo_generar_sha256 $Destdir
                return $true
            }
        }
    }

    # Alternativa: descargar el nupkg desde nuget.org via curl/Invoke-WebRequest
    aputs_info "Intentando descarga directa del nupkg..."
    $url = "https://community.chocolatey.org/api/v2/package/${Paquete}/${Version}"
    $destFile = Join-Path $Destdir "${Paquete}.${Version}.nupkg"
    try {
        Invoke-WebRequest -Uri $url -OutFile $destFile -UseBasicParsing -ErrorAction Stop
        aputs_success "nupkg descargado: $(Split-Path $destFile -Leaf)"
        _repo_generar_sha256 $Destdir
        return $true
    } catch {
        aputs_error "No se pudo descargar ${Paquete}-${Version}: $_"
        Remove-Item $Destdir -Force -Recurse -ErrorAction SilentlyContinue
        return $false
    }
}

function _repo_generar_sha256 {
    param([string]$Directorio)

    $sumsFile = Join-Path $Directorio "SHA256SUMS.txt"
    $sb = [System.Text.StringBuilder]::new()

    Get-ChildItem $Directorio -Include "*.nupkg", "*.zip" -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
            $sb.AppendLine("$hash  $($_.Name)") | Out-Null
        }

    [System.IO.File]::WriteAllText($sumsFile, $sb.ToString())
    aputs_success "SHA256SUMS.txt generado"
}

# ------------------------------------------------------------
# Menu IIS (caracteristica Windows -- no usa Chocolatey)
# ------------------------------------------------------------

function _repo_menu_iis {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Repositorio -- IIS"

        # Detectar version IIS disponible en el sistema
        $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -ErrorAction SilentlyContinue)
        $verStr = if ($iisVer) { "$($iisVer.MajorVersion).$($iisVer.MinorVersion)" } else {
            $osVer = [System.Environment]::OSVersion.Version
            if ($osVer.Major -ge 10) { "10.0" } else { "8.5" }
        }

        $instalado   = (Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue).Installed
        $estadoStr   = if ($instalado) { "[instalado]" } else { "[no instalado]" }
        $marcador    = Join-Path $Script:SSL_REPO_IIS "IIS-instalado.txt"
        $enRepo      = if (Test-Path $marcador) { "[en repositorio]" } else { "[no en repositorio]" }

        Write-Host ""
        Write-Host ("  {0,-22} {1}" -f "Version disponible:", "IIS $verStr (Windows Server)")
        Write-Host ("  {0,-22} {1}" -f "Estado:", $estadoStr)
        Write-Host ("  {0,-22} {1}" -f "Repositorio:", $enRepo)
        Write-Host ""

        # Modulos adicionales
        $modulos = @(
            @{ Feat = "Web-Ftp-Server";    Nombre = "FTP Server"        },
            @{ Feat = "Web-WebSockets";    Nombre = "WebSockets"        },
            @{ Feat = "Web-Asp-Net45";     Nombre = "ASP.NET 4.5"       },
            @{ Feat = "Web-Mgmt-Console";  Nombre = "Consola de gestion"},
            @{ Feat = "Web-Scripting-Tools"; Nombre = "Scripting Tools" }
        )

        Write-Host "  Modulos opcionales:"
        foreach ($mod in $modulos) {
            $est = (Get-WindowsFeature -Name $mod.Feat -ErrorAction SilentlyContinue).Installed
            $icono = if ($est) { "[X]" } else { "[ ]" }
            Write-Host ("    {0} {1}" -f $icono, $mod.Nombre)
        }
        Write-Host ""

        Write-Host "  1) Instalar IIS $verStr + modulos basicos"
        Write-Host "  2) Instalar IIS $verStr + TODOS los modulos"
        Write-Host "  3) Guardar marcador en repositorio"
        Write-Host "  0) Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Write-Host ""
                _repo_instalar_iis | Out-Null
                pause
            }
            "2" {
                Write-Host ""
                _repo_instalar_iis | Out-Null
                aputs_info "Instalando modulos adicionales..."
                $extras = @("Web-WebSockets","Web-Asp-Net45","Web-Scripting-Tools","Web-DAV-Publishing")
                $porInstalar = $extras | Where-Object {
                    -not (Get-WindowsFeature -Name $_ -ErrorAction SilentlyContinue).Installed
                }
                if ($porInstalar.Count -gt 0) {
                    Install-WindowsFeature -Name $porInstalar -ErrorAction SilentlyContinue | Out-Null
                    aputs_success "Modulos adicionales instalados"
                } else {
                    aputs_success "Todos los modulos ya estaban instalados"
                }
                pause
            }
            "3" {
                Write-Host ""
                New-Item -ItemType Directory -Path $Script:SSL_REPO_IIS -Force -ErrorAction SilentlyContinue | Out-Null
                [System.IO.File]::WriteAllText($marcador,
                    "IIS $verStr`r`nFecha: $(Get-Date)`r`nEstado: $estadoStr`r`n")
                aputs_success "Marcador guardado: $marcador"
                pause
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ------------------------------------------------------------
# Menu de seleccion de versiones para un servicio
# ------------------------------------------------------------

function _repo_menu_versiones {
    param(
        [string]$Nombre,   # Apache / Nginx / Tomcat
        [string]$Paquete,  # httpd / nginx / tomcat
        [string]$Basedir   # SSL_REPO_APACHE / etc.
    )

    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Repositorio -- $Nombre"

        aputs_info "Consultando versiones disponibles en Chocolatey..."
        Write-Host ""

        $versiones = _repo_listar_versiones_choco $Paquete

        if ($versiones.Count -eq 0) {
            aputs_error "No se encontraron versiones de $Paquete en Chocolatey"
            aputs_info  "Verifique: choco search $Paquete --exact --all-versions"
            pause
            return
        }

        Write-Host "  Versiones disponibles:"
        Write-Host ""
        $i = 1
        foreach ($v in $versiones) {
            $vdir = Join-Path $Basedir $v
            $estado = ""
            if ((Test-Path $vdir) -and
                (Get-ChildItem $vdir -Filter "*.nupkg" -ErrorAction SilentlyContinue)) {
                $estado = "  [descargada]"
            }
            Write-Host ("  {0,2}) {1}{2}" -f $i, $v, $estado)
            $i++
        }

        Write-Host ""
        Write-Host "  a) Descargar TODAS las versiones"
        Write-Host "  0) Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "0" { return }
            { $_ -match '^[aA]$' } {
                Write-Host ""
                foreach ($v in $versiones) {
                    $vdir = Join-Path $Basedir $v
                    draw_line
                    aputs_info "Version: $v"
                    _repo_descargar_version $Paquete $v $vdir | Out-Null
                    Write-Host ""
                }
                pause
            }
            default {
                $n = 0
                if ([int]::TryParse($op, [ref]$n) -and $n -ge 1 -and $n -le $versiones.Count) {
                    $versionSel = $versiones[$n - 1]
                    $vdir = Join-Path $Basedir $versionSel
                    Write-Host ""
                    draw_line
                    _repo_descargar_version $Paquete $versionSel $vdir | Out-Null
                    pause
                } else {
                    aputs_error "Opcion invalida"
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
}

# ------------------------------------------------------------
# Instalar IIS (caracteristica de Windows)
# ------------------------------------------------------------

function _repo_instalar_iis {
    aputs_info "Instalando IIS (caracteristica de Windows)..."
    Write-Host ""

    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service",
                  "Web-Mgmt-Tools", "Web-Mgmt-Console")

    $porInstalar = $features | Where-Object {
        $f = Get-WindowsFeature -Name $_ -ErrorAction SilentlyContinue
        $f -and -not $f.Installed
    }

    if ($porInstalar.Count -eq 0) {
        aputs_success "IIS ya estaba instalado"
    } else {
        try {
            Install-WindowsFeature -Name $porInstalar -IncludeManagementTools -ErrorAction Stop | Out-Null
            aputs_success "IIS instalado correctamente"
        } catch {
            aputs_error "Error instalando IIS: $_"
            return $false
        }
    }

    # Crear marcador en el repositorio
    New-Item -ItemType Directory -Path $Script:SSL_REPO_IIS -Force -ErrorAction SilentlyContinue | Out-Null
    $marcador = Join-Path $Script:SSL_REPO_IIS "IIS-instalado.txt"
    $version  = (Get-WindowsFeature -Name "Web-Server").Description
    [System.IO.File]::WriteAllText($marcador, "IIS instalado: $(Get-Date)`r`n$version`r`n")
    aputs_success "Marcador creado: $marcador"
    return $true
}

# ------------------------------------------------------------
# Descargar todos los servicios (version actual de cada uno)
# ------------------------------------------------------------

function ssl_repo_descargar_todos {
    Write-Host ""
    aputs_info "Descargando version actual de todos los servicios..."
    Write-Host ""

    $ok = 0; $fail = 0

    $servicios = @(
        @{ Pkg = "apache-httpd"; Nombre = "Apache"; Basedir = $Script:SSL_REPO_APACHE },
        @{ Pkg = "nginx";  Nombre = "Nginx";  Basedir = $Script:SSL_REPO_NGINX  },
        @{ Pkg = "tomcat"; Nombre = "Tomcat"; Basedir = $Script:SSL_REPO_TOMCAT },
        @{ Pkg = "iis";    Nombre = "IIS";    Basedir = $Script:SSL_REPO_IIS    }
    )

    foreach ($svc in $servicios) {
        draw_line
        aputs_info "Consultando version actual de $($svc.Nombre) ($($svc.Pkg))..."

        if ($svc.Pkg -eq "iis") {
            if (_repo_instalar_iis) { $ok++ } else { $fail++ }
            Write-Host ""
            continue
        }

        $versiones = _repo_listar_versiones_choco $svc.Pkg
        if ($versiones.Count -eq 0) {
            aputs_error "$($svc.Pkg) no encontrado en Chocolatey"
            $fail++
            Write-Host ""
            continue
        }

        $version = $versiones[-1]
        aputs_info "Version: $version"
        Write-Host ""

        $vdir = Join-Path $svc.Basedir $version
        if (_repo_descargar_version $svc.Pkg $version $vdir) {
            $ok++
        } else {
            $fail++
        }
        Write-Host ""
    }

    draw_line
    Write-Host ""
    aputs_success "Descarga completada: $ok exitosa(s), $fail fallida(s)"
}

# ------------------------------------------------------------
# Descargar paquete individual (wrapper para el menu principal)
# ------------------------------------------------------------

function ssl_repo_descargar_paquete {
    param([string]$NombreCorto)

    if ($NombreCorto -eq "iis") {
        _repo_instalar_iis | Out-Null
        return
    }

    $map = @{
        "apache-httpd" = @{ Nombre = "Apache"; Basedir = $Script:SSL_REPO_APACHE }
        "nginx"  = @{ Nombre = "Nginx";  Basedir = $Script:SSL_REPO_NGINX  }
        "tomcat" = @{ Nombre = "Tomcat"; Basedir = $Script:SSL_REPO_TOMCAT }
    }

    if (-not $map.ContainsKey($NombreCorto)) {
        aputs_error "Paquete desconocido: $NombreCorto"
        return
    }

    $info     = $map[$NombreCorto]
    $versiones = _repo_listar_versiones_choco $NombreCorto

    if ($versiones.Count -eq 0) {
        aputs_error "$NombreCorto no encontrado en Chocolatey"
        return
    }

    $version = $versiones[-1]
    $vdir    = Join-Path $info.Basedir $version
    aputs_info "Descargando $($info.Nombre) v$version..."
    _repo_descargar_version $NombreCorto $version $vdir | Out-Null
}

# ------------------------------------------------------------
# Verificar integridad SHA256
# ------------------------------------------------------------

function ssl_repo_verificar_integridad {
    Write-Host ""
    aputs_info "Verificando integridad SHA256 de los paquetes..."
    Write-Host ""

    $errores = 0

    foreach ($subdir in @("Apache", "Nginx", "Tomcat", "IIS")) {
        $base = Join-Path $Script:SSL_REPO_WINDOWS $subdir
        if (-not (Test-Path $base)) { continue }

        Write-Host "  ${subdir}:"

        $hayVersiones = $false
        Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            $hayVersiones = $true
            $version   = $_.Name
            $vdir      = $_.FullName
            $sumsFile  = Join-Path $vdir "SHA256SUMS.txt"

            Write-Host "    Version ${version}:"

            if (-not (Test-Path $sumsFile)) {
                Write-Host "      [--] Sin SHA256SUMS.txt"
                return
            }

            Get-Content $sumsFile | Where-Object { $_ -match '\S' } | ForEach-Object {
                $linea = $_.Trim()
                $partes = $linea -split '\s+', 2
                if ($partes.Count -lt 2) { return }
                $hashEsperado = $partes[0]
                $nombreArchivo = $partes[1].TrimStart('*')
                $rutaArchivo = Join-Path $vdir $nombreArchivo

                if (-not (Test-Path $rutaArchivo)) {
                    Write-Host "      [NO] $nombreArchivo -- no encontrado" -ForegroundColor Red
                    $errores++
                    return
                }

                $hashActual = (Get-FileHash $rutaArchivo -Algorithm SHA256).Hash
                if ($hashActual -eq $hashEsperado) {
                    Write-Host "      [OK] $nombreArchivo" -ForegroundColor Green
                } else {
                    Write-Host "      [NO] $nombreArchivo -- hash no coincide" -ForegroundColor Red
                    $errores++
                }
            }
        }

        if (-not $hayVersiones) {
            Write-Host "    [--] Sin versiones descargadas"
        }
        Write-Host ""
    }

    if ($errores -eq 0) {
        aputs_success "Todos los archivos son integros"
    } else {
        aputs_error "$errores archivo(s) con problemas de integridad"
    }
}

# ------------------------------------------------------------
# Menu del repositorio
# ------------------------------------------------------------

function ssl_menu_repo {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Menu -- Repositorio FTP (Windows)"
        ssl_repo_listar

        Write-Host "  1) Crear estructura de directorios"
        Write-Host "  2) Descargar/instalar todos (Apache + Nginx + Tomcat + IIS)"
        Write-Host "  3) Apache  -- seleccionar version"
        Write-Host "  4) Nginx   -- seleccionar version"
        Write-Host "  5) Tomcat  -- seleccionar version"
        Write-Host "  6) IIS     -- instalar caracteristica Windows"
        Write-Host "  7) Verificar integridad SHA256"
        Write-Host "  0) Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { Write-Host ""; ssl_repo_crear_estructura | Out-Null;                    pause }
            "2" { ssl_repo_descargar_todos;                                                pause }
            "3" { _repo_menu_versiones "Apache" "httpd"  $Script:SSL_REPO_APACHE }
            "4" { _repo_menu_versiones "Nginx"  "nginx"  $Script:SSL_REPO_NGINX  }
            "5" { _repo_menu_versiones "Tomcat" "tomcat" $Script:SSL_REPO_TOMCAT }
            "6" { _repo_menu_iis }
            "7" { ssl_repo_verificar_integridad;                                           pause }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}
