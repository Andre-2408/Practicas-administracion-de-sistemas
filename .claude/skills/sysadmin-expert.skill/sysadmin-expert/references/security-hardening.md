# Security Hardening — Checklist Cross-Platform

## Linux (Fedora / RHEL Focus)

### SSH Hardening

```bash
# /etc/ssh/sshd_config — cambios mínimos recomendados
PermitRootLogin no
PasswordAuthentication no        # Solo keys
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers usuario1 usuario2     # Whitelist explícita
Protocol 2
X11Forwarding no
```

```bash
# Aplicar cambios y verificar  🟡
$ sudo sshd -t                  # Test de configuración ANTES de reiniciar
$ sudo systemctl reload sshd    # Reload sin cerrar sesiones activas
```

### Auditoría y Logging

```bash
# auditd — framework de auditoría del kernel
$ sudo systemctl enable --now auditd
$ sudo auditctl -l              # Reglas activas

# Reglas de auditoría útiles (en /etc/audit/rules.d/audit.rules)
# -w /etc/passwd -p wa -k identity
# -w /etc/sudoers -p wa -k privilege_escalation
# -w /var/log/sudo.log -p wa -k sudo_log
# -a always,exit -F arch=b64 -S execve -k exec_commands

$ sudo ausearch -k identity -ts today    # Cambios en /etc/passwd hoy
$ sudo aureport --login                  # Resumen de logins
```

### fail2ban / firewalld como IPS básico

```bash
$ sudo dnf install fail2ban
$ sudo systemctl enable --now fail2ban

# /etc/fail2ban/jail.local
# [sshd]
# enabled = true
# maxretry = 3
# bantime = 3600
# findtime = 600

$ sudo fail2ban-client status sshd      # Estado de la cárcel SSH
$ sudo fail2ban-client set sshd unbanip 1.2.3.4  # Desbanear IP específica
```

### Actualizaciones de Seguridad Automáticas

```bash
$ sudo dnf install dnf-automatic

# /etc/dnf/automatic.conf
# apply_updates = yes
# upgrade_type = security       # Solo parches de seguridad

$ sudo systemctl enable --now dnf-automatic.timer
```

### Verificación de Integridad

```bash
# AIDE — detector de cambios en archivos (IDS host-based)
$ sudo dnf install aide
$ sudo aide --init              # Crear base de datos inicial  🟡 (puede tardar)
$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
$ sudo aide --check             # Comparar contra base de datos  🟢

# Verificar binarios del sistema
$ rpm -Va                       # Verificar TODOS los paquetes (lento)
$ rpm -Va --nodeps --nofiles    # Sin verificar archivos (rápido)
```

---

## Windows Hardening

### Configuración Base

```powershell
# Deshabilitar SMBv1 (vulnerable a EternalBlue/WannaCry)
PS> Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force   # 🟡
PS> Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol

# Windows Defender
PS> Get-MpComputerStatus            # Estado de Defender
PS> Update-MpSignature              # Actualizar definiciones
PS> Start-MpScan -ScanType QuickScan

# Políticas de contraseña (local)
PS> net accounts /minpwlen:12 /maxpwage:90 /minpwage:1 /uniquepw:10   # 🟡

# Auditoría de seguridad
PS> auditpol /get /category:*       # Ver políticas de auditoría actuales
PS> auditpol /set /subcategory:"Logon" /success:enable /failure:enable   # 🟡
```

### Análisis de Seguridad Rápido

```powershell
# Usuarios con privilegios elevados
PS> Get-LocalGroupMember -Group "Administrators"
PS> net localgroup administrators

# Servicios corriendo como SYSTEM (revisar los no-Microsoft)
PS> Get-WmiObject Win32_Service | Where-Object {$_.StartName -eq 'LocalSystem'} | Select-Object Name, PathName

# Scheduled tasks sospechosas (no firmadas por Microsoft)
PS> Get-ScheduledTask | Where-Object {$_.Principal.UserId -notin @('SYSTEM','LOCAL SERVICE','NETWORK SERVICE')} | Select-Object TaskName, TaskPath

# Conexiones de red activas con proceso
PS> Get-NetTCPConnection -State Established | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess | Sort-Object RemoteAddress
```

### Windows Firewall Hardening

```powershell
# Bloquear todo el tráfico entrante excepto lo explícitamente permitido
PS> Set-NetFirewallProfile -Profile Domain,Public,Private -DefaultInboundAction Block -DefaultOutboundAction Allow  # 🟡

# Deshabilitar reglas innecesarias (ejemplo: File and Printer Sharing si no se usa)
PS> Disable-NetFirewallRule -DisplayGroup "File and Printer Sharing"  # 🟡
```

---

## Principios Generales de Hardening

1. **Principio de mínimo privilegio**: cada proceso/usuario solo tiene los permisos necesarios
2. **Reducción de superficie de ataque**: deshabilitar servicios no usados, cerrar puertos innecesarios
3. **Defense in depth**: múltiples capas de seguridad (firewall + SELinux + auditoría + IDS)
4. **Monitoreo continuo**: logs centralizados, alertas en tiempo real
5. **Patch management**: actualizaciones de seguridad aplicadas en <30 días (críticas: <7 días)
6. **Backups verificados**: backup 3-2-1, prueba de restauración periódica
7. **Segmentación de red**: VLANs, DMZ para servicios expuestos

---

## Checklist Rápido Post-Instalación (Fedora Server)

```bash
# 1. Actualizar todo
$ sudo dnf upgrade -y

# 2. Instalar herramientas de seguridad
$ sudo dnf install -y fail2ban audit aide dnf-automatic setroubleshoot-server

# 3. Configurar SSH (deshabilitar password auth, cambiar puerto si aplica)
# Editar /etc/ssh/sshd_config

# 4. Habilitar y configurar firewalld
$ sudo systemctl enable --now firewalld
$ sudo firewall-cmd --set-default-zone=drop        # Zona más restrictiva

# 5. Verificar SELinux
$ getenforce    # Debe ser Enforcing

# 6. Configurar actualizaciones automáticas de seguridad
# Editar /etc/dnf/automatic.conf: upgrade_type = security

# 7. Configurar auditoría
$ sudo systemctl enable --now auditd

# 8. Crear usuario no-root con sudo en lugar de usar root directamente
$ sudo useradd -m -G wheel admin-usuario
$ sudo passwd admin-usuario
```
