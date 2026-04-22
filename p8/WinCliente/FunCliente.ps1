#
# FunCliente.ps1 -- Funciones para el cliente Windows (Practica 8)
# Union al dominio + configuracion de AppLocker
#

# ------------------------------------------------------------
# Configuracion -- AJUSTAR SEGUN EL ENTORNO
# ------------------------------------------------------------

$Global:WC_DomainName   = "p8.local"
$Global:WC_DomainAdmin  = "P8\Administrator"
$Global:WC_DomainPass   = ""            # Si se deja vacio, se pedira interactivamente
$Global:WC_DnsServer    = ""            # IP del DC. Vacio = auto-detectar
$Global:WC_AppLockerXml = "C:\AppLocker_Local.xml"

# SID del grupo NoCuates -- se obtiene automaticamente si esta vacio
$Global:WC_SidNoCuates  = ""
$Global:WC_SidAdmins    = "S-1-5-32-544"   # BUILTIN\Administrators

# ------------------------------------------------------------
# Detectar interfaz de red activa
# ------------------------------------------------------------

function Get-InterfazRed {
    $iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } |
        ForEach-Object {
            $ip = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex `
                      -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ip -and $ip.IPAddress -notlike "127.*") { $_ }
        } | Select-Object -First 1

    if (-not $iface) {
        $iface = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    }

    Write-Host "  Interfaz detectada: $($iface.Name)" -ForegroundColor Green
    return $iface
}

# ------------------------------------------------------------
# Configurar DNS hacia el DC
# ------------------------------------------------------------

function Set-DnsHaciasDC {
    param([Parameter(Mandatory)][string]$IpDC)

    $iface = Get-InterfazRed
    Set-DnsClientServerAddress -InterfaceIndex $iface.InterfaceIndex -ServerAddresses $IpDC
    Write-Host "  DNS configurado -> $IpDC" -ForegroundColor Green
}

# ------------------------------------------------------------
# Verificar resolucion DNS del dominio
# ------------------------------------------------------------

function Test-ResolucionDominio {
    Start-Sleep -Seconds 2
    $dns = if ($Global:WC_DnsServer) { $Global:WC_DnsServer } else { (Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object -First 1).ServerAddresses[0] }
    $resolve = Resolve-DnsName -Name $Global:WC_DomainName -ErrorAction SilentlyContinue
    if ($resolve) {
        Write-Host "  Resolucion DNS: OK ($Global:WC_DomainName)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  ERROR: No se puede resolver $Global:WC_DomainName" -ForegroundColor Red
        return $false
    }
}

# ------------------------------------------------------------
# Unirse al dominio
# ------------------------------------------------------------

function Invoke-UnirDominio {
    Write-Host ""

    # Configurar DNS si se especifico IP del DC
    if ($Global:WC_DnsServer) {
        Set-DnsHaciasDC -IpDC $Global:WC_DnsServer
    }

    if (-not (Test-ResolucionDominio)) {
        Write-Host "  Abortando: sin resolucion DNS." -ForegroundColor Red
        return
    }

    # Credenciales
    if ($Global:WC_DomainPass) {
        $cred = New-Object System.Management.Automation.PSCredential(
            $Global:WC_DomainAdmin,
            (ConvertTo-SecureString $Global:WC_DomainPass -AsPlainText -Force)
        )
    } else {
        Write-Host "  Ingrese credenciales del administrador del dominio:"
        $cred = Get-Credential -Message "Administrador del dominio $Global:WC_DomainName" `
                               -UserName $Global:WC_DomainAdmin
    }

    Add-Computer -DomainName $Global:WC_DomainName -Credential $cred -Force -ErrorAction Stop
    Write-Host "  Unido al dominio '$Global:WC_DomainName'. Reiniciando en 3 segundos..." -ForegroundColor Green
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ------------------------------------------------------------
# Obtener hashes de notepad.exe via AppLocker
# ------------------------------------------------------------

function Get-HashesNotepad {
    $notepad1 = "$env:SystemRoot\System32\notepad.exe"
    $notepad2 = "$env:SystemRoot\SysWOW64\notepad.exe"

    $hash1 = (Get-AppLockerFileInformation -Path $notepad1).Hash.HashDataString
    $len1  = (Get-Item $notepad1).Length
    Write-Host "  Hash System32  : $hash1" -ForegroundColor Cyan

    if (Test-Path $notepad2) {
        $hash2 = (Get-AppLockerFileInformation -Path $notepad2).Hash.HashDataString
        $len2  = (Get-Item $notepad2).Length
        Write-Host "  Hash SysWOW64  : $hash2" -ForegroundColor Cyan
    } else {
        $hash2 = $hash1
        $len2  = $len1
    }

    return @{ Hash1 = $hash1; Len1 = $len1; Hash2 = $hash2; Len2 = $len2 }
}

# ------------------------------------------------------------
# Obtener SID del grupo NoCuates desde AD
# ------------------------------------------------------------

function Get-SidNoCuates {
    if ($Global:WC_SidNoCuates) { return $Global:WC_SidNoCuates }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop | Out-Null
        $grupo = Get-ADGroup -Filter "Name -like '*NoCuates*'" -ErrorAction Stop |
            Select-Object -First 1
        if ($grupo) {
            $sid = $grupo.SID.Value
            Write-Host "  SID NoCuates detectado: $sid" -ForegroundColor Cyan
            $Global:WC_SidNoCuates = $sid
            return $sid
        }
    } catch {}

    # Si no hay AD disponible, pedir manualmente
    Write-Host "  No se pudo obtener el SID automaticamente." -ForegroundColor Yellow
    $sid = Read-Host "  Ingresa el SID del grupo NoCuates (S-1-5-21-...)"
    $Global:WC_SidNoCuates = $sid
    return $sid
}

