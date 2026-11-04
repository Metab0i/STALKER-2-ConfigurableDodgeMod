@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1" %*
pause
