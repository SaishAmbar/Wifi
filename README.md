# RVCE-Connect

A small Windows tool that reconnects you to the **RVCE** Wi-Fi and signs in to the
**RV Institutions captive portal** (`https://172.16.0.2:1003`) with **your own** institution account.

It does not bypass authentication. It does exactly what you would do in the browser:
it submits the official portal's login form once, with your credentials, and then
checks that the internet works.

> **Use it only with your own RVCE account**, and follow RV Institutions' IT usage policy.
> Never share your password with anyone, including whoever gave you this tool. The tool keeps it on your PC only.

Requirements: Windows 10 or 11 (uses the built-in Windows PowerShell 5.1 and .NET Framework). Nothing to install.

## Install

1. **Get the files.** On the GitHub page click **Code > Download ZIP** and extract it, or clone it with Git.
   Put the folder somewhere **outside OneDrive**, for example `C:\Users\<you>\RVCE-Connect`.
   (OneDrive can make files "online-only", and they can't be downloaded while the portal is blocking the internet.)
2. **Double-click `Setup.cmd`** once. It builds `RVCE-Connect.exe` and `RVCE-Stop.exe` on your PC.
   If Windows shows *"Windows protected your PC"* or a security warning for `Setup.cmd`, click **More info > Run anyway**
   (or **Run**). That warning appears for any script downloaded from the internet. You can read `Setup.cmd` and
   `app\Build-Launchers.ps1` first; they're short.
3. Connect to the **RVCE** Wi-Fi once through the normal Windows Wi-Fi menu, so Windows has a saved profile for it.
4. **Double-click `RVCE-Connect.exe`.** The first time, it asks you to:
   - **confirm the portal's certificate** (see step 3 under *Use*), and
   - **enter your own RVCE username and password**, then offers to save them in Windows Credential Manager.
     Say **Yes** if you want the watcher to sign you back in automatically.
5. Optional: right-click `RVCE-Connect.exe` > *Send to* > *Desktop (create shortcut)*.

If you move the folder later, run `Setup.cmd` again.

## Files

```
RVCE-Connect\
  Setup.cmd          <- run once: builds the two .exe launchers below
  RVCE-Connect.exe   <- double-click: signs in if needed, starts the watcher -> "Connected. Watcher running."
  RVCE-Stop.exe      <- double-click: stops the watcher (you stay signed in) -> "Watcher stopped."
  README.md
  app\               <- internals; you don't need to open these
    RVCE-Connect.ps1, RVCE-Watch.ps1, RVCE-Stop.ps1   the scripts
    RVCE-Connect.cmd, RVCE-Stop.cmd                   console versions, for the options below
    RvceCommon.ps1     shared code
    RvceHelper.cs      C# helper (compiled automatically at run time)
    Launcher.cs, Build-Launchers.ps1                  source and build script for the two .exe files
    config.default.json  default settings (shipped)
    config.json        your own settings, created on first run (not in git)
```

The two `.exe` files are tiny launchers built on your own PC by `Setup.cmd` from `app\Launcher.cs`, using the
C# compiler that ships with Windows. All they do is start the matching script with **no console window**, so you
only see the dialog box. They aren't stored in the repository; everyone builds their own from the source.

`RvceHelper.cs` handles Credential Manager access, certificate pinning and secure form submission.

## Use

Double-click **`RVCE-Connect.exe`**. No window opens; when it's done you get a **"Connected. Watcher running."**
box, or a box explaining what went wrong. Any questions it needs to ask (reconnect to Wi-Fi, trust the
certificate, your username and password, save them?) also appear as dialog boxes on top of other windows.

What happens:

1. **Wi-Fi check.** If you are not on `RVCE`, it asks whether to connect using your saved Wi-Fi profile.
2. **Portal check.** One request to Windows' own connectivity-check URL (`http://www.msftconnecttest.com/connecttest.txt`).
   If you are already online it skips straight to starting the watcher.
3. **First run only: certificate check.** The portal uses a certificate Windows doesn't trust (that is why
   Chrome shows "Not secure"). The tool shows the certificate's SHA-256 fingerprint and asks you to confirm
   (No is the default; in the console you type `YES`).
   To check it, click **Not secure > Certificate is not valid > Details** in Chrome on the portal page and compare
   the SHA-256 fingerprint, or ask IT. After that, the tool refuses any portal that presents a different certificate.
