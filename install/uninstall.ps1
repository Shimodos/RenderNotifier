# Removes render_notifier.ms and render_notifier.ini from scripts\startup
# of every 3ds Max version of the current Windows user.
# With -System: from <Program Files>\Autodesk\3ds Max XXXX\scripts\startup
# (run PowerShell as administrator).
#
#   powershell -ExecutionPolicy Bypass -File install\uninstall.ps1
param(
    [switch]$System,
    [string]$MaxRoot = (Join-Path $env:LOCALAPPDATA 'Autodesk\3dsMax'),
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'Autodesk')
)
$ErrorActionPreference = 'Stop'

$targets = @()
if ($System) {
    $targets = @(Get-ChildItem $InstallRoot -Directory -Filter '3ds Max *' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'scripts\startup' })
}
elseif (Test-Path $MaxRoot) {
    $targets = @(Get-ChildItem $MaxRoot -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory } |
        Where-Object { $_.Name -cmatch '^[A-Z]{3}$' } | ForEach-Object { Join-Path $_.FullName 'scripts\startup' })
}

$removed = 0
foreach ($startup in $targets) {
    foreach ($name in 'render_notifier.ms', 'render_notifier.ini') {
        $file = Join-Path $startup $name
        if (Test-Path $file) { Remove-Item $file -Force; Write-Host "Removed: $file"; $removed++ }
    }
}
if ($removed -eq 0) { Write-Host 'Nothing to remove.' } else { Write-Host 'Done. Restart 3ds Max.' }
