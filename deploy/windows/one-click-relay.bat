@echo off
setlocal
set SCRIPT_DIR=%~dp0
set LOCK_FILE=%TEMP%\ethii-relay-launch.lock

if exist "%LOCK_FILE%" (
  echo [ETHII relay] Launcher is already running. Please use the existing window.
  pause
  exit /b 1
)

echo %DATE% %TIME%>"%LOCK_FILE%"

net session >nul 2>&1
if errorlevel 1 (
  echo [ETHII relay] Elevation required. Re-launching as Administrator...
  del "%LOCK_FILE%" >nul 2>&1
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup-relay-node.ps1"
if errorlevel 1 (
  echo.
  echo Relay setup failed. Review the messages above.
  del "%LOCK_FILE%" >nul 2>&1
  pause
  exit /b 1
)
echo.
echo Relay setup completed.
del "%LOCK_FILE%" >nul 2>&1
pause
