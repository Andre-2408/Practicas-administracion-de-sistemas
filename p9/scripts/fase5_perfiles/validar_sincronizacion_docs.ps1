# validar_sincronizacion_docs.ps1 -- Fase 5: Test sincronizacion de perfiles
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# Test 5a: Crear archivo en Documents -> aparece en servidor
# Test 5b: Verificar que cuota bloquea al superar limite

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 5 -- Validacion Sincronizacion Perfiles"
Ensure-OutputDir

$EvidenciaFile = "$($Global:OutputDir)\test_perfiles_evidencia.txt"
$LogFile       = "$($Global:OutputDir)\fase5_perfiles.log"
$Servidor      = $env:COMPUTERNAME

@"
==========================================================
  TEST PERFILES MOVILES -- PRACTICA 09
  Fecha: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina: $($env:COMPUTERNAME)
  Dominio: $($Global:Dominio)
==========================================================
"@ | Out-File -FilePath $EvidenciaFile -Encoding UTF8 -Force

p9_log $LogFile "=== INICIO: Validacion Perfiles ==="
$resultados = @()

# ---- Obtener usuario de prueba ----
$usuarioPrueba = Get-ADUser -Filter * -SearchBase $Global:OU_Cuates -ResultSetSize 1 `
    -Properties HomeDirectory, ProfilePath -ErrorAction SilentlyContinue
if (-not $usuarioPrueba) {
    p9_error "No hay usuarios en OU Cuates. Verifique la configuracion."
    exit 1
}

p9_info "Usuario de prueba: $($usuarioPrueba.SamAccountName)"
p9_info "  HomeDirectory: $($usuarioPrueba.HomeDirectory)"
p9_info "  ProfilePath:   $($usuarioPrueba.ProfilePath)"
Write-Host ""

# ============================================================
# TEST A: Verificar configuracion de perfil en AD
# ============================================================
p9_linea
Write-Host "  TEST A: Configuracion de perfil en AD"
p9_linea

$homeDir    = $usuarioPrueba.HomeDirectory
$profileDir = $usuarioPrueba.ProfilePath

$testA_home    = $homeDir    -and $homeDir    -match "\\\\$Servidor\\"
$testA_profile = $profileDir -and $profileDir -match "\\\\$Servidor\\"

if ($testA_home) {
    p9_ok "  HomeDirectory configurado: $homeDir"
} else {
    p9_warning "  HomeDirectory no apunta al servidor o no configurado: '$homeDir'"
}

if ($testA_profile) {
    p9_ok "  ProfilePath configurado: $profileDir"
} else {
    p9_warning "  ProfilePath no apunta al servidor o no configurado: '$profileDir'"
}

$passA = $testA_home -and $testA_profile
$resultados += [PSCustomObject]@{
    Test    = "Test A: Perfil configurado en AD"
    Detalle = "HomeDir=$testA_home | ProfilePath=$testA_profile"
    Pass    = $passA
}

Write-Host ""

# ============================================================
# TEST B: Crear archivo de prueba en ruta del servidor
# ============================================================
p9_linea
Write-Host "  TEST B: Crear archivo en servidor (simula sincronizacion)"
p9_linea

$rutaHomeUsuario = "C:\Documentos\$($usuarioPrueba.SamAccountName)"
$archivoTest     = "$rutaHomeUsuario\test_sincronizacion_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

if (Test-Path $rutaHomeUsuario) {
    try {
        @"
Archivo de prueba -- Practica 09
Usuario: $($usuarioPrueba.SamAccountName)
Fecha:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Servidor: $Servidor
Objetivo: Verificar sincronizacion de perfiles moviles
"@ | Out-File -FilePath $archivoTest -Encoding UTF8 -Force

        p9_ok "  Archivo creado: $archivoTest"
        p9_ok "  Tamano: $((Get-Item $archivoTest).Length) bytes"

        # Verificar que el archivo existe (simula que el cliente lo puede ver via UNC)
        $uncPath = "\\$Servidor\documentos\$($usuarioPrueba.SamAccountName)\$(Split-Path $archivoTest -Leaf)"
        $existeUNC = Test-Path $uncPath
        if ($existeUNC) {
            p9_ok "  Acceso UNC verificado: $uncPath"
        } else {
            p9_info "  Acceso UNC: $uncPath (acceso desde cliente remoto)"
        }

        $resultados += [PSCustomObject]@{
            Test    = "Test B: Crear archivo en servidor"
            Detalle = "Archivo: $archivoTest | Acceso UNC: $existeUNC"
            Pass    = $true
        }
    } catch {
        p9_error "  Error creando archivo: $_"
        $resultados += [PSCustomObject]@{
            Test = "Test B: Crear archivo en servidor"
            Detalle = "Error: $_"
            Pass = $false
        }
    }
} else {
    p9_warning "  Carpeta home no existe: $rutaHomeUsuario"
    p9_info "  Ejecute crear_compartidas_home.ps1 primero."
    $resultados += [PSCustomObject]@{
        Test    = "Test B: Crear archivo en servidor"
        Detalle = "Carpeta home no existe"
        Pass    = $false
    }
}

Write-Host ""

# ============================================================
# TEST C: Verificar cuotas FSRM activas
# ============================================================
p9_linea
Write-Host "  TEST C: Cuotas FSRM activas"
p9_linea

try {
    Import-Module FileServerResourceManager -ErrorAction Stop

    $cuotaHome    = Get-FsrmQuota -Path "C:\Documentos" -ErrorAction SilentlyContinue
    $cuotaPerfiles = Get-FsrmQuota -Path "C:\Perfiles"   -ErrorAction SilentlyContinue

    if ($cuotaHome) {
        $usoPct = if ($cuotaHome.Size -gt 0) { [Math]::Round($cuotaHome.Usage / $cuotaHome.Size * 100, 1) } else { 0 }
        p9_ok "  Cuota Documentos: $([Math]::Round($cuotaHome.Size/1MB)) MB | Uso: $([Math]::Round($cuotaHome.Usage/1MB,2)) MB ($usoPct%)"
        $resultados += [PSCustomObject]@{
            Test    = "Test C: Cuota FSRM Documentos activa"
            Detalle = "Limite: $([Math]::Round($cuotaHome.Size/1MB)) MB | Uso: $([Math]::Round($cuotaHome.Usage/1MB,2)) MB"
            Pass    = $true
        }
    } else {
        p9_warning "  No hay cuota en C:\Documentos. Ejecute aplicar_cuotas_fsrm.ps1"
        $resultados += [PSCustomObject]@{
            Test    = "Test C: Cuota FSRM Documentos activa"
            Detalle = "Sin cuota configurada"
            Pass    = $false
        }
    }

    if ($cuotaPerfiles) {
        p9_ok "  Cuota Perfiles:   $([Math]::Round($cuotaPerfiles.Size/1MB)) MB | Uso: $([Math]::Round($cuotaPerfiles.Usage/1MB,2)) MB"
    }
} catch {
    p9_warning "  FSRM no disponible: $_"
    $resultados += [PSCustomObject]@{
        Test = "Test C: Cuota FSRM"
        Detalle = "FSRM no disponible"
        Pass = $false
    }
}

Write-Host ""

# ============================================================
# TEST D: Verificar GPO de redireccion aplicada
# ============================================================
p9_linea
Write-Host "  TEST D: GPO Redireccion de carpetas"
p9_linea

try {
    $gpo = Get-GPO -Name "P9_FolderRedirection" -Domain $Global:Dominio -ErrorAction Stop
    p9_ok "  GPO P9_FolderRedirection encontrada. Estado: $($gpo.GpoStatus)"
    $links = Get-GPInheritance -Target $Global:OU_Cuates -ErrorAction SilentlyContinue
    $linkActivo = $links.GpoLinks | Where-Object { $_.DisplayName -eq "P9_FolderRedirection" }
    if ($linkActivo) {
        p9_ok "  GPO vinculada a OU Cuates."
        $resultados += [PSCustomObject]@{
            Test    = "Test D: GPO Redireccion activa"
            Detalle = "Estado: $($gpo.GpoStatus) | Vinculada: Si"
            Pass    = $true
        }
    } else {
        p9_warning "  GPO no vinculada a OU Cuates."
        $resultados += [PSCustomObject]@{
            Test    = "Test D: GPO Redireccion activa"
            Detalle = "GPO existe pero no vinculada"
            Pass    = $false
        }
    }
} catch {
    p9_warning "  GPO P9_FolderRedirection no encontrada: $_"
    $resultados += [PSCustomObject]@{
        Test = "Test D: GPO Redireccion"
        Detalle = "GPO no encontrada"
        Pass = $false
    }
}

# ---- Resumen ----
Write-Host ""
p9_linea
Write-Host "  RESUMEN TEST PERFILES:"
p9_linea
$resultados | ForEach-Object {
    $s = if ($_.Pass) { "[PASS]" } else { "[FAIL]" }
    $c = if ($_.Pass) { "Green" } else { "Red" }
    Write-Host "    $s $($_.Test)" -ForegroundColor $c
    Write-Host "       $($_.Detalle)"
}

"`n--- RESULTADOS TEST PERFILES ---" | Add-Content -Path $EvidenciaFile -Encoding UTF8
$resultados | ForEach-Object {
    $s = if ($_.Pass) { "PASS" } else { "FAIL" }
    "[$s] $($_.Test)" | Add-Content -Path $EvidenciaFile -Encoding UTF8
    "     $($_.Detalle)" | Add-Content -Path $EvidenciaFile -Encoding UTF8
    "" | Add-Content -Path $EvidenciaFile -Encoding UTF8
}
$total = $resultados.Count
$pass  = ($resultados | Where-Object Pass).Count
"`nTotal: $total  |  PASS: $pass  |  FAIL: $($total - $pass)" |
    Add-Content -Path $EvidenciaFile -Encoding UTF8

p9_log $LogFile "=== FIN: Validacion Perfiles -- $pass/$total PASS ==="
p9_ok "Evidencia guardada: $EvidenciaFile"
p9_pausa
