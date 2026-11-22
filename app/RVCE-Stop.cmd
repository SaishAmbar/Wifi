@echo off
rem Console version of RVCE-Stop (the double-click version is ..\RVCE-Stop.exe).
rem   app\RVCE-Stop.cmd               disconnect: stop the watcher and sign out of the Wi-Fi portal
rem   app\RVCE-Stop.cmd -WatcherOnly  only stop the watcher (stay signed in)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RVCE-Stop.ps1" %*
