# Render Notifier

A small script for 3ds Max that posts to a Telegram chat when a render starts, finishes or dies:
which scene, which shot, which machine and how long it took. One MAXScript file, no server,
nothing to launch by hand.

[Русская версия](README.ru.md)

<p align="center">
  <img src="assets/viarde_render_logo.png" width="160" alt="Render Notifier">
</p>

```
🟡 Рендер запущен — кадр 2 из 5
Сцена: Kitchen_main.max
Кадр: Kitchen_Angle02
Компьютер: 🟦 Ферма 1
4000×3000, Corona

🟢 Рендер закончен — 1 ч 42 мин — кадр 2 из 5
Сцена: Kitchen_main.max
Кадр: Kitchen_Angle02
Компьютер: 🟦 Ферма 1

🏁 Очередь завершена — 5 кадров за 6 ч 10 мин

🔴 3ds Max закрылся во время рендера — кадр 2 из 5
Рендер шёл 1:12:40 (ч:мм:сс)
```

Messages are in Russian; the texts live in one place in `src/render_notifier.ms`.

## Features

- **Start and finish messages** with scene name, machine, resolution, renderer and duration.
- **Works with any way of rendering.** The script listens to 3ds Max's own `#preRender` / `#postRender`
  events, so it does not matter whether the render was started by the Render button, a script or
  Pulze Scene Manager.
- **Pulze Scene Manager 2.x queues.** Reads the setups stored in the scene and adds the shot name,
  "shot N of M" among the setups marked for render, and a separate message when the last one is done.
- **Crash watchdog.** A hidden PowerShell process sits next to 3ds Max and reports when Max exits
  in the middle of a render.
- **Machine labels.** One config for the whole studio maps Windows computer names to readable labels;
  a coloured emoji in the label tells machines apart in the chat.
- **Corona DR nodes stay silent.** A node that picks up someone else's render does not post; the
  master machine does.
- **Never gets in the way of the render.** The start message is sent in the background, every
  error only goes to a log, and without internet 3ds Max renders as usual.
- **No dependencies.** HTTP goes through .NET that ships with 3ds Max. Tested on 3ds Max 2024
  (.NET Framework) and 2026 (.NET 8).

## Setup

### 1. Bot and chat (once)

1. Talk to [@BotFather](https://t.me/BotFather), `/newbot`, get the token.
2. Create a group and add the bot to it.
3. Send `/start@your_bot` in the group, open `https://api.telegram.org/bot<TOKEN>/getUpdates`
   and find `chat.id` (negative for groups).
4. Copy `config\render_notifier.example.ini` to `config\render_notifier.ini`, fill in `token` and `chat_id`.
5. Check the bot without 3ds Max:

```powershell
powershell -ExecutionPolicy Bypass -File tools\test_send.ps1
```

`config\render_notifier.ini` is ignored by git, so the token never gets committed.

### 2. Install on a workstation

Close 3ds Max and double-click `Install.cmd`. It asks for administrator rights and copies the script
and the config to `C:\Program Files\Autodesk\3ds Max <version>\scripts\startup` of every installed
3ds Max. Start 3ds Max and render something.

`Uninstall.cmd` removes it. Per-user install without administrator rights:
`install\install.ps1` (goes to `%LOCALAPPDATA%\Autodesk\3dsMax\<version>\ENU\scripts\startup`).

### 3. Roll out to a studio

`tools\publish.ps1 -Target <shared folder>` copies everything needed for installation to a shared
folder (Dropbox, a network share). On each machine: close 3ds Max, run `Install.cmd` from that folder.

## Configuration

`render_notifier.ini` sits next to the script and is read before every render.

| Key | Meaning |
|---|---|
| `token`, `chat_id`, `thread_id` | Bot, chat and, optionally, a forum topic |
| `[computers]` section | `WINDOWS-NAME=label` for each machine, e.g. `RENDER-01=🟦 Farm 1` |
| `enabled` | `false` switches notifications off on this machine |
| `notify_start`, `notify_finish` | Which messages to send |
| `min_duration_sec` | Skip the finish message for renders shorter than this |
| `display_name` | Person's name shown next to the machine |
| `timeout_ms` | Telegram request timeout, 5000 by default |
| `crash_watch` | `false` disables the crash watchdog |

## Troubleshooting

The log is `%LOCALAPPDATA%\RenderNotifier\render_notifier.log`: script load, every render start and
end, and Telegram's answer to every request. The token is masked.

No log at all means 3ds Max did not load the script. Look for
`Hidden/System startup script ... skip loading` in `ENU\Network\Max.log`: since 2021.3, 3ds Max skips
startup scripts in folders with the Hidden or System attribute. The installer warns about it.

## Limitations

- A cancelled render looks the same as a finished one: 3ds Max reports the end of a render identically.
- The watchdog cannot tell a crash from closing 3ds Max by hand in the middle of a render, and does
  not notice a hung render or a power loss.
- Network rendering through a queue manager (Backburner, Deadline) is not covered.

## Development

- `src/render_notifier.ms` is the whole script. It must stay UTF-8 **with BOM** (Cyrillic and emoji).
- `tests/run_tests.ps1 -Years 2024,2026` runs it in `3dsmaxbatch.exe` (PowerShell 7) against a local
  HTTP listener instead of Telegram: message texts, encoding, Scene Manager queue, the watchdog
  (3ds Max is killed mid-render), Corona DR nodes, an unreachable network.
- `SPEC.md` is the original specification, `CLAUDE.md` holds the design notes.

## License

[MIT](LICENSE)
