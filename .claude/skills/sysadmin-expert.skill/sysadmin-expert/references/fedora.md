# Fedora Workstation & Server — Referencia Completa

## Versiones y Variantes

| Variante | Descripción | Gestor de paquetes |
|---|---|---|
| Fedora Workstation | Desktop GNOME, rolling cada ~6 meses | DNF / DNF5 |
| Fedora Server | Sin GUI, para infraestructura | DNF / DNF5 |
| Fedora Silverblue | Immutable desktop, GNOME | rpm-ostree + flatpak |
| Fedora Kinoite | Immutable desktop, KDE | rpm-ostree + flatpak |
| Fedora CoreOS | Para contenedores, auto-actualizante | rpm-ostree |
| Fedora IoT | Dispositivos embebidos | rpm-ostree |

**Ciclo de vida**: Fedora N y N-1 reciben soporte (~13 meses por versión). Fedora N+1 es Rawhide (bleeding edge).

---

## DNF — Gestión de Paquetes

### DNF5 (Fedora 41+) vs DNF4

La sintaxis es mayormente compatible, pero hay diferencias:
```bash
# DNF5 — más rápido, en C++, nuevo backend
dnf5 install paquete          # o simplemente: dnf install (alias)
dnf5 history                  # Historial de transacciones
dnf5 replay <id>              # Reproducir transacción
```

### Comandos Esenciales DNF

```bash
# Instalación y eliminación
# 🟢 Solo consulta
$ dnf info paquete             # Info del paquete
$ dnf search término           # Buscar paquetes
$ dnf provides /ruta/binario   # ¿Qué paquete provee este archivo?
$ dnf repoquery --list paquete # Listar archivos de un paquete

# 🟡 Modifica el sistema
# dnf install paquete          # Instalar
# dnf remove paquete           # Eliminar (--noautoremove para evitar cascada)
# dnf autoremove               # Eliminar dependencias huérfanas
# dnf upgrade                  # Actualizar todo
# dnf upgrade paquete          # Actualizar paquete específico
# dnf downgrade paquete        # Bajar versión

# Historial y rollback
$ dnf history list             # Ver historial de transacciones
# dnf history undo <id>        # 🔴 Revertir transacción específica
# dnf history rollback <id>    # 🔴 Revertir a estado anterior al ID

# Grupos y entornos
$ dnf group list --installed   # Grupos instalados
# dnf group install "Development Tools"

# Cache
# dnf clean all                # 🟡 Limpiar cache completa
$ dnf makecache                # Actualizar metadata de repos
```

### Repositorios

```bash
$ dnf repolist                 # Repos habilitados
$ dnf repolist --all           # Todos los repos (habilitados y no)

# Habilitar/deshabilitar repos
# dnf config-manager --enable rpmfusion-free
# dnf config-manager --disable nombre-repo

# RPM Fusion (multimedia, drivers no-libres)
$ sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# COPR (repositorios de la comunidad, equivalente a PPA)
$ dnf copr enable usuario/proyecto
$ dnf copr list --enabled
```

### RPM — Gestión Directa

```bash
$ rpm -qa                      # Listar todos los paquetes instalados
$ rpm -qi paquete              # Info detallada del paquete
$ rpm -ql paquete              # Archivos del paquete
$ rpm -qf /ruta/archivo        # ¿A qué paquete pertenece este archivo?
$ rpm -qc paquete              # Archivos de configuración del paquete
$ rpm --verify paquete         # Verificar integridad del paquete instalado
# rpm -ivh paquete.rpm         # 🟡 Instalar .rpm directamente
# rpm -e paquete               # 🔴 Eliminar paquete sin verificar deps
```

---

## SELinux — El Guardián Invisible

**REGLA DE ORO**: En Fedora, SELinux está en `enforcing` por defecto. Antes de asumir un bug, verifica SELinux.

### Conceptos Clave

- **Contexto de seguridad**: `usuario:rol:tipo:nivel` (ej: `system_u:object_r:httpd_sys_content_t:s0`)
- **Tipos (domains)**: definen qué puede hacer un proceso (`httpd_t`, `sshd_t`, etc.)
- **AVC denial**: cuando SELinux bloquea una acción, genera un log AVC en `/var/log/audit/audit.log`
- **Boolean**: switches on/off para comportamientos específicos sin escribir políticas

### Diagnóstico SELinux

