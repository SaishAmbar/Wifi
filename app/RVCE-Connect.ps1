<#
.SYNOPSIS
    Reconnects to the RVCE Wi-Fi and signs in to the RV Institutions captive portal
    with your own institution account.

.DESCRIPTION
    1. Checks that Windows is connected to the expected Wi-Fi network (config.json: Ssid)
       and offers to reconnect using your saved Windows Wi-Fi profile.
    2. Detects a captive portal with one request to the Windows connectivity-check URL.
    3. Sends your credentials ONCE, only to the allow-listed HTTPS portal
       (config.json: PortalHost/PortalPort) whose certificate fingerprint you confirmed.
    4. Verifies that internet access works afterwards.

.PARAMETER Status            Only report status. Sends no credentials.
.PARAMETER BrowserOnly       Open the portal in your default browser instead of signing in here.
.PARAMETER ForgetCredential  Remove the saved credential from Windows Credential Manager.
.PARAMETER ResetCertificatePin  Forget the confirmed portal certificate fingerprint.
.PARAMETER NoReconnect       Do not offer to reconnect the Wi-Fi.
.PARAMETER NoWatch           Do not start the background watcher afterwards.
.PARAMETER Gui               Use dialog boxes instead of the console (used when double-clicked).
.PARAMETER InstallStartup    Start the background watcher automatically when you log in.
.PARAMETER RemoveStartup     Undo -InstallStartup.
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Connect')]
param(
    [Parameter(ParameterSetName = 'Status')]   [switch] $Status,
    [Parameter(ParameterSetName = 'Browser')]  [switch] $BrowserOnly,
    [Parameter(ParameterSetName = 'Forget')]   [switch] $ForgetCredential,
    [Parameter(ParameterSetName = 'ResetPin')] [switch] $ResetCertificatePin,
    [Parameter(ParameterSetName = 'Connect')]  [switch] $NoReconnect,
    [Parameter(ParameterSetName = 'Connect')]  [switch] $NoWatch,
    [Parameter(ParameterSetName = 'Connect')]  [switch] $Gui,
    [Parameter(ParameterSetName = 'Startup')]  [switch] $InstallStartup,
    [Parameter(ParameterSetName = 'Startup2')] [switch] $RemoveStartup,
    [string] $ConfigPath = ''
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliable inside param() defaults on Windows PowerShell 5.1.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
. (Join-Path $ScriptDir 'RvceCommon.ps1')

# Exit codes
$EXIT_OK = 0; $EXIT_WIFI = 1; $EXIT_PORTAL = 2; $EXIT_AUTH = 3; $EXIT_VERIFY = 4; $EXIT_CONFIG = 5; $EXIT_CANCEL = 6

function Connect-ExpectedWifi {
    $ssid = [string]$cfg.Ssid
    & netsh.exe wlan show profiles "name=$ssid" *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "No saved Windows Wi-Fi profile named '$ssid'. Connect once from the Wi-Fi menu, then run this again."
        return $false
    }
    if (-not (Confirm-RvceChoice "You are not connected to the '$ssid' Wi-Fi. Connect now?" $true)) { return $false }
    Write-Step "Connecting to '$ssid'..."
    & netsh.exe wlan connect "name=$ssid" *> $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if (Test-ExpectedSsid (Get-WifiState)) { Start-Sleep -Seconds 2; return $true }  # let DHCP settle
    }
    return $false
}

function Confirm-PinCertificate {
    if ($RvceUi.Gui) {
        $text = "First connection to the portal: its certificate is not trusted by Windows " +
                "(this is why your browser shows 'Not secure'). Please check it before trusting it.`n`n" +
                "Subject:  $([RvceWifi.Portal]::LastCertSubject)`n" +
                "Issuer:  $([RvceWifi.Portal]::LastCertIssuer)`n" +
                "Expires:  $([RvceWifi.Portal]::LastCertExpiry)`n`n" +
                "SHA-256:`n$(Format-Fingerprint ([RvceWifi.Portal]::LastCertSha256))`n`n" +
                "Compare the SHA-256 with your browser (click 'Not secure' > Certificate details) or ask IT.`n`n" +
                "Trust this certificate for $($cfg.PortalHost):$($cfg.PortalPort)?"
        if ((Show-RvceMessage $text 'Warning' 'YesNo' 'Button2') -ne 'Yes') { return $false }
        Set-PinnedCertificate ([RvceWifi.Portal]::LastCertSha256)
        return $true
    }
    Write-Host ''
    Write-Warn2 "First connection to the portal: its certificate is not trusted by Windows"
    Write-Info  "(this is why your browser shows 'Not secure'). Please check it before trusting it."
    Write-Info  "Subject : $([RvceWifi.Portal]::LastCertSubject)"
    Write-Info  "Issuer  : $([RvceWifi.Portal]::LastCertIssuer)"
    Write-Info  "Expires : $([RvceWifi.Portal]::LastCertExpiry)"
    Write-Info  "SHA-256 : $(Format-Fingerprint ([RvceWifi.Portal]::LastCertSha256))"
    Write-Info  "Compare the SHA-256 with your browser (click 'Not secure' > Certificate details) or ask IT."
    $ans = Read-Host "Type YES to trust this certificate for $($cfg.PortalHost):$($cfg.PortalPort)"
    if ($ans -cne 'YES') { return $false }
    Set-PinnedCertificate ([RvceWifi.Portal]::LastCertSha256)
    Write-Ok "Certificate fingerprint saved to config.json."
    return $true
}

# Prompt in the console (a pop-up dialog can open hidden behind other windows).
# The password is read as a SecureString and is not echoed.
function Read-ConsoleCredential {
    Write-Host ''
    Write-Host 'RV Institutions Wi-Fi sign-in (press Enter on an empty username to cancel)'
    $user = (Read-Host '  Institution username').Trim()
    if (-not $user) { return $null }
    $pw = Read-Host '  Password (hidden)' -AsSecureString
    if (-not $pw -or $pw.Length -eq 0) { return $null }
    return [pscustomobject]@{ UserName = $user; Password = $pw; FromStore = $false }
}

function Get-BrowserTarget($probe) {
    if ($probe.PortalUrl -and $probe.PortalUrl.Host -ieq $cfg.PortalHost) { return $probe.PortalUrl }
    return [Uri]$cfg.BrowserFallbackUrl
}

