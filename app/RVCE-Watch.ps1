<#
.SYNOPSIS
    Background watcher for the RVCE Wi-Fi. Lives in the system tray and checks once a minute.

.DESCRIPTION
    Every WatchIntervalSeconds (default 60) while you are on the RVCE Wi-Fi it:
      - checks internet access (one request to the Windows connectivity-check URL);
      - if online, refreshes the portal's own keep-alive page (what the portal's browser tab does);
      - if the portal has signed you out, signs you back in ONCE with the credentials saved in
        Windows Credential Manager (it never prompts and never uses anything else).
    Safeguards against repeated submissions:
      - at most one automatic sign-in every AutoSignInCooldownMinutes (default 5);
      - automatic sign-in stops completely if the portal rejects the credentials, the certificate
        changes, or it fails MaxAutoSignInFailures times in a row (default 3). Use "Sign in now"
        from the tray menu to resume.
    State changes (disconnects, sign-outs, re-sign-ins) are written to
    %LOCALAPPDATA%\RVCE-Connect\watch.log. Credentials are never logged.

.PARAMETER InstallStartup  Start the watcher automatically when you log in to Windows.
.PARAMETER RemoveStartup   Undo -InstallStartup.
.PARAMETER Stop            Stop a running watcher (stays signed in to the portal).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $InstallStartup,
    [switch] $RemoveStartup,
    [switch] $Stop,
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
. (Join-Path $ScriptDir 'RvceCommon.ps1')

$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'RVCE-Connect Watch.lnk'

# ---------------------------------------------------------------- one-shot commands
if ($InstallStartup) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($StartupLnk)
    # Use the no-window launcher so no terminal window appears at log-in.
    $launcher = Join-Path (Split-Path -Parent $ScriptDir) 'RVCE-Connect.exe'
    if (-not (Test-Path -LiteralPath $launcher)) { Write-Fail "Missing $launcher. Run app\Build-Launchers.ps1 first."; exit 1 }
    $lnk.TargetPath = $launcher
    $lnk.Arguments = '/watch'
    $lnk.WorkingDirectory = Split-Path -Parent $ScriptDir
    $lnk.Description = 'RVCE Wi-Fi watcher'
    $lnk.Save()
    Write-Ok "The watcher will start automatically when you log in ($StartupLnk)."
    exit 0
}
if ($RemoveStartup) {
    if (Test-Path -LiteralPath $StartupLnk) { Remove-Item -LiteralPath $StartupLnk -Force; Write-Ok 'Removed from startup.' }
    else { Write-Info 'It was not set to start automatically.' }
    exit 0
}
if ($Stop) {
    if (Stop-RvceWatcher) { Write-Ok 'Watcher stopped (you are still signed in to the portal).' }
    else { Write-Info 'The watcher was not running.' }
    exit 0
}

# ---------------------------------------------------------------- start-up
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$mutex = New-Object Threading.Mutex($false, $RvceWatchMutexName)
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    [void][Windows.Forms.MessageBox]::Show('The RVCE watcher is already running (look for the dot in the system tray).', 'RVCE-Connect')
    exit 0
}
$stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $RvceWatchStopEventName)
[void]$stopEvent.Reset()

try {
    $cfg = Read-RvceConfig $ConfigPath
    $TimeoutMs = [int]$cfg.TimeoutSeconds * 1000
    Initialize-RvceHelper $cfg
} catch {
    [void][Windows.Forms.MessageBox]::Show("RVCE watcher could not start: $($_.Exception.Message)", 'RVCE-Connect')
    $mutex.ReleaseMutex(); exit 5
}

# Mutable state lives in a hashtable so event handlers can update it.
$W = @{
    State = 'Starting'; Busy = $false; NextCheck = (Get-Date)
    LastAttempt = $null; Failures = 0; Blocked = $null; LastPortal = $null
}