4. **Sign-in.** It uses credentials saved in Windows Credential Manager, or shows the standard Windows credential
   dialog. The form is submitted **once**.
5. **Verification.** It re-checks internet access a few times and tells you clearly whether it works.
6. If sign-in worked and you typed the credentials in, it asks whether to save them in Credential Manager.
7. **Watcher.** It starts the background watcher (below), unless it is already running.

### Options (console)

Run these from a terminal in the tool's folder. They print to the console instead of showing dialogs.

| Command | What it does |
|---|---|
| `app\RVCE-Connect.cmd -Status` | Only report Wi-Fi and internet/portal status. Never sends credentials. |
| `app\RVCE-Connect.cmd -BrowserOnly` | Detect the portal and open it in your default browser (sign in there yourself). |
| `app\RVCE-Connect.cmd -NoWatch` | Sign in without starting the background watcher. |
| `app\RVCE-Connect.cmd -NoReconnect` | Don't offer to reconnect the Wi-Fi. |
| `app\RVCE-Connect.cmd -ForgetCredential` | Delete the saved credential from Credential Manager. |
| `app\RVCE-Connect.cmd -ResetCertificatePin` | Forget the confirmed certificate (for example after IT replaces it). |
| `app\RVCE-Connect.cmd -InstallStartup` | Start the watcher automatically when you log in (`-RemoveStartup` to undo). |
| `app\RVCE-Stop.cmd -SignOut` | Stop the watcher **and** sign out of the Wi-Fi portal. |

## Background watcher (checks every minute)

It starts automatically after `RVCE-Connect.exe` finds you online. A coloured dot appears in the system tray
(it may be under the `^` arrow):

| Dot | Meaning |
|---|---|
| Green | On RVCE and online. |
| Amber | Signed out by the portal; signing in again or waiting to retry. |
| Red | A problem needs you: Wi-Fi dropped, the portal isn't responding, or automatic sign-in is paused. |
| Grey | Not on RVCE (for example at home). The watcher does nothing. |

Every minute while you're on RVCE it:
- checks internet access with one request to Windows' connectivity-check URL;
- when online, refreshes the portal's own keep-alive page, the same thing the portal's browser tab does (turn off with `"UseKeepalive": false`);
- if the portal has signed you out, **signs you back in once** using the credentials saved in Credential Manager, then shows a notification.

It needs saved credentials: answer **Yes** when `RVCE-Connect.exe` offers to save them after a sign-in.

**Limits that stop it resubmitting credentials:**
- at most one automatic sign-in every 5 minutes (`AutoSignInCooldownMinutes`);
- automatic sign-in **pauses completely** if the portal rejects the credentials, the certificate changes,
  the portal page is unrecognised, or it fails 3 times in a row (`MaxAutoSignInFailures`).
  Choose **Sign in now...** from the tray menu to resume.
- It never reconnects you to the Wi-Fi network itself. It only tells you when the Wi-Fi drops.

Notifications appear only when something changes: you lost internet, you were signed back in, or the Wi-Fi dropped.
Every change is also written to `%LOCALAPPDATA%\RVCE-Connect\watch.log`, so you can see when disconnects happened.
Open it with **Open connection log** from the tray menu. The log never contains your username or password.

**Tray menu (right-click the dot):** Check now, Sign in now..., Open portal in browser, Open connection log,
Sign out and exit, Exit (stay signed in). Double-clicking the dot runs a check immediately.

## Stopping

Double-click **`RVCE-Stop.exe`**. It stops the background watcher and shows **"Watcher stopped."**
**You stay signed in** to the Wi-Fi portal; it just stops checking. (**Exit** in the tray menu does the same.)

