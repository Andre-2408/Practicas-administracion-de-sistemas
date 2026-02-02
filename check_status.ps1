
Write-Host "NOMBRE DEL EQUIPO:" -ForegroundColor Yellow
Write-Host $env:COMPUTERNAME
Write-Host ""

Write-Host "DIRECCIÓN IP:" -ForegroundColor Yellow
$ipAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" }
foreach ($ip in $ipAddresses) {
    Write-Host "   Interfaz: $($ip.InterfaceAlias) - IP: $($ip.IPAddress)"
}
Write-Host ""

Write-Host "ESPACIO EN DISCO:" -ForegroundColor Yellow
Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | Format-Table Name, @{Label = "Size(GB)"; Expression = { [math]::Round($_.Used / 1GB + $_.Free / 1GB, 2) } }, @{Label = "Used(GB)"; Expression = { [math]::Round($_.Used / 1GB, 2) } }, @{Label = "Free(GB)"; Expression = { [math]::Round($_.Free / 1GB, 2) } }, @{Label = "Use%"; Expression = { [math]::Round(($_.Used / ($_.Used + $_.Free)) * 100, 2) } } -AutoSize
Write-Host ""