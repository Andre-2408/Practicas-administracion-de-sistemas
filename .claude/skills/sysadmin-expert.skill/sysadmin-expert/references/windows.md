# Windows Server & Windows 11 — Referencia de Administración

## PowerShell — Comandos Esenciales

### Sistema y Hardware

```powershell
# Info del sistema
PS> Get-ComputerInfo | Select-Object CsName, OsName, OsVersion, CsProcessors, CsTotalPhysicalMemory
PS> systeminfo                                    # Alternativa clásica
PS> Get-WmiObject -Class Win32_OperatingSystem   # Info del SO vía WMI

# Hardware
PS> Get-WmiObject Win32_Processor | Select-Object Name, NumberOfCores, MaxClockSpeed
PS> Get-WmiObject Win32_PhysicalMemory | Measure-Object Capacity -Sum
PS> Get-PnpDevice | Where-Object {$_.Status -ne 'OK'}   # Dispositivos con problemas
```

### Servicios y Procesos

```powershell
# Servicios
PS> Get-Service | Where-Object {$_.Status -eq 'Stopped' -and $_.StartType -eq 'Automatic'}
PS> Start-Service -Name "servicio"
PS> Stop-Service -Name "servicio" -Force
PS> Restart-Service -Name "servicio"
PS> Set-Service -Name "servicio" -StartupType Automatic

# Procesos
PS> Get-Process | Sort-Object CPU -Descending | Select-Object -First 15
PS> Get-Process -Name "proceso" | Stop-Process -Force    # 🔴
PS> Get-WmiObject Win32_Process | Select-Object Name, ProcessId, CommandLine
```

### Event Viewer — Logs del Sistema

```powershell
# Errores recientes del sistema
PS> Get-EventLog -LogName System -EntryType Error -Newest 20
PS> Get-EventLog -LogName Application -EntryType Error -Newest 20

# Eventos específicos por ID
PS> Get-WinEvent -FilterHashtable @{LogName='System'; Id=7034; StartTime=(Get-Date).AddDays(-7)}

# Usando el nuevo cmdlet (más flexible)
PS> Get-WinEvent -LogName System -MaxEvents 50 | Where-Object {$_.LevelDisplayName -eq 'Error'}

# Exportar a CSV para análisis
PS> Get-EventLog -LogName System -EntryType Error -Newest 100 | Export-Csv errores.csv -NoTypeInformation
```

### Red y Conectividad

```powershell
# Estado de red
PS> Get-NetAdapter                                        # Adaptadores
PS> Get-NetIPAddress                                      # IPs asignadas
PS> Get-NetRoute                                          # Tabla de rutas
PS> Get-DnsClientServerAddress                           # Servidores DNS

# Diagnóstico
PS> Test-NetConnection -ComputerName "8.8.8.8" -Port 53  # Test TCP
PS> Test-NetConnection -ComputerName "host.dominio.com" -TraceRoute
PS> Resolve-DnsName "dominio.com" -Type A                # Resolución DNS

# Puertos en escucha
PS> netstat -ano | findstr LISTENING
PS> Get-NetTCPConnection -State Listen

# Configurar IP estática
PS> New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "192.168.1.100" -PrefixLength 24 -DefaultGateway "192.168.1.1"
PS> Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("1.1.1.1","8.8.8.8")
```

### Firewall de Windows

```powershell
# Estado
PS> Get-NetFirewallProfile | Select-Object Name, Enabled

# Reglas
PS> Get-NetFirewallRule | Where-Object {$_.Enabled -eq 'True'} | Select-Object DisplayName, Direction, Action
PS> New-NetFirewallRule -DisplayName "Permitir puerto 8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
PS> Remove-NetFirewallRule -DisplayName "Permitir puerto 8080"

# Habilitar/deshabilitar perfil
PS> Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
```

### Almacenamiento y Discos

```powershell
# Discos y particiones
PS> Get-Disk
PS> Get-Partition
PS> Get-Volume

# Gestión de discos
PS> Initialize-Disk -Number 1 -PartitionStyle GPT                    # 🔴
PS> New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter    # 🔴
PS> Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel "Datos"  # 🔴

# Chequeo de disco
PS> Repair-Volume -DriveLetter C -Scan                    # 🟢 Solo escaneo
PS> Repair-Volume -DriveLetter C -SpotFix                 # 🔴 Reparar sin reinicio
# chkdsk C: /f /r                                         # 🔴 Reparación completa (requiere reinicio si es C:)
```

