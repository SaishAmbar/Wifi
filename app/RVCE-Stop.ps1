<#
.SYNOPSIS
    Disconnects: stops the RVCE background watcher (so it cannot sign you straight back in)
    and signs you out of the RV Institutions (Sophos) portal.
.PARAMETER WatcherOnly  Only stop the watcher; stay signed in to the portal.
.PARAMETER Gui          Show the result in a dialog box instead of the console (used when double-clicked).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $WatcherOnly,
    [switch] $Gui,
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
. (Join-Path $ScriptDir 'RvceCommon.ps1')

if ($Gui) { Initialize-RvceGui }

function Finish([string]$text, [string]$icon, [int]$code) {
    if ($Gui) { [void](Show-RvceMessage $text $icon) }
    else {
        if ($icon -eq 'Information') { Write-Host "[OK] $($text -replace "`n+", ' ')" -ForegroundColor Green }
        else { Write-Host "[X]  $($text -replace "`n+", ' ')" -ForegroundColor Red }
    }
    exit $code
}

try {
    $wasRunning = Stop-RvceWatcher

    if ($WatcherOnly) {
        if ($wasRunning) { Finish 'Watcher stopped.' 'Information' 0 }
        Finish 'Watcher was not running.' 'Information' 0
    }

    $cfg = Read-RvceConfig $ConfigPath
    $TimeoutMs = [int]$cfg.TimeoutSeconds * 1000
    Initialize-RvceHelper $cfg

    if (-not (Test-ExpectedSsid (Get-WifiState))) {
        Clear-RvceSession
        Finish "Watcher stopped.`nNot on the $($cfg.Ssid) Wi-Fi." 'Information' 0
    }
    if ((Invoke-Probe).State -ne 'Online') {
        Clear-RvceSession
        Finish 'Disconnected.' 'Information' 0
    }
    $r = Invoke-PortalLogout
    if ($r.Ok) { Finish 'Disconnected.' 'Information' 0 }
    Finish "Watcher stopped, but sign-out did not work.`n`n$($r.Message)" 'Warning' 2
} catch {
    Finish "Unexpected error:`n`n$($_.Exception.Message)" 'Error' 2
}