function Invoke-Main {
    try { $script:cfg = Read-RvceConfig $ConfigPath } catch { Write-Fail $_.Exception.Message; return $EXIT_CONFIG }
    $script:TimeoutMs = [int]$cfg.TimeoutSeconds * 1000
    Initialize-RvceHelper $cfg

    if ($ForgetCredential) {
        if ([RvceWifi.CredMan]::Delete([string]$cfg.CredentialTarget)) { Write-Ok 'Saved credential removed from Windows Credential Manager.' }
        else { Write-Info 'No saved credential found.' }
        return $EXIT_OK
    }
    if ($ResetCertificatePin) {
        Set-PinnedCertificate ''
        Write-Ok 'Certificate pin cleared. You will be asked to confirm the certificate on the next sign-in.'
        return $EXIT_OK
    }

    # 1. Wi-Fi
    Write-Step "Checking Wi-Fi connection (expected network: $($cfg.Ssid))..."
    $wifi = Get-WifiState
    if (-not $wifi.HasWifi) { Write-Fail 'No Wi-Fi adapter found (or it is disabled).'; return $EXIT_WIFI }
    if ($wifi.LocationBlocked -and $wifi.Source -ne 'netsh') {
        Write-Warn2 'Windows hid the network name because Location access is off (see README > Permissions).'
    }
    if (-not (Test-ExpectedSsid $wifi)) {
        if ($wifi.Connected -and $wifi.Ssid) { Write-Fail "Connected to '$($wifi.Ssid)', not '$($cfg.Ssid)'." }
        elseif ($wifi.Connected) { Write-Fail "Connected to Wi-Fi, but the network name could not be read." }
        else { Write-Fail "Not connected to '$($cfg.Ssid)'." }
        if ($Status -or $NoReconnect -or ($wifi.Connected -and -not $wifi.Ssid)) { return $EXIT_WIFI }
        if (-not (Connect-ExpectedWifi)) { Write-Fail "Could not connect to '$($cfg.Ssid)'. Check that you are in range."; return $EXIT_WIFI }
    }
    Write-Ok "Connected to '$($cfg.Ssid)'."

    # 2. Internet / captive portal
    Write-Step 'Checking internet access...'
    $probe = Invoke-Probe
    switch ($probe.State) {
        'Online' { Write-Ok 'Internet access is working. Nothing to do.'; return $EXIT_OK }
        'Unreachable' {
            Write-Fail "No internet and no portal response ($($probe.Detail))."
            Write-Info 'The network may still be assigning an address, or the portal may be down.'
            if ($Status) { return $EXIT_PORTAL }
            if (Confirm-RvceChoice 'No internet and the portal is not responding. Open the sign-in page in your browser instead?' $false) { Open-InBrowser ([Uri]$cfg.BrowserFallbackUrl) }
            return $EXIT_PORTAL
        }
    }
    $portal = $null
    if ($probe.PortalUrl) { $portal = Resolve-PortalUrl $probe.PortalUrl }
    if ($portal) { Write-Warn2 "Captive portal detected: $($portal.GetLeftPart([UriPartial]::Path))" }
    else         { Write-Warn2 "Internet is blocked ($($probe.Detail)), but no portal address was found." }

    if ($Status) { return $EXIT_PORTAL }
    if ($BrowserOnly) { Write-Step 'Opening the portal in your default browser...'; Open-InBrowser (Get-BrowserTarget $probe); return $EXIT_OK }

    if (-not $portal -or -not [RvceWifi.Portal]::IsAllowed($portal)) {
        if ($portal) {
            Write-Fail "The portal address is not the official one in config.json ($($cfg.PortalHost):$($cfg.PortalPort) over HTTPS)."
            Write-Info 'Credentials will NOT be sent. If IT changed the portal, update config.json.'
        } else {
            Write-Info 'Opening the browser so you can sign in manually.'
            Open-InBrowser ([Uri]$cfg.BrowserFallbackUrl)
        }
        return $EXIT_PORTAL
    }

    # 3. Load the sign-in page (pinned TLS)
    Write-Step 'Loading the portal sign-in page...'
    $page = Get-PortalPage $portal
    if ($page.Cert -eq 'Untrusted') {
        if (-not (Confirm-PinCertificate)) { Write-Warn2 'Certificate not trusted. Nothing was sent.'; return $EXIT_CANCEL }
        $page = Get-PortalPage $portal
    }
    if ($page.Cert -eq 'Changed') {
        Write-Fail 'The portal presented a DIFFERENT certificate than the one you confirmed earlier.'
        Write-Info "Expected: $(Format-Fingerprint $cfg.PinnedCertSha256)"
        Write-Info "Got     : $(Format-Fingerprint $page.SeenSha256)"
        Write-Info 'This can happen if IT replaced the certificate, or if someone is impersonating the portal.'
        Write-Info 'No credentials were sent. Verify with IT, then run with -ResetCertificatePin.'
        return $EXIT_PORTAL
    }
    if ($page.Response.Status -eq 0) {
        Write-Fail "The portal did not respond within $($cfg.TimeoutSeconds)s ($($page.Response.Error))."
        Write-Info 'Try again in a minute, or use -BrowserOnly.'
        return $EXIT_PORTAL
    }
    $form = Get-LoginForm $page.Response.Body $portal
    if (-not $form) {
        Write-Warn2 'Could not recognise a username/password form on the portal page. Opening it in your browser.'
        Open-InBrowser $portal
        return $EXIT_PORTAL
    }
    if (-not (Test-LoginForm $form)) {
        Write-Fail 'The sign-in form does not POST to the official HTTPS portal. Credentials will NOT be sent.'
        Open-InBrowser $portal
        return $EXIT_PORTAL
    }

    # 4. Credentials
    $cred = $null
    try { $cred = Get-StoredCredential } catch { Write-Warn2 "Could not read Windows Credential Manager: $($_.Exception.Message)" }
    if ($cred) { Write-Info 'Using credentials saved in Windows Credential Manager.' }
    elseif ($RvceUi.Gui) { $cred = Read-GuiCredential }
    else { $cred = Read-ConsoleCredential }
    if (-not $cred) { Write-Warn2 'Sign-in cancelled. Nothing was sent.'; return $EXIT_CANCEL }

    # 5. Submit ONCE and verify
    Write-Step 'Signing in (one attempt) and verifying internet access...'
    $res = Submit-PortalLogin $portal $form $cred

    switch ($res.Result) {
        'Online' {
            Write-Ok 'Signed in. Internet access is working.'
            Write-RvceLog 'Signed in (RVCE-Connect).'
            if ($res.KeepaliveUrl) { Write-Info "Portal keep-alive page: $($res.KeepaliveUrl)" }
            if (-not $cred.FromStore) {
                if (Confirm-RvceChoice 'Signed in. Save these credentials in Windows Credential Manager so the watcher can sign you in again automatically?' $false) {
                    try { [RvceWifi.CredMan]::Write([string]$cfg.CredentialTarget, $cred.UserName, $cred.Password); Write-Ok 'Saved (Credential Manager > Windows Credentials).' }
                    catch { Write-Warn2 "Could not save: $($_.Exception.Message)" }
                }
            }
            $cred.Password.Dispose()
            return $EXIT_OK
        }
        'Error' {
            $cred.Password.Dispose()
            Write-Fail "Sign-in was not sent: $($res.Detail)"
            return $EXIT_PORTAL
        }
        'Rejected' {
            $cred.Password.Dispose()
            Write-Fail 'The portal rejected the sign-in (wrong username/password, expired account, or session limit).'
            if ($cred.FromStore) { Write-Info 'The saved credential may be outdated. Remove it with:  RVCE-Connect.cmd -ForgetCredential' }
            Write-Info 'Not retrying automatically, to avoid repeated submissions / account lockout.'
            return $EXIT_AUTH
        }
        'Timeout' {
            $cred.Password.Dispose()
            Write-Fail "The portal did not answer within $($cfg.TimeoutSeconds)s ($($res.Detail)) and internet access is still not working."
            Write-Info 'Not re-sending. Wait a minute and run again, or use -BrowserOnly.'
            return $EXIT_PORTAL
        }
        default {
            $cred.Password.Dispose()
            Write-Fail 'Credentials were submitted, but internet access still does not work.'
            Write-Info 'The portal may need more time, or the account may lack access. Try -Status in a minute, or -BrowserOnly.'
            return $EXIT_VERIFY
        }
    }
}

