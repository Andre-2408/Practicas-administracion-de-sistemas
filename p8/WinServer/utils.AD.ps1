# utils.AD.ps1 -- Constantes globales y helpers compartidos para Active Directory (Practica 8)

if ($Script:_AD_UTILS_CARGADO) { return }
$Script:_AD_UTILS_CARGADO = $true

# ------------------------------------------------------------
# Configuracion del dominio -- AJUSTAR SEGUN EL ENTORNO
# ------------------------------------------------------------

$Script:AD_DOMINIO        = "p8.local"
$Script:AD_NETBIOS        = "P8"
$Script:AD_DC_NOMBRE      = "DC01"                          # Nombre NetBIOS del DC
$Script:AD_ADMIN          = "Administrator"

# DNs del dominio
$Script:AD_DN_DOMINIO     = "DC=p8,DC=local"
$Script:AD_OU_CUATES      = "OU=Cuates,DC=p8,DC=local"
$Script:AD_OU_NOCUATES    = "OU=NoCuates,DC=p8,DC=local"

# Grupos de seguridad
$Script:AD_GRUPO_CUATES   = "GRP_Cuates"
$Script:AD_GRUPO_NOCUATES = "GRP_NoCuates"

# Directorios personales (home directories)
$Script:AD_HOME_RAIZ      = "C:\Homes"                      # Ruta local en el servidor
$Script:AD_HOME_SHARE     = "Homes"                         # Nombre del recurso compartido
$Script:AD_HOME_UNC       = "\\$($Script:AD_DC_NOMBRE)\Homes"  # Ruta UNC para los usuarios

# Ruta del CSV con usuarios
$Script:AD_CSV_PATH       = "$PSScriptRoot\data\usuarios.csv"

# ------------------------------------------------------------
# Configuracion de horarios de acceso (hora local)
# ------------------------------------------------------------

$Script:AD_UTC_OFFSET           = -6   # UTC-6 (Mexico Centro, CST)
                                       # Cambiar a -5 si DST esta activo (CDT)

$Script:AD_CUATES_HORA_INICIO   = 8    #  8:00 AM (hora local)
$Script:AD_CUATES_HORA_FIN      = 15   #  3:00 PM (hora local, exclusivo)

$Script:AD_NOCUATES_HORA_INICIO = 15   #  3:00 PM (hora local)
$Script:AD_NOCUATES_HORA_FIN    = 2    #  2:00 AM (hora local, exclusivo, cruza medianoche)

# ------------------------------------------------------------
# Configuracion de cuotas FSRM (en bytes)
# ------------------------------------------------------------

$Script:AD_CUOTA_CUATES         = 10MB   # = 10485760 bytes
$Script:AD_CUOTA_NOCUATES       = 5MB    # =  5242880 bytes

# Nombres de plantillas FSRM
$Script:AD_FSRM_TPL_CUOTAS_CUATES   = "P8-Cuota-10MB"
$Script:AD_FSRM_TPL_CUOTAS_NOCUATES = "P8-Cuota-5MB"
$Script:AD_FSRM_GRUPO_BLOQUEADOS    = "P8-ArchivosProhibidos"
$Script:AD_FSRM_TPL_PANTALLA        = "P8-Pantalla-Activa"

# Extensiones bloqueadas por el apantallamiento activo
$Script:AD_FSRM_EXTENSIONES_BLOQUEADAS = @(
    "*.mp3", "*.mp4",         # Multimedia
    "*.exe", "*.msi"          # Ejecutables / instaladores
)

# ------------------------------------------------------------
# Configuracion de AppLocker
# ------------------------------------------------------------

$Script:AD_APPLOCKER_NOTEPAD    = "$env:SystemRoot\System32\notepad.exe"
$Script:AD_GPO_APPLOCKER        = "P8-AppLocker"
$Script:AD_GPO_SEGURIDAD        = "P8-Seguridad"

# ------------------------------------------------------------
# Helper: detectar DC actual
# ------------------------------------------------------------

function _ad_detectar_dc {
    try {
        $dc = Get-ADDomainController -Discover -ErrorAction SilentlyContinue
        if ($dc) { return $dc.HostName[0] }
    } catch {}
    return $Script:AD_DC_NOMBRE
}

