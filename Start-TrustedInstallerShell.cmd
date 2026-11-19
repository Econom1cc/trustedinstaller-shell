@echo off
setlocal
title TrustedInstaller Shell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File %~dp0scripts\Start-TrustedInstallerShell.ps1 %*
exit /b %errorlevel%

