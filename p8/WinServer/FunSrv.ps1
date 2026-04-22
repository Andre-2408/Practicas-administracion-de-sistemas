# FunSrv.ps1 -- Funciones servidor Practica 8
# Logica basada en la implementacion de referencia (YuckierOlive370/Tarea8GCC)
# Diseno visual y helpers al estilo del proyecto.

# ============================================================
# VARIABLES GLOBALES -- AJUSTAR SEGUN EL ENTORNO
# ============================================================
$Global:DominioDN  = "DC=p8,DC=local"
$Global:Dominio    = "p8.local"
$Global:NetBIOS    = "P8"
$Global:HomesBase  = "C:\Homes"
$Global:CsvPath    = "C:\Scripts\usuarios.csv"
$Global:AdminPass  = "Admin@12345!"

# ============================================================
# HELPERS DE OUTPUT
# ============================================================
function srv_info    { param($m) Write-Host "  [INFO]    $m" }
function srv_ok      { param($m) Write-Host "  [OK]      $m" -ForegroundColor Green }
function srv_error   { param($m) Write-Host "  [ERROR]   $m" -ForegroundColor Red }
function srv_warning { param($m) Write-Host "  [AVISO]   $m" -ForegroundColor Yellow }

function srv_linea  { Write-Host "  ----------------------------------------------------------" }

function srv_banner {
    param([string]$Titulo = "Practica 08 -- Servidor AD")
    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    $Titulo"
    Write-Host "  =========================================================="
    Write-Host ""
}

