@echo off
rem Console version of RVCE-Stop (the double-click version is ..\RVCE-Stop.exe).
rem   app\RVCE-Stop.cmd            stop the watcher (stay signed in)
rem   app\RVCE-Stop.cmd -SignOut   stop the watcher and sign out of the Wi-Fi portal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RVCE-Stop.ps1" %*
