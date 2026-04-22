# main.ps1 -- Script maestro Practica 09
# Seguridad de Identidad, Delegacion y MFA
# Ejecuta las 6 fases en orden con menu interactivo

. "$PSScriptRoot\helpers.ps1"

function Show-Menu {
    p9_banner "Practica 09 -- Seguridad de Identidad, Delegacion y MFA"
    Write-Host "  MENU PRINCIPAL"
    p9_linea
    Write-Host "  [1] FASE 1 - Auditoria Base (prerequisito)"
    Write-Host "       -> harvesting_eventos | inventario_usuarios_ous | validar_applocker"
    Write-Host ""
    Write-Host "  [2] FASE 2 - RBAC + Delegacion (bloqueante para Fase 4)"
    Write-Host "       -> crear_4_usuarios_admin | aplicar_acls_* | validar_permisos"
    Write-Host ""
    Write-Host "  [3] FASE 3 - FGPP Politicas de Contrasena (paralela)"
    Write-Host "       -> crear_fgpp_admins | crear_fgpp_usuarios | validar_fgpp"
    Write-Host ""
    Write-Host "  [4] FASE 4 - MFA Google Authenticator (requiere Fase 2)"
    Write-Host "       -> instalar_winotp | generar_secrets | crear_qr | lockout | validar"
    Write-Host ""
    Write-Host "  [5] FASE 5 - Perfiles Moviles (paralela)"
    Write-Host "       -> compartidas_perfil | compartidas_home | gpo_redirecciones | cuotas | validar"
    Write-Host ""
    Write-Host "  [6] FASE 6 - Auditoria Avanzada (final)"
    Write-Host "       -> config_auditpol | extraccion_4625 | reporte_final"
    Write-Host ""
    Write-Host "  [A] Ejecutar TODAS las fases en orden"
    Write-Host "  [R] Generar Reporte Final"
    Write-Host "  [Q] Salir"
    p9_linea
    Write-Host ""
}

function Invoke-Fase {
    param([string]$Fase, [string[]]$Scripts)
    p9_banner "Ejecutando: $Fase"
    foreach ($script in $Scripts) {
        p9_info "Ejecutando: $script"
        p9_linea
        try {
            & $script
        } catch {
            p9_error "Error en $script : $_"
            p9_warning "Continuando con el siguiente script..."
        }
        Write-Host ""
    }
    p9_ok "$Fase completada."
}

# ---- Rutas de scripts ----
$base = $PSScriptRoot

$fase1 = @(
    "$base\fase1_auditoria\harvesting_eventos.ps1",
    "$base\fase1_auditoria\inventario_usuarios_ous.ps1",
    "$base\fase1_auditoria\validar_applocker.ps1"
)
$fase2 = @(
    "$base\fase2_rbac\crear_4_usuarios_admin.ps1",
    "$base\fase2_rbac\aplicar_acls_iam.ps1",
    "$base\fase2_rbac\aplicar_acls_storage.ps1",
    "$base\fase2_rbac\aplicar_acls_gpo.ps1",
    "$base\fase2_rbac\aplicar_acls_auditoria.ps1",
    "$base\fase2_rbac\validar_permisos_delegados.ps1"
)
$fase3 = @(
    "$base\fase3_fgpp\crear_fgpp_admins.ps1",
    "$base\fase3_fgpp\crear_fgpp_usuarios.ps1",
    "$base\fase3_fgpp\validar_aplicacion_fgpp.ps1"
)
$fase4 = @(
    "$base\fase4_mfa\instalar_winotp.ps1",
    "$base\fase4_mfa\generar_secrets_totp.ps1",
    "$base\fase4_mfa\crear_qr_codes.ps1",
    "$base\fase4_mfa\config_lockout_registry.ps1",
    "$base\fase4_mfa\validar_mfa_login.ps1"
)
$fase5 = @(
    "$base\fase5_perfiles\crear_compartidas_perfil.ps1",
    "$base\fase5_perfiles\crear_compartidas_home.ps1",
    "$base\fase5_perfiles\gpo_redirecciones.ps1",
    "$base\fase5_perfiles\aplicar_cuotas_fsrm.ps1",
    "$base\fase5_perfiles\validar_sincronizacion_docs.ps1"
)
$fase6 = @(
    "$base\fase6_auditoria\config_auditpol_eventos.ps1",
    "$base\fase6_auditoria\script_extraccion_4625.ps1",
    "$base\fase6_auditoria\generar_reporte_eventos.ps1"
)

# ---- Loop principal ----
do {
    Show-Menu
    $opcion = Read-Host "  Seleccione una opcion"

    switch ($opcion.ToUpper()) {
        "1" { Invoke-Fase "FASE 1 - Auditoria Base"          $fase1 }
        "2" { Invoke-Fase "FASE 2 - RBAC + Delegacion"       $fase2 }
        "3" { Invoke-Fase "FASE 3 - FGPP"                    $fase3 }
        "4" { Invoke-Fase "FASE 4 - MFA"                     $fase4 }
        "5" { Invoke-Fase "FASE 5 - Perfiles Moviles"        $fase5 }
        "6" { Invoke-Fase "FASE 6 - Auditoria Avanzada"      $fase6 }
        "A" {
            p9_banner "Ejecucion Completa -- Todas las Fases"
            p9_warning "Esto ejecutara las 6 fases en orden. Puede tardar varios minutos."
            $confirm = Read-Host "  Confirmar? (S/N)"
            if ($confirm -eq "S" -or $confirm -eq "s") {
                Invoke-Fase "FASE 1" $fase1
                Invoke-Fase "FASE 2" $fase2
                Invoke-Fase "FASE 3" $fase3
                Invoke-Fase "FASE 4" $fase4
                Invoke-Fase "FASE 5" $fase5
                Invoke-Fase "FASE 6" $fase6
                p9_ok "Ejecucion completa finalizada."
            }
        }
        "R" { & "$base\fase6_auditoria\generar_reporte_eventos.ps1" }
        "Q" { p9_info "Saliendo..."; break }
        default { p9_warning "Opcion no valida." }
    }

    if ($opcion.ToUpper() -ne "Q") { p9_pausa }

} while ($opcion.ToUpper() -ne "Q")
