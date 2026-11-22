<#
.SYNOPSIS
    Background watcher for the RVCE Wi-Fi (Sophos portal). Lives in the system tray.

.DESCRIPTION
    Only acts while you are on the RVCE Wi-Fi; on any other network (or with Wi-Fi off) it stays idle.
    On RVCE it:
      - checks internet access every WatchIntervalSeconds (default 1800 = 30 min), and a few seconds
        after the Wi-Fi connection changes (joining RVCE, waking from sleep). Change detection is local
        and sends nothing over the network;
      - while signed in, sends the portal's own keep-alive to the firewall every KeepaliveSeconds
        (default 180 s), exactly as the portal's browser tab does. If the firewall answers that you are
        signed out, it signs you back in straight away. Turn off with "UseKeepalive": false;
      - if you are not signed in, signs in ONCE with the credentials saved in Windows Credential Manager
        (it never prompts and never uses anything else).
    Safeguards against repeated submissions:
      - after a failed attempt it waits AutoSignInCooldownMinutes (default 5) before the next one;
      - automatic sign-in stops completely if the portal rejects the credentials, the certificate
        changes, or it fails MaxAutoSignInFailures times in a row (default 3). Use "Sign in now"
        from the tray menu to resume.
    State changes are written to %LOCALAPPDATA%\RVCE-Connect\watch.log. Credentials are never logged.

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
    if (-not (Test-Path -LiteralPath $launcher)) { Write-Fail "Missing $launcher. Run Setup.cmd first."; exit 1 }
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
    [void](Show-RvceMessage 'Watcher already running.' 'Information')
    exit 0
}
$stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $RvceWatchStopEventName)
[void]$stopEvent.Reset()

try {
    $cfg = Read-RvceConfig $ConfigPath
    $TimeoutMs = [int]$cfg.TimeoutSeconds * 1000
    Initialize-RvceHelper $cfg
} catch {
    [void](Show-RvceMessage "Watcher could not start:`n`n$($_.Exception.Message)" 'Error')
    $mutex.ReleaseMutex(); exit 5
}

# Mutable state lives in a hashtable so event handlers can update it.
$W = @{
    State = 'Starting'; Busy = $false; NextCheck = (Get-Date); NextKeepalive = $null
    NextNetLook = (Get-Date); NetSignature = $null
    LastAttempt = $null; Failures = 0; Blocked = $null
}

