@echo off
title Le0 Network Host
cd /d "%~dp0"
net session >nul 2>&1
if not %errorlevel%==0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Le0-Host.ps1"
if errorlevel 1 pause
