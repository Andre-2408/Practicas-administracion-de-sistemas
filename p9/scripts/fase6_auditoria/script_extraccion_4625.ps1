# script_extraccion_4625.ps1 -- Fase 6: Extraccion de eventos 4625 (accesos denegados)
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
#
# EventID 4625 = An account failed to log on
# Extrae los ultimos 10 eventos y exporta a accesos_denegados.txt
# Este script puede ser ejecutado por admin_auditoria (Event Log Readers)

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 6 -- Extraccion EventID 4625 (Accesos Denegados)"
Ensure-OutputDir

$LogFile    = "$($Global:OutputDir)\fase6_auditoria.log"
$OutputFile = "$($Global:OutputDir)\accesos_denegados.txt"
p9_log $LogFile "=== INICIO: Extraccion EventID 4625 ==="

p9_info "Extrayendo ultimos 10 eventos 4625 del Security Log..."
Write-Host ""

try {
    # Intentar con Get-WinEvent (mas detallado, disponible en PS3+)
    $eventos4625 = Get-WinEvent -FilterHashtable @{
        LogName = "Security"
        Id      = 4625
    } -MaxEvents 10 -ErrorAction Stop

    p9_ok "Eventos encontrados: $($eventos4625.Count)"
    Write-Host ""

    # Parsear eventos para extraer campos relevantes
    $eventosParseados = foreach ($ev in $eventos4625) {
        $xml     = [xml]$ev.ToXml()
        $data    = $xml.Event.EventData.Data

        # Extraer campos del XML del evento 4625
        $getVal = { param($n) ($data | Where-Object { $_.Name -eq $n }).'#text' }

        [PSCustomObject]@{
            Timestamp      = $ev.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            EventID        = $ev.Id
            UsuarioFallido = & $getVal "TargetUserName"
            Dominio        = & $getVal "TargetDomainName"
            WorkstationName= & $getVal "WorkstationName"
            IpAddress      = & $getVal "IpAddress"
            FailureReason  = & $getVal "FailureReason"
            SubStatus      = & $getVal "SubStatus"
            LogonType      = & $getVal "LogonType"
        }
    }

    # Mostrar en pantalla
    p9_info "Ultimos 10 intentos fallidos de logon (EventID 4625):"
    p9_linea
    $eventosParseados | ForEach-Object {
        Write-Host "  [$($_.Timestamp)] Usuario: $($_.UsuarioFallido.PadRight(20)) IP: $($_.IpAddress.PadRight(16)) Razon: $($_.FailureReason)"
    }

} catch {
    p9_warning "Get-WinEvent fallo ($($_.Exception.Message)). Intentando Get-EventLog..."

    try {
        $eventos4625 = Get-EventLog -LogName Security -InstanceId 4625 -Newest 10 -ErrorAction Stop

        p9_ok "Eventos encontrados: $($eventos4625.Count)"

        $eventosParseados = $eventos4625 | ForEach-Object {
            [PSCustomObject]@{
                Timestamp      = $_.TimeGenerated.ToString("yyyy-MM-dd HH:mm:ss")
                EventID        = $_.EventID
                UsuarioFallido = if ($_.ReplacementStrings.Count -gt 5) { $_.ReplacementStrings[5] } else { "N/A" }
                Dominio        = if ($_.ReplacementStrings.Count -gt 6) { $_.ReplacementStrings[6] } else { "N/A" }
                WorkstationName= if ($_.ReplacementStrings.Count -gt 13) { $_.ReplacementStrings[13] } else { "N/A" }
                IpAddress      = if ($_.ReplacementStrings.Count -gt 19) { $_.ReplacementStrings[19] } else { "N/A" }
                FailureReason  = if ($_.ReplacementStrings.Count -gt 9)  { $_.ReplacementStrings[9]  } else { "N/A" }
                SubStatus      = if ($_.ReplacementStrings.Count -gt 8)  { $_.ReplacementStrings[8]  } else { "N/A" }
                LogonType      = if ($_.ReplacementStrings.Count -gt 10) { $_.ReplacementStrings[10] } else { "N/A" }
            }
        }

        p9_info "Ultimos 10 intentos fallidos (EventID 4625):"
        p9_linea
        $eventosParseados | ForEach-Object {
            Write-Host "  [$($_.Timestamp)] Usuario: $($_.UsuarioFallido.PadRight(20)) IP: $($_.IpAddress)"
        }

    } catch {
        p9_error "No se pudo extraer eventos: $_"
        p9_info "Asegurese de que:"
        p9_info "  1. La auditoria de Logon este habilitada (config_auditpol_eventos.ps1)"
        p9_info "  2. admin_auditoria este en el grupo 'Event Log Readers'"
        p9_info "  3. Hayan ocurrido intentos fallidos de logon"

        # Generar archivo con mensaje informativo
        @"
==========================================================
  ACCESOS DENEGADOS -- PRACTICA 09
  Generado: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina:  $($env:COMPUTERNAME)
==========================================================

SIN EVENTOS 4625 DISPONIBLES

Posibles causas:
  - Auditoria de Logon no configurada
  - Sin intentos fallidos recientes
  - Permisos insuficientes para leer Security Log

Para generar eventos de prueba:
  1. Intentar logon con password incorrecta 3+ veces
  2. Re-ejecutar este script como admin_auditoria
"@ | Out-File -FilePath $OutputFile -Encoding UTF8 -Force

        p9_log $LogFile "ERROR: Sin eventos 4625 disponibles"
        exit 1
    }
}

# ---- Exportar a accesos_denegados.txt ----
p9_info "Generando archivo: $OutputFile"

$header = @"
==========================================================
  ACCESOS DENEGADOS -- PRACTICA 09
  EventID: 4625 (An account failed to log on)
  Generado: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina:  $($env:COMPUTERNAME)
  Dominio:  $($Global:Dominio)
  Total:    $($eventosParseados.Count) eventos
==========================================================

"@
$header | Out-File -FilePath $OutputFile -Encoding UTF8 -Force

# Tabla formateada
"Timestamp            | Usuario              | IP Address       | Dominio      | Razon" |
    Add-Content -Path $OutputFile -Encoding UTF8
("-" * 95) | Add-Content -Path $OutputFile -Encoding UTF8

$eventosParseados | ForEach-Object {
    "$($_.Timestamp) | $($_.UsuarioFallido.PadRight(20)) | $($_.IpAddress.PadRight(16)) | $($_.Dominio.PadRight(12)) | $($_.FailureReason)" |
        Add-Content -Path $OutputFile -Encoding UTF8
}

"`n--- DETALLE COMPLETO ---" | Add-Content -Path $OutputFile -Encoding UTF8
$eventosParseados | ForEach-Object {
    @"

[Evento]
  Timestamp:    $($_.Timestamp)
  EventID:      $($_.EventID)
  Usuario:      $($_.UsuarioFallido)
  Dominio:      $($_.Dominio)
  Workstation:  $($_.WorkstationName)
  IP Address:   $($_.IpAddress)
  Logon Type:   $($_.LogonType)
  Fallo:        $($_.FailureReason)
  SubStatus:    $($_.SubStatus)
"@ | Add-Content -Path $OutputFile -Encoding UTF8
}

p9_ok "Archivo generado: $OutputFile"
p9_log $LogFile "Extraccion completa: $($eventosParseados.Count) eventos 4625"
p9_log $LogFile "=== FIN: Extraccion EventID 4625 ==="
p9_pausa