### Registro de Windows

```powershell
# Navegar el registro
PS> Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"

# Leer valor
PS> Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "Size"

# Crear/modificar clave  🟡
PS> Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Servicio" -Name "Start" -Value 2

# Exportar rama del registro (backup antes de modificar)  🟢
PS> reg export "HKLM\SOFTWARE\MiApp" backup-miapp.reg

# Importar  🟡
PS> reg import backup-miapp.reg
```

---

## Windows Server — Roles y Características

### Instalación de Roles (Server Manager / PowerShell)

```powershell
# Ver roles instalados
PS> Get-WindowsFeature | Where-Object {$_.Installed -eq $true}

# Instalar roles comunes  🟡
PS> Install-WindowsFeature -Name Web-Server -IncludeManagementTools        # IIS
PS> Install-WindowsFeature -Name DNS -IncludeManagementTools               # DNS Server
PS> Install-WindowsFeature -Name DHCP -IncludeManagementTools              # DHCP Server
PS> Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools # Active Directory
PS> Install-WindowsFeature -Name FS-FileServer, FS-SMB1                    # File Server
PS> Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart  # 🔴 Hyper-V
```

### Active Directory

```powershell
# Usuarios
PS> Get-ADUser -Identity "usuario" -Properties *
PS> Get-ADUser -Filter {Enabled -eq $false} | Select-Object Name, SamAccountName
PS> New-ADUser -Name "Juan Pérez" -SamAccountName "jperez" -AccountPassword (Read-Host -AsSecureString)
PS> Set-ADAccountPassword -Identity "jperez" -Reset -NewPassword (Read-Host -AsSecureString)  # 🟡
PS> Enable-ADAccount -Identity "jperez"
PS> Disable-ADAccount -Identity "jperez"

# Grupos
PS> Get-ADGroup -Filter * | Select-Object Name, GroupCategory
PS> Add-ADGroupMember -Identity "GrupoIT" -Members "jperez"
PS> Get-ADGroupMember -Identity "GrupoIT"

# Equipos
PS> Get-ADComputer -Filter * | Select-Object Name, IPv4Address, OperatingSystem
PS> Get-ADComputer -Identity "PC-NOMBRE" -Properties LastLogonDate

# GPO
PS> Get-GPO -All | Select-Object DisplayName, GpoStatus
PS> New-GPO -Name "MiPolitica"
PS> New-GPLink -Name "MiPolitica" -Target "OU=Usuarios,DC=dominio,DC=com"
PS> gpresult /R                       # Políticas aplicadas al usuario/equipo actual
PS> gpupdate /force                   # Forzar actualización de GPOs  🟡
```

### IIS — Internet Information Services

```powershell
# Gestión
PS> Import-Module WebAdministration
PS> Get-Website                        # Sitios web
PS> Start-Website -Name "Default Web Site"
PS> Stop-Website -Name "Default Web Site"
PS> New-Website -Name "MiSitio" -Port 80 -PhysicalPath "C:\inetpub\miSitio"

# Pools de aplicación
PS> Get-WebConfiguration system.applicationHost/applicationPools/add | Select-Object name, state
PS> Restart-WebAppPool -Name "DefaultAppPool"

# Logs IIS
# Ubicación default: C:\inetpub\logs\LogFiles\W3SVC1\
PS> Get-Content "C:\inetpub\logs\LogFiles\W3SVC1\u_ex*.log" | Select-String "500"  # Errores 500

# iisreset (reinicia todo IIS)  🟡
PS> iisreset /restart
PS> iisreset /status
```

---

## Herramientas de Diagnóstico Clásicas (cmd.exe)