# ------------------------------------------------------------
# Helpers de output (estilo p7)
# ------------------------------------------------------------

function aputs_info    { param($m) Write-Host "  [INFO]    $m" }
function aputs_ok      { param($m) Write-Host "  [OK]      $m" }
function aputs_success { param($m) Write-Host "  [OK]      $m" }
function aputs_error   { param($m) Write-Host "  [ERROR]   $m" }
function aputs_warning { param($m) Write-Host "  [AVISO]   $m" }

function draw_line {
    Write-Host "  ----------------------------------------------------------"
}

function pause {
    Write-Host ""
    Write-Host "  Presione ENTER para continuar..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function ad_mostrar_banner {
    param([string]$Titulo = "Practica 08 -- Gobernanza y Control AD")
    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    $Titulo"
    Write-Host "  =========================================================="
    Write-Host ""
}

# ------------------------------------------------------------
# Helper: verificar que el modulo AD esta disponible
# ------------------------------------------------------------

function ad_verificar_modulo_ad {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop | Out-Null
        return $true
    } catch {
        aputs_error "Modulo ActiveDirectory no disponible"
        aputs_info  "Instale RSAT o ejecute desde un controlador de dominio"
        return $false
    }
}

# ------------------------------------------------------------
# Helper: calcular array de bytes para LogonHours de AD
#
#   El array de 21 bytes (168 bits) representa los 7 dias x 24 horas
#   en UTC. El bit 0 = Domingo 00:00 UTC, bit 1 = Domingo 01:00 UTC, etc.
#   Dentro de cada byte, el bit de menor peso (LSB) corresponde a la
#   hora mas temprana.
# ------------------------------------------------------------

function ad_calcular_bytes_horario {
    param(
        [int]$HoraInicioLocal,   # Hora de inicio permitida (local, 0-23)
        [int]$HoraFinLocal,      # Hora de fin exclusiva (local, 0-23)
        [int]$OffsetUTC          # Desfase UTC (ej. -6 para UTC-6 / CST)
    )

    $bytes = New-Object byte[] 21

    for ($diaLocal = 0; $diaLocal -lt 7; $diaLocal++) {
        for ($horaLocal = 0; $horaLocal -lt 24; $horaLocal++) {

            # Determinar si la hora esta dentro del rango permitido
            $permitida = $false
            if ($HoraInicioLocal -lt $HoraFinLocal) {
                # Rango normal sin cruzar medianoche (ej. 8-15)
                $permitida = ($horaLocal -ge $HoraInicioLocal) -and ($horaLocal -lt $HoraFinLocal)
            } else {
                # Rango que cruza medianoche (ej. 15-2: 15,16,...,23,0,1)
                $permitida = ($horaLocal -ge $HoraInicioLocal) -or ($horaLocal -lt $HoraFinLocal)
            }

            if ($permitida) {
                # Convertir hora local a UTC
                # Para UTC-6: utcRaw = horaLocal + 6
                $utcRaw    = $horaLocal - $OffsetUTC
                $horaUTC   = (($utcRaw % 24) + 24) % 24
                $diaOffset = [Math]::Floor($utcRaw / 24)
                $diaUTC    = (($diaLocal + $diaOffset) % 7 + 7) % 7

                # Calcular posicion del bit y aplicarlo
                $bitPos  = $diaUTC * 24 + $horaUTC
                $byteIdx = [Math]::Floor($bitPos / 8)
                $bitIdx  = $bitPos % 8
                $bytes[$byteIdx] = [byte]($bytes[$byteIdx] -bor (1 -shl $bitIdx))
            }
        }
    }

    return $bytes
}

# ------------------------------------------------------------
# Helper: obtener SID de un grupo de AD
# ------------------------------------------------------------

function ad_obtener_sid_grupo {
    param([string]$NombreGrupo)
    try {
        $grupo = Get-ADGroup -Identity $NombreGrupo -ErrorAction Stop
        return $grupo.SID.Value
    } catch {
        aputs_error "No se pudo obtener SID del grupo '$NombreGrupo': $_"
        return $null
    }
}
