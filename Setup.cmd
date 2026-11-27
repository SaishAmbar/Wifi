@echo off
rem One-time setup for RVCE-Connect: builds RVCE-Connect.exe and RVCE-Stop.exe on this PC and adds desktop shortcuts.
rem Run it again if you move this folder.
echo Setting up RVCE-Connect...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Build-Launchers.ps1"
if errorlevel 1 (
    echo.
    echo Setup failed - see the message above.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\RVCE-Watch.ps1" -InstallStartup
echo.
echo Done. Double-click "RVCE Connect" on your desktop to sign in to the RVCE Wi-Fi.
echo (Its first run asks you to confirm the portal certificate and enter your own RVCE username and password.)
echo.
pause
