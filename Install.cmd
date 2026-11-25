@echo off
rem Render Notifier: installs the script for every 3ds Max on this PC.
rem Double-click it. It asks for administrator rights by itself.
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install\install.ps1" -System -Force
echo.
pause
