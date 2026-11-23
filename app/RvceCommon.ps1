# Shared functions for RVCE-Connect.ps1, RVCE-Watch.ps1 and RVCE-Stop.ps1.
# Dot-source this file. Callers must set $cfg (from Read-RvceConfig), $TimeoutMs and $ConfigPath.
#
# Security rules enforced here:
#  - Credentials are only POSTed to the allow-listed HTTPS portal with the pinned certificate.
#  - Credentials are never written to output, logs or files (only to Windows Credential Manager, on request).

$RvceDataDir = Join-Path $env:LOCALAPPDATA 'RVCE-Connect'
$RvceWatchMutexName = 'Local\RVCE-Connect-Watch'
$RvceWatchStopEventName = 'Local\RVCE-Connect-Watch-Stop'

# ---------------------------------------------------------------- output helpers
# In dialog mode (double-clicked launchers) messages are also collected for the final dialog box.
$RvceUi = @{ Gui = $false; Owner = $null; Log = (New-Object System.Collections.Generic.List[string]) }

function Write-Step([string]$m) { Write-Host "-> $m" -ForegroundColor Cyan }
function Write-Info([string]$m) { Write-Host "   $m"; if ($RvceUi.Gui) { $RvceUi.Log.Add($m) } }
function Write-Ok  ([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green; if ($RvceUi.Gui) { $RvceUi.Log.Add($m) } }
function Write-Warn2([string]$m){ Write-Host "[!]  $m" -ForegroundColor Yellow; if ($RvceUi.Gui) { $RvceUi.Log.Add($m) } }
function Write-Fail([string]$m) { Write-Host "[X]  $m" -ForegroundColor Red; if ($RvceUi.Gui) { $RvceUi.Log.Add($m) } }

# ---------------------------------------------------------------- dialog boxes
# An invisible, always-on-top owner window keeps every dialog in front of other windows.
function Initialize-RvceGui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $f = New-Object Windows.Forms.Form
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true
    $f.StartPosition = 'CenterScreen'; $f.Size = New-Object Drawing.Size(1, 1); $f.Opacity = 0
    $f.Show(); $f.Activate()
    $RvceUi.Owner = $f
    $RvceUi.Gui = $true
}

# Message dialog with a fixed, comfortable width (the standard Windows message box sizes itself to the text).
# icon: Information | Warning | Error | Question ; buttons: OK | YesNo ; default: Button1 | Button2
# Returns 'OK', 'Yes' or 'No' (closing a Yes/No dialog with X counts as 'No').
$RvceDialogWidth = 360

# Current Windows (10/11) stock icons; falls back to the classic .NET icons if unavailable.
function Get-RvceStockIcon([string]$name) {
    Add-Type -AssemblyName System.Drawing
    if (-not ('RvceWifi.StockIcon' -as [type])) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
namespace RvceWifi {
    public static class StockIcon {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHSTOCKICONINFO {
            public uint cbSize; public IntPtr hIcon; public int iSysImageIndex; public int iIcon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szPath;
        }
        [DllImport("shell32.dll")] private static extern int SHGetStockIconInfo(int siid, uint flags, ref SHSTOCKICONINFO info);
        [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr h);
        public static Bitmap Get(int siid) {
            SHSTOCKICONINFO info = new SHSTOCKICONINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(SHSTOCKICONINFO));
            if (SHGetStockIconInfo(siid, 0x100 /* SHGSI_ICON | SHGSI_LARGEICON */, ref info) != 0 || info.hIcon == IntPtr.Zero) return null;
            try { using (Icon ic = Icon.FromHandle(info.hIcon)) { return ic.ToBitmap(); } }
            finally { DestroyIcon(info.hIcon); }
        }
    }
}
'@
    }
    $siid = @{ Information = 79; Warning = 78; Error = 80; Question = 23 }[$name]
    $bmp = $null
    try { $bmp = [RvceWifi.StockIcon]::Get([int]$siid) } catch { }
    if (-not $bmp) { $bmp = ([Drawing.SystemIcons]::$name).ToBitmap() }
    return $bmp
}

