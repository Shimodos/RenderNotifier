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
    # Install into <Program Files>\Autodesk\3ds Max XXXX\scripts\startup instead
    # (all Windows users of the machine; run PowerShell as administrator).
    [switch]$System,
    [string]$MaxRoot = (Join-Path $env:LOCALAPPDATA 'Autodesk\3dsMax'),
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'Autodesk')
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

$targets = @()
if ($System) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin -and $InstallRoot -eq (Join-Path $env:ProgramFiles 'Autodesk')) {
        Write-Host 'Run this from PowerShell started "as administrator": -System writes to Program Files.'
        exit 1
    }
    # Only folders with a real installation (leftover folders have no 3dsmax.exe)
    $targets = @(Get-ChildItem $InstallRoot -Directory -Filter '3ds Max *' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '3dsmax.exe') } |
        ForEach-Object { Join-Path $_.FullName 'scripts\startup' })
    if ($targets.Count -eq 0) { Write-Host "No 3ds Max installations found in $InstallRoot."; exit 1 }
}
else {
    if (-not (Test-Path $MaxRoot)) { Write-Host "3ds Max user folder not found: $MaxRoot"; exit 1 }
    # <MaxRoot>\<2024 - 64bit>\<ENU>\scripts\startup. Only real language folders
    # (ENU, FRA, DEU, JPN, KOR, CHS, PTB...), not backups like ENU__ or ENU-recover-*.
    $targets = @(Get-ChildItem $MaxRoot -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory } |
        Where-Object { $_.Name -cmatch '^[A-Z]{3}$' } | ForEach-Object { Join-Path $_.FullName 'scripts\startup' })
    if ($targets.Count -eq 0) { Write-Host "No 3ds Max versions found in $MaxRoot (start 3ds Max once and retry)."; exit 1 }
}

foreach ($startup in $targets) {
    if (-not (Test-Path $startup)) { New-Item -ItemType Directory -Path $startup | Out-Null }
    Copy-Item $script (Join-Path $startup 'render_notifier.ms') -Force
    $ini = Join-Path $startup 'render_notifier.ini'
    if ($Force -or -not (Test-Path $ini)) {
        Copy-Item $ConfigPath $ini -Force
        Write-Host "Installed (script + config): $startup"
    }
    else { Write-Host "Installed (script, config kept): $startup" }
}

# 3ds Max 2021.3+ does not load startup scripts from a folder that has the
# Hidden or System attribute (Max.log: "Hidden/System startup script ... skip loading").
# AppData itself is hidden on every Windows and is fine; anything below it must be clean.
$bad = @()
$appData = Split-Path $env:LOCALAPPDATA -Parent
foreach ($startup in $targets) {
    if ($System) { break }
    $item = Get-Item -LiteralPath $startup -Force
    while ($item -and $item.FullName.Length -gt $appData.Length) {
        if ($item.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) { $bad += $item.FullName }
        $item = $item.Parent
    }
}
$bad = @($bad | Select-Object -Unique)
if ($bad.Count -gt 0) {
    Write-Host ''
    Write-Host 'WARNING: 3ds Max will NOT load startup scripts from here, these folders are Hidden or System:'
    foreach ($b in $bad) { Write-Host "  $b" }
    Write-Host 'Clear the attributes and restart 3ds Max, for example:'
    foreach ($b in $bad) { Write-Host "  attrib -s -h `"$b`"" }
    Write-Host 'Or install for all users instead (as administrator): install.ps1 -System'
}
Write-Host 'Done. Restart 3ds Max.'