```cmd
:: Verificación de archivos del sistema
sfc /scannow
DISM /Online /Cleanup-Image /CheckHealth
DISM /Online /Cleanup-Image /RestoreHealth

:: Red
ipconfig /all
ipconfig /flushdns
netsh winsock reset        :: 🔴 Requiere reinicio
netsh int ip reset         :: 🔴 Requiere reinicio
ping -t host               :: Ping continuo
tracert host               :: Traceroute
nslookup dominio servidor  :: Consulta DNS

:: Rendimiento
perfmon                    :: Performance Monitor (GUI)
resmon                     :: Resource Monitor (GUI)
tasklist /SVC              :: Procesos con servicios asociados
wmic process list brief    :: Lista de procesos vía WMI

:: Tareas programadas
schtasks /query /fo LIST /v  :: Ver todas las tareas
schtasks /create /tn "MiTarea" /tr "C:\script.bat" /sc daily /st 02:00  :: Crear tarea
```

---

## Gestión de Usuarios y Permisos (Local)

```powershell
# Usuarios locales
PS> Get-LocalUser
PS> New-LocalUser -Name "usuario" -Password (Read-Host -AsSecureString) -FullName "Nombre Completo"
PS> Add-LocalGroupMember -Group "Administrators" -Member "usuario"
PS> Remove-LocalGroupMember -Group "Administrators" -Member "usuario"

# Permisos NTFS
PS> Get-Acl "C:\carpeta" | Format-List
PS> $acl = Get-Acl "C:\carpeta"
PS> $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("usuario","FullControl","Allow")
PS> $acl.SetAccessRule($rule)
PS> Set-Acl "C:\carpeta" $acl     # 🟡

# icacls (cmd) — más directo para scripts
icacls "C:\carpeta" /grant "usuario:(OI)(CI)F"  # Full Control, heredado  🟡
icacls "C:\carpeta" /inheritance:d               # Deshabilitar herencia  🟡
icacls "C:\carpeta" /reset /T                    # Reset permisos heredados  🔴
```

---

## BitLocker y Cifrado

```powershell
PS> Get-BitLockerVolume                          # Estado de cifrado por volumen
PS> Enable-BitLocker -MountPoint "C:" -RecoveryPasswordProtector  # 🔴
PS> Suspend-BitLocker -MountPoint "C:"           # 🟡 Suspender temporalmente (para BIOS update)
PS> Resume-BitLocker -MountPoint "C:"
PS> Backup-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId (Get-BitLockerVolume C:).KeyProtector[1].KeyProtectorId
```

---

## Windows Update (PowerShell)

```powershell
# Requiere módulo PSWindowsUpdate
PS> Install-Module PSWindowsUpdate -Force
PS> Get-WindowsUpdate                            # Ver actualizaciones disponibles
PS> Install-WindowsUpdate -AcceptAll -AutoReboot # 🔴
PS> Get-WUHistory                                # Historial de actualizaciones

# Nativo (sin módulo externo)
PS> wuauclt /detectnow                          # Forzar detección
PS> UsoClient StartScan                         # Alternativa moderna
```

---

## Windows 10 Pro — Especialización ⭐

### Identificación de Versión y Build

```powershell
# Identificar versión exacta (SIEMPRE hacer esto primero en Win10)
PS> winver                                                          # GUI con versión y build
PS> (Get-WmiObject Win32_OperatingSystem).Caption                   # "Microsoft Windows 10 Pro"
PS> (Get-WmiObject Win32_OperatingSystem).BuildNumber               # Ej: 19045 = 22H2
PS> (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion  # "22H2"
PS> (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR             # Update Build Revision

# Tabla de referencia de builds relevantes:
# 19041 = 2004  |  19042 = 20H2  |  19043 = 21H1
# 19044 = 21H2  |  19045 = 22H2  (última versión soportada de Win10)
# Fin de soporte Win10: 14 octubre 2025
```

### Group Policy Local — gpedit.msc (exclusivo de Pro)

```cmd
:: Abrir editor de políticas locales
gpedit.msc

:: Forzar aplicación de políticas
gpupdate /force
gpresult /R                        :: Políticas aplicadas al usuario actual
gpresult /H C:\gp-report.html      :: Reporte HTML detallado
```

```powershell
# Políticas útiles vía registro (equivalente a GPO local)
# Deshabilitar telemetría (nivel 0 = Security, solo disponible en Enterprise/Education; en Pro mínimo es 1)
PS> Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 1 -Type DWord  # 🟡

# Deshabilitar actualizaciones automáticas (solo deferir, no bloquear total — Win10 Pro)
PS> Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Type DWord  # 🟡
```