# Wi-Fi adapters that are up, with their IPv4 addresses. Purely local; used to notice network changes.
function Get-WifiSignature {
    try {
        $parts = foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211 -and
                $n.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up) {
                $ips = @($n.GetIPProperties().UnicastAddresses |
                         Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
                         ForEach-Object { $_.Address.ToString() }) -join ','
                "$($n.Id)=$ips"
            }
        }
        return (@($parts) -join ';')
    } catch { return '' }
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
[void](Add-MenuItem 'Open portal in browser' { Open-InBrowser (Get-PortalPageUrl) })
[void](Add-MenuItem 'Open connection log' {
    $log = Join-Path $RvceDataDir 'watch.log'
    if (Test-Path -LiteralPath $log) { Start-Process notepad.exe -ArgumentList ('"' + $log + '"') }
})
Add-Separator
[void](Add-MenuItem 'Disconnect and exit' {
    $timer.Stop()
    Set-TrayState 'Working' 'Signing out...'
    $r = $null
    try { $r = Invoke-PortalLogout } catch { $r = [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } }
    Write-RvceLog "Sign out from tray: $($r.Message)"
    Exit-Watcher
    if ($r.Ok) { [void](Show-RvceMessage 'Disconnected.' 'Information') }
    else { [void](Show-RvceMessage "Watcher stopped, but sign-out did not work.`n`n$($r.Message)" 'Warning') }
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

function Exit-Watcher {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    [Windows.Forms.Application]::ExitThread()
}

# ---------------------------------------------------------------- keep-alive (between full checks)
function Invoke-Keepalive {
    $W.NextKeepalive = (Get-Date).AddSeconds([int]$cfg.KeepaliveSeconds)
    if ([string]::IsNullOrEmpty([string]$cfg.PinnedCertSha256)) { $W.NextKeepalive = $null; return }
    $user = Get-PortalUser
    if (-not $user) { return }
    switch (Send-SophosKeepalive $user) {
        'Ok'        { }
        'Off'       { $W.NextKeepalive = $null }   # the portal does not want keep-alives
        'SignedOut' { Write-RvceLog 'Keep-alive: the portal says you were signed out.'; $W.NextCheck = Get-Date }
        default     { $W.NextCheck = Get-Date }    # portal unreachable: do a full check now
    }
}

# ---------------------------------------------------------------- the full check
function Invoke-WatchCheck([switch]$Manual) {
    if ($W.Busy) { return }
    $W.Busy = $true
    $next = [int]$cfg.WatchIntervalSeconds
    try {
        $wasOnRvce = @('Online', 'Captive', 'Retry', 'Blocked', 'Unreachable', 'Waiting') -contains $W.State
        $W.NextKeepalive = $null

        # Pick up a certificate confirmed (or reset) by RVCE Connect while the watcher was running.
        try {
            $pin = [string](Read-RvceConfig $ConfigPath).PinnedCertSha256
            if ($pin -ne [string]$cfg.PinnedCertSha256) {
                $cfg.PinnedCertSha256 = $pin; [RvceWifi.Portal]::PinnedSha256 = $pin
                if ($W.Blocked -like '*certificate*') { $W.Blocked = $null }
            }
        } catch { }

        # Wi-Fi: on any other network (or none), leave everything as it is.
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
            if ($cfg.UseKeepalive) { $W.NextKeepalive = (Get-Date).AddSeconds([int]$cfg.KeepaliveSeconds) }
            return
        }

        # Not signed in: sign in once (subject to the safeguards).
        if ($W.State -eq 'Online') { Write-RvceLog "Internet lost ($($probe.State)): signing in again." }
        if ($W.Blocked) { Set-Blocked $W.Blocked; return }

        $cooldown = [int]$cfg.AutoSignInCooldownMinutes
        if ($W.LastAttempt -and ((Get-Date) - $W.LastAttempt).TotalMinutes -lt $cooldown -and -not $Manual) {
            $wait = [math]::Ceiling($cooldown - ((Get-Date) - $W.LastAttempt).TotalMinutes)
            Set-WatchState 'Waiting' 'Working' "Signed out - next automatic sign-in in $wait min"
            $next = 60
            return
        }

        $cred = $null
        try { $cred = Get-StoredCredential } catch { }
        if (-not $cred) { Set-Blocked 'no saved credentials (use "Sign in now" and save them)'; return }

        $page = Get-PortalPage (Get-PortalPageUrl)
        if ($page.Cert -eq 'Untrusted') { $cred.Password.Dispose(); Set-Blocked 'portal certificate not confirmed yet (use "Sign in now")'; return }
        if ($page.Cert -eq 'Changed')   { $cred.Password.Dispose(); Set-Blocked 'portal certificate CHANGED - check with IT'; return }
        if ($page.Response.Status -eq 0) {
            $cred.Password.Dispose()
            Set-WatchState 'Unreachable' 'Problem' 'No internet and the portal is not responding' 'Warning'
            $next = $cooldown * 60
            return
        }

        Set-TrayState 'Working' 'Signing in...'
        $W.LastAttempt = Get-Date
        Write-RvceLog 'Signing in automatically with saved credentials (one attempt).'
        $res = Invoke-SophosLogin $cred
        $cred.Password.Dispose()

        switch ($res.Result) {
            'Online' {
                $W.Failures = 0
                Write-RvceLog 'Automatic sign-in succeeded.'
                Set-WatchState 'Online' 'Online' 'Online (signed in automatically)' 'Info'
                if ($cfg.UseKeepalive) { $W.NextKeepalive = (Get-Date).AddSeconds([int]$cfg.KeepaliveSeconds) }
            }
            'Rejected' { Set-Blocked "the portal rejected the saved credentials ($($res.Detail))" }
            default {
                $W.Failures++
                Write-RvceLog "Automatic sign-in failed: $($res.Result) $($res.Detail)"
                if ($W.Failures -ge [int]$cfg.MaxAutoSignInFailures) { Set-Blocked "automatic sign-in failed $($W.Failures) times" }
                else {
                    Set-WatchState 'Retry' 'Problem' "Sign-in did not work ($($res.Result)); retrying in $cooldown min" 'Warning'
                    $next = $cooldown * 60
                }
            }
        }
    } catch {
        Write-RvceLog "Error during check: $($_.Exception.Message)"
        Set-TrayState 'Problem' 'Error during check (see log)'
        $next = [int]$cfg.AutoSignInCooldownMinutes * 60
    } finally {
        $W.Busy = $false
        $W.NextCheck = (Get-Date).AddSeconds($next)
    }
}

# ---------------------------------------------------------------- main loop
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($stopEvent.WaitOne(0)) { Write-RvceLog 'Watcher stopped (stop requested).'; Exit-Watcher; return }
    if ($W.Busy) { return }
    $now = Get-Date
    # Every 15 s, look (locally) for a Wi-Fi change; if there is one, check a few seconds later.
    if ($now -ge $W.NextNetLook) {
        $W.NextNetLook = $now.AddSeconds(15)
        $sig = Get-WifiSignature
        if ($null -ne $W.NetSignature -and $sig -ne $W.NetSignature) {
            Write-RvceLog 'Wi-Fi connection changed: checking shortly.'
            $soon = $now.AddSeconds(5)
            if ($W.NextCheck -gt $soon) { $W.NextCheck = $soon }
        }
        $W.NetSignature = $sig
    }
    if ($now -ge $W.NextCheck) { Invoke-WatchCheck; return }
    if ($W.NextKeepalive -and $now -ge $W.NextKeepalive) { Invoke-Keepalive }
})

$mins = [math]::Round([int]$cfg.WatchIntervalSeconds / 60)
Write-RvceLog "Watcher started (full check every $mins min; keep-alive $(if ($cfg.UseKeepalive) { "every $($cfg.KeepaliveSeconds) s" } else { 'off' }))."
Show-Note "Watching your RVCE connection. Right-click the tray dot for options."
$timer.Start()
try {
    [Windows.Forms.Application]::Run()
} finally {
    $timer.Dispose()
    $stopEvent.Dispose()
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