```bash
# Estado
$ getenforce                   # Enforcing / Permissive / Disabled
$ sestatus                     # Estado detallado

# Ver denegaciones recientes
$ ausearch -m avc -ts recent   # Últimas AVC denials
$ ausearch -m avc -ts today    # AVC denials de hoy
$ journalctl -t audit | grep AVC  # Alternativa vía journald

# Herramienta de análisis (requiere: dnf install setroubleshoot-server)
$ sealert -a /var/log/audit/audit.log   # Análisis con sugerencias
$ sealert -l <uuid>            # Detalle de alerta específica

# Ver contexto de archivos y procesos
$ ls -Z /ruta/archivo          # Contexto de archivo
$ ps -eZ | grep proceso        # Contexto de proceso
$ id -Z                        # Contexto del usuario actual
```

### Soluciones Comunes SELinux

```bash
# Restaurar contexto correcto de archivos (la solución más común)
# 🟡 Restaurar contexto por defecto del directorio
$ sudo restorecon -Rv /ruta/directorio

# Cambiar contexto temporalmente
# $ sudo chcon -t httpd_sys_content_t /ruta/archivo  # 🟡 Temporal (no sobrevive relabel)

# Cambiar contexto de forma permanente
# $ sudo semanage fcontext -a -t httpd_sys_content_t "/ruta(/.*)?"  # 🟡 Permanente
# $ sudo restorecon -Rv /ruta  # Aplicar la regla

# Booleans — activar funcionalidades específicas
$ getsebool -a | grep httpd    # Ver booleans de httpd
$ sudo setsebool -P httpd_can_network_connect on  # 🟡 -P = persistente

# Modo permissive para un dominio específico (sin deshabilitar SELinux global)
# $ sudo semanage permissive -a httpd_t   # 🟡 Solo httpd en permissive
# $ sudo semanage permissive -d httpd_t   # Revertir

# ⚠️ NUNCA como solución permanente:
# setenforce 0  → solo para diagnóstico temporal, siempre revertir
```

### Generar Política Personalizada

```bash
# Método audit2allow — generar política desde denials
$ ausearch -m avc -ts recent | audit2allow -M mi-politica
$ sudo semodule -i mi-politica.pp   # Instalar política
$ sudo semodule -r mi-politica      # Eliminar política
```

---

## Firewalld — Gestión del Firewall

```bash
# Estado y zonas
$ sudo firewall-cmd --state                    # ¿Activo?
$ sudo firewall-cmd --get-active-zones         # Zonas activas
$ sudo firewall-cmd --list-all                 # Reglas zona activa
$ sudo firewall-cmd --list-all --zone=public   # Zona específica

# Abrir/cerrar servicios y puertos
# 🟡 Temporal (hasta reinicio)
$ sudo firewall-cmd --add-service=http
$ sudo firewall-cmd --add-port=8080/tcp

# 🟡 Permanente (con --permanent + reload)
$ sudo firewall-cmd --permanent --add-service=http
$ sudo firewall-cmd --permanent --add-port=8080/tcp
$ sudo firewall-cmd --reload

# Eliminar reglas
# $ sudo firewall-cmd --permanent --remove-service=http
# $ sudo firewall-cmd --permanent --remove-port=8080/tcp

# Rich rules (reglas más complejas)
$ sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" service name="ssh" accept'

# Servicios disponibles
$ firewall-cmd --get-services
$ cat /usr/lib/firewalld/services/http.xml   # Definición de servicio
```

---

## Btrfs — Sistema de Archivos Default

```bash
# Información del filesystem
$ sudo btrfs filesystem show /
$ sudo btrfs filesystem df /        # Uso real (distinto de df -h en Btrfs)
$ sudo btrfs filesystem usage /     # Detalle de uso

# Subvolúmenes (Fedora usa @ y @home por defecto)
$ sudo btrfs subvolume list /
$ sudo btrfs subvolume show /

# Snapshots
$ sudo btrfs subvolume snapshot / /snapshots/root-$(date +%Y%m%d)  # 🟡
$ sudo btrfs subvolume delete /snapshots/nombre  # 🔴

# Balance y scrub
$ sudo btrfs scrub start /          # 🟡 Verificar integridad (background)
$ sudo btrfs scrub status /
$ sudo btrfs balance start /        # 🔴 Puede tardar horas en discos grandes

# Compresión (Fedora activa zstd por defecto)
$ sudo compsize /                   # Ver ratio de compresión (dnf install compsize)
```

---

## Systemd — Gestión de Servicios

