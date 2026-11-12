<#
.SYNOPSIS
    Stops the RVCE background watcher. You stay signed in to the portal.
.PARAMETER SignOut  Also sign out of the RV Institutions captive portal.
.PARAMETER Gui      Show the result in a dialog box instead of the console (used when double-clicked).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $SignOut,
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

    if (-not $SignOut) {
        if ($wasRunning) { Finish 'Watcher stopped.' 'Information' 0 }
        Finish 'Watcher was not running.' 'Information' 0
    }

    # Optional: also sign out of the portal.
    $cfg = Read-RvceConfig $ConfigPath
    $TimeoutMs = [int]$cfg.TimeoutSeconds * 1000
    Initialize-RvceHelper $cfg

    if (-not (Test-ExpectedSsid (Get-WifiState))) {
        Clear-RvceSession
        Finish "Watcher stopped.`n`nNot connected to '$($cfg.Ssid)', so there is no portal session to sign out of." 'Information' 0
    }
    if ((Invoke-Probe).State -ne 'Online') {
        Clear-RvceSession
        Finish "Watcher stopped.`n`nYou are already signed out of the portal." 'Information' 0
    }
    $r = Invoke-PortalLogout
    if ($r.Ok) { Finish "Watcher stopped.`n`n$($r.Message)" 'Information' 0 }
    Finish "Watcher stopped, but signing out did not work.`n`n$($r.Message)" 'Warning' 2
} catch {
    Finish "Unexpected error:`n`n$($_.Exception.Message)" 'Error' 2
}