function srv_pausa {
    Write-Host ""
    Write-Host "  Presione ENTER para continuar..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ============================================================
# FASE 1 -- PREPARACION: crear CSV de usuarios
# ============================================================
function Invoke-Preparacion {
    srv_banner "Fase 1 -- Preparacion"
    srv_info "Creando directorio C:\Scripts y archivo CSV de usuarios..."

    New-Item -ItemType Directory -Path "C:\Scripts" -Force | Out-Null

    @"
Nombre,Apellido,Usuario,Password,Departamento,Email
Carlos,Ramirez,cramirez,P@ssw0rd123,Cuates,cramirez@$($Global:Dominio)
Maria,Lopez,mlopez,P@ssw0rd123,Cuates,mlopez@$($Global:Dominio)
Juan,Perez,jperez,P@ssw0rd123,Cuates,jperez@$($Global:Dominio)
Ana,Torres,atorres,P@ssw0rd123,Cuates,atorres@$($Global:Dominio)
Luis,Gomez,lgomez,P@ssw0rd123,Cuates,lgomez@$($Global:Dominio)
Sofia,Mendez,smendez,P@ssw0rd123,NoCuates,smendez@$($Global:Dominio)
Diego,Vargas,dvargas,P@ssw0rd123,NoCuates,dvargas@$($Global:Dominio)
Elena,Castro,ecastro,P@ssw0rd123,NoCuates,ecastro@$($Global:Dominio)
Pablo,Ruiz,pruiz,P@ssw0rd123,NoCuates,pruiz@$($Global:Dominio)
Laura,Soto,lsoto,P@ssw0rd123,NoCuates,lsoto@$($Global:Dominio)
"@ | Out-File -FilePath $Global:CsvPath -Encoding UTF8 -Force

    srv_ok "CSV creado en: $Global:CsvPath"
    Write-Host ""
    Import-Csv $Global:CsvPath | Format-Table -AutoSize

    $rol = (Get-WmiObject Win32_ComputerSystem).DomainRole
    srv_info "DomainRole actual: $rol  (5 = Controlador de Dominio listo)"
}

# ============================================================
# FASE 2 -- INSTALAR AD DS (reinicia el servidor)
# ============================================================
function Invoke-InstalarAD {
    srv_banner "Fase 2 -- Instalacion de AD DS"
    srv_info "Cambiando password del administrador local..."
    net user Administrator $Global:AdminPass | Out-Null

    srv_info "Instalando caracteristicas: AD-Domain-Services, GPMC, RSAT, FSRM..."
    Install-WindowsFeature -Name AD-Domain-Services, GPMC, RSAT-AD-PowerShell, FS-Resource-Manager `
        -IncludeManagementTools | Out-Null
    srv_ok "Caracteristicas instaladas"

    srv_info "Promoviendo a Controlador de Dominio (el servidor se reiniciara)..."
    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName            $Global:Dominio `
        -DomainNetbiosName     $Global:NetBIOS `
        -ForestMode            "WinThreshold" `
        -DomainMode            "WinThreshold" `
        -InstallDns:$true `
        -SafeModeAdministratorPassword (ConvertTo-SecureString $Global:AdminPass -AsPlainText -Force) `
        -NoRebootOnCompletion:$false `
        -Force:$true
}

# ============================================================
# FASE 3 -- CONFIGURAR DOMINIO (post-reinicio)
# ============================================================

# -- OUs y Grupos --
function New-OUsYGrupos {
    srv_info "Creando Unidades Organizativas..."
    foreach ($ou in @("Cuates","NoCuates")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $Global:DominioDN `
                -ProtectedFromAccidentalDeletion $false
            srv_ok "OU creada: $ou"
        } else { srv_info "OU ya existe: $ou" }
    }

    srv_info "Creando grupos de seguridad..."
    New-ADGroup -Name "GRP_Cuates"   -GroupScope Global -GroupCategory Security `
        -Path "OU=Cuates,$Global:DominioDN"   -Description "Cuates -- 8AM-3PM"   -ErrorAction SilentlyContinue
    New-ADGroup -Name "GRP_NoCuates" -GroupScope Global -GroupCategory Security `
        -Path "OU=NoCuates,$Global:DominioDN" -Description "NoCuates -- 3PM-2AM" -ErrorAction SilentlyContinue
    srv_ok "OUs y Grupos listos"
}

# -- Share Homes --
function New-ShareHomes {
    srv_info "Configurando directorio raiz de homes: $Global:HomesBase"
    New-Item -ItemType Directory -Path $Global:HomesBase -Force | Out-Null

    # Permisos NTFS en la raiz C:\Homes:
    #   Administrators  : Control total (esta carpeta y subcarpetas)
    #   SYSTEM          : Control total (esta carpeta y subcarpetas)
    #   Domain Users    : Solo "Listar carpeta" en ESTA carpeta
    #                     (permite traversal a su propia subcarpeta)
    # La herencia se deshabilita para que cada subcarpeta de usuario
    # tenga solo sus propios permisos (sin filtrar por Domain Users).
    # SIDs independientes del idioma del SO
    $sidAdmin   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544") # BUILTIN\Administrators
    $sidSystem  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")     # NT AUTHORITY\SYSTEM
    $sidEveryone = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")     # Everyone/Todos
    $everyoneNT = $sidEveryone.Translate([System.Security.Principal.NTAccount]).Value

    $aclRoot = Get-Acl $Global:HomesBase
    $aclRoot.SetAccessRuleProtection($true, $false)   # deshabilitar herencia, no copiar
    foreach ($sid in @($sidAdmin, $sidSystem)) {
        $aclRoot.AddAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, "FullControl",
                "ContainerInherit,ObjectInherit", "None", "Allow")))
    }
    # Domain Users: solo listar esta carpeta (traversal)
    # SID de Domain Users = SID-dominio + RID 513 (independiente del idioma)
    try {
        $domSID = (Get-ADDomain).DomainSID
        $sidDomainUsers = New-Object System.Security.Principal.SecurityIdentifier(
            [System.Security.Principal.WellKnownSidType]::AccountDomainUsersSid, $domSID)
        $aclRoot.AddAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sidDomainUsers,
                "ReadAndExecute",
                "None", "None", "Allow")))
    } catch {
        srv_warning "No se pudo agregar Domain Users al ACL raiz: $_"
    }
    Set-Acl -Path $Global:HomesBase -AclObject $aclRoot

    if (-not (Get-SmbShare -Name "Homes" -ErrorAction SilentlyContinue)) {
        # New-SmbShare con FullAccess a Everyone/Todos al nivel de share.
        # NTFS (por carpeta de usuario) es quien restringe el acceso real.
        New-SmbShare -Name "Homes" -Path $Global:HomesBase `
            -FullAccess $everyoneNT `
            -Description "Directorios personales P8" | Out-Null
        srv_ok "Share Homes creado: \\$env:COMPUTERNAME\Homes"
    } else {
        # Si el share ya existia, asegurarse de que Everyone/Todos tenga Full al nivel share
        Grant-SmbShareAccess -Name "Homes" -AccountName $everyoneNT `
            -AccessRight Full -Force | Out-Null
        srv_ok "Share Homes ya existe -- permisos share actualizados"
    }
}

# -- Crear usuario AD individual --
function _New-UsuarioAD {
    param($Nombre, $Apellido, $Usuario, $Password, $Departamento, $Email)

    $ouPath  = if ($Departamento -eq "Cuates") {"OU=Cuates,$Global:DominioDN"} else {"OU=NoCuates,$Global:DominioDN"}
    $grupo   = if ($Departamento -eq "Cuates") {"GRP_Cuates"} else {"GRP_NoCuates"}
    $homeDir = "$Global:HomesBase\$Usuario"
    $homeUNC = "\\$env:COMPUTERNAME\Homes\$Usuario"

    if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Path $homeDir | Out-Null }

    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Usuario'" -ErrorAction SilentlyContinue)) {
        New-ADUser `
            -Name              "$Nombre $Apellido" `
            -GivenName         $Nombre `
            -Surname           $Apellido `
            -SamAccountName    $Usuario `
            -UserPrincipalName "$Usuario@$Global:Dominio" `
            -AccountPassword   (ConvertTo-SecureString $Password -AsPlainText -Force) `
            -Enabled           $true `
            -Path              $ouPath `
            -HomeDirectory     $homeUNC `
            -HomeDrive         "H:" `
            -Department        $Departamento `
            -EmailAddress      $Email `
            -PasswordNeverExpires $true `
            -ErrorAction Stop
        srv_ok "Usuario creado: $Usuario [$Departamento]"
    } else { srv_info "Usuario ya existe: $Usuario" }

    Add-ADGroupMember -Identity $grupo -Members $Usuario -ErrorAction SilentlyContinue

    # Permisos NTFS en la carpeta personal del usuario.
    # Se deshabilita herencia para que FSRM y los permisos queden limpios,
    # sin que Domain Users (del padre) interfiera con escritura.
    $sidAdminH  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $sidSystemH = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
    $sidUsuario = (Get-ADUser $Usuario).SID

    $acl = Get-Acl $homeDir
    $acl.SetAccessRuleProtection($true, $false)   # deshabilitar herencia, no copiar
    foreach ($sid in @($sidAdminH, $sidSystemH, $sidUsuario)) {
        $acl.AddAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, "FullControl",
                "ContainerInherit,ObjectInherit", "None", "Allow")))
    }
    Set-Acl -Path $homeDir -AclObject $acl
    srv_ok "Permisos NTFS aplicados: $Usuario -> FullControl en $homeDir"
}

