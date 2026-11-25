/*
    Render Notifier - уведомления о рендере из 3ds Max в Telegram.

    Файл кладётся в scripts/startup пользователя вместе с render_notifier.ini
    и загружается сам при старте Max. Ничего не пишет в .max файлы.

    Файл должен оставаться в UTF-8 с BOM: в нём есть кириллица и эмодзи.
*/
(
    global RenderNotifier

    -- повторная загрузка безопасна: старые callbacks снимаются по id
    try (callbacks.removeScripts id:#renderNotifier) catch ()

    struct RenderNotifierStruct
    (
        version = "0.1.0",
        iniPath = "",

        -- конфиг (значения по умолчанию)
        token = "",
        chatId = "",
        threadId = "",
        apiBase = "https://api.telegram.org",
        enabled = true,
        notifyStart = true,
        notifyFinish = true,
        minDurationSec = 0,
        displayName = "",
        timeoutMs = 5000,
        crashWatch = true,
        computerLabel = "",

        -- состояние
        watchProc = undefined,
        markerPath = "",
        client = undefined,
        clientTimeout = 0,
        active = false,
        watch = undefined,
        startTask = undefined,
        frameCount = 0,
        sceneLine = "",
        machineLine = "",
        setupLine = "",
        queueIdx = 0,
        queueTotal = 0,
        lastSetupIdx = 0,
        queueWatch = undefined,

        -------------------------------------------------------------- лог

        fn scrub msg =
        (
            if token != "" then substituteString msg token "<token>" else msg
        ),

        fn logMsg msg =
        (
            try
            (
                local dir = (systemTools.getEnvVariable "LOCALAPPDATA") + "\\RenderNotifier"
                makeDir dir all:true
                local f = dir + "\\render_notifier.log"
                -- ротация по размеру: один предыдущий файл
                if (doesFileExist f) and (getFileSize f) > 524288 do
                (
                    local old = f + ".1"
                    if doesFileExist old do deleteFile old
                    renameFile f old
                )
                local stamp = ((dotNetClass "System.DateTime").Now).ToString "yyyy-MM-dd HH:mm:ss"
                (dotNetClass "System.IO.File").AppendAllText f (stamp + "  " + (scrub (msg as string)) + "\r\n")
            )
            catch ()
        ),

        ----------------------------------------------------------- конфиг

        fn trimStr s = trimLeft (trimRight s),

        fn asBool s default =
        (
            local v = toLower (trimStr s)
            if v == "" then default
            else (v == "true" or v == "1" or v == "yes" or v == "on")
        ),

        fn asInt s default =
        (
            local v = (trimStr s) as integer
            if v == undefined then default else v
        ),

        -- INI читается через .NET как UTF-8: getINISetting не понимает UTF-8,
        -- а display_name бывает кириллицей.
        fn loadConfig =
        (
            token = ""; chatId = ""; threadId = ""
            apiBase = "https://api.telegram.org"
            enabled = true; notifyStart = true; notifyFinish = true
            minDurationSec = 0; displayName = ""; timeoutMs = 5000; crashWatch = true
            computerLabel = ""
            -- строка секции [computers] для этой машины: ИМЯ_КОМПЬЮТЕРА=как показывать
            local myKey = "computers." + (toLower sysInfo.computername)

            if not (doesFileExist iniPath) then false
            else
            (
                local lines = (dotNetClass "System.IO.File").ReadAllLines iniPath
                -- строки режем регулярками .NET: substring/trim в MAXScript портят
                -- значения с эмодзи (символы вне BMP)
                local rx = dotNetClass "System.Text.RegularExpressions.Regex"
                local section = ""
                for ln in lines do
                (
                    local mSec = rx.Match ln "^\\s*\\[\\s*(.*?)\\s*\\]\\s*$"
                    if mSec.Success then section = toLower mSec.Groups.Item[1].Value
                    else
                    (
                        local mKv = rx.Match ln "^\\s*([^;#=\\s][^=]*?)\\s*=\\s*(.*?)\\s*$"
                        if mKv.Success do
                        (
                            (
                                local k = section + "." + (toLower mKv.Groups.Item[1].Value)
                                local v = mKv.Groups.Item[2].Value
                                case k of
                                (
                                    "telegram.token": token = v
                                    "telegram.chat_id": chatId = v
                                    "telegram.thread_id": threadId = v
                                    "telegram.api_base": (if v != "" do apiBase = v)
                                    "options.enabled": enabled = asBool v true
                                    "options.notify_start": notifyStart = asBool v true
                                    "options.notify_finish": notifyFinish = asBool v true
                                    "options.min_duration_sec": minDurationSec = asInt v 0
                                    "options.display_name": displayName = v
                                    "options.timeout_ms": timeoutMs = asInt v 5000
                                    "options.crash_watch": crashWatch = asBool v true
                                    default: (if k == myKey do computerLabel = v)
                                )
                            )
                        )
                    )
                )
                if timeoutMs < 500 do timeoutMs = 500
                true
            )
        ),

        ------------------------------------------------------------- HTTP

        fn ensureClient =
        (
            if client == undefined or clientTimeout != timeoutMs do
            (
                -- TLS 1.2: добавляем к уже включённым протоколам, только если
                -- процесс не на системных настройках (они и так включают 1.2).
                -- Настройка общая на весь процесс Max, поэтому ничего не отключаем.
                try
                (
                    local spm = dotNetClass "System.Net.ServicePointManager"
                    local cur = spm.SecurityProtocol.ToString()
                    if cur != "SystemDefault" and (findString cur "Tls12") == undefined do
                        spm.SecurityProtocol = dotNet.combineEnums spm.SecurityProtocol (dotNetClass "System.Net.SecurityProtocolType").Tls12
                )
                catch (logMsg ("TLS setup failed: " + getCurrentException()))

                dotNet.loadAssembly "System.Net.Http"
                client = dotNetObject "System.Net.Http.HttpClient"
                client.Timeout = (dotNetClass "System.TimeSpan").FromMilliseconds timeoutMs
                clientTimeout = timeoutMs
            )
        ),

        -- Отправка не ждёт ответа: возвращает .NET Task, запрос идёт в пуле потоков.
        -- Из чужих потоков в MAXScript ничего не вызывается.
        fn apiUrl = apiBase + "/bot" + token + "/sendMessage",

        fn buildBody txt =
        (
            local uriClass = dotNetClass "System.Uri"
            local body = "chat_id=" + (uriClass.EscapeDataString chatId) + "&text=" + (uriClass.EscapeDataString txt)
            if threadId != "" do body += "&message_thread_id=" + (uriClass.EscapeDataString threadId)
            body
        ),

        fn sendText txt =
        (
            ensureClient()
            local content = dotNetObject "System.Net.Http.StringContent" (buildBody txt) (dotNetClass "System.Text.Encoding").UTF8 "application/x-www-form-urlencoded"
            client.PostAsync (dotNetObject "System.Uri" (apiUrl())) content
        ),

        ----------------------------------------------- сторож падений Max

        -- Пока идёт рендер, на диске лежит файл-метка с готовым запросом в Telegram.
        -- Рядом с Max работает скрытый процесс PowerShell: он ждёт, пока Max закроется,
        -- и если метка к этому моменту не убрана (рендер не закончился) - отправляет её.
        -- Текст сторожа: только одинарные кавычки и без обратных слэшей.
        fn watchdogScript =
        (
            "param([int]$MaxPid, [string]$Marker)
try { Wait-Process -Id $MaxPid -ErrorAction Stop } catch {}
Start-Sleep -Seconds 2
if (-not (Test-Path -LiteralPath $Marker)) { exit 0 }
$log = Join-Path (Split-Path $Marker -Parent) 'render_notifier.log'
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$lines = $null
try {
    $lines = [IO.File]::ReadAllLines($Marker)
    $d = (Get-Date) - (Get-Item -LiteralPath $Marker).LastWriteTime
    $dur = '{0}:{1:00}:{2:00}' -f [int][Math]::Floor($d.TotalHours), $d.Minutes, $d.Seconds
    $body = $lines[1].Replace('RNDURATION', $dur)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod -Method Post -Uri $lines[0] -ContentType 'application/x-www-form-urlencoded; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
    [IO.File]::AppendAllText($log, $stamp + '  watchdog: 3ds Max ' + $MaxPid + ' exited during render, message sent' + [Environment]::NewLine)
}
catch {
    $m = $_.Exception.Message
    if ($lines) { $m = $m.Replace($lines[0], '<url>') }
    [IO.File]::AppendAllText($log, $stamp + '  watchdog: 3ds Max ' + $MaxPid + ' exited during render, send failed: ' + $m + [Environment]::NewLine)
}
Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
"
        ),

        fn clearMarker =
        (
            try (if markerPath != "" and (doesFileExist markerPath) do deleteFile markerPath) catch ()
        ),

        -- Записать метку и убедиться, что сторож этого Max запущен (один на сессию Max).
        fn armWatchdog txt =
        (
            try
            (
                local dir = (systemTools.getEnvVariable "LOCALAPPDATA") + "\\RenderNotifier"
                makeDir dir all:true
                local maxPid = ((dotNetClass "System.Diagnostics.Process").GetCurrentProcess()).Id
                markerPath = dir + "\\running_" + (maxPid as string) + ".txt"
                local ioFile = dotNetClass "System.IO.File"
                ioFile.WriteAllText markerPath (apiUrl() + "\r\n" + (buildBody txt) + "\r\n")

                local alive = false
                try (alive = watchProc != undefined and not watchProc.HasExited) catch ()
                if not alive do
                (
                    local ps1 = dir + "\\render_watchdog.ps1"
                    ioFile.WriteAllText ps1 (watchdogScript())
                    local psi = dotNetObject "System.Diagnostics.ProcessStartInfo" "powershell.exe"
                    psi.Arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1 + "\" -MaxPid " + (maxPid as string) + " -Marker \"" + markerPath + "\""
                    psi.UseShellExecute = false
                    psi.CreateNoWindow = true
                    watchProc = (dotNetClass "System.Diagnostics.Process").Start psi
                    logMsg ("watchdog started for 3ds Max " + (maxPid as string))
                )
            )
            catch (logMsg ("watchdog error: " + getCurrentException()))
        ),

        -- Дождаться задачи (не дольше waitMs) и записать результат в лог.
        fn finishTask task label waitMs =
        (
            try
            (
                if task != undefined do
                (
                    if not task.IsCompleted do (try (task.Wait waitMs) catch ())
                    if not task.IsCompleted then logMsg (label + ": no response in " + (waitMs as string) + " ms")
                    else if task.IsCanceled then logMsg (label + ": request timed out")
                    else if task.IsFaulted then logMsg (label + ": send failed: " + (task.Exception.GetBaseException()).Message)
                    else
                    (
                        local resp = task.Result
                        if resp.IsSuccessStatusCode then logMsg (label + ": sent")
                        else
                        (
                            local answer = ""
                            try (answer = (resp.Content.ReadAsStringAsync()).Result) catch ()
                            logMsg (label + ": Telegram answered " + (resp.StatusCode.ToString()) + " " + answer)
                        )
                    )
                )
            )
            catch (logMsg (label + ": result check failed: " + getCurrentException()))
        ),

        ------------------------------------------------------ данные сцены

        fn pluralFrames n =
        (
            local m10 = mod n 10
            local m100 = mod n 100
            if m10 == 1 and m100 != 11 then "кадр"
            else if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then "кадра"
            else "кадров"
        ),

        fn formatDuration sec =
        (
            local s = sec as integer
            local h = s / 3600
            local m = (s - h * 3600) / 60
            local r = s - h * 3600 - m * 60
            if h > 0 then (h as string) + " ч " + (m as string) + " мин"
            else if m > 0 then (m as string) + " мин " + (r as string) + " сек"
            else (r as string) + " сек"
        ),

        fn rendererName =
        (
            local n = (classof renderers.current) as string
            if matchPattern n pattern:"V_Ray*" then "V-Ray"
            else if matchPattern n pattern:"Corona*" then "Corona"
            else substituteString n "_" " "
        ),

        -- Число кадров по настройкам Render Setup.
        fn framesText =
        (
            local nth = rendNThFrame
            if nth == undefined or nth < 1 do nth = 1
            case rendTimeType of
            (
                2: (
                    local n = (((animationRange.end - animationRange.start).frame as integer) / nth) + 1
                    (n as string) + " " + (pluralFrames n) + " анимации"
                )
                3: (
                    local n = ((((rendEnd - rendStart) as time).frame as integer) / nth) + 1
                    (n as string) + " " + (pluralFrames n) + " анимации"
                )
                4: "кадры анимации " + rendPickupFrames
                default: ""
            )
        ),

        -- Pulze Scene Manager 2.x хранит свои setup-ы ("кадры") в сцене:
        -- rootnode.SceneManager_Attributes.SceneManager_Dat, JSON в base64.
        -- Какой setup рендерится сейчас, там не записано - определяем по имени файла
        -- вывода (rendOutputFilename == finalPath setup-а), запасной вариант - камера + кадр.
        -- Возвращает #(имя, номер среди отмеченных на рендер, всего отмечено, способ) или undefined.
        fn sceneManagerInfo =
        (
            local res = undefined
            try
            (
                if isProperty rootnode #SceneManager_Attributes do
                (
                    local dat = rootnode.SceneManager_Attributes.SceneManager_Dat
                    if dat != undefined and dat != "" do
                    (
                        local js = (dotNetClass "System.Text.Encoding").UTF8.GetString ((dotNetClass "System.Convert").FromBase64String dat)
                        local rx = dotNetClass "System.Text.RegularExpressions.Regex"
                        local str = "\"((?:[^\"\\\\]|\\\\.)*)\""
                        local outName = toLower (getFilenameFile (substituteString rendOutputFilename "/" "\\"))
                        local camName = ""
                        try (local cam = viewport.getCamera(); if cam != undefined do camName = cam.name) catch ()
                        local frame = (currentTime.frame as integer) as string
                        local names = #(), queued = #(), byName = #(), byPath = #(), byCamera = #()

                        for c in (rx.Split js "(?=\\{\"version\":\\d+,\"id\":\")") do
                        (
                            local mName = rx.Match c ("\"scenename\":\\{\"text\":" + str)
                            if mName.Success do
                            (
                                append names (rx.Unescape mName.Groups.Item[1].Value)
                                append queued (rx.IsMatch c "\"render\":\\{\"enabled\":true\\}")
                                local i = names.count

                                -- имя файла вывода обычно равно имени setup-а; сохранённый finalPath
                                -- бывает устаревшим, поэтому он только запасной признак
                                if outName != "" and (toLower names[i]) == outName do append byName i
                                local mOut = rx.Match c ("\"output_Common\":\\{\"enabled\":true,\"projectPath\":(?:null|" + str + "),\"finalPath\":" + str)
                                if outName != "" and mOut.Success do
                                (
                                    local f = substituteString (rx.Unescape mOut.Groups.Item[2].Value) "/" "\\"
                                    if (toLower (getFilenameFile f)) == outName do append byPath i
                                )

                                local mCam = rx.Match c ("\"camera\":\\{\"enabled\":true,\"name\":" + str)
                                local mFrame = rx.Match c "\"frames\":\\{\"enabled\":true,\"type\":0,\"single\":\"(-?\\d+)\""
                                if camName != "" and mCam.Success and (rx.Unescape mCam.Groups.Item[1].Value) == camName do
                                    if (not mFrame.Success) or mFrame.Groups.Item[1].Value == frame do append byCamera i
                            )
                        )

                        local pick = 0
                        local how = "name"
                        local cands = byName
                        if cands.count == 0 do (cands = byPath; how = "output")
                        if cands.count == 0 do (cands = byCamera; how = "camera")
                        if cands.count > 0 do
                        (
                            -- в списке бывают копии setup-а с тем же именем: берём отмеченную на рендер
                            local q = for i in cands where queued[i] collect i
                            if q.count > 0 do cands = q
                            pick = cands[1]
                            -- всё ещё несколько: берём следующий после прошлого
                            for i = cands.count to 1 by -1 where cands[i] > lastSetupIdx do pick = cands[i]
                        )
                        if pick > 0 do
                        (
                            lastSetupIdx = pick
                            local total = 0
                            local idx = 0
                            for i = 1 to names.count where queued[i] do
                            (
                                total += 1
                                if i == pick do idx = total
                            )
                            res = #(names[pick], idx, total, how)
                        )
                    )
                )
            )
            catch (logMsg ("Scene Manager data error: " + getCurrentException()))
            res
        ),

        fn queueSuffix =
        (
            if queueIdx > 0 and queueTotal > 1 then " — кадр " + (queueIdx as string) + " из " + (queueTotal as string) else ""
        ),

        -------------------------------------------------------- callbacks

        fn onPreRender =
        (
            try
            (
                active = false
                startTask = undefined
                frameCount = 0

                -- массив RendParams: [1] rendType, [2] isNetRender, [13] inMtlEdit, [26] размер
                local p = callbacks.notificationParam()
                local inMtlEdit = (isKindOf p Array) and p.count >= 13 and p[13] == true

                if inMtlEdit then ()
                else if not (loadConfig()) then logMsg ("skip: config not found: " + iniPath)
                else if not enabled then ()
                else if token == "" or chatId == "" then logMsg "skip: token or chat_id is empty"
                else
                (
                    local w = renderWidth
                    local h = renderHeight
                    if (isKindOf p Array) and p.count >= 26 and (isKindOf p[26] Point2) do
                    (
                        w = p[26].x as integer
                        h = p[26].y as integer
                    )

                    -- своё имя машины из [computers] показываем без имени пользователя Windows
                    if computerLabel != "" then
                        machineLine = "Компьютер: " + computerLabel + (if displayName != "" then " (" + displayName + ")" else "")
                    else
                    (
                        local who = if displayName != "" then displayName else sysInfo.username
                        machineLine = "Компьютер: " + sysInfo.computername + " (" + who + ")"
                    )
                    sceneLine = "Сцена: " + (if maxFileName != "" then maxFileName else "без имени")

                    watch = dotNetObject "System.Diagnostics.Stopwatch"
                    watch.Start()
                    active = true

                    local prevIdx = queueIdx
                    setupLine = ""
                    queueIdx = 0
                    queueTotal = 0
                    local sm = sceneManagerInfo()
                    if sm != undefined do
                    (
                        setupLine = "Кадр: " + sm[1]
                        queueIdx = sm[2]
                        queueTotal = sm[3]
                    )
                    -- время очереди считаем, только если она идёт подряд с первого кадра
                    if queueIdx == 1 then
                    (
                        queueWatch = dotNetObject "System.Diagnostics.Stopwatch"
                        queueWatch.Start()
                    )
                    else if queueIdx != prevIdx + 1 do queueWatch = undefined

                    logMsg ("render start: " + maxFileName + ", type=" + ((if (isKindOf p Array) and p.count >= 2 then p[1] else "?") as string) + ", net=" + ((if (isKindOf p Array) and p.count >= 2 then p[2] else "?") as string) + ", out=" + (rendOutputFilename as string) + ", setup=" + (sm as string))

                    if crashWatch do
                    (
                        local crashTxt = "🔴 3ds Max закрылся во время рендера" + queueSuffix() + "\n" + sceneLine + "\n"
                        if setupLine != "" do crashTxt += setupLine + "\n"
                        crashTxt += machineLine + "\nРендер шёл RNDURATION (ч:мм:сс)"
                        armWatchdog crashTxt
                    )

                    if notifyStart do
                    (
                        local txt = "🟡 Рендер запущен" + queueSuffix() + "\n" + sceneLine + "\n"
                        if setupLine != "" do txt += setupLine + "\n"
                        txt += machineLine + "\n"
                        local ft = framesText()
                        if ft != "" do txt += ft + ", "
                        txt += (w as string) + "×" + (h as string) + ", " + rendererName()
                        startTask = sendText txt
                    )
                )
            )
            catch (logMsg ("preRender error: " + getCurrentException()))
        ),

        fn onPostRenderFrame =
        (
            if active do frameCount += 1
        ),

        fn onPostRender =
        (
            try
            (
                -- рендер закончился штатно: сторожу сообщать не о чем
                clearMarker()
                if active do
                (
                    active = false
                    local sec = watch.Elapsed.TotalSeconds
                    logMsg ("render end: " + (formatDuration sec) + ", frames=" + (frameCount as string))

                    finishTask startTask "start" timeoutMs
                    startTask = undefined

                    if notifyFinish and sec >= minDurationSec do
                    (
                        local txt = "🟢 Рендер закончен — " + (formatDuration sec) + queueSuffix() + "\n" + sceneLine + "\n"
                        if setupLine != "" do txt += setupLine + "\n"
                        txt += machineLine
                        if frameCount > 1 do txt += "\nКадров анимации: " + (frameCount as string)
                        finishTask (sendText txt) "finish" timeoutMs
                    )

                    -- дорендерился последний из отмеченных на рендер setup-ов Scene Manager
                    if queueTotal > 1 and queueIdx == queueTotal do
                    (
                        if notifyFinish do
                        (
                            local txt = "🏁 Очередь завершена — " + (queueTotal as string) + " " + (pluralFrames queueTotal)
                            if queueWatch != undefined do txt += " за " + (formatDuration queueWatch.Elapsed.TotalSeconds)
                            txt += "\n" + sceneLine + "\n" + machineLine
                            finishTask (sendText txt) "queue" timeoutMs
                        )
                        queueWatch = undefined
                    )
                )
            )
            catch (logMsg ("postRender error: " + getCurrentException()))
        ),

        fn register =
        (
            callbacks.removeScripts id:#renderNotifier
            callbacks.addScript #preRender "try (RenderNotifier.onPreRender()) catch ()" id:#renderNotifier
            callbacks.addScript #postRenderFrame "try (RenderNotifier.onPostRenderFrame()) catch ()" id:#renderNotifier
            callbacks.addScript #postRender "try (RenderNotifier.onPostRender()) catch ()" id:#renderNotifier
        )
    )

    try
    (
        RenderNotifier = RenderNotifierStruct()
        RenderNotifier.iniPath = (getFilenamePath (getSourceFileName())) + "render_notifier.ini"
        RenderNotifier.register()
        RenderNotifier.logMsg ("loaded v" + RenderNotifier.version + ", maxVersion " + ((maxVersion())[1] as string) + (if doesFileExist RenderNotifier.iniPath then "" else (", config not found: " + RenderNotifier.iniPath)))
    )
    catch (format "Render Notifier: load failed: %\n" (getCurrentException()))
)