# Run unless dot-sourced (dot-sourcing is used only for testing).
if ($MyInvocation.InvocationName -ne '.') {
    $watchScript = Join-Path $ScriptDir 'RVCE-Watch.ps1'
    if ($InstallStartup) { & $watchScript -InstallStartup; exit $LASTEXITCODE }
    if ($RemoveStartup)  { & $watchScript -RemoveStartup;  exit $LASTEXITCODE }
    if ($Gui) { Initialize-RvceGui }
    try {
        $code = @(Invoke-Main)[-1]
        $watching = $false
        # After a normal run that ends online, keep watching in the background.
        if ($code -eq $EXIT_OK -and $PSCmdlet.ParameterSetName -eq 'Connect' -and -not $NoWatch) {
            try {
                [void][Threading.Mutex]::OpenExisting($RvceWatchMutexName)
                Write-Host '   Background watcher is already running (tray icon).'
            } catch {
                Start-RvceWatcher $watchScript
                Write-Host '[OK] Background watcher started: it checks every minute (tray icon). Stop it with RVCE-Stop.exe.' -ForegroundColor Green
            }
            $watching = $true
        }
        if ($Gui) {
            if ($code -eq $EXIT_OK) {
                $text = 'Connected.'
                if ($watching) { $text += "`nWatcher running." }
                [void](Show-RvceMessage $text 'Information')
            } elseif ($code -eq $EXIT_CANCEL) {
                [void](Show-RvceMessage ("Cancelled.`n`n" + ($RvceUi.Log -join "`n")) 'Information')
            } else {
                [void](Show-RvceMessage ("Not connected.`n`n" + ($RvceUi.Log -join "`n")) 'Warning')
            }
        }
        exit $code
    }
    catch {
        Write-Fail "Unexpected error: $($_.Exception.Message)"
        if ($Gui) { [void](Show-RvceMessage "Unexpected error:`n`n$($_.Exception.Message)" 'Error') }
        exit $EXIT_PORTAL
    }
}
