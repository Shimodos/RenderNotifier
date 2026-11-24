# Sends a test message to the Telegram chat without 3ds Max.
# Reads token and chat_id from config\render_notifier.ini (or -ConfigPath).
#
#   powershell -ExecutionPolicy Bypass -File tools\test_send.ps1
param(
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\render_notifier.ini' }
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Config not found: $ConfigPath"
    Write-Host 'Copy config\render_notifier.example.ini to config\render_notifier.ini and fill in token and chat_id.'
    exit 1
}

$cfg = @{}
foreach ($line in [IO.File]::ReadAllLines($ConfigPath, [Text.Encoding]::UTF8)) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1].ToLower()] = $Matches[2] }
}
if (-not $cfg['token'] -or -not $cfg['chat_id']) { Write-Host 'token or chat_id is empty in the config.'; exit 1 }

# Windows PowerShell 5.1 may default to an old TLS version
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Cyrillic and emoji are built from code points so the script stays plain ASCII
$hello = -join ([char[]](0x41F, 0x440, 0x438, 0x432, 0x435, 0x442))
$text = [char]::ConvertFromUtf32(0x1F7E2) + " Render Notifier: $hello, $env:COMPUTERNAME"

$fields = @{ chat_id = $cfg['chat_id']; text = $text }
if ($cfg['thread_id']) { $fields['message_thread_id'] = $cfg['thread_id'] }
$body = ($fields.GetEnumerator() | ForEach-Object { $_.Key + '=' + [Uri]::EscapeDataString($_.Value) }) -join '&'

$base = if ($cfg['api_base']) { $cfg['api_base'] } else { 'https://api.telegram.org' }
try {
    $r = Invoke-RestMethod -Method Post -Uri "$base/bot$($cfg['token'])/sendMessage" `
        -ContentType 'application/x-www-form-urlencoded; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10
    if ($r.ok) { Write-Host "OK: message sent to chat $($cfg['chat_id'])" } else { Write-Host 'Telegram answered ok=false'; exit 1 }
}
catch {
    $msg = $_.ErrorDetails.Message
    if (-not $msg) { $msg = $_.Exception.Message }
    Write-Host ('FAILED: ' + $msg.Replace($cfg['token'], '<token>'))
    exit 1
}