function Show-RvceMessage([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK', [string]$default = 'Button1') {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $w = $RvceDialogWidth
    $f = New-Object Windows.Forms.Form
    $f.Text = 'RVCE Wi-Fi'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.ShowIcon = $false; $f.ShowInTaskbar = $true; $f.TopMost = $true; $f.StartPosition = 'CenterScreen'
    $f.BackColor = [Drawing.Color]::White
    $f.Font = New-Object Drawing.Font('Segoe UI', 9.5)

    $pic = New-Object Windows.Forms.PictureBox
    $pic.Image = Get-RvceStockIcon $icon
    $pic.SizeMode = 'Zoom'
    $pic.Size = New-Object Drawing.Size(32, 32); $pic.Location = New-Object Drawing.Point(24, 24)

    $lbl = New-Object Windows.Forms.Label
    $lbl.Font = $f.Font
    $lbl.UseMnemonic = $false
    $lbl.Text = $text
    $textWidth = $w - 72 - 24
    # Measure with the label's real font and word wrapping, so long messages are never cut off.
    $flags = [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::NoPrefix
    $meas = [Windows.Forms.TextRenderer]::MeasureText($text, $lbl.Font, (New-Object Drawing.Size($textWidth, 0)), $flags)
    $textHeight = $meas.Height + 6
    $lbl.AutoSize = $false
    $lbl.Size = New-Object Drawing.Size($textWidth, [Math]::Max(32, $textHeight))
    $lbl.Location = New-Object Drawing.Point(72, 24)
    if ($textHeight -lt 32) { $lbl.TextAlign = 'MiddleLeft' }

    $bandTop = 24 + $lbl.Height + 22
    $band = New-Object Windows.Forms.Panel
    $band.BackColor = [Drawing.SystemColors]::Control
    $band.Location = New-Object Drawing.Point(0, $bandTop); $band.Size = New-Object Drawing.Size($w, 52)

    $specs = @(@{ Text = 'OK'; Result = 'OK' })
    if ($buttons -eq 'YesNo') { $specs = @(@{ Text = 'Yes'; Result = 'Yes' }, @{ Text = 'No'; Result = 'No' }) }
    $btns = @()
    $x = $w - 16
    for ($i = $specs.Count - 1; $i -ge 0; $i--) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $specs[$i].Text
        $b.DialogResult = [Windows.Forms.DialogResult]::($specs[$i].Result)
        $b.Size = New-Object Drawing.Size(96, 30)
        $x -= 96
        $b.Location = New-Object Drawing.Point($x, 11)
        $x -= 8
        $band.Controls.Add($b)
        $btns = @($b) + $btns
    }
    $defIndex = 0; if ($default -eq 'Button2' -and $btns.Count -gt 1) { $defIndex = 1 }
    $f.AcceptButton = $btns[$defIndex]
    $f.CancelButton = $btns[$btns.Count - 1]

    $f.Controls.AddRange(@($pic, $lbl, $band))
    $f.ClientSize = New-Object Drawing.Size($w, ($bandTop + 52))
    $defBtn = $btns[$defIndex]
    $f.Add_Shown({ $f.Activate(); [void]$defBtn.Focus() })

    $r = $f.ShowDialog($RvceUi.Owner)
    $f.Dispose()
    $s = [string]$r
    if ($s -eq 'Cancel') { if ($buttons -eq 'YesNo') { $s = 'No' } else { $s = 'OK' } }
    return $s
}

# Yes/No question: a dialog in dialog mode, a console prompt otherwise.
function Confirm-RvceChoice([string]$question, [bool]$defaultYes) {
    if ($RvceUi.Gui) {
        $d = 'Button2'; if ($defaultYes) { $d = 'Button1' }
        return (Show-RvceMessage $question 'Question' 'YesNo' $d) -eq 'Yes'
    }
    if ($defaultYes) { return (Read-Host "$question [Y/n]") -notmatch '^(n|no)$' }
    return (Read-Host "$question [y/N]") -match '^(y|yes)$'
}

# Windows credential dialog, on top of other windows. Returns $null if cancelled.
function Read-GuiCredential {
    $user = $null
    $pw = [RvceWifi.CredPrompt]::Prompt($RvceUi.Owner.Handle, 'RVCE Wi-Fi sign-in',
        'Enter your RV Institutions username and password.', 'RVCE Wi-Fi', [ref]$user)
    if (-not $pw -or $pw.Length -eq 0 -or -not $user) { return $null }
    return [pscustomobject]@{ UserName = $user.Trim().TrimStart('\'); Password = $pw; FromStore = $false }
}

# Event log of connection state changes. Never contains credentials.
function Write-RvceLog([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $RvceDataDir)) { New-Item -ItemType Directory -Path $RvceDataDir | Out-Null }
        $log = Join-Path $RvceDataDir 'watch.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
            Move-Item -LiteralPath $log -Destination "$log.old" -Force
        }
        Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg) -Encoding UTF8
    } catch { }
}