To also sign out of the portal, use **Sign out and exit** in the tray menu, or `app\RVCE-Stop.cmd -SignOut`.
It stops the watcher first (so it can't sign you straight back in), then signs out using the portal's logout link
from your last sign-in, and confirms you're really signed out.

### Exit codes (for scripting)

`0` online, `1` not on RVCE Wi-Fi, `2` portal not found / timed out / not the official portal,
`3` sign-in rejected, `4` signed in but internet still not working, `5` bad config, `6` cancelled.

## Security and privacy

- **Credentials** are stored only in **Windows Credential Manager** (*Control Panel > Credential Manager >
  Windows Credentials*, entry `RVCE-Connect:CaptivePortal`). They are tied to your Windows account and protected by Windows.
  The tool never writes them to a file, never prints them, and never logs them. In memory the password stays a
  `SecureString`, and the request body containing it is wiped right after it is sent.
- **Credentials go only to the official portal**: HTTPS, host `172.16.0.2`, port `1003`, with the certificate
  you confirmed. Plain HTTP, any other host or port, a form that posts elsewhere, or a GET-method form are all refused.
- **One attempt per run.** Timeouts and rejections are reported, never retried automatically, so your account
  can't be locked out by repeated submissions.
- **Network traffic:** the Microsoft connectivity-check URL and the RVCE portal only. Nothing else is probed or scanned.
- The browser is only ever opened on `http`/`https` URLs: the allow-listed portal, or Microsoft's connectivity redirect.

## Permissions needed

| Permission | Why | Required? |
|---|---|---|
| **Run a local PowerShell script** | The launchers use `-ExecutionPolicy Bypass` for that one process only. Your system policy is not changed. | Yes |
| **Location access for desktop apps** (Windows 11 24H2 and later) | Windows hides the Wi-Fi network name (SSID) from `netsh` unless location is allowed: *Settings > Privacy & security > Location* > turn on *Location services* and *Let desktop apps access your location*. Without it the tool falls back to the Windows network-profile name, which is usually still `RVCE`. | Recommended |
| **Windows Credential Manager** (your own user store) | Only if you choose to save credentials. No admin needed. | Optional |
| **Administrator** | Not needed. | No |

## Configuration (`app\config.json`)

`app\config.json` is created from `app\config.default.json` the first time you run the tool. Edit your
`config.json`, not the default (the default is what other people get).

| Key | Meaning |
|---|---|
| `Ssid` | Expected Wi-Fi name (`RVCE`). |
| `PortalHost`, `PortalPort` | The only place credentials may be sent (`172.16.0.2`, `1003`). Change only if RVCE IT changes the portal. |
| `PinnedCertSha256` | Filled in automatically when you confirm the certificate. |
| `CredentialTarget` | Name of the Credential Manager entry. |
| `TimeoutSeconds`, `VerifyAttempts`, `VerifyIntervalSeconds` | Network timeout and how long to keep checking after sign-in. |
| `WatchIntervalSeconds` | How often the watcher checks (default 60, minimum 30). |
| `AutoSignInCooldownMinutes`, `MaxAutoSignInFailures` | Watcher limits on automatic sign-in (defaults 5 and 3). |
| `UseKeepalive` | Whether the watcher refreshes the portal's keep-alive page. |

Files kept in `%LOCALAPPDATA%\RVCE-Connect\` (your user folder, not synced to OneDrive):
`watch.log` (connection history) and `session.json` (the portal's keep-alive and logout links from your last sign-in; no credentials).

## Troubleshooting

- **"Connected to Wi-Fi, but the network name could not be read"**: turn on Location access (see Permissions).
- **"Could not recognise a username/password form"**: the portal page changed. The tool opens the browser instead; sign in there.
- **"Different certificate"**: don't sign in. Check with IT. If the change is genuine, run `app\RVCE-Connect.cmd -ResetCertificatePin`.
- **Sign-in rejected**: check your username and password in the browser. If a saved credential is outdated, run `app\RVCE-Connect.cmd -ForgetCredential`.
- **Signed in but no internet**: wait a few seconds and run `app\RVCE-Connect.cmd -Status`. The gateway sometimes takes a moment.
- **`RVCE-Connect.exe` is missing**: run `Setup.cmd`.
- **"Missing file ... Keep the 'app' folder next to this program"**: the `.exe` was moved away from the `app` folder.
  Keep them together, or run `Setup.cmd` again in the new place.
- **Antivirus warns about the .exe**: it's the launcher built from `app\Launcher.cs`. Rebuild it with `Setup.cmd`,
  or run the scripts with `app\RVCE-Connect.cmd` instead.

## Uninstall

Double-click `RVCE-Stop.exe`, then run `app\RVCE-Connect.cmd -RemoveStartup` and `app\RVCE-Connect.cmd -ForgetCredential`.
Then delete this folder and `%LOCALAPPDATA%\RVCE-Connect`.
