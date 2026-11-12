@echo off
rem One-time setup for RVCE-Connect: builds RVCE-Connect.exe and RVCE-Stop.exe on this PC.
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
echo.
echo Done. Double-click RVCE-Connect.exe to sign in to the RVCE Wi-Fi.
echo (Its first run asks you to confirm the portal certificate and enter your own RVCE username and password.)
echo.
pause
