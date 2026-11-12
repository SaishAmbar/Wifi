@echo off
rem Console version of RVCE-Connect (the double-click version is ..\RVCE-Connect.exe). Examples:
rem   app\RVCE-Connect.cmd -Status            check only, never sends credentials
rem   app\RVCE-Connect.cmd -BrowserOnly       open the portal in your browser
rem   app\RVCE-Connect.cmd -NoWatch           sign in without starting the watcher
rem   app\RVCE-Connect.cmd -ForgetCredential  delete the saved credential
rem   app\RVCE-Connect.cmd -InstallStartup    start the watcher when you log in (-RemoveStartup to undo)
rem "-ExecutionPolicy Bypass" applies to this one PowerShell process only.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RVCE-Connect.ps1" %*
