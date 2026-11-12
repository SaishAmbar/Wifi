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
function Read-RvceConfig([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        # First run: create this user's own config.json (not tracked by git) from the shipped defaults.
        $default = Join-Path (Split-Path -Parent $Path) 'config.default.json'
        if (-not (Test-Path -LiteralPath $default)) { throw "Config file not found: $Path (and no config.default.json)" }
        Copy-Item -LiteralPath $default -Destination $Path
    }
    try { $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "config.json is not valid JSON: $($_.Exception.Message)" }

    $defaults = [ordered]@{
        Ssid = 'RVCE'; PortalHost = '172.16.0.2'; PortalPort = 1003; PinnedCertSha256 = ''
        CredentialTarget = 'RVCE-Connect:CaptivePortal'
        ProbeUrl = 'http://www.msftconnecttest.com/connecttest.txt'
        ProbeExpectedBody = 'Microsoft Connect Test'
        BrowserFallbackUrl = 'http://www.msftconnecttest.com/redirect'
        TimeoutSeconds = 10; VerifyAttempts = 5; VerifyIntervalSeconds = 2
        WatchIntervalSeconds = 60; AutoSignInCooldownMinutes = 5; MaxAutoSignInFailures = 3; UseKeepalive = $true
    }
    foreach ($k in $defaults.Keys) {
        if (-not ($c.PSObject.Properties.Name -contains $k) -or $null -eq $c.$k) {
            $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        }
    }
    $probe = $null
    if ([string]::IsNullOrWhiteSpace($c.Ssid) -or [string]::IsNullOrWhiteSpace($c.PortalHost) -or
        [int]$c.PortalPort -lt 1 -or [int]$c.PortalPort -gt 65535 -or
        -not [Uri]::TryCreate([string]$c.ProbeUrl, [UriKind]::Absolute, [ref]$probe) -or $probe.Scheme -ne 'http') {
        throw 'config.json: Ssid, PortalHost, PortalPort (1-65535) and an http:// ProbeUrl are required.'
    }
    if ([int]$c.WatchIntervalSeconds -lt 30) { $c.WatchIntervalSeconds = 30 }
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
}

