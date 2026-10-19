@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" %*
exit /b %ERRORLEVEL%