### Windows Update for Business (Win10 Pro)

```powershell
# Ver estado de WU
PS> Get-WindowsUpdateLog                          # Generar log de WU (lo crea en Desktop)
PS> (New-Object -ComObject Microsoft.Update.AutoUpdate).Settings  # Config actual de AU

# Deferir Feature Updates (máx 365 días en Pro)
# vía gpedit: Computer > Admin Templates > Windows Components > Windows Update > Windows Update for Business
# O vía registro:
PS> $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
PS> New-Item -Path $wuPath -Force | Out-Null
PS> Set-ItemProperty -Path $wuPath -Name "DeferFeatureUpdates" -Value 1 -Type DWord         # 🟡
PS> Set-ItemProperty -Path $wuPath -Name "DeferFeatureUpdatesPeriodInDays" -Value 180 -Type DWord  # 🟡

# Deferir Quality Updates (parches, máx 30 días en Pro)
PS> Set-ItemProperty -Path $wuPath -Name "DeferQualityUpdates" -Value 1 -Type DWord         # 🟡
PS> Set-ItemProperty -Path $wuPath -Name "DeferQualityUpdatesPeriodInDays" -Value 7 -Type DWord   # 🟡
```

### Hyper-V en Windows 10 Pro

```powershell
# Habilitar Hyper-V  🔴 Requiere reinicio
PS> Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All

# Verificar que la virtualización está habilitada en CPU
PS> (Get-WmiObject Win32_Processor).VirtualizationFirmwareEnabled
# Si es False → habilitar en BIOS/UEFI (Intel VT-x o AMD-V)

# Gestión básica de VMs
PS> Get-VM                                         # Listar VMs
PS> Start-VM -Name "NombreVM"
PS> Stop-VM -Name "NombreVM" -Force                # 🟡
PS> New-VM -Name "MiVM" -MemoryStartupBytes 2GB -Generation 2 -NewVHDPath "C:\VMs\MiVM.vhdx" -NewVHDSizeBytes 50GB
PS> Set-VMProcessor -VMName "MiVM" -Count 2

# Hyper-V y WSL2 — coexistencia
# WSL2 usa Hyper-V internamente. Si Hyper-V está deshabilitado, WSL2 revierte a WSL1
PS> wsl --status                                   # Ver versión y estado de WSL
```

### WSL2 (Windows Subsystem for Linux)

```powershell
# Instalar WSL2  🟡 Requiere reinicio
PS> wsl --install                                  # Instala WSL2 + Ubuntu por defecto
PS> wsl --install -d Fedora                        # Instalar distro específica

# Gestión
PS> wsl --list --verbose                           # Distros instaladas y versión WSL
PS> wsl --set-default-version 2                    # WSL2 como default para nuevas distros
PS> wsl --set-version Ubuntu 2                     # Convertir distro existente a WSL2  🟡

# Diagnóstico
PS> wsl --status
PS> wsl --update
PS> wsl --shutdown                                 # 🟡 Apagar todas las instancias WSL

# Acceso al filesystem de WSL desde Windows
# \\wsl$\Ubuntu\home\usuario\
# O desde WSL: /mnt/c/ para acceder a C:\
```

### Remote Desktop — RDP (exclusivo de Pro como HOST)

```powershell
# Habilitar RDP  🟡
PS> Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
PS> Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Verificar que RDP está activo
PS> (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
# 0 = habilitado, 1 = deshabilitado

# Puerto RDP (default 3389 — cambiar si hay exposición pública)
PS> (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp").PortNumber

# Cambiar puerto RDP  🟡 (requiere actualizar firewall también)
PS> Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "PortNumber" -Value 3390
PS> New-NetFirewallRule -DisplayName "RDP Custom Port" -Direction Inbound -Protocol TCP -LocalPort 3390 -Action Allow

# Sesiones RDP activas
PS> query session                                  # Ver sesiones activas
PS> logoff <id-sesion>                             # 🟡 Cerrar sesión remota
```

### Problemas Frecuentes y Específicos de Windows 10 Pro

#### Perfil de usuario corrupto

