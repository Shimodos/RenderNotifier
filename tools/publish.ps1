# Copies the files needed for installation to the shared Dropbox folder.
# Run it again after every change of the script or of config\render_notifier.ini.
#
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1
param(
    [string]$Target = 'D:\Viarde Studio Dropbox\Viarde_Install\Leshkin_scripts\RenderNotifier'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# source (relative to the repository) -> destination (relative to $Target)
$files = [ordered]@{
    'Install.cmd'                = 'Install.cmd'
    'Uninstall.cmd'              = 'Uninstall.cmd'
    'install\README.txt'         = 'README.txt'
    'install\install.ps1'        = 'install\install.ps1'
    'install\uninstall.ps1'      = 'install\uninstall.ps1'
    'src\render_notifier.ms'     = 'src\render_notifier.ms'
    'config\render_notifier.ini' = 'config\render_notifier.ini'
}

foreach ($src in $files.Keys) {
    if (-not (Test-Path (Join-Path $root $src))) { Write-Host "Missing: $src"; exit 1 }
}
foreach ($src in $files.Keys) {
    $dst = Join-Path $Target $files[$src]
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($dst -match '\.(cmd|txt)$') {
        # cmd.exe and old Notepad want CRLF line ends; the .txt also gets a BOM (it is in Russian)
        $text = [IO.File]::ReadAllText((Join-Path $root $src), [Text.Encoding]::UTF8) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding ($dst -match '\.txt$')))
    }
    else { Copy-Item (Join-Path $root $src) $dst -Force }
    Write-Host "  $($files[$src])"
}
Write-Host "Published to $Target"
