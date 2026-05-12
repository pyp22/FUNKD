@echo off
setlocal

set "URL=https://raw.githubusercontent.com/pyp22/pyp22/master/openwrt/test-adguardhome-client.ps1"
set "TMP=%TEMP%\test-adguardhome-client.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%URL%' -OutFile '%TMP%' -UseBasicParsing"
if errorlevel 1 (
    echo [X] Echec du telechargement du script.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%TMP%" %*
set "EXIT=%ERRORLEVEL%"

del /q "%TMP%" 2>nul
pause
exit /b %EXIT%
