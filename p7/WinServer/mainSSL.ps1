#Requires -RunAsAdministrator
#
# mainSSL.ps1 -- Orquestador principal Practica 7 (Windows Server)
#

$ErrorActionPreference = "Stop"

$Script:SSL_SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:P5_DIR = Join-Path $Script:SSL_SCRIPT_DIR "..\P5"
$Script:P6_DIR = Join-Path $Script:SSL_SCRIPT_DIR "..\P6"
$Script:P5_DIR = [System.IO.Path]::GetFullPath($Script:P5_DIR)
$Script:P6_DIR = [System.IO.Path]::GetFullPath($Script:P6_DIR)

# ------------------------------------------------------------
# Verificar privilegios de administrador
# ------------------------------------------------------------

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$esAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    Write-Host ""
    Write-Host "  [ERROR] Este script requiere privilegios de Administrador."
    Write-Host "  Ejecute PowerShell como Administrador y vuelva a lanzar:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Write-Host ""
    exit 1
}

# ------------------------------------------------------------
# Verificar estructura de archivos
# ------------------------------------------------------------

function _verificar_estructura {
    $errores = 0

    foreach ($dir in @($Script:P5_DIR, $Script:P6_DIR, $Script:SSL_SCRIPT_DIR)) {
        if (-not (Test-Path $dir)) {
            Write-Host "  [ERROR] Directorio no encontrado: $dir"
            $errores++
        }
    }

    $archivosReq = @(
        (Join-Path $Script:P5_DIR "ftp-win.ps1"),
        (Join-Path $Script:P6_DIR "Start-HTTPManager.ps1"),
        (Join-Path $Script:SSL_SCRIPT_DIR "utils.SSL.ps1")
    )

    foreach ($archivo in $archivosReq) {
        if (-not (Test-Path $archivo)) {
            Write-Host "  [ERROR] Archivo no encontrado: $archivo"
            $errores++
        }
    }

    $archivosSSL = @(
        "certSSL.ps1", "FTP-SSL.ps1", "HTTP-SSL.ps1",
        "verifySSL.ps1", "reporHTTP.ps1", "installFTP.ps1"
    )

    foreach ($mod in $archivosSSL) {
        $ruta = Join-Path $Script:SSL_SCRIPT_DIR $mod
        if (-not (Test-Path $ruta)) {
            Write-Host "  [AVISO] Modulo SSL no encontrado: $ruta"
        }
    }

    if ($errores -gt 0) {
        Write-Host ""
        Write-Host "  Verifique que las Practicas 5, 6 y 7 estan en:"
        Write-Host "  ..\P5\  ..\P6\  ..\P7\"
        Write-Host ""
        exit 1
    }
}

# ------------------------------------------------------------
# Cargar modulos
# ------------------------------------------------------------

function _cargar_modulos {
    . (Join-Path $Script:SSL_SCRIPT_DIR "utils.SSL.ps1")

    $modulosSSL = @(
        "certSSL.ps1", "FTP-SSL.ps1", "HTTP-SSL.ps1",
        "verifySSL.ps1", "reporHTTP.ps1", "installFTP.ps1"
    )

    foreach ($mod in $modulosSSL) {
        $ruta = Join-Path $Script:SSL_SCRIPT_DIR $mod
        if (Test-Path $ruta) { . $ruta }
    }
}

# ------------------------------------------------------------
# Indicadores de estado
# ------------------------------------------------------------

function _icono_estado {
    param([bool]$Condicion)
    if ($Condicion) { return "[*]" } else { return "[ ]" }
}

function _estado_ftp {
    $svc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq "Running")
}

function _estado_ftps {
    # Lee applicationHost.config directamente (sin Import-Module WebAdministration)
    try {
        $appHost = "$env:SystemRoot\system32\inetsrv\config\applicationHost.config"
        if (-not (Test-Path $appHost)) { return $false }
        $contenido = Get-Content $appHost -Raw -ErrorAction Stop
        return ($contenido -match 'serverCertHash="[A-Fa-f0-9]{10}')
    } catch { return $false }
}