# ---------------------------------------------------------------- configuration
$RvceDefaults = [ordered]@{
    Ssid = 'RVCE'; PortalHost = '172.16.0.4'; PortalPort = 8090; PinnedCertSha256 = ''
    PortalCertName = 'rvce-fw.rvce.edu.in'
    CredentialTarget = 'RVCE-Connect:CaptivePortal'
    ProbeUrl = 'http://www.msftconnecttest.com/connecttest.txt'
    ProbeExpectedBody = 'Microsoft Connect Test'
    TimeoutSeconds = 10; VerifyAttempts = 5; VerifyIntervalSeconds = 2
    WatchIntervalSeconds = 1800; UseKeepalive = $true; KeepaliveSeconds = 180
    AutoSignInCooldownMinutes = 5; MaxAutoSignInFailures = 3
}

function Read-RvceConfig([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        # First run: create this user's own config.json (not tracked by git) from the shipped defaults.
        $default = Join-Path (Split-Path -Parent $Path) 'config.default.json'
        if (-not (Test-Path -LiteralPath $default)) { throw "Config file not found: $Path (and no config.default.json)" }
        Copy-Item -LiteralPath $default -Destination $Path
    }
    try { $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "config.json is not valid JSON: $($_.Exception.Message)" }

    $changed = $false
    foreach ($k in $RvceDefaults.Keys) {
        if (-not ($c.PSObject.Properties.Name -contains $k) -or $null -eq $c.$k) {
            $c | Add-Member -NotePropertyName $k -NotePropertyValue $RvceDefaults[$k] -Force
            $changed = $true
        }
    }
    # Migrate configs from the FortiGate era (portal 172.16.0.2:1003, checks every 60 s) and the first Sophos default (1500 s) to the Sophos portal.
    # The old certificate pin belongs to the old portal, so it is cleared and confirmed again on the next run.
    if ($c.PortalHost -eq '172.16.0.2' -and [int]$c.PortalPort -eq 1003) {
        $c.PortalHost = $RvceDefaults.PortalHost; $c.PortalPort = $RvceDefaults.PortalPort; $c.PinnedCertSha256 = ''
        $changed = $true
    }
    if (@(60, 1500) -contains [int]$c.WatchIntervalSeconds) { $c.WatchIntervalSeconds = $RvceDefaults.WatchIntervalSeconds; $changed = $true }
    if ($c.PSObject.Properties.Name -contains 'BrowserFallbackUrl') { $c.PSObject.Properties.Remove('BrowserFallbackUrl'); $changed = $true }
    if ($changed) {
        try { Save-RvceConfig $c $Path; Write-RvceLog 'config.json updated (Sophos portal defaults).' } catch { }
    }

    $probe = $null
    if ([string]::IsNullOrWhiteSpace($c.Ssid) -or [string]::IsNullOrWhiteSpace($c.PortalHost) -or
        [int]$c.PortalPort -lt 1 -or [int]$c.PortalPort -gt 65535 -or
        -not [Uri]::TryCreate([string]$c.ProbeUrl, [UriKind]::Absolute, [ref]$probe) -or $probe.Scheme -ne 'http') {
        throw 'config.json: Ssid, PortalHost, PortalPort (1-65535) and an http:// ProbeUrl are required.'
    }
    if ([int]$c.WatchIntervalSeconds -lt 60) { $c.WatchIntervalSeconds = 60 }
    if ([int]$c.KeepaliveSeconds -lt 30) { $c.KeepaliveSeconds = 30 }
    if ([int]$c.AutoSignInCooldownMinutes -lt 2) { $c.AutoSignInCooldownMinutes = 2 }
    return $c
}

