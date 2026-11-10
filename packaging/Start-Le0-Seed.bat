@echo off
title Le0 Seed Node
cd /d "%~dp0"
echo Starting Le0 as a public seed (listen on port 37070)...
echo Allow port 37070 TCP through Windows Firewall / router if others should connect.
echo.

REM Best-effort firewall rule (needs Admin; ignore failure)
netsh advfirewall firewall add rule name="Le0 P2P 37070" dir=in action=allow protocol=TCP localport=37070 >nul 2>&1

set DATA=%LOCALAPPDATA%\Le0-seed
mkdir "%DATA%" 2>nul
(
  echo server=1
  echo listen=1
  echo port=37070
  echo rpcport=28445
  echo rpcuser=le0seed
  echo rpcpassword=le0-seed-local
  echo fallbackfee=0.0002
) > "%DATA%\le0.conf"

start "" "%~dp0le0-qt.exe" -datadir="%DATA%" -server=1 -listen=1 -port=37070
echo Seed GUI started. Leave it running 24/7 for the network.
pause