# ------------------------------------------------------------
# Generar XML de politica AppLocker
# ------------------------------------------------------------

function New-AppLockerXml {
    param([Parameter(Mandatory)][hashtable]$Hashes)

    $sidNoCuates = Get-SidNoCuates
    if (-not $sidNoCuates) {
        Write-Host "  ERROR: No se pudo obtener el SID de NoCuates" -ForegroundColor Red
        return $false
    }

    $xml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FileHashRule Id="b2e2d5b5-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
                  Name="BLOQUEAR Notepad System32 - NoCuates"
                  Description="Bloquea notepad.exe System32 por hash para NoCuates aunque sea renombrado"
                  UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions><FileHashCondition>
        <FileHash Type="SHA256" Data="$($Hashes.Hash1)" SourceFileName="notepad.exe" SourceFileLength="$($Hashes.Len1)" />
      </FileHashCondition></Conditions>
    </FileHashRule>
    <FileHashRule Id="c5d6e7f8-a9b0-1234-cdef-567890abcdef"
                  Name="BLOQUEAR Notepad SysWOW64 - NoCuates"
                  Description="Bloquea notepad.exe SysWOW64 por hash para NoCuates aunque sea renombrado"
                  UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions><FileHashCondition>
        <FileHash Type="SHA256" Data="$($Hashes.Hash2)" SourceFileName="notepad.exe" SourceFileLength="$($Hashes.Len2)" />
      </FileHashCondition></Conditions>
    </FileHashRule>
    <FilePathRule Id="a1b2c3d4-e5f6-7890-abcd-ef1234567890" Name="Permitir Windows - Todos"
                  Description="Permite ejecutables de Windows para todos (notepad para Cuates incluido)"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="b2c3d4e5-f6a7-8901-bcde-f12345678901" Name="Permitir Program Files - Todos"
                  Description="Permite ejecutables de Program Files para todos"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="Admins - Acceso Total"
                  Description="Administradores sin restriccion"
                  UserOrGroupSid="$($Global:WC_SidAdmins)" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Msi"    EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll"    EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx"   EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

    $xml | Out-File $Global:WC_AppLockerXml -Encoding UTF8 -Force
    Write-Host "  XML guardado en $Global:WC_AppLockerXml" -ForegroundColor Green
    return $true
}

# ------------------------------------------------------------
# Habilitar el servicio AppIDSvc
# ------------------------------------------------------------

function Enable-AppIDSvc {
    Set-Service   AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service AppIDSvc -ErrorAction SilentlyContinue
    Write-Host "  AppIDSvc: $((Get-Service AppIDSvc).Status)" -ForegroundColor Cyan
}

# ------------------------------------------------------------
# Aplicar politica AppLocker localmente
# ------------------------------------------------------------

function Set-AppLockerPolicyLocal {
    $basePath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2"
    if (Test-Path $basePath) { Remove-Item -Path $basePath -Recurse -Force }
    New-Item -Path $basePath -Force | Out-Null

    Set-AppLockerPolicy -XmlPolicy $Global:WC_AppLockerXml
    Restart-Service AppIDSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  AppLocker aplicado correctamente" -ForegroundColor Green
}

# ------------------------------------------------------------
# Mostrar resumen de la politica AppLocker efectiva
# ------------------------------------------------------------

function Show-ResumenAppLocker {
    Write-Host ""
    Write-Host "  ===== POLITICA EFECTIVA =====" -ForegroundColor Magenta
    try { Get-AppLockerPolicy -Effective -Xml } catch { Write-Host "  (No disponible aun)" }

    Write-Host ""
    Write-Host "  ===== RESUMEN =====" -ForegroundColor Magenta
    Write-Host "  GrupoCuates   : notepad PERMITIDO"   -ForegroundColor Green
    Write-Host "  GrupoNoCuates : notepad BLOQUEADO por hash SHA256" -ForegroundColor Red
    Write-Host ""
    Write-Host "  ===== PRUEBAS PARA LA RUBRICA =====" -ForegroundColor Magenta
    Write-Host "  AppLocker (30%):"        -ForegroundColor Yellow
    Write-Host "    smendez  (NoCuates) -> notepad debe BLOQUEARSE"
    Write-Host "    cramirez (Cuates)   -> notepad debe ABRIRSE"
    Write-Host "  Cuotas FSRM (40%):"     -ForegroundColor Yellow
    Write-Host "    smendez  : >5MB  en H: debe BLOQUEARSE"
    Write-Host "    cramirez : >10MB en H: debe BLOQUEARSE"
    Write-Host "  Logon Hours (15%):"     -ForegroundColor Yellow
    Write-Host "    cramirez fuera de 8AM-3PM  -> login RECHAZADO"
    Write-Host "    smendez  fuera de 3PM-2AM  -> login RECHAZADO"
}

# ------------------------------------------------------------
# Flujo completo: configurar AppLocker (Fase 2, post-reinicio)
# ------------------------------------------------------------

function Invoke-ConfigAppLocker {
    Write-Host ""
    Write-Host "  Dominio: $((Get-WmiObject Win32_ComputerSystem).Domain)" -ForegroundColor Cyan
    gpupdate /force | Out-Null
    Enable-AppIDSvc
    Write-Host ""
    $hashes = Get-HashesNotepad
    Write-Host ""
    New-AppLockerXml   -Hashes $hashes | Out-Null
    Write-Host ""
    Set-AppLockerPolicyLocal
    Write-Host ""
    Show-ResumenAppLocker
}
