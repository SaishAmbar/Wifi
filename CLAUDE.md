# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows-only tool (Windows PowerShell 5.1 + C# compiled at run time, no dependencies) that signs a user in to the
RVCE campus Wi-Fi captive portal with their own account, then keeps them signed in from a system-tray watcher.
The portal is **Sophos** (`https://172.16.0.4:8090`) on branch `sophos-portal`; `main` still holds the earlier
**FortiGate** version (`https://172.16.0.2:1003`, HTML-form scraping). User-facing docs are in `README.md`.

## Commands

There is no build system, linter or test suite in the repo. Run from the repo root in PowerShell:

```powershell
# Build the two no-window launchers (+ icons + desktop shortcuts); what Setup.cmd runs
powershell -NoProfile -ExecutionPolicy Bypass -File app\Build-Launchers.ps1 -NoShortcuts

# Run in console mode (prints instead of dialogs). -Status never sends credentials.
app\RVCE-Connect.cmd -Status
app\RVCE-Stop.cmd -WatcherOnly          # stop the tray watcher, stay signed in

# Syntax-check every script (the only "lint" available)
Get-ChildItem app\*.ps1 | % { $e=$null; [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e); "$($_.Name): $(if($e){$e[0]}else{'ok'})" }
```

To exercise individual functions, dot-source the entry script (its main body is guarded by
`if ($MyInvocation.InvocationName -ne '.')`), then set up the globals the shared code expects:

```powershell
. .\app\RVCE-Connect.ps1
$ConfigPath = 'app\config.json'; $cfg = Read-RvceConfig $ConfigPath; $TimeoutMs = 10000; Initialize-RvceHelper $cfg
Get-SophosTag '<status><![CDATA[LIVE]]></status>' 'status'   # pure helpers can be tested like this
```

Be careful when testing against the live portal: a sign-out (`Invoke-PortalLogout`) cuts the machine's internet,
including the session you are running in.

## Architecture

**Entry points.** `RVCE-Connect.exe` / `RVCE-Stop.exe` are the same tiny program (`app/Launcher.cs`), built locally by
`Build-Launchers.ps1` and git-ignored. It picks the script from its own file name (`*Stop*` -> `RVCE-Stop.ps1 -Gui`,
otherwise `RVCE-Connect.ps1 -Gui`; `/watch` -> `RVCE-Watch.ps1`) and starts PowerShell with `CreateNoWindow`. This exists
because Windows Terminal (default console host on Windows 11) ignores `-WindowStyle Hidden`, so `.cmd` launchers
leave a terminal window open. The `app/*.cmd` files are the console-mode equivalents.

**Scripts.** `RVCE-Connect.ps1` (one-shot sign-in, then starts the watcher), `RVCE-Watch.ps1` (tray watcher),
`RVCE-Stop.ps1` (stop watcher + sign out). All dot-source `RvceCommon.ps1`, which relies on caller-scope globals
`$cfg`, `$TimeoutMs` and `$ConfigPath`. `-Gui` mode calls `Initialize-RvceGui`; output helpers (`Write-Ok/Fail/...`)
then also collect lines into `$RvceUi.Log` for the final dialog. All dialogs go through `Show-RvceMessage` (a
custom fixed-width WinForms dialog, width `$RvceDialogWidth`), and Yes/No prompts through `Confirm-RvceChoice`
(dialog in GUI mode, `Read-Host` in console mode).

**`RvceHelper.cs`** (compiled by `Initialize-RvceHelper` via `Add-Type`) holds everything security-sensitive:
- `Portal`: HTTP via `HttpWebRequest` with a per-request certificate callback. HTTPS is accepted **only** for
  `AllowedHost:AllowedPort` presenting the SHA-256 in `PinnedSha256` (trust-on-first-use, confirmed by the user and
  stored in `config.json`). `PostLogin` builds the form body from a `SecureString` and wipes it; `PostForm` is for
  password-less posts. Both refuse non-allow-listed URLs or a missing pin.
- `CredMan` (Windows Credential Manager, generic credential `RVCE-Connect:CaptivePortal`) and `CredPrompt`
  (CredUI dialog owned by the always-on-top owner window so it can't open behind other windows).

**Sophos protocol** (reverse-read from the portal's `/javascript/validation/httpclient.js`; documented above
`Get-PortalBase` in `RvceCommon.ps1`): `POST /login.xml` (`mode=191`), `POST /logout.xml` (`mode=193`),
`GET /live?mode=192` keep-alive every 180 s, all with `a=<epoch ms>&producttype=0`. Replies are tiny XML read with
`Get-SophosTag`: `<status>` `LIVE`/`LOGIN`/`CHALLENGE`, `<ack>` `ack`/`nack`/`login_again`/`live_off`. Usernames have
`'` doubled, as the portal page does. The tool remembers the signed-in username in
`%LOCALAPPDATA%\RVCE-Connect\session.json` for keep-alive and sign-out.

**Watcher** (`RVCE-Watch.ps1`): WinForms `NotifyIcon` + 1 s `Windows.Forms.Timer`. Single instance via named mutex
`Local\RVCE-Connect-Watch`; other processes stop it by setting named event `Local\RVCE-Connect-Watch-Stop`
(`Stop-RvceWatcher` then waits on the mutex). Mutable state lives in the `$W` hashtable because event-handler
script blocks can't assign script-scope variables. Each tick: every 15 s compare a local Wi-Fi signature
(`Get-WifiSignature`) and schedule a check 5 s after a change; run the full check (`Invoke-WatchCheck`) when
`NextCheck` is due (30 min when online, cooldown after failures); otherwise send a keep-alive when due, which triggers
an immediate full check on `nack`/failure. Off the RVCE SSID it stays idle. Auto sign-in safeguards (cooldown, block
on rejection/cert change/repeated failure until "Sign in now") are deliberate; keep them.

**Config.** `app/config.default.json` is shipped; each user's `app/config.json` (git-ignored, holds their pin) is
created from it on first run. `Read-RvceConfig` fills missing keys from `$RvceDefaults` and migrates old FortiGate
configs (clears the pin, which belongs to the old portal). Add new settings to both `$RvceDefaults` and
`config.default.json`.

## Constraints and gotchas

- Target is **Windows PowerShell 5.1** (.NET Framework): C# passed to `Add-Type`/CodeDom must be **C# 5** (no `$""`,
  `?.`, `out var`, expression-bodied members). Scripts run under `Set-StrictMode -Version 2`.
- Keep `.ps1`/`.cs`/`.cmd` files **ASCII-only**: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
- `$PSScriptRoot` is empty inside `param()` defaults on 5.1; scripts compute `$ScriptDir` in the body instead.
- `.gitattributes` forces CRLF (`cmd` misparses LF batch files, and GitHub ZIP downloads honour it).
- Security invariants the design depends on: credentials go only to the pinned, allow-listed portal; one sign-in
  attempt per run; the password is never logged or written to files; only `http(s)` URLs are opened in the browser.