# ---------------------------------------------------------------- tray icon
function New-DotIcon([Drawing.Color]$color) {
    $bmp = New-Object Drawing.Bitmap 16, 16
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $b = New-Object Drawing.SolidBrush $color
    $g.FillEllipse($b, 2, 2, 12, 12)
    $b.Dispose(); $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$Icons = @{
    Online  = New-DotIcon ([Drawing.Color]::FromArgb(46, 160, 67))    # green
    Working = New-DotIcon ([Drawing.Color]::FromArgb(230, 162, 30))   # amber
    Problem = New-DotIcon ([Drawing.Color]::FromArgb(207, 34, 46))    # red
    Away    = New-DotIcon ([Drawing.Color]::FromArgb(140, 140, 140))  # grey
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $Icons.Away
$tray.Text = 'RVCE: starting...'
$tray.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
function Add-MenuItem([string]$text, [scriptblock]$onClick) {
    $mi = New-Object Windows.Forms.ToolStripMenuItem $text
    if ($onClick) { $mi.Add_Click($onClick) }
    [void]$menu.Items.Add($mi)
    return $mi
}
function Add-Separator { [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }

$miStatus = Add-MenuItem 'Starting...' $null
$miStatus.Enabled = $false
Add-Separator
[void](Add-MenuItem 'Check now' { Invoke-WatchCheck -Manual })
[void](Add-MenuItem 'Sign in now...' {
    $W.Blocked = $null; $W.Failures = 0; $W.LastAttempt = $null
    Start-Process (Join-Path (Split-Path -Parent $ScriptDir) 'RVCE-Connect.exe')
    $W.NextCheck = (Get-Date).AddSeconds(30)
})
[void](Add-MenuItem 'Open portal in browser' {
    if ($W.LastPortal) { Open-InBrowser $W.LastPortal } else { Open-InBrowser ([Uri]$cfg.BrowserFallbackUrl) }
})
[void](Add-MenuItem 'Open connection log' {
    $log = Join-Path $RvceDataDir 'watch.log'
    if (Test-Path -LiteralPath $log) { Start-Process notepad.exe -ArgumentList ('"' + $log + '"') }
})
Add-Separator
[void](Add-MenuItem 'Sign out and exit' {
    $timer.Stop()
    Set-TrayState 'Working' 'Signing out...'
    $r = $null
    try { $r = Invoke-PortalLogout } catch { $r = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } }
    Write-RvceLog "Sign out from tray: $($r.Message)"
    Exit-Watcher
    [void][Windows.Forms.MessageBox]::Show($r.Message, 'RVCE-Connect')
})
[void](Add-MenuItem 'Exit (stay signed in)' { Write-RvceLog 'Watcher stopped from tray.'; Exit-Watcher })
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Invoke-WatchCheck -Manual })

function Set-TrayState([string]$kind, [string]$text) {
    $tray.Icon = $Icons[$kind]
    $t = "RVCE: $text"
    if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }   # NotifyIcon.Text limit
    $tray.Text = $t
    $miStatus.Text = "$text   (checked $(Get-Date -Format 'HH:mm'))"
}

function Show-Note([string]$text, [string]$level = 'Info') {
    $tray.ShowBalloonTip(6000, 'RVCE Wi-Fi', $text, [Windows.Forms.ToolTipIcon]::$level)
}

# Updates the tray; logs and (optionally) notifies only when the state actually changes.
function Set-WatchState([string]$state, [string]$kind, [string]$text, [string]$notify = '') {
    if ($W.State -ne $state) {
        Write-RvceLog "$state - $text"
        if ($notify) { Show-Note $text $notify }
    }
    $W.State = $state
    Set-TrayState $kind $text
}

function Set-Blocked([string]$reason) {
    $W.Blocked = $reason
    Set-WatchState 'Blocked' 'Problem' "Sign-in needed: $reason" 'Warning'
}

function Send-Keepalive {
    if (-not $cfg.UseKeepalive) { return }
    $s = Get-RvceSession
    if (-not $s -or -not ($s.PSObject.Properties.Name -contains 'KeepaliveUrl') -or -not $s.KeepaliveUrl) { return }
    [Uri]$u = $null
    if (-not [Uri]::TryCreate([string]$s.KeepaliveUrl, [UriKind]::Absolute, [ref]$u) -or -not [RvceWifi.Portal]::IsAllowed($u)) { return }
    $p = Get-PortalPage $u
    if ($p.Cert -ne 'Ok') { Write-RvceLog 'Keep-alive skipped: portal certificate does not match.' }
}

function Exit-Watcher {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    [Windows.Forms.Application]::ExitThread()
}

