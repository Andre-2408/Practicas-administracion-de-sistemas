# helpers.ps1 -- Funciones compartidas Practica 9
# Incluir con: . "$PSScriptRoot\..\helpers.ps1"

# ============================================================
# VARIABLES GLOBALES -- AJUSTAR SEGUN EL ENTORNO
# ============================================================
$Global:DominioDN   = "DC=p8,DC=local"
$Global:Dominio     = "p8.local"
$Global:NetBIOS     = "P8"
$Global:AdminPass   = "Admin@12345!"
$Global:OutputDir   = "C:\P9\output"

# OUs base (heredadas de p8)
$Global:OU_Cuates   = "OU=Cuates,$($Global:DominioDN)"
$Global:OU_NoCuates = "OU=NoCuates,$($Global:DominioDN)"
$Global:OU_Admins   = "OU=Administradores,$($Global:DominioDN)"

# Usuarios admin p9
$Global:AdminUsers  = @(
    @{ Usuario="admin_identidad";  Nombre="Admin";  Apellido="Identidad";  Rol="IAM Operator"      },
    @{ Usuario="admin_storage";    Nombre="Admin";  Apellido="Storage";    Rol="Storage Operator"  },
    @{ Usuario="admin_politicas";  Nombre="Admin";  Apellido="Politicas";  Rol="GPO Compliance"    },
    @{ Usuario="admin_auditoria";  Nombre="Admin";  Apellido="Auditoria";  Rol="Security Auditor"  }
)

# ============================================================
# HELPERS DE OUTPUT
# ============================================================
function p9_info    { param($m) Write-Host "  [INFO]    $m" }
function p9_ok      { param($m) Write-Host "  [OK]      $m" -ForegroundColor Green }
function p9_error   { param($m) Write-Host "  [ERROR]   $m" -ForegroundColor Red }
function p9_warning { param($m) Write-Host "  [AVISO]   $m" -ForegroundColor Yellow }
function p9_linea   { Write-Host "  ----------------------------------------------------------" }

function p9_banner {
    param([string]$Titulo = "Practica 09 -- Seguridad de Identidad, Delegacion y MFA")
    Write-Host ""
    Write-Host "  =========================================================="
    Write-Host "    $Titulo"
    Write-Host "  =========================================================="
    Write-Host ""
}

function p9_pausa {
    Write-Host ""
    Write-Host "  Presione ENTER para continuar..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function p9_log {
    param([string]$Archivo, [string]$Mensaje)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea = "[$timestamp] $Mensaje"
    Add-Content -Path $Archivo -Value $linea -Encoding UTF8
}

function Ensure-OutputDir {
    if (-not (Test-Path $Global:OutputDir)) {
        New-Item -ItemType Directory -Path $Global:OutputDir -Force | Out-Null
        p9_info "Directorio de output creado: $($Global:OutputDir)"
    }
}
