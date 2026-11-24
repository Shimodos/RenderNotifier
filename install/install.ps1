# Copies render_notifier.ms and render_notifier.ini into scripts\startup
# of every 3ds Max version found for the current Windows user.
#
#   powershell -ExecutionPolicy Bypass -File install\install.ps1
#
# The config is taken from config\render_notifier.ini (or -ConfigPath).
# An existing config in the startup folder is kept unless -Force is given.
param(
    [string]$ConfigPath,
    [switch]$Force,
    [string]$MaxRoot = (Join-Path $env:LOCALAPPDATA 'Autodesk\3dsMax')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'src\render_notifier.ms'

if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config\render_notifier.ini' }
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Config not found: $ConfigPath"
    Write-Host 'Copy config\render_notifier.example.ini to config\render_notifier.ini and fill in token and chat_id first.'
    exit 1
}
if (-not (Test-Path $MaxRoot)) { Write-Host "3ds Max user folder not found: $MaxRoot"; exit 1 }

# <MaxRoot>\<2024 - 64bit>\<ENU>\scripts\startup. Only real language folders
# (ENU, FRA, DEU, JPN, KOR, CHS, PTB...), not backups like ENU__ or ENU-recover-*.
$langDirs = @(Get-ChildItem $MaxRoot -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory } |
    Where-Object { $_.Name -cmatch '^[A-Z]{3}$' })
if ($langDirs.Count -eq 0) { Write-Host "No 3ds Max versions found in $MaxRoot (start 3ds Max once and retry)."; exit 1 }

foreach ($dir in $langDirs) {
    $startup = Join-Path $dir.FullName 'scripts\startup'
    if (-not (Test-Path $startup)) { New-Item -ItemType Directory -Path $startup | Out-Null }
    Copy-Item $script (Join-Path $startup 'render_notifier.ms') -Force
    $ini = Join-Path $startup 'render_notifier.ini'
    if ($Force -or -not (Test-Path $ini)) {
        Copy-Item $ConfigPath $ini -Force
        Write-Host "Installed (script + config): $startup"
    }
    else { Write-Host "Installed (script, config kept): $startup" }
}
Write-Host 'Done. Restart 3ds Max.'
