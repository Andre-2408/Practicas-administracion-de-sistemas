# harvesting_eventos.ps1 -- Fase 1: Extraccion de eventos de seguridad
# Practica 09 -- Seguridad de Identidad, Delegacion y MFA
# Extrae los 100 eventos mas recientes del Security Log

. "$PSScriptRoot\..\helpers.ps1"

p9_banner "Fase 1 -- Harvesting de Eventos de Seguridad"
Ensure-OutputDir

$OutputFile = "$($Global:OutputDir)\diagnostico_baseline.txt"
$CsvFile    = "$($Global:OutputDir)\eventos_seguridad.csv"

p9_info "Extrayendo ultimos 100 eventos del Security Log..."
p9_linea

try {
    $eventos = Get-EventLog -LogName Security -Newest 100 -ErrorAction Stop

    p9_ok "Se encontraron $($eventos.Count) eventos."
    Write-Host ""

    # Mostrar resumen en pantalla
    $resumen = $eventos | Group-Object EventID | Sort-Object Count -Descending | Select-Object -First 10
    Write-Host "  Top 10 EventIDs encontrados:"
    p9_linea
    $resumen | ForEach-Object {
        Write-Host "    EventID $($_.Name.PadRight(6)) -- $($_.Count) ocurrencias"
    }

    # Exportar CSV
    $eventos | Select-Object TimeGenerated, EventID, EntryType, Source, Message |
        Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
    p9_ok "CSV exportado: $CsvFile"

    # Escribir baseline
    $header = @"
==========================================================
  DIAGNOSTICO BASELINE -- PRACTICA 09
  Generado: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Maquina:  $($env:COMPUTERNAME)
  Dominio:  $($Global:Dominio)
==========================================================

--- RESUMEN EVENTOS SECURITY LOG (ultimos 100) ---
"@
    $header | Out-File -FilePath $OutputFile -Encoding UTF8 -Force

    $resumen | ForEach-Object {
        "  EventID $($_.Name) -- $($_.Count) ocurrencias" |
            Add-Content -Path $OutputFile -Encoding UTF8
    }

    "`n--- EVENTOS DETALLADOS ---" | Add-Content -Path $OutputFile -Encoding UTF8
    $eventos | ForEach-Object {
        "[$($_.TimeGenerated)] EventID:$($_.EventID) Tipo:$($_.EntryType) -- $($_.Message.Substring(0,[Math]::Min(120,$_.Message.Length)))" |
            Add-Content -Path $OutputFile -Encoding UTF8
    }

    p9_ok "Baseline guardado en: $OutputFile"

} catch {
    p9_error "Error al leer Security Log: $_"
    p9_warning "Asegurese de ejecutar como Administrador de Dominio."
    exit 1
}

p9_linea
p9_ok "Harvesting completado."
p9_pausa