function _estado_repo {
    if (-not (Test-Path $Script:SSL_REPO_ROOT)) { return $false }
    $cnt = (Get-ChildItem $Script:SSL_REPO_ROOT -Recurse -Include "*.nupkg", "*.zip" `
        -ErrorAction SilentlyContinue | Measure-Object).Count
    return ($cnt -gt 0)
}

function _estado_http {
    return ((ssl_servicio_instalado "apache") -or
            (ssl_servicio_instalado "nginx")  -or
            (ssl_servicio_instalado "tomcat") -or
            (ssl_servicio_instalado "iis"))
}

function _estado_ssl_http {
    # Solo comprueba existencia de archivos SSL (sin leer contenido)
    return ((Test-Path (ssl_conf_apache_ssl)) -or
            (Test-Path (ssl_conf_nginx_ssl))  -or
            (Test-Path (ssl_conf_tomcat)))
}

# ------------------------------------------------------------
# Pasos del menu
# ------------------------------------------------------------

function _paso_1_ftp {
    Clear-Host
    ssl_mostrar_banner "Paso 1 -- Instalar y configurar FTP"

    aputs_info "Se redirigira al script de instalacion FTP (Practica 5):"
    Write-Host "    $Script:P5_DIR\ftp-win.ps1"
    Write-Host ""
    pause

    $ftpScript = Join-Path $Script:P5_DIR "ftp-win.ps1"
    if (Test-Path $ftpScript) {
        & $ftpScript
    } else {
        aputs_error "ftp-win.ps1 no encontrado en $Script:P5_DIR"
        pause
    }
}

function _paso_2_ftps {
    Clear-Host
    ssl_mostrar_banner "Paso 2 -- Configurar FTPS/TLS (opcional)"

    $ftpSvc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if (-not $ftpSvc) {
        aputs_error "IIS FTP no esta instalado"
        aputs_info  "Ejecute primero el Paso 1 -- Instalar FTP"
        pause
        return
    }

    Write-Host ""
    Write-Host "  Este paso configurara:"
    Write-Host "    - Certificado SSL autofirmado (si no existe)"
    Write-Host "    - TLS explicito en IIS FTP (puerto 21)"
    Write-Host ""
    $resp = Read-Host "  Desea aplicar FTPS/TLS a IIS FTP? [S/n]"
    if ($resp -match '^[nN]$') {
        aputs_info "FTPS omitido -- puede configurarlo despues desde el menu"
        pause
        return
    }

    Write-Host ""

    if (-not (ssl_cert_existe)) {
        aputs_info "El certificado no existe -- generando..."
        Write-Host ""
        if (-not (ssl_cert_generar)) { pause; return }
        Write-Host ""
    } else {
        aputs_info "Certificado ya existe -- reutilizando"
        ssl_cert_mostrar_info | Out-Null
        Write-Host ""
    }

    ssl_ftp_aplicar | Out-Null
    pause
}

function _paso_3_repo_estructura {
    Clear-Host
    ssl_mostrar_banner "Paso 3 -- Repositorio FTP + usuario 'repo'"

    $ftpSvc = Get-Service -Name "ftpsvc" -ErrorAction SilentlyContinue
    if (-not $ftpSvc) {
        aputs_error "IIS FTP no esta instalado"
        aputs_info  "Ejecute primero el Paso 1 -- Instalar FTP"
        pause
        return
    }

    aputs_info "Creando estructura del repositorio FTP..."
    Write-Host ""
    if (-not (ssl_repo_crear_estructura)) { pause; return }

    Write-Host ""
    draw_line
    Write-Host ""

    aputs_info "Configurando usuario dedicado '$Script:SSL_FTP_USER'..."
    Write-Host ""

    $repoUser   = $Script:SSL_FTP_USER
    $repoChroot = $Script:SSL_FTP_CHROOT
    $repoReal   = $Script:SSL_REPO_ROOT

    # Crear usuario local si no existe
    $userObj = Get-LocalUser -Name $repoUser -ErrorAction SilentlyContinue
    if ($userObj) {
        aputs_info "El usuario '$repoUser' ya existe"
    } else {
        aputs_info "Creando usuario '$repoUser'..."
        $pass = Read-Host "  Contrasena para '$repoUser' (Enter = Reprobados1!)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
        $passStr = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        if ([string]::IsNullOrEmpty($passStr)) { $passStr = "Reprobados1!" }
        $securePwd = ConvertTo-SecureString $passStr -AsPlainText -Force
        New-LocalUser -Name $repoUser -Password $securePwd -PasswordNeverExpires | Out-Null
        aputs_success "Usuario '$repoUser' creado"
    }

    # Crear directorio chroot y junction
    if (-not (Test-Path $repoChroot)) {
        New-Item -ItemType Directory -Path $repoChroot -Force | Out-Null
        aputs_success "Directorio chroot: $repoChroot"
    }

    # Junction (equivalente al bind mount de Linux)
    $repoSubdir = Join-Path $repoChroot "repositorio"
    if (-not (Test-Path $repoSubdir)) {
        cmd /c "mklink /J `"$repoSubdir`" `"$repoReal`"" | Out-Null
        aputs_success "Junction creado: $repoSubdir -> $repoReal"
    } else {
        aputs_info "Junction ya existe: $repoSubdir"
    }

    # Configurar sitio FTP en IIS con aislamiento de usuarios
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $sitioNombre = _ftp_ssl_obtener_sitio

        # Ruta virtual para el usuario (IIS FTP user isolation: LocalUser\<usuario>)
        $vdirPath = "IIS:\Sites\$sitioNombre\LocalUser\$repoUser"
        if (-not (Test-Path $vdirPath)) {
            New-Item $vdirPath -physicalPath $repoChroot -Type VirtualDirectory | Out-Null
            aputs_success "Directorio virtual FTP creado para '$repoUser'"
        } else {
            aputs_info "Directorio virtual FTP para '$repoUser' ya existe"
        }
    } catch {
        aputs_warning "No se pudo crear directorio virtual FTP: $_"
    }

    # Permisos NTFS
    & icacls $repoChroot /grant:r "${env:COMPUTERNAME}\${repoUser}:(OI)(CI)(RX)" /T /C /Q 2>$null | Out-Null
    aputs_success "Permisos NTFS aplicados a $repoChroot"

    Write-Host ""
    draw_line
    Write-Host ""
    aputs_success "Paso 3 completado"
    Write-Host ("  {0,-22} {1}" -f "Usuario FTP:",    $repoUser)
    Write-Host ("  {0,-22} {1}" -f "Raiz chroot:",    $repoChroot)
    Write-Host ("  {0,-22} {1} -> {2}" -f "Repositorio:", $repoSubdir, $repoReal)
    Write-Host ("  {0,-22} ftp://{1}  usuario: {2}" -f "Acceso FTP:", $Script:SSL_FTP_IP, $repoUser)
    Write-Host ("  {0,-22} /repositorio/http/Windows/{{Apache,Nginx,Tomcat}}" -f "Navegar a:")
    Write-Host ""
    pause
}

