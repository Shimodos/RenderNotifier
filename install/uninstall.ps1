# Removes render_notifier.ms and render_notifier.ini from scripts\startup
# of every 3ds Max version of the current Windows user.
#
#   powershell -ExecutionPolicy Bypass -File install\uninstall.ps1
param(
    [string]$MaxRoot = (Join-Path $env:LOCALAPPDATA 'Autodesk\3dsMax')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $MaxRoot)) { Write-Host "3ds Max user folder not found: $MaxRoot"; exit 0 }

$removed = 0
$langDirs = @(Get-ChildItem $MaxRoot -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory } |
    Where-Object { $_.Name -cmatch '^[A-Z]{3}$' })
foreach ($dir in $langDirs) {
    foreach ($name in 'render_notifier.ms', 'render_notifier.ini') {
        $file = Join-Path $dir.FullName "scripts\startup\$name"
        if (Test-Path $file) { Remove-Item $file -Force; Write-Host "Removed: $file"; $removed++ }
    }
}
if ($removed -eq 0) { Write-Host 'Nothing to remove.' } else { Write-Host 'Done. Restart 3ds Max.' }