```bash
# Servicios
$ systemctl status servicio
$ sudo systemctl start|stop|restart|reload servicio
$ sudo systemctl enable|disable servicio          # Persistir entre reinicios
$ sudo systemctl enable --now servicio            # Habilitar e iniciar
$ systemctl list-units --type=service --state=failed

# Timers (reemplazo de cron)
$ systemctl list-timers --all
$ sudo systemctl enable --now nombre.timer

# Targets (equivalente a runlevels)
$ systemctl get-default
$ sudo systemctl set-default multi-user.target    # Server sin GUI
$ sudo systemctl set-default graphical.target     # Con GUI
$ sudo systemctl isolate rescue.target            # 🔴 Modo rescate inmediato

# Análisis de arranque
$ systemd-analyze                  # Tiempo total de arranque
$ systemd-analyze blame            # Servicios más lentos
$ systemd-analyze critical-chain   # Ruta crítica de arranque

# Journald — logs
$ journalctl -xe                   # Logs recientes con contexto
$ journalctl -u servicio.service -f  # Follow en tiempo real
$ journalctl -p err                  # Solo errores
$ journalctl --since "2024-01-01" --until "2024-01-02"
$ journalctl --disk-usage           # Espacio usado por logs
$ sudo journalctl --vacuum-size=500M  # 🟡 Liberar espacio de logs
```

---

## Podman — Contenedores en Fedora

Podman es el reemplazo de Docker en el ecosistema Fedora/RHEL. **Rootless por defecto**.

```bash
# Equivalente a Docker casi 1:1
$ podman pull imagen:tag
$ podman run -d --name mi-contenedor -p 8080:80 imagen
$ podman ps                        # Contenedores activos
$ podman ps -a                     # Todos
$ podman logs mi-contenedor
$ podman exec -it mi-contenedor bash

# Diferencias clave vs Docker
$ podman generate systemd --new --name mi-contenedor > ~/.config/systemd/user/mi-contenedor.service
$ systemctl --user enable --now mi-contenedor.service  # Contenedor como servicio

# Pods (grupo de contenedores)
$ podman pod create --name mi-pod -p 8080:80
$ podman run -d --pod mi-pod imagen

# Compose (requiere: dnf install podman-compose)
$ podman-compose up -d
$ podman-compose down
```

---

## NetworkManager — Redes

```bash
# Estado
$ nmcli device status
$ nmcli connection show
$ nmcli general status

# Gestión de conexiones
$ nmcli connection up|down nombre-conexion
$ nmcli connection add type ethernet ifname eth0 con-name "mi-red"
$ nmcli connection modify "mi-red" ipv4.addresses "192.168.1.100/24"
$ nmcli connection modify "mi-red" ipv4.gateway "192.168.1.1"
$ nmcli connection modify "mi-red" ipv4.dns "1.1.1.1 8.8.8.8"
$ nmcli connection modify "mi-red" ipv4.method manual

# WiFi
$ nmcli device wifi list
$ nmcli device wifi connect "SSID" password "clave"

# DNS (systemd-resolved integrado)
$ resolvectl status
$ resolvectl query dominio.com
```

---

## Cockpit — Administración Web (Fedora Server)

```bash
# Instalar y activar
$ sudo dnf install cockpit cockpit-podman cockpit-networkmanager
$ sudo systemctl enable --now cockpit.socket
$ sudo firewall-cmd --permanent --add-service=cockpit && sudo firewall-cmd --reload

# Acceso: https://IP-servidor:9090
# Se autentica con usuario del sistema (root o con sudo)

# Módulos adicionales
$ sudo dnf install cockpit-storaged    # Gestión de almacenamiento
$ sudo dnf install cockpit-composer    # Construcción de imágenes
$ sudo dnf install cockpit-machines    # Gestión de VMs (KVM)
```

---

## Actualización de Versión de Fedora

```bash
# Método oficial: dnf-plugin-system-upgrade
$ sudo dnf upgrade --refresh                   # 🟡 Actualizar sistema actual primero
$ sudo dnf install dnf-plugin-system-upgrade
$ sudo dnf system-upgrade download --releasever=41  # 🟡 Descargar paquetes nueva versión
$ sudo dnf system-upgrade reboot               # 🔴 Reinicia y actualiza (sin vuelta atrás fácil)

# Verificar post-upgrade
$ rpm -Va --nofiles --nodigest 2>/dev/null     # Verificar integridad de paquetes
$ sudo dnf distro-sync                         # Sincronizar posibles conflictos residuales
```

---

## Flatpak (Aplicaciones Sandbox)

```bash
$ flatpak list                         # Aplicaciones instaladas
$ flatpak search nombre                # Buscar
$ flatpak install flathub com.app.Nombre
$ flatpak update                       # Actualizar todo
$ flatpak uninstall com.app.Nombre
$ flatpak override --user --filesystem=home com.app.Nombre  # Dar acceso al home
$ flatpak override --user --reset com.app.Nombre            # Resetear permisos
```