function Save-RvceConfig($c, [string]$Path) {
    $json = $c | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Initialize-RvceHelper($c) {
    if (-not ('RvceWifi.Portal' -as [type])) {
        $src = Join-Path $PSScriptRoot 'RvceHelper.cs'
        if (-not (Test-Path -LiteralPath $src)) { throw "Missing helper file: $src" }
        Add-Type -TypeDefinition (Get-Content -LiteralPath $src -Raw) -Language CSharp
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    [RvceWifi.Portal]::AllowedHost  = [string]$c.PortalHost
    [RvceWifi.Portal]::AllowedPort  = [int]$c.PortalPort
    [RvceWifi.Portal]::PinnedSha256 = [string]$c.PinnedCertSha256
    [RvceWifi.Portal]::TrustedName  = [string]$c.PortalCertName
}

function Set-PinnedCertificate([string]$sha) {
    $cfg.PinnedCertSha256 = $sha
    [RvceWifi.Portal]::PinnedSha256 = $sha
    Save-RvceConfig $cfg $ConfigPath
}

# If the last request accepted a renewed portal certificate (see Portal.IsTrustedRenewal), pin the new one.
function Update-RenewedPin {
    $new = [RvceWifi.Portal]::RenewedSha256
    [RvceWifi.Portal]::RenewedSha256 = $null
    if ($new -and $new -ine [string]$cfg.PinnedCertSha256) {
        try { Set-PinnedCertificate $new } catch { }
        Write-RvceLog "Portal certificate renewed ($($cfg.PortalCertName)); new SHA-256 $(Format-Fingerprint $new)."
    }
}

# ---------------------------------------------------------------- Wi-Fi
function Get-WifiState {
    $state = [pscustomobject]@{ HasWifi = $true; Connected = $false; Ssid = $null; Source = 'netsh'; LocationBlocked = $false }
    $out = ''
    try { $out = (& netsh.exe wlan show interfaces 2>&1 | Out-String) } catch { $out = '' }

    if ($out -match '(?i)There is no wireless interface') { $state.HasWifi = $false; return $state }
    if ($out -match '(?i)location permission|location services') { $state.LocationBlocked = $true }

    $st = [regex]::Match($out, '(?m)^\s*State\s*:\s*(.+?)\s*$')
    $ss = [regex]::Match($out, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
    if ($st.Success -and $st.Groups[1].Value -eq 'connected') { $state.Connected = $true }
    if ($ss.Success) { $state.Ssid = $ss.Groups[1].Value }

    if (-not $state.Ssid) {
        # Fallback (e.g. location permission off): the network profile name is normally the SSID.
        try {
            $nic = Get-NetAdapter -Physical -ErrorAction Stop |
                   Where-Object { $_.Status -eq 'Up' -and ($_.NdisPhysicalMedium -eq 9 -or $_.PhysicalMediaType -match '802\.11') } |
                   Select-Object -First 1
            if ($nic) {
                $prof = Get-NetConnectionProfile -InterfaceIndex $nic.ifIndex -ErrorAction Stop | Select-Object -First 1
                if ($prof) { $state.Connected = $true; $state.Ssid = $prof.Name; $state.Source = 'network profile name' }
            }
        } catch { }
    }
    return $state
}

function Test-ExpectedSsid($state) {
    if (-not $state.Connected -or -not $state.Ssid) { return $false }
    if ($state.Source -eq 'netsh') { return $state.Ssid -ceq $cfg.Ssid }
    return $state.Ssid -match ('^' + [regex]::Escape($cfg.Ssid) + '( \d+)?$')
}

# ---------------------------------------------------------------- internet check
# One plain-HTTP request to the Windows connectivity-check URL. State: Online | Captive | Unreachable.
function Invoke-Probe {
    $r = [RvceWifi.Portal]::Get([string]$cfg.ProbeUrl, $TimeoutMs)
    if ($r.Status -eq 0) { return [pscustomobject]@{ State = 'Unreachable'; Detail = $r.Error } }
    if ($r.Status -eq 200 -and $r.Body -and $r.Body.Trim() -eq $cfg.ProbeExpectedBody) {
        return [pscustomobject]@{ State = 'Online'; Detail = $null }
    }
    return [pscustomobject]@{ State = 'Captive'; Detail = "HTTP $($r.Status)" }
}

# ---------------------------------------------------------------- Sophos portal
# Protocol (from the portal's own /javascript/validation/httpclient.js):
#   sign in   POST /login.xml   mode=191 username password a=<ms> producttype=0
#             reply <status>: LIVE = signed in, LOGIN = rejected (reason in <message>), CHALLENGE = extra step
#   sign out  POST /logout.xml  mode=193 username a producttype=0     reply <status>LOGIN
#   keep-alive GET /live?mode=192&username=<lower>&a=<ms>&producttype=0   reply <ack>: ack | nack | login_again | live_off
# The portal page sends a keep-alive every 180 s and signs out when its tab is closed.
function Get-PortalBase { 'https://{0}:{1}' -f $cfg.PortalHost, [int]$cfg.PortalPort }
function Get-PortalPageUrl { [Uri]((Get-PortalBase) + '/httpclient.html') }
function Get-SophosTime { [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Value of <tag> in a Sophos XML reply (CDATA or plain text). Regex instead of an XML parser: the replies are tiny.
function Get-SophosTag([string]$xml, [string]$tag) {
    if (-not $xml) { return $null }
    $m = [regex]::Match($xml, '(?is)<' + $tag + '>\s*(?:<!\[CDATA\[(.*?)\]\]>|([^<]*))\s*</' + $tag + '>')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value.Trim() }
    return [Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()
}

function Format-Fingerprint([string]$hex) {
    if (-not $hex) { return '' }
    return (($hex.ToUpper() -split '(..)' | Where-Object { $_ }) -join ':')
}

# GET a page on the allow-listed HTTPS portal with the pinned certificate.
# Cert: 'Ok' | 'Untrusted' (nothing pinned yet) | 'Changed' (pin mismatch).
function Get-PortalPage([Uri]$u) {
    [RvceWifi.Portal]::ResetLastCert()
    $r = [RvceWifi.Portal]::Get($u.AbsoluteUri, $TimeoutMs)
    Update-RenewedPin
    $seen = [RvceWifi.Portal]::LastCertSha256
    $cert = 'Ok'
    if ($r.Status -eq 0 -and $seen -and $seen -ine [string]$cfg.PinnedCertSha256) {
        if ([string]::IsNullOrEmpty([string]$cfg.PinnedCertSha256)) { $cert = 'Untrusted' } else { $cert = 'Changed' }
    }
    return [pscustomobject]@{ Response = $r; Cert = $cert; SeenSha256 = $seen }
}

# Signs in ONCE and verifies access. Never retries.
# Result: Online | Rejected | Timeout | NotVerified | Error ; Detail: the portal's message or the error.
function Invoke-SophosLogin($Cred) {
    $res = [pscustomobject]@{ Result = ''; Detail = '' }
    $user = $Cred.UserName.Replace("'", "''")   # the portal's own page escapes quotes this way
    $resp = $null
    try {
        $resp = [RvceWifi.Portal]::PostLogin((Get-PortalBase) + '/login.xml', (Get-PortalPageUrl).AbsoluteUri,
            [string[]]@('mode', 'a', 'producttype'), [string[]]@('191', (Get-SophosTime), '0'),
            'username', $user, 'password', $Cred.Password, $TimeoutMs)
        Update-RenewedPin
    } catch {
        $res.Result = 'Error'; $res.Detail = $_.Exception.Message
        return $res
    }
    if ($resp.Status -eq 0) { $res.Result = 'Timeout'; $res.Detail = $resp.Error; return $res }

    $status = Get-SophosTag $resp.Body 'status'
    $msg = Get-SophosTag $resp.Body 'message'
    if ($msg) { $msg = ($msg -replace '\{username\}', $Cred.UserName).Trim() }

    if ($status -eq 'LIVE') {
        Save-RvceSession $Cred.UserName
        for ($i = 1; $i -le [int]$cfg.VerifyAttempts; $i++) {
            Start-Sleep -Seconds ([int]$cfg.VerifyIntervalSeconds)
            if ((Invoke-Probe).State -eq 'Online') { $res.Result = 'Online'; return $res }
        }
        $res.Result = 'NotVerified'; $res.Detail = 'The portal says you are signed in, but the internet check still fails.'
        return $res
    }
    if ($status -eq 'CHALLENGE') {
        $res.Result = 'Rejected'
        $res.Detail = 'The portal asked for an extra verification step that this tool does not support. Sign in in the browser.'
        return $res
    }
    if ($status -eq 'LOGIN') {
        $res.Result = 'Rejected'
        $res.Detail = $msg; if (-not $res.Detail) { $res.Detail = 'The portal rejected the sign-in.' }
        return $res
    }
    $res.Result = 'Error'; $res.Detail = "Unexpected reply from the portal (HTTP $($resp.Status))."
    return $res
}

# Keep-alive, as the portal page sends it. Returns Ok | SignedOut | Off | Failed.
function Send-SophosKeepalive([string]$user) {
    $q = 'mode=192&username=' + [Uri]::EscapeDataString($user.ToLowerInvariant()) + '&a=' + (Get-SophosTime) + '&producttype=0'
    $r = [RvceWifi.Portal]::Get((Get-PortalBase) + '/live?' + $q, $TimeoutMs)
    Update-RenewedPin
    if ($r.Status -ne 200) { return 'Failed' }
    switch (Get-SophosTag $r.Body 'ack') {
        'ack'         { return 'Ok' }
        'nack'        { return 'SignedOut' }
        'login_again' { return 'SignedOut' }
        'live_off'    { return 'Off' }
    }
    return 'Failed'
}

# Signs out of the portal. Returns @{ Ok; Message }.
function Invoke-PortalLogout {
    if ([string]::IsNullOrEmpty([string]$cfg.PinnedCertSha256)) {
        return [pscustomobject]@{ Ok = $false; Message = 'Sign in once with RVCE Connect first (the portal certificate is not confirmed yet).' }
    }
    $user = Get-PortalUser
    if (-not $user) {
        return [pscustomobject]@{ Ok = $false; Message = 'No saved username to sign out with. Use Sign out on the portal page in your browser.' }
    }
    $r = $null
    try {
        [RvceWifi.Portal]::ResetLastCert()
        $r = [RvceWifi.Portal]::PostForm((Get-PortalBase) + '/logout.xml', (Get-PortalPageUrl).AbsoluteUri,
            [string[]]@('mode', 'username', 'a', 'producttype'), [string[]]@('193', $user.Replace("'", "''"), (Get-SophosTime), '0'), $TimeoutMs)
        Update-RenewedPin
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message }
    }
    if ($r.Status -eq 0) {
        $seen = [RvceWifi.Portal]::LastCertSha256
        if ($seen -and $seen -ine [string]$cfg.PinnedCertSha256) {
            return [pscustomobject]@{ Ok = $false; Message = 'The portal presented a different certificate than the one you confirmed. Nothing was sent.' }
        }
        return [pscustomobject]@{ Ok = $false; Message = "The portal did not respond ($($r.Error))." }
    }
    Clear-RvceSession
    if ((Get-SophosTag $r.Body 'status') -eq 'LOGIN' -or (Invoke-Probe).State -ne 'Online') {
        Write-RvceLog 'Signed out of the portal.'
        return [pscustomobject]@{ Ok = $true; Message = 'Signed out of the RVCE portal.' }
    }
    $msg = Get-SophosTag $r.Body 'message'
    return [pscustomobject]@{ Ok = $false; Message = ("The portal did not confirm the sign-out. $msg").Trim() }
}

# ---------------------------------------------------------------- browser
function Open-InBrowser([Uri]$u) {
    # Only ever hand http(s) URLs to the shell, never arbitrary protocol handlers.
    if (-not $u -or ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https')) { return }
    Start-Process $u.AbsoluteUri
}

# ---------------------------------------------------------------- credentials
function Get-StoredCredential {
    $stored = [RvceWifi.CredMan]::Read([string]$cfg.CredentialTarget)
    if ($stored -and $stored.UserName -and $stored.Password.Length -gt 0) {
        return [pscustomobject]@{ UserName = $stored.UserName; Password = $stored.Password; FromStore = $true }
    }
    return $null
}

# Username for keep-alive and sign-out: the one this tool last signed in with, else the saved credential's.
function Get-PortalUser {
    $s = Get-RvceSession
    if ($s -and ($s.PSObject.Properties.Name -contains 'User') -and $s.User) { return [string]$s.User }
    try {
        $c = [RvceWifi.CredMan]::Read([string]$cfg.CredentialTarget)
        if ($c -and $c.UserName) { $c.Password.Dispose(); return $c.UserName }
    } catch { }
    return $null
}

# ---------------------------------------------------------------- portal session
# Remembers which username is signed in (no password), per user in %LOCALAPPDATA%.
function Get-SessionPath { Join-Path $RvceDataDir 'session.json' }

function Save-RvceSession([string]$user) {
    try {
        if (-not (Test-Path -LiteralPath $RvceDataDir)) { New-Item -ItemType Directory -Path $RvceDataDir | Out-Null }
        $o = [pscustomobject]@{ User = $user; SignedInAt = (Get-Date).ToString('s') }
        [IO.File]::WriteAllText((Get-SessionPath), ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-RvceSession {
    $p = Get-SessionPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Clear-RvceSession {
    $p = Get-SessionPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# ---------------------------------------------------------------- watcher control
# Starts the tray watcher with no console window (so Windows Terminal never opens one).
function Start-RvceWatcher([string]$WatchScript) {
    $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $psi = New-Object Diagnostics.ProcessStartInfo($ps, ('-NoProfile -ExecutionPolicy Bypass -STA -File "' + $WatchScript + '"'))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path -Parent $WatchScript
    [void][Diagnostics.Process]::Start($psi)
}

# Asks a running watcher to exit and waits for it. Returns $true if one was running.
function Stop-RvceWatcher([int]$TimeoutSeconds = 45) {
    $ev = $null
    try { $ev = [Threading.EventWaitHandle]::OpenExisting($RvceWatchStopEventName) } catch { return $false }
    try { [void]$ev.Set() } finally { $ev.Dispose() }
    $m = New-Object Threading.Mutex($false, $RvceWatchMutexName)
    try {
        $got = $false
        try { $got = $m.WaitOne($TimeoutSeconds * 1000) } catch [Threading.AbandonedMutexException] { $got = $true }
        if ($got) { $m.ReleaseMutex() }
    } finally { $m.Dispose() }
    return $true
}
