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

        -- состояние
        client = undefined,
        clientTimeout = 0,
        active = false,
        watch = undefined,
        startTask = undefined,
        frameCount = 0,
        sceneLine = "",
        machineLine = "",

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
            minDurationSec = 0; displayName = ""; timeoutMs = 5000

            if not (doesFileExist iniPath) then false
            else
            (
                local lines = (dotNetClass "System.IO.File").ReadAllLines iniPath
                local section = ""
                for ln in lines do
                (
                    local s = trimStr ln
                    if s.count > 0 and s[1] != ";" and s[1] != "#" do
                    (
                        if s[1] == "[" then section = toLower (trimStr (substituteString (substituteString s "[" "") "]" ""))
                        else
                        (
                            local eq = findString s "="
                            if eq != undefined do
                            (
                                local k = section + "." + (toLower (trimStr (substring s 1 (eq - 1))))
                                local v = trimStr (substring s (eq + 1) -1)
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
                                    default: ()
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
        fn sendText txt =
        (
            ensureClient()
            local uriClass = dotNetClass "System.Uri"
            local body = "chat_id=" + (uriClass.EscapeDataString chatId) + "&text=" + (uriClass.EscapeDataString txt)
            if threadId != "" do body += "&message_thread_id=" + (uriClass.EscapeDataString threadId)
            local content = dotNetObject "System.Net.Http.StringContent" body (dotNetClass "System.Text.Encoding").UTF8 "application/x-www-form-urlencoded"
            local uri = dotNetObject "System.Uri" (apiBase + "/bot" + token + "/sendMessage")
            client.PostAsync uri content
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

        fn viewLine =
        (
            local r = ""
            try
            (
                local cam = viewport.getCamera()
                if cam != undefined then r = "Камера: " + cam.name
                else
                (
                    local t = viewport.getType()
                    if t != undefined do r = "Вид: " + (substituteString (t as string) "view_" "")
                )
            )
            catch ()
            r
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
                    (n as string) + " " + (pluralFrames n)
                )
                3: (
                    local n = ((((rendEnd - rendStart) as time).frame as integer) / nth) + 1
                    (n as string) + " " + (pluralFrames n)
                )
                4: "кадры " + rendPickupFrames
                default: "1 кадр"
            )
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

                    local who = if displayName != "" then displayName else sysInfo.username
                    machineLine = "Компьютер: " + sysInfo.computername + " (" + who + ")"
                    sceneLine = "Сцена: " + (if maxFileName != "" then maxFileName else "без имени")

                    watch = dotNetObject "System.Diagnostics.Stopwatch"
                    watch.Start()
                    active = true

                    logMsg ("render start: " + maxFileName + ", type=" + ((if (isKindOf p Array) and p.count >= 2 then p[1] else "?") as string) + ", net=" + ((if (isKindOf p Array) and p.count >= 2 then p[2] else "?") as string))

                    if notifyStart do
                    (
                        local txt = "🟡 Рендер запущен\n" + sceneLine + "\n"
                        local v = viewLine()
                        if v != "" do txt += v + "\n"
                        txt += machineLine + "\n"
                        txt += framesText() + ", " + (w as string) + "×" + (h as string) + ", " + rendererName()
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
                if active do
                (
                    active = false
                    local sec = watch.Elapsed.TotalSeconds
                    logMsg ("render end: " + (formatDuration sec) + ", frames=" + (frameCount as string))

                    finishTask startTask "start" timeoutMs
                    startTask = undefined

                    if notifyFinish and sec >= minDurationSec do
                    (
                        local txt = "🟢 Рендер закончен — " + (formatDuration sec) + "\n" + sceneLine + "\n" + machineLine
                        if frameCount > 1 do txt += "\nКадров: " + (frameCount as string)
                        finishTask (sendText txt) "finish" timeoutMs
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