# -- Importar usuarios desde CSV --
function New-UsuariosDesdeCSV {
    param([array]$Usuarios)
    $ok = 0; $err = 0
    foreach ($u in $Usuarios) {
        try {
            _New-UsuarioAD -Nombre $u.Nombre -Apellido $u.Apellido `
                -Usuario $u.Usuario -Password $u.Password `
                -Departamento $u.Departamento -Email $u.Email
            $ok++
        } catch { srv_error "Error en '$($u.Usuario)': $_"; $err++ }
    }
    srv_info "Importacion: $ok exitosos, $err errores"
}

# -- Horarios de acceso (LogonHours) --
function Set-HorariosLogon {
    param([array]$Usuarios)

    function _Bytes-Horario ([int[]]$horas) {
        $bytes = New-Object byte[] 21
        for ($d = 0; $d -lt 7; $d++) {
            $bits = 0
            foreach ($h in $horas) { $bits = $bits -bor (1 -shl $h) }
            $bytes[$d*3]   = $bits -band 0xFF
            $bytes[$d*3+1] = ($bits -shr 8)  -band 0xFF
            $bytes[$d*3+2] = ($bits -shr 16) -band 0xFF
        }
        return $bytes
    }

    # Cuates: 8AM-3PM local = 14:00-20:00 UTC-6
    $bytesCuates   = _Bytes-Horario @(14,15,16,17,18,19,20)
    # NoCuates: 3PM-2AM local = 21:00-07:00 UTC-6
    $bytesNoCuates = _Bytes-Horario @(21,22,23,0,1,2,3,4,5,6,7)

    foreach ($u in $Usuarios) {
        [byte[]]$bytes = if ($u.Departamento -eq "Cuates") {$bytesCuates} else {$bytesNoCuates}
        try {
            # Set-ADUser -Replace falla con byte arrays cuando el atributo ya tiene valor.
            # ADSI es el metodo confiable para logonHours.
            $dn = (Get-ADUser $u.Usuario -ErrorAction Stop).DistinguishedName
            $adsiUser = [ADSI]"LDAP://$dn"
            $adsiUser.Put("logonHours", $bytes)
            $adsiUser.SetInfo()
            srv_ok "Horario aplicado: $($u.Usuario) [$($u.Departamento)]"
        } catch { srv_error "Error en $($u.Usuario): $_" }
    }
}