function Set-PinnedCertificate([string]$sha) {
    $cfg.PinnedCertSha256 = $sha
    [RvceWifi.Portal]::PinnedSha256 = $sha
    Save-RvceConfig $cfg $ConfigPath
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

# ---------------------------------------------------------------- probing / portal discovery
function Find-RedirectUrl($r, [Uri]$base) {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($r.Location) { $cands.Add($r.Location) }
    if ($r.Body) {
        $patterns = @(
            '(?i)(?:window\.|document\.|top\.)?location(?:\.href)?\s*=\s*["'']([^"'']+)["'']',
            '(?i)location\.replace\(\s*["'']([^"'']+)["'']',
            '(?i)<meta[^>]+http-equiv\s*=\s*["'']?refresh["'']?[^>]*content\s*=\s*["''][^"'']*?url\s*=\s*([^"''>\s]+)',
            '(?i)(https?://[^\s"''<>]+/fgtauth\?[^\s"''<>]*)'
        )
        foreach ($p in $patterns) {
            $m = [regex]::Match($r.Body, $p)
            if ($m.Success) { $cands.Add([Net.WebUtility]::HtmlDecode($m.Groups[1].Value)) }
        }
    }
    foreach ($c in $cands) {
        [Uri]$u = $null
        if ([Uri]::TryCreate($base, $c, [ref]$u) -and ($u.Scheme -eq 'http' -or $u.Scheme -eq 'https')) { return $u }
    }
    return $null
}

function Invoke-Probe {
    $r = [RvceWifi.Portal]::Get([string]$cfg.ProbeUrl, $TimeoutMs)
    if ($r.Status -eq 0) {
        return [pscustomobject]@{ State = 'Unreachable'; PortalUrl = $null; Detail = $r.Error }
    }
    if ($r.Status -eq 200 -and $r.Body -and $r.Body.Trim() -eq $cfg.ProbeExpectedBody) {
        return [pscustomobject]@{ State = 'Online'; PortalUrl = $null; Detail = $null }
    }
    $u = Find-RedirectUrl $r ([Uri]$cfg.ProbeUrl)
    return [pscustomobject]@{ State = 'Captive'; PortalUrl = $u; Detail = "HTTP $($r.Status)" }
}

# Follows plain-HTTP hops on the portal host (e.g. http://gw:1000/fgtauth -> https://gw:1003/fgtauth).
function Resolve-PortalUrl([Uri]$u) {
    for ($hop = 0; $hop -lt 3 -and $u -and $u.Scheme -eq 'http'; $hop++) {
        if ($u.Host -ine $cfg.PortalHost) { return $u }
        $r = [RvceWifi.Portal]::Get($u.AbsoluteUri, $TimeoutMs)
        if ($r.Status -eq 0) { return $u }
        $next = Find-RedirectUrl $r $u
        if (-not $next) { return $u }
        $u = $next
    }
    return $u
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
    $seen = [RvceWifi.Portal]::LastCertSha256
    $cert = 'Ok'
    if ($r.Status -eq 0 -and $seen -and $seen -ine [string]$cfg.PinnedCertSha256) {
        if ([string]::IsNullOrEmpty([string]$cfg.PinnedCertSha256)) { $cert = 'Untrusted' } else { $cert = 'Changed' }
    }
    return [pscustomobject]@{ Response = $r; Cert = $cert; SeenSha256 = $seen }
}

# ---------------------------------------------------------------- login form parsing
function Get-Attr([string]$attrs, [string]$name) {
    $m = [regex]::Match($attrs, '(?is)(?:^|\s)' + [regex]::Escape($name) + '\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))')
    if (-not $m.Success) { return $null }
    foreach ($g in 1..3) { if ($m.Groups[$g].Success) { return [Net.WebUtility]::HtmlDecode($m.Groups[$g].Value) } }
    return $null
}

function Get-LoginForm([string]$html, [Uri]$baseUri) {
    if (-not $html) { return $null }
    foreach ($f in [regex]::Matches($html, '(?is)<form\b([^>]*)>(.*?)</form>')) {
        $fields = @(foreach ($i in [regex]::Matches($f.Groups[2].Value, '(?is)<input\b([^>]*?)/?>')) {
            $a = $i.Groups[1].Value
            $t = Get-Attr $a 'type'; if (-not $t) { $t = 'text' }
            [pscustomobject]@{
                Name    = Get-Attr $a 'name'
                Type    = $t.ToLowerInvariant()
                Value   = Get-Attr $a 'value'
                Checked = ($a -match '(?i)(^|\s)checked(\s|=|$)')
            }
        })
        $pw = @($fields | Where-Object { $_.Type -eq 'password' -and $_.Name })
        if ($pw.Count -ne 1) { continue }
        $users = @($fields | Where-Object { $_.Name -and @('text', 'email') -contains $_.Type })
        if ($users.Count -lt 1) { continue }
        $user = @($users | Where-Object { $_.Name -match '(?i)user|login|uid|email|name' }) + $users | Select-Object -First 1

        $extra = @($fields | Where-Object {
            $_.Name -and ($_.Type -eq 'hidden' -or (@('checkbox', 'radio') -contains $_.Type -and $_.Checked))
        })
        $submit = @($fields | Where-Object { $_.Type -eq 'submit' -and $_.Name }) | Select-Object -First 1
        if ($submit) { $extra += $submit }

        $method = Get-Attr $f.Groups[1].Value 'method'; if (-not $method) { $method = 'get' }
        $action = Get-Attr $f.Groups[1].Value 'action'
        [Uri]$actionUri = $null
        if ([string]::IsNullOrWhiteSpace($action)) { $actionUri = $baseUri }
        elseif (-not [Uri]::TryCreate($baseUri, $action, [ref]$actionUri)) { continue }

        return [pscustomobject]@{
            Action     = $actionUri
            Method     = $method.ToUpperInvariant()
            UserField  = $user.Name
            PassField  = $pw[0].Name
            Names      = [string[]]@($extra | ForEach-Object { $_.Name })
            Values     = [string[]]@($extra | ForEach-Object { if ($null -eq $_.Value) { '' } else { $_.Value } })
        }
    }
    return $null
}

# A form is only usable if it POSTs to the allow-listed HTTPS portal.
function Test-LoginForm($form) {
    return [bool]($form -and $form.Method -eq 'POST' -and [RvceWifi.Portal]::IsAllowed($form.Action))
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

# ---------------------------------------------------------------- portal session (keep-alive / logout links)
# Holds only the portal's keep-alive/logout links (no credentials), per user in %LOCALAPPDATA%.
function Get-SessionPath { Join-Path $RvceDataDir 'session.json' }

function Save-RvceSession($links) {
    try {
        if (-not (Test-Path -LiteralPath $RvceDataDir)) { New-Item -ItemType Directory -Path $RvceDataDir | Out-Null }
        $o = [pscustomobject]@{ KeepaliveUrl = $links.KeepaliveUrl; LogoutUrl = $links.LogoutUrl; SignedInAt = (Get-Date).ToString('s') }
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

function Find-PortalLinks([string]$body, [Uri]$base) {
    $out = [pscustomobject]@{ KeepaliveUrl = $null; LogoutUrl = $null }
    if (-not $body) { return $out }
    foreach ($kind in 'keepalive', 'logout') {
        $m = [regex]::Match($body, '(?i)(?:https://[^\s"''<>/]+)?/' + $kind + '\?[^\s"''<>]*')
        if (-not $m.Success) { continue }
        [Uri]$u = $null
        if ([Uri]::TryCreate($base, [Net.WebUtility]::HtmlDecode($m.Value), [ref]$u) -and [RvceWifi.Portal]::IsAllowed($u)) {
            if ($kind -eq 'keepalive') { $out.KeepaliveUrl = $u.AbsoluteUri } else { $out.LogoutUrl = $u.AbsoluteUri }
        }
    }
    # FortiGate uses the same token for both links.
    if (-not $out.LogoutUrl -and $out.KeepaliveUrl) { $out.LogoutUrl = $out.KeepaliveUrl -replace '/keepalive\?', '/logout?' }
    return $out
}

# ---------------------------------------------------------------- sign-in / sign-out
# Submits the form ONCE and verifies access. Never retries.
# Result: Online | Rejected | Timeout | NotVerified | Error
function Submit-PortalLogin([Uri]$Portal, $Form, $Cred) {
    $res = [pscustomobject]@{ Result = ''; Detail = ''; KeepaliveUrl = $null; LogoutUrl = $null }
    $resp = $null
    try {
        $resp = [RvceWifi.Portal]::PostLogin($Form.Action.AbsoluteUri, $Portal.AbsoluteUri, $Form.Names, $Form.Values,
                                             $Form.UserField, $Cred.UserName, $Form.PassField, $Cred.Password, $TimeoutMs)
    } catch {
        $res.Result = 'Error'; $res.Detail = $_.Exception.Message
        return $res
    }
    $timedOut = ($resp.Status -eq 0)
    if ($timedOut) { $res.Detail = $resp.Error }
    $looksRejected = (-not $timedOut) -and $resp.Body -and (
        $resp.Body -match '(?i)authentication failed|invalid (user|credential|password|login)|incorrect (user|password)|login failed|failed to authenticate|access denied' -or
        $resp.Body -match '(?i)<input[^>]+type\s*=\s*["'']?password')

    $online = $false
    for ($i = 1; $i -le [int]$cfg.VerifyAttempts; $i++) {
        Start-Sleep -Seconds ([int]$cfg.VerifyIntervalSeconds)
        if ((Invoke-Probe).State -eq 'Online') { $online = $true; break }
    }

    if ($online) {
        $links = Find-PortalLinks ([string]$resp.Body) $Portal
        $res.KeepaliveUrl = $links.KeepaliveUrl; $res.LogoutUrl = $links.LogoutUrl
        Save-RvceSession $links
        $res.Result = 'Online'
    }
    elseif ($looksRejected) { $res.Result = 'Rejected' }
    elseif ($timedOut)      { $res.Result = 'Timeout' }
    else                    { $res.Result = 'NotVerified' }
    return $res
}

# Signs out of the portal. Returns @{ Ok; Message }.
function Invoke-PortalLogout {
    if ([string]::IsNullOrEmpty([string]$cfg.PinnedCertSha256)) {
        return [pscustomobject]@{ Ok = $false; Message = 'The portal certificate has not been confirmed yet, so nothing was sent. Sign in once with RVCE-Connect first.' }
    }
    $s = Get-RvceSession
    [Uri]$u = $null
    if ($s -and ($s.PSObject.Properties.Name -contains 'LogoutUrl') -and $s.LogoutUrl) { [void][Uri]::TryCreate([string]$s.LogoutUrl, [UriKind]::Absolute, [ref]$u) }
    if (-not $u -or -not [RvceWifi.Portal]::IsAllowed($u)) { $u = [Uri]('https://{0}:{1}/logout?' -f $cfg.PortalHost, $cfg.PortalPort) }

    $p = Get-PortalPage $u
    if ($p.Cert -ne 'Ok') {
        return [pscustomobject]@{ Ok = $false; Message = 'The portal presented a different certificate than the one you confirmed. Nothing was sent.' }
    }
    if ($p.Response.Status -eq 0) {
        return [pscustomobject]@{ Ok = $false; Message = "The portal did not respond ($($p.Response.Error))." }
    }
    Clear-RvceSession
    Start-Sleep -Seconds 2
    if ((Invoke-Probe).State -eq 'Online') {
        return [pscustomobject]@{ Ok = $false; Message = 'Sign-out was sent, but internet access still works. The portal may not support this sign-out link; it will expire on its own, or sign out from the portal page in your browser.' }
    }
    Write-RvceLog 'Signed out of the portal.'
    return [pscustomobject]@{ Ok = $true; Message = 'Signed out of the RVCE portal.' }
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
