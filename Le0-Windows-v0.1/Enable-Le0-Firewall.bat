@echo off
:: Double-click and approve UAC — opens seed + explorer ports
netsh advfirewall firewall delete rule name="Le0 P2P 37070" >nul 2>&1
netsh advfirewall firewall delete rule name="Le0 Explorer 8080" >nul 2>&1
netsh advfirewall firewall add rule name="Le0 P2P 37070" dir=in action=allow protocol=TCP localport=37070
netsh advfirewall firewall add rule name="Le0 Explorer 8080" dir=in action=allow protocol=TCP localport=8080
echo.
echo Done. Ports 37070 (seed) and 8080 (explorer) allowed inbound.
pause