```powershell
# Síntoma: escritorio vacío, configuraciones perdidas, "Perfil temporal"
# Diagnóstico
PS> Get-EventLog -LogName Application -Source "Microsoft-Windows-User Profiles Service" -Newest 10

# Verificar en registro
PS> Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
# Si hay una clave terminada en .bak, hay un perfil corrupto

# Solución: renombrar clave .bak en registro  🔴 Hacer backup del registro primero
# reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" perfil-backup.reg
# Luego en regedit: renombrar la clave S-1-5-21-...-XXXX.bak a S-1-5-21-...-XXXX
# y la original S-1-5-21-...-XXXX a S-1-5-21-...-XXXX.old
```

#### WMI Repository corrupto

```cmd
:: Síntoma: comandos WMI fallan, Get-WmiObject devuelve errores
:: Verificar
winmgmt /verifyrepository

:: Reparar  🔴
net stop winmgmt
winmgmt /resetrepository
net start winmgmt

:: Si falla, reconstruir completo  🔴
winmgmt /salvagerepository
```

#### Windows Search en loop (alto CPU/disco)

```powershell
# Deshabilitar Windows Search temporalmente para diagnóstico
PS> Stop-Service WSearch -Force
PS> Set-Service WSearch -StartupType Disabled   # 🟡

# Reconstruir índice (solución permanente)
# Panel de Control > Opciones de indización > Avanzadas > Reconstruir índice  🟡 (tarda horas)

# O vía PowerShell
PS> $indexer = New-Object -ComObject Microsoft.Search.Index.Manager
# Alternativamente, eliminar el índice directamente
# Ubicación: C:\ProgramData\Microsoft\Search\Data\Applications\Windows\
```

#### Activación KMS en entorno corporativo

```cmd
:: Verificar estado de activación
slmgr /xpr                          :: Fecha de expiración de la licencia
slmgr /dlv                          :: Info detallada de licencia

:: Activar contra servidor KMS corporativo
slmgr /skms servidor-kms.dominio.com:1688   :: 🟡 Configurar servidor KMS
slmgr /ato                                   :: 🟡 Forzar activación

:: Si la activación falla por cambio de hardware
slmgr /rearm                         :: 🟡 Resetear grace period (máx 3 veces)

:: Ver clave de producto (últimos 5 dígitos)
wmic path softwarelicensingservice get OA3xOriginalProductKey
```

#### Actualizaciones que rompen drivers (patrón común en Win10)

```powershell
# Identificar qué actualización causó el problema
PS> Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10

# Desinstalar actualización problemática  🔴
PS> $kb = "KB5012345"
PS> wusa /uninstall /kb:$kb.Replace("KB","") /quiet /norestart

# Bloquear reinstalación de una actualización específica
# Usar "Show or hide updates" troubleshooter (wushowhide.diagcab) — herramienta oficial de MS

# Verificar integridad de drivers
PS> Get-WmiObject Win32_PnPSignedDriver | Where-Object {$_.IsSigned -eq $false} | Select-Object DeviceName, DriverVersion
```

### Windows Sandbox (Win10 Pro)

```powershell
# Habilitar Windows Sandbox  🟡 Requiere reinicio + virtualización habilitada
PS> Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM"

# Lanzar
PS> WindowsSandbox    # o buscar en inicio

# Configuración personalizada (.wsb)
# Crear archivo MiSandbox.wsb:
# <Configuration>
#   <MappedFolders>
#     <MappedFolder>
#       <HostFolder>C:\Tools</HostFolder>
#       <ReadOnly>true</ReadOnly>
#     </MappedFolder>
#   </MappedFolders>
#   <LogonCommand>
#     <Command>explorer.exe C:\Users\WDAGUtilityAccount\Desktop\Tools</Command>
#   </LogonCommand>
# </Configuration>
```

### Assigned Access / Kiosk Mode (exclusivo Pro)

```powershell
# Configurar kiosk de app única para usuario específico
PS> Set-AssignedAccess -AppUserModelId "Microsoft.MicrosoftEdge_8wekyb3d8bbwe!MicrosoftEdge" -UserName "KioskUser"  # 🟡

# Quitar kiosk mode
PS> Clear-AssignedAccess  # 🟡 Requiere reinicio
```