# ---------------------------------------------------------------- the check
function Invoke-WatchCheck([switch]$Manual) {
    if ($W.Busy) { return }
    $W.Busy = $true
    try {
        $wasOnRvce = @('Online', 'Captive', 'Retry', 'Blocked', 'Unreachable', 'Waiting') -contains $W.State

        # Wi-Fi
        $wifi = Get-WifiState
        if (-not (Test-ExpectedSsid $wifi)) {
            if ($wifi.Connected -and $wifi.Ssid) { Set-WatchState 'Away' 'Away' "On '$($wifi.Ssid)' (not $($cfg.Ssid)) - idle" }
            elseif ($wifi.Connected)            { Set-WatchState 'Away' 'Away' 'Wi-Fi name unreadable (Location off?) - idle' }
            elseif ($wasOnRvce)                 { Set-WatchState 'WifiDown' 'Problem' "Disconnected from $($cfg.Ssid) Wi-Fi" 'Warning' }
            else                                { Set-WatchState 'WifiDown' 'Away' 'Wi-Fi not connected - idle' }
            return
        }

        # Internet
        $probe = Invoke-Probe
        if ($probe.State -eq 'Online') {
            $note = ''
            if ($wasOnRvce -and $W.State -ne 'Online') { $note = 'Info' }
            Set-WatchState 'Online' 'Online' 'Online' $note
            $W.Failures = 0
            Send-Keepalive
            return
        }
        if ($probe.State -eq 'Unreachable') {
            Set-WatchState 'Unreachable' 'Problem' 'No internet and the portal is not responding' 'Warning'
            return
        }

        # Captive portal: the portal has signed us out (or we were never signed in).
        if ($W.State -eq 'Online') { Write-RvceLog 'Internet lost: the portal is asking for sign-in again.' }
        if ($W.Blocked) { Set-Blocked $W.Blocked; return }

        $cooldown = [int]$cfg.AutoSignInCooldownMinutes
        if ($W.LastAttempt -and ((Get-Date) - $W.LastAttempt).TotalMinutes -lt $cooldown -and -not $Manual) {
            $wait = [math]::Ceiling($cooldown - ((Get-Date) - $W.LastAttempt).TotalMinutes)
            Set-WatchState 'Waiting' 'Working' "Signed out - next automatic sign-in in $wait min"
            return
        }

        $cred = $null
        try { $cred = Get-StoredCredential } catch { }
        if (-not $cred) { Set-Blocked 'no saved credentials (use "Sign in now" and save them)'; return }

        $portal = $null
        if ($probe.PortalUrl) { $portal = Resolve-PortalUrl $probe.PortalUrl }
        if (-not $portal) { $cred.Password.Dispose(); Set-WatchState 'Captive' 'Problem' 'Signed out, but the portal address was not found' 'Warning'; return }
        $W.LastPortal = $portal
        if (-not [RvceWifi.Portal]::IsAllowed($portal)) { $cred.Password.Dispose(); Set-Blocked "unexpected portal address $($portal.Authority)"; return }

        $page = Get-PortalPage $portal
        if ($page.Cert -eq 'Untrusted') { $cred.Password.Dispose(); Set-Blocked 'portal certificate not confirmed yet'; return }
        if ($page.Cert -eq 'Changed')   { $cred.Password.Dispose(); Set-Blocked 'portal certificate CHANGED - check with IT'; return }
        if ($page.Response.Status -eq 0) {
            $cred.Password.Dispose()
            Set-WatchState 'Captive' 'Problem' 'Signed out, and the portal page is not responding' 'Warning'
            return
        }
        $form = Get-LoginForm $page.Response.Body $portal
        if (-not (Test-LoginForm $form)) { $cred.Password.Dispose(); Set-Blocked 'portal page not recognised (sign in in the browser)'; return }

        Set-TrayState 'Working' 'Signing in again...'
        $W.LastAttempt = Get-Date
        Write-RvceLog 'Signing in automatically with saved credentials (one attempt).'
        $res = Submit-PortalLogin $portal $form $cred
        $cred.Password.Dispose()

        switch ($res.Result) {
            'Online'   { $W.Failures = 0; Write-RvceLog 'Automatic sign-in succeeded.'; Set-WatchState 'Online' 'Online' 'Online (signed in again automatically)' 'Info' }
            'Rejected' { Set-Blocked 'the portal rejected the saved credentials' }
            default {
                $W.Failures++
                Write-RvceLog "Automatic sign-in failed: $($res.Result) $($res.Detail)"
                if ($W.Failures -ge [int]$cfg.MaxAutoSignInFailures) { Set-Blocked "automatic sign-in failed $($W.Failures) times" }
                else { Set-WatchState 'Retry' 'Problem' "Sign-in did not work ($($res.Result)); retrying in $cooldown min" 'Warning' }
            }
        }
    } catch {
        Write-RvceLog "Error during check: $($_.Exception.Message)"
        Set-TrayState 'Problem' 'Error during check (see log)'
    } finally {
        $W.Busy = $false
        $W.NextCheck = (Get-Date).AddSeconds([int]$cfg.WatchIntervalSeconds)
    }
}

# ---------------------------------------------------------------- main loop
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($stopEvent.WaitOne(0)) { Write-RvceLog 'Watcher stopped (stop requested).'; Exit-Watcher; return }
    if ((Get-Date) -ge $W.NextCheck) { Invoke-WatchCheck }
})

Write-RvceLog "Watcher started (checking every $($cfg.WatchIntervalSeconds)s)."
Show-Note "Watching your RVCE connection every $($cfg.WatchIntervalSeconds) seconds. Right-click the tray dot for options."
$timer.Start()
try {
    [Windows.Forms.Application]::Run()
} finally {
    $timer.Dispose()
    $stopEvent.Dispose()
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
