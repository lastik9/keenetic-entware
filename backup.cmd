@echo off
rem Wrapper: fixes ExecutionPolicy (Restricted by default) and working directory.
rem Double-click safe: new console opens in %USERPROFILE%, not in the repo.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup.ps1" %*
set RC=%ERRORLEVEL%
if "%~1"=="" pause
exit /b %RC%