# -- GPO cierre de sesion --
function New-GPOCierreHorario {
    if (-not (Get-GPO -Name "GPO-CierreHorario" -ErrorAction SilentlyContinue)) {
        New-GPO  -Name "GPO-CierreHorario" | Out-Null
        New-GPLink -Name "GPO-CierreHorario" -Target $Global:DominioDN -LinkEnabled Yes | Out-Null
        srv_ok "GPO-CierreHorario creada y vinculada"
    } else { srv_info "GPO-CierreHorario ya existe" }

    Set-GPRegistryValue -Name "GPO-CierreHorario" `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
        -ValueName "EnableForcedLogOff" -Type DWord -Value 1 | Out-Null
    srv_ok "EnableForcedLogOff = 1 configurado"
}

# -- Cuotas FSRM --
function New-CuotasFSRM {
    param([array]$Usuarios)

    foreach ($t in @(
        @{Nombre="P8-Cuota-5MB-NoCuates"; Tam=5MB},
        @{Nombre="P8-Cuota-10MB-Cuates";  Tam=10MB}
    )) {
        Remove-FsrmQuotaTemplate -Name $t.Nombre -Confirm:$false -ErrorAction SilentlyContinue
        New-FsrmQuotaTemplate    -Name $t.Nombre -Size $t.Tam -SoftLimit:$false | Out-Null
        srv_ok "Plantilla: $($t.Nombre) ($([int]($t.Tam/1MB)) MB, limite estricto)"
    }

    foreach ($u in $Usuarios) {
        $homeDir  = "$Global:HomesBase\$($u.Usuario)"
        $template = if ($u.Departamento -eq "Cuates") {"P8-Cuota-10MB-Cuates"} else {"P8-Cuota-5MB-NoCuates"}
        $tam      = if ($u.Departamento -eq "Cuates") {10MB} else {5MB}
        if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Path $homeDir | Out-Null }
        Remove-FsrmQuota -Path $homeDir -Confirm:$false -ErrorAction SilentlyContinue
        New-FsrmQuota    -Path $homeDir -Template $template -Size $tam -SoftLimit:$false | Out-Null
        srv_ok "Cuota $([int]($tam/1MB)) MB aplicada: $($u.Usuario)"
    }
}

# -- Apantallamiento de archivos FSRM --
function New-FileScreeningFSRM {
    param([array]$Usuarios)

    $fgName = "P8-ArchivosProhibidos"
    $stName = "P8-Pantalla-Activa"

    Remove-FsrmFileGroup          -Name $fgName -Confirm:$false -ErrorAction SilentlyContinue
    New-FsrmFileGroup             -Name $fgName -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi") | Out-Null
    srv_ok "Grupo de archivos: $fgName (mp3, mp4, exe, msi)"

    Remove-FsrmFileScreenTemplate -Name $stName -Confirm:$false -ErrorAction SilentlyContinue
    New-FsrmFileScreenTemplate    -Name $stName -Active:$true -IncludeGroup @($fgName) | Out-Null
    srv_ok "Plantilla de apantallamiento activo: $stName"

    foreach ($u in $Usuarios) {
        $homeDir = "$Global:HomesBase\$($u.Usuario)"
        if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Path $homeDir | Out-Null }
        Remove-FsrmFileScreen -Path $homeDir -Confirm:$false -ErrorAction SilentlyContinue
        New-FsrmFileScreen    -Path $homeDir -Template $stName -Active:$true | Out-Null
        srv_ok "Apantallamiento activo: $($u.Usuario)"
    }
}

# -- Habilitar AppIDSvc --
function Enable-AppIDSvc {
    Set-Service   AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $estado = (Get-Service AppIDSvc).Status
    srv_ok "AppIDSvc: $estado"
}

# ============================================================
# ORQUESTADOR FASE 3
# ============================================================
function Invoke-ConfigurarDominio {
    srv_banner "Fase 3 -- Configuracion del Dominio (post-reinicio)"
    Import-Module ActiveDirectory, GroupPolicy, FileServerResourceManager -ErrorAction Stop | Out-Null

    $usuarios = Import-Csv $Global:CsvPath -Encoding UTF8

    srv_linea; srv_info "Paso 3.1: OUs y Grupos"
    New-OUsYGrupos
    srv_linea; srv_info "Paso 3.2: Share Homes"
    New-ShareHomes
    srv_linea; srv_info "Paso 3.3: Usuarios desde CSV"
    New-UsuariosDesdeCSV  -Usuarios $usuarios
    srv_linea; srv_info "Paso 3.4: Horarios de acceso"
    Set-HorariosLogon     -Usuarios $usuarios
    srv_linea; srv_info "Paso 3.5: GPO cierre de sesion"
    New-GPOCierreHorario
    srv_linea; srv_info "Paso 3.6: Cuotas FSRM"
    New-CuotasFSRM        -Usuarios $usuarios
    srv_linea; srv_info "Paso 3.7: Apantallamiento de archivos"
    New-FileScreeningFSRM -Usuarios $usuarios
    srv_linea; srv_info "Paso 3.8: AppIDSvc"
    Enable-AppIDSvc

    Write-Host ""
    srv_linea
    srv_ok "FASE 3 COMPLETADA -- Dominio configurado"
    Write-Host ""
    Invoke-VerificacionFinal
}

# ============================================================
# VERIFICACION FINAL
# ============================================================
function Invoke-VerificacionFinal {
    srv_banner "Verificacion Final"

    srv_info "Usuarios en AD:"
    Get-ADUser -Filter * -SearchBase $Global:DominioDN -Properties Department |
        Where-Object { $_.Department -in @("Cuates","NoCuates") } |
        Select-Object SamAccountName, Department, Enabled |
        Format-Table -AutoSize

    srv_info "Horarios (logonHours):"
    foreach ($u in (Import-Csv $Global:CsvPath -Encoding UTF8)) {
        try {
            $adU    = Get-ADUser $u.Usuario -Properties logonHours -ErrorAction Stop
            $estado = if ($adU.logonHours.Count -eq 21) {"OK ($($adU.logonHours.Count) bytes)"} else {"PENDIENTE"}
            Write-Host ("    {0,-12} [{1,-8}] : {2}" -f $u.Usuario, $u.Departamento, $estado)
        } catch { Write-Host "    $($u.Usuario) : no encontrado" }
    }

    Write-Host ""
    srv_info "Cuotas FSRM:"
    Get-FsrmQuota -ErrorAction SilentlyContinue |
        Select-Object Path, @{N="MB";E={[int]($_.Size/1MB)}}, @{N="Tipo";E={if($_.SoftLimit){"SOFT"}else{"HARD"}}} |
        Format-Table -AutoSize

    srv_info "Apantallamiento activo:"
    Get-FsrmFileScreen -ErrorAction SilentlyContinue |
        Select-Object Path, Active | Format-Table -AutoSize

    srv_info "GPOs activas:"
    (Get-GPInheritance -Target $Global:DominioDN).GpoLinks |
        Select-Object DisplayName, Enabled | Format-Table -AutoSize

    srv_info "AppIDSvc: $((Get-Service AppIDSvc -ErrorAction SilentlyContinue).Status)"
    srv_linea
    srv_ok "Servidor listo para pruebas"
}
