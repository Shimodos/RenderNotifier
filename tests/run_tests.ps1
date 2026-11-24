# Headless test of src/render_notifier.ms in 3dsmaxbatch. Needs PowerShell 7.
# Telegram is replaced by a local HTTP listener (api_base in the test ini),
# nothing is sent to the network and no real token is used.
#
#   tests\run_tests.ps1 -Years 2024,2026
param(
    [int[]]$Years = @(2024),
    [int]$Port = 18765
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
$root = Split-Path $PSScriptRoot -Parent
$failed = 0

function Check($name, $cond) {
    if ($cond) { Write-Host "  ok    $name" }
    else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:failed++ }
}

foreach ($year in $Years) {
    $batch = "C:\Program Files\Autodesk\3ds Max $year\3dsmaxbatch.exe"
    if (-not (Test-Path $batch)) { Write-Host "3ds Max $year - not installed, skipped"; continue }
    Write-Host "3ds Max $year"

    $out = Join-Path $PSScriptRoot "_out\$year"
    Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $out | Out-Null
    Copy-Item (Join-Path $root 'src\render_notifier.ms') $out

    $ini = "[telegram]`ntoken=TESTTOKEN123`nchat_id=-100123`nthread_id=7`napi_base={0}`n`n[options]`ndisplay_name=Олексій`ntimeout_ms=3000`n"
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText("$out\render_notifier.ini", ($ini -f "http://localhost:$Port"), $utf8)
    [IO.File]::WriteAllText("$out\dead.ini", ($ini -f 'http://localhost:1'), $utf8)

    $reqFile = "$out\requests.jsonl"
    $job = Start-Job -ArgumentList $Port, $reqFile -ScriptBlock {
        param($Port, $reqFile)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        $l.Start()
        while ($true) {
            $c = $l.GetContext()
            if ($c.Request.Url.AbsolutePath -eq '/stop') { $c.Response.Close(); break }
            $body = [IO.StreamReader]::new($c.Request.InputStream, [Text.Encoding]::UTF8).ReadToEnd()
            $rec = @{ path = $c.Request.Url.AbsolutePath; contentType = $c.Request.ContentType; body = $body } | ConvertTo-Json -Compress
            [IO.File]::AppendAllText($reqFile, $rec + "`n")
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":true}')
            $c.Response.ContentType = 'application/json'
            $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $c.Response.Close()
        }
        $l.Stop()
    }
    Start-Sleep -Seconds 2

    $logFile = Join-Path $env:LOCALAPPDATA 'RenderNotifier\render_notifier.log'
    $logBefore = if (Test-Path $logFile) { @(Get-Content $logFile).Count } else { 0 }

    $env:RN_TEST_DIR = $out
    & $batch (Join-Path $PSScriptRoot 'test_render.ms') -log "$out\max.log" *> "$out\batch_stdout.txt"

    try { Invoke-WebRequest "http://localhost:$Port/stop" -TimeoutSec 5 | Out-Null } catch {}
    Wait-Job $job -Timeout 10 | Out-Null
    Remove-Job $job -Force

    $result = if (Test-Path "$out\result.txt") { Get-Content "$out\result.txt" -Raw } else { '' }
    Check 'script loads' ($result -match 'loaded=true')
    Check 'reload keeps 3 callbacks' ($result -match 'callbacks=3\b')
    Check 'all four renders finished' ($result -match 'render1 ok' -and $result -match 'render2 ok' -and $result -match 'render3 ok=true' -and $result -match 'render4 ok')
    Check 'no script error' ($result -notmatch 'ERROR')

    $reqs = @()
    if (Test-Path $reqFile) { $reqs = @(Get-Content $reqFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }) }
    Check "4 requests received (got $($reqs.Count))" ($reqs.Count -eq 4)
    if ($reqs.Count -eq 4) {
        $msgs = @(); foreach ($r in $reqs) { $msgs += , [System.Web.HttpUtility]::ParseQueryString($r.body) }
        $texts = @(); foreach ($m in $msgs) { $texts += $m['text'] }
        $texts | ForEach-Object { Write-Host ("    | " + ($_ -replace "`n", "`n    | ")) -ForegroundColor DarkGray }
        Check 'path has token and method' ($reqs[0].path -eq '/botTESTTOKEN123/sendMessage')
        Check 'form-urlencoded utf-8' ($reqs[0].contentType -match 'application/x-www-form-urlencoded' -and $reqs[0].contentType -match 'utf-8')
        Check 'chat_id and thread_id' ($msgs[0]['chat_id'] -eq '-100123' -and $msgs[0]['message_thread_id'] -eq '7')
        Check 'start message' ($texts[0].StartsWith("🟡 Рендер запущен`n") -and $texts[0] -match '1 кадр, 64×48, Default Scanline Renderer')
        Check 'cyrillic display name' ($texts[0] -match "Компьютер: $([regex]::Escape($env:COMPUTERNAME)) \(Олексій\)")
        Check 'finish message with duration' ($texts[1] -match '^🟢 Рендер закончен — \d+ сек')
        Check 'frame count on sequence' ($texts[3] -match 'Кадров: 3')
    }

    $log = if (Test-Path $logFile) { @(Get-Content $logFile -Encoding UTF8 | Select-Object -Skip $logBefore) } else { @() }
    $log | ForEach-Object { Write-Host "    > $_" -ForegroundColor DarkGray }
    Check 'log: successful sends' (@($log -match ': sent$').Count -eq 4)
    Check 'log: failure recorded' (@($log -match 'send failed|timed out|no response').Count -ge 1)
    Check 'log: missing config recorded' (@($log -match 'config not found').Count -ge 1)
    Check 'log: token is masked' (@($log -match 'TESTTOKEN123').Count -eq 0)
}

if ($failed) { Write-Host "$failed check(s) failed" -ForegroundColor Red } else { Write-Host 'All checks passed' -ForegroundColor Green }
exit $failed
