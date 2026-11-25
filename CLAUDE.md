# Render Notifier

MAXScript для 3ds Max: шлёт в Telegram-чат студии сообщения о старте и конце рендера. Спецификация — `SPEC.md`, инструкция для художников — `README.md`.

## Устройство

- `src/render_notifier.ms` — весь скрипт, одна глобальная struct `RenderNotifier`. Ставится в `scripts/startup` пользователя вместе с `render_notifier.ini`.
- Callbacks с `id:#renderNotifier`: `#preRender`, `#postRenderFrame` (счётчик кадров), `#postRender`. Не persistent.
- HTTP: `System.Net.Http.HttpClient.PostAsync`, тело `application/x-www-form-urlencoded` в UTF-8. Старт не ждёт ответа (Task проверяется в `#postRender`), финиш ждёт не дольше `timeout_ms`. Из чужих потоков MAXScript не вызывается — никаких .NET-обработчиков событий.
- INI читается через `System.IO.File.ReadAllLines` (UTF-8), а не `getINISetting`: тот не понимает UTF-8. Конфиг перечитывается перед каждым рендером.
- Недокументированный для художников ключ `[telegram] api_base=` подменяет `https://api.telegram.org` — на нём держатся тесты, пригодится и для relay.
- Сторож падений: в `#preRender` пишется метка `%LOCALAPPDATA%\RenderNotifier\running_<pid>.txt` (строка 1 — URL, строка 2 — готовое тело запроса с плейсхолдером `RNDURATION`), в `#postRender` она удаляется. Один на сессию Max скрытый `powershell.exe` (`render_watchdog.ps1`, текст зашит в `watchdogScript` и пишется рядом с логом) ждёт выхода Max и, если метка осталась, отправляет её. В тексте сторожа нельзя использовать двойные кавычки и обратные слэши — он лежит в строке MAXScript.
- Лог `%LOCALAPPDATA%\RenderNotifier\render_notifier.log`, ротация на 512 КБ, токен маскируется.

## Правила

- `render_notifier.ms` — UTF-8 **с BOM**. Править через Edit, после правок проверять первые байты `EF BB BF`. `.ps1` в `install/` и `tools/` — только ASCII (их запускают в Windows PowerShell 5.1), `tests/run_tests.ps1` — UTF-8, запускать в PowerShell 7.
- Любая ошибка в callback должна уйти в лог, а не в рендер: всё в try/catch.
- Токен не коммитить: `render_notifier.ini` в `.gitignore`.
- После правок скрипта: `tests\run_tests.ps1 -Years 2024,2026` (вызывать .ps1 напрямую, не через `pwsh -File`). Тест пишет в настоящий лог пользователя.
- Не запускать `install.ps1` в живую папку пользователя без спроса; для проверки есть `-MaxRoot`.

## Подтверждено

- Документация MAXScript (Rendering Notifications): `#preRender` отдаёт через `callbacks.notificationParam()` массив из 28 элементов RendParams — `[1]` rendType, `[2]` isNetRender, `[13]` inMtlEdit, `[26]` Point2 размер; `#postRender` параметров не имеет; покадровые события не шлются для превью Material Editor.
- Тест в 3dsmaxbatch 2024 (.NET Framework) и 2026 (.NET 8): HttpClient, кодировки, перезагрузка скрипта, недоступная сеть, отсутствие конфига.

- Живой рендер из Pulze Scene Manager 2.6.3 + Corona (2026-11-25): `#preRender` / `#postRender` срабатывают, сообщения доходят.
- Scene Manager 2.x хранит setup-ы в `rootnode.SceneManager_Attributes.SceneManager_Dat` (JSON в base64, массив; у setup-а `render.enabled` — отмечен на рендер, `scenename.text`, `camera.name`, `frames.single`, `output_Common.finalPath`). Активный setup там не записан; API для скриптов у Scene Manager нет. Разбор — регулярками в `sceneManagerInfo`, проверен на настоящем дампе сцены.
- Живой пакетный рендер 5 setup-ов (лог 2026-11-25 16:46): перед каждым рендером Scene Manager ставит `rendOutputFilename` равным `finalPath` setup-а — текущий кадр определяется способом `output`; очередь идёт по списку сверху вниз.
- `substring` / `trimLeft` / `trimRight` в MAXScript портят строки с эмодзи (символы вне BMP): «🟦 Ферма 1» превращалось в «🟦 Ферм». Значения из INI поэтому режутся регулярками .NET; для пользовательского текста строковые функции MAXScript не использовать.

## Не проверено (нужна живая сцена)

- Запасной путь определения кадра (камера + номер кадра) — на живой сцене не срабатывал, хватило основного.
- Сторож на настоящем падении Max и с настоящим Telegram (в тесте Max убивается через `Process.Kill`, запрос уходит в заглушку).

- Срабатывают ли callbacks при рендере из Pulze Scene Manager и сколько раз при пакете setup-ов (допущения 1–3 из SPEC).
- ActiveShade / V-Ray IPR / Corona Interactive и Render to Texture: фильтра нет, в логе при старте пишется `type=` (rendType) — по нему решать, что отсекать.
- Число кадров в сообщении о старте берётся из Render Setup (`rendTimeType`); если рендер запущен скриптом с другими параметрами, оно может не совпасть. В финише — фактический счётчик.
- Отмену рендера штатно отличить нечем.
- Реальная отправка в Telegram: настоящего токена в тестах не было.