function _paso_4_descargar_paquetes {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Paso 4 -- Descargar paquetes al repositorio"

        if (-not (Test-Path $Script:SSL_REPO_ROOT)) {
            aputs_error "El repositorio no existe"
            aputs_info  "Ejecute primero el Paso 3 -- Crear repositorio"
            pause
            return
        }

        ssl_repo_listar

        Write-Host "  1) Descargar/instalar todos (Apache + Nginx + Tomcat + IIS)"
        Write-Host "  2) Descargar solo Apache (httpd)"
        Write-Host "  3) Descargar solo Nginx"
        Write-Host "  4) Descargar solo Tomcat"
        Write-Host "  5) Instalar IIS (caracteristica Windows)"
        Write-Host "  6) Verificar integridad (SHA256)"
        Write-Host "  0) Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { ssl_repo_descargar_todos;                    pause }
            "2" { _repo_menu_versiones "Apache" "apache-httpd" $Script:SSL_REPO_APACHE }
            "3" { _repo_menu_versiones "Nginx"  "nginx"  $Script:SSL_REPO_NGINX  }
            "4" { _repo_menu_versiones "Tomcat" "tomcat" $Script:SSL_REPO_TOMCAT }
            "5" { _repo_menu_iis }
            "6" { ssl_repo_verificar_integridad;               pause }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

function _paso_5_http {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Paso 5 -- Instalar y configurar HTTP"

        Write-Host "  Como desea instalar los servicios HTTP?"
        Write-Host ""

        $pkgCount = 0
        if (Test-Path $Script:SSL_REPO_ROOT) {
            $pkgCount = (Get-ChildItem $Script:SSL_REPO_ROOT -Recurse -Include "*.nupkg", "*.zip" `
                -ErrorAction SilentlyContinue | Measure-Object).Count
        }

        if ($pkgCount -gt 0) {
            Write-Host "  [*] Repositorio FTP local disponible ($pkgCount paquete(s))"
        } else {
            Write-Host "  [ ] Repositorio FTP local vacio (ejecute Paso 4 primero)"
        }

        Write-Host ""
        Write-Host "  1) Instalar desde Chocolatey  (Practica 6)"
        Write-Host "  2) Instalar desde repositorio FTP propio"
        Write-Host "  0) Volver al menu principal"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" {
                $httpScript = Join-Path $Script:P6_DIR "Start-HTTPManager.ps1"
                if (Test-Path $httpScript) {
                    & $httpScript
                } else {
                    aputs_error "Start-HTTPManager.ps1 no encontrado en $Script:P6_DIR"
                    pause
                }
            }
            "2" {
                if ($pkgCount -eq 0) {
                    Write-Host ""
                    aputs_warning "El repositorio FTP esta vacio"
                    aputs_info   "Ejecute el Paso 4 para descargar los paquetes primero"
                    pause
                } else {
                    ssl_instalar_desde_ftp
                }
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

function _paso_6_ssl_http {
    Clear-Host
    ssl_mostrar_banner "Paso 6 -- Configurar SSL/HTTPS (opcional)"

    if (-not (_estado_http)) {
        aputs_error "No hay servicios HTTP instalados"
        aputs_info  "Ejecute primero el Paso 5 -- Instalar HTTP"
        pause
        return
    }

    Write-Host ""
    Write-Host "  Este paso configurara:"
    Write-Host "    - Certificado SSL autofirmado (si no existe)"
    Write-Host "    - HTTPS en los servicios HTTP instalados"
    Write-Host "    - Redirect HTTP -> HTTPS"
    Write-Host ""
    $resp = Read-Host "  Desea aplicar SSL/HTTPS? [S/n]"
    if ($resp -match '^[nN]$') {
        aputs_info "SSL/HTTPS omitido -- puede configurarlo despues desde el menu"
        pause
        return
    }

    Write-Host ""

    if (-not (ssl_cert_existe)) {
        aputs_info "El certificado no existe -- generando..."
        Write-Host ""
        if (-not (ssl_cert_generar)) { pause; return }
        Write-Host ""
    } else {
        aputs_info "Certificado ya existe -- reutilizando"
        ssl_cert_mostrar_info | Out-Null
        Write-Host ""
    }

    ssl_http_aplicar_todos
    pause
}

function _paso_7_testing {
    ssl_verify_todo
    pause
}

# ------------------------------------------------------------
# Menu principal
# ------------------------------------------------------------

function _refrescar_estado {
    $Script:_c1    = _estado_ftp
    $Script:_c2    = _estado_ftps
    $Script:_c3    = Test-Path $Script:SSL_REPO_ROOT
    $Script:_c4    = _estado_repo
    $Script:_c5    = _estado_http
    $Script:_c6    = _estado_ssl_http
    $Script:_cCert = ssl_cert_existe
}

function _dibujar_menu {
    Clear-Host

    $s1    = _icono_estado $Script:_c1
    $s2    = _icono_estado $Script:_c2
    $s3    = _icono_estado $Script:_c3
    $s4    = _icono_estado $Script:_c4
    $s5    = _icono_estado $Script:_c5
    $s6    = _icono_estado $Script:_c6
    $sCert = _icono_estado $Script:_cCert

    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    Practica 07 -- Infraestructura Segura FTP/HTTP (Windows)"
    Write-Host "  =========================================================="
    Write-Host ""
    Write-Host "  Certificado SSL: $sCert"
    Write-Host ""
    Write-Host "  -- Fase FTP --------------------------------------------------"
    Write-Host "  1) $s1  Instalar y configurar FTP"
    Write-Host "  2) $s2  Configurar FTPS/TLS         (requiere paso 1)"
    Write-Host ""
    Write-Host "  -- Fase Repositorio ------------------------------------------"
    Write-Host "  3) $s3  Crear repositorio + usuario 'repo'  (req. paso 1)"
    Write-Host "  4) $s4  Descargar paquetes al repositorio   (req. paso 3)"
    Write-Host ""
    Write-Host "  -- Fase HTTP -------------------------------------------------"
    Write-Host "  5) $s5  Instalar y configurar HTTP"
    Write-Host "  6) $s6  Configurar SSL/HTTPS         (requiere paso 5)"
    Write-Host ""
    Write-Host "  -- Extras ----------------------------------------------------"
    Write-Host "  7)      Testing general completo"
    Write-Host "  f)      Menu completo FTP           (Practica 5)"
    Write-Host "  h)      Menu completo HTTP          (Practica 6)"
    Write-Host "  c)      Gestionar certificado SSL"
    Write-Host "  r)      Menu repositorio FTP"
    Write-Host ""
    Write-Host "  0)      Salir"
    Write-Host ""
}

function main_menu {
    _refrescar_estado   # carga inicial de estado
    while ($true) {
        _dibujar_menu   # dibuja instantaneamente desde cache

        $Host.UI.RawUI.FlushInputBuffer()
        $op = Read-Host "  Opcion"

        switch ($op.Trim().ToLower()) {
            "1" { _paso_1_ftp;              _refrescar_estado }
            "2" { _paso_2_ftps;             _refrescar_estado }
            "3" { _paso_3_repo_estructura;  _refrescar_estado }
            "4" { _paso_4_descargar_paquetes; _refrescar_estado }
            "5" { _paso_5_http;             _refrescar_estado }
            "6" { _paso_6_ssl_http;         _refrescar_estado }
            "7" { _paso_7_testing                             }
            "f" {
                Clear-Host
                ssl_mostrar_banner "Menu completo FTP (Practica 5)"
                aputs_info "Se redirigira al script FTP de la Practica 5:"
                Write-Host "    $Script:P5_DIR\ftp-win.ps1"
                Write-Host ""
                pause
                $ftpScript = Join-Path $Script:P5_DIR "ftp-win.ps1"
                if (Test-Path $ftpScript) {
                    & $ftpScript
                } else {
                    aputs_error "ftp-win.ps1 no encontrado en $Script:P5_DIR"
                    pause
                }
                _refrescar_estado
            }
            "h" {
                Clear-Host
                ssl_mostrar_banner "Menu completo HTTP (Practica 6)"
                aputs_info "Se redirigira al script HTTP de la Practica 6:"
                Write-Host "    $Script:P6_DIR\Start-HTTPManager.ps1"
                Write-Host ""
                pause
                $httpScript = Join-Path $Script:P6_DIR "Start-HTTPManager.ps1"
                if (Test-Path $httpScript) {
                    & $httpScript
                } else {
                    aputs_error "Start-HTTPManager.ps1 no encontrado en $Script:P6_DIR"
                    pause
                }
                _refrescar_estado
            }
            "c" { ssl_menu_cert;  _refrescar_estado }
            "r" { ssl_menu_repo;  _refrescar_estado }
            "0" {
                Write-Host ""
                aputs_info "Saliendo de la Practica 7..."
                Write-Host ""
                exit 0
            }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ------------------------------------------------------------
# Punto de entrada
# ------------------------------------------------------------

_verificar_estructura

# Cargar modulos en el scope del script (dot-source fuera de funciones)
. (Join-Path $Script:SSL_SCRIPT_DIR "utils.SSL.ps1")

foreach ($mod in @("certSSL.ps1", "FTP-SSL.ps1", "HTTP-SSL.ps1",
                    "verifySSL.ps1", "reporHTTP.ps1", "installFTP.ps1")) {
    $ruta = Join-Path $Script:SSL_SCRIPT_DIR $mod
    if (Test-Path $ruta) { . $ruta }
}

main_menu
