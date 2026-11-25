@echo off
rem Render Notifier: removes the script from every 3ds Max on this PC.
rem Double-click it. It asks for administrator rights by itself.
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install\uninstall.ps1" -System
echo.
pause
