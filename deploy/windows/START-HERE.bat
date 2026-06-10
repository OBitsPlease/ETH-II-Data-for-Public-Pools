@echo off
setlocal
set SCRIPT_DIR=%~dp0

echo.
echo ETH II Windows Relay Bundle
echo.
echo This is the simplest way to run an ETH II node on Windows.
echo Double-clicking this file starts the self-elevating relay setup.
echo.
call "%SCRIPT_DIR%one-click-relay.bat"
exit /b %ERRORLEVEL%