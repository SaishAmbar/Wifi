# RVCE-Connect

A small Windows tool that reconnects you to the **RVCE** Wi-Fi and signs in to the
**RV Institutions captive portal** (Sophos, `https://172.16.0.4:8090`) with **your own** institution account.

It does not bypass authentication. It does exactly what the portal's own sign-in page does:
it sends your username and password to the official portal once, and then checks that the internet works.

> **Use it only with your own RVCE account**, and follow RV Institutions' IT usage policy.
> Never share your password with anyone, including whoever gave you this tool. The tool keeps it on your PC only.

Requirements: Windows 10 or 11 (uses the built-in Windows PowerShell 5.1 and .NET Framework). Nothing to install.

> The college switched the portal from FortiGate to **Sophos** in November 2026. This version (branch `sophos-portal`)
> works with the Sophos portal. If you used the FortiGate version, just replace the files and run `Setup.cmd` again;
> your settings are migrated automatically and you'll be asked to confirm the new portal's certificate once.

## Install

1. **Get the files.** On the GitHub page click **Code > Download ZIP** and extract it, or clone it with Git.
   Put the folder somewhere **outside OneDrive**, for example `C:\Users\<you>\RVCE-Connect`.
   (OneDrive can make files "online-only", and they can't be downloaded while the portal is blocking the internet.)
2. **Double-click `Setup.cmd`** once. It builds `RVCE-Connect.exe` and `RVCE-Stop.exe` on your PC and puts two
   shortcuts on your desktop: **RVCE Connect** (green) and **RVCE Disconnect** (red).
   If Windows shows *"Windows protected your PC"* or a security warning for `Setup.cmd`, click **More info > Run anyway**
   (or **Run**). That warning appears for any script downloaded from the internet. You can read `Setup.cmd` and
   `app\Build-Launchers.ps1` first; they're short.
3. Connect to the **RVCE** Wi-Fi once through the normal Windows Wi-Fi menu, so Windows has a saved profile for it.
4. **Double-click RVCE Connect.** The first time, it asks you to:
   - **confirm the portal's certificate** (see step 2 under *Use*), and
   - **enter your own RVCE username and password** (if you're not signed in yet), then offers to save them in
     Windows Credential Manager. Say **Yes** if you want the watcher to sign you back in automatically.

If you move the folder later, run `Setup.cmd` again (it also refreshes the desktop shortcuts).

## Files

```
RVCE-Connect\
  Setup.cmd          <- run once: builds the two .exe launchers and the desktop shortcuts
  RVCE-Connect.exe   <- "RVCE Connect": signs in if needed, starts the watcher -> "Connected. Watcher running."
  RVCE-Stop.exe      <- "RVCE Disconnect": stops the watcher and signs you out -> "Disconnected."
  README.md
  app\               <- internals; you don't need to open these
    RVCE-Connect.ps1, RVCE-Watch.ps1, RVCE-Stop.ps1   the scripts
    RVCE-Connect.cmd, RVCE-Stop.cmd                   console versions, for the options below
    RvceCommon.ps1     shared code (Sophos protocol, dialogs, Wi-Fi checks)
    RvceHelper.cs      C# helper (compiled automatically at run time)
    Launcher.cs, Build-Launchers.ps1                  source and build script for the .exe files, icons and shortcuts
    config.default.json  default settings (shipped)
    config.json        your own settings, created on first run (not in git)
```

The two `.exe` files are tiny launchers built on your own PC by `Setup.cmd` from `app\Launcher.cs`, using the
C# compiler that ships with Windows. All they do is start the matching script with **no console window**, so you
only see the dialog box. They aren't stored in the repository; everyone builds their own from the source.

## Use

Double-click **RVCE Connect** on the desktop. No window opens; when it's done you get a
**"Connected. Watcher running."** box, or a box explaining what went wrong. Any questions it needs to ask
(reconnect to Wi-Fi, trust the certificate, your username and password, save them?) appear as dialog boxes.

What happens:

1. **Wi-Fi check.** If you are not on `RVCE`, it connects using your saved Wi-Fi profile, without asking.
2. **First run only: certificate check.** The portal is reached by IP address, so its certificate doesn't match
   the address (that is why Chrome shows "Not secure"). The tool shows the certificate's SHA-256 fingerprint and
   asks you to confirm (No is the default; in the console you type `YES`). To check it, open
   `https://172.16.0.4:8090/httpclient.html` in Chrome, click **Not secure > Certificate is not valid > Details**
   and compare the SHA-256 fingerprint, or ask IT.
   After that, the tool refuses any portal that presents a different certificate, with one exception: routine
   **renewals**. The portal's certificate (Let's Encrypt, for `rvce-fw.rvce.edu.in`) is replaced every couple of
   months. A new certificate is accepted without asking only if it is issued to `rvce-fw.rvce.edu.in` and chains to a
   certificate authority Windows trusts; the saved fingerprint is then updated and the change is noted in `watch.log`.
3. **Internet check.** One request to Windows' own connectivity-check URL (`http://www.msftconnecttest.com/connecttest.txt`).
   If you are already online it skips straight to starting the watcher.
4. **Sign-in.** It uses credentials saved in Windows Credential Manager, or shows the standard Windows credential
   dialog, and signs in **once**. If the portal refuses, the dialog shows the portal's own reason
   (for example a wrong password or the login limit).
5. **Verification.** It re-checks internet access a few times and tells you clearly whether it works.
6. If sign-in worked and you typed the credentials in, it asks whether to save them in Credential Manager.
7. **Watcher.** It starts the background watcher (below), unless it is already running.

Double-click **RVCE Disconnect** to stop the watcher and sign out of the portal ("Disconnected.").
It stops the watcher first, so it can't sign you straight back in. Your Wi-Fi itself stays connected.

### Options (console)

Run these from a terminal in the tool's folder. They print to the console instead of showing dialogs.

| Command | What it does |
|---|---|
| `app\RVCE-Connect.cmd -Status` | Only report Wi-Fi and internet/portal status. Never sends credentials. |
| `app\RVCE-Connect.cmd -BrowserOnly` | Open the portal's sign-in page in your default browser (sign in there yourself). |
| `app\RVCE-Connect.cmd -NoWatch` | Sign in without starting the background watcher. |
| `app\RVCE-Connect.cmd -NoReconnect` | Don't connect to the Wi-Fi automatically. |
| `app\RVCE-Connect.cmd -ForgetCredential` | Delete the saved credential from Credential Manager. |
| `app\RVCE-Connect.cmd -ResetCertificatePin` | Forget the confirmed certificate (for example after IT replaces it). |
| `app\RVCE-Connect.cmd -InstallStartup` | Start the watcher automatically when you log in (`-RemoveStartup` to undo). |
| `app\RVCE-Stop.cmd` | Disconnect: stop the watcher and sign out. |
| `app\RVCE-Stop.cmd -WatcherOnly` | Only stop the watcher; stay signed in. |
| `powershell -ExecutionPolicy Bypass -File app\Build-Launchers.ps1 -NoShortcuts` | Rebuild the `.exe` files without touching the desktop shortcuts. |

## Background watcher

It starts when you log in to Windows (Setup adds it to Startup; `-RemoveStartup` undoes that), and after
RVCE Connect finds you online. It keeps running until you choose **Exit** from its tray menu or use RVCE
Disconnect. A coloured dot appears in the system tray (it may be under the `^` arrow):

| Dot | Meaning |
|---|---|
| Green | On RVCE and online. |
| Amber | Signing in, or waiting before retrying. |
| Red | A problem needs you: RVCE Wi-Fi not found, the portal isn't responding, or automatic sign-in is paused. |
| Grey | On another network (for example at home, or on a hotspot), or Wi-Fi is off. The watcher leaves everything alone. |

While you're on RVCE it:
- checks internet access **every 30 minutes** (`WatchIntervalSeconds`), and a few seconds after your Wi-Fi
  connection changes (joining RVCE, waking from sleep). Noticing the change is purely local; it sends nothing;
- only signs in **if you're not signed in**, once, using the credentials saved in Credential Manager;
- sends the portal's own **keep-alive** to the firewall every 3 minutes (`KeepaliveSeconds`). This is exactly what
  the Sophos sign-in tab does in your browser ("do not close this page"); it is a tiny request to the firewall on
  the campus network, not to the internet. If the firewall answers that you've been signed out, the watcher signs
  you back in immediately instead of waiting 30 minutes. Turn it off with `"UseKeepalive": false`.

When you're **not connected to any Wi-Fi** (for example after waking from sleep), it joins `RVCE` using your
saved Windows Wi-Fi profile. If RVCE isn't in range it shows a warning once and quietly tries again every minute.

On any other Wi-Fi network (or with Wi-Fi switched off) it does nothing at all; it never switches you away from
another network. To move to RVCE, double-click **RVCE Connect**.

It needs saved credentials: answer **Yes** when RVCE Connect offers to save them after a sign-in.

**Limits that stop it resubmitting credentials:**
- after a failed attempt it waits 5 minutes before trying again (`AutoSignInCooldownMinutes`);
- automatic sign-in **pauses completely** if the portal rejects the credentials, the certificate changes,
  or it fails 3 times in a row (`MaxAutoSignInFailures`). Choose **Sign in now...** from the tray menu to resume.
- It never switches your Wi-Fi network. It only tells you when the RVCE Wi-Fi drops.

Notifications appear only when something changes: you lost internet, you were signed back in, or the Wi-Fi dropped.
Every change is also written to `%LOCALAPPDATA%\RVCE-Connect\watch.log`, so you can see when disconnects happened.
Open it with **Open connection log** from the tray menu. The log never contains your password.

**Tray menu (right-click the dot):** Check now, Sign in now..., Open portal in browser, Open connection log,
Disconnect and exit, Exit (stay signed in). Double-clicking the dot runs a check immediately.

### Exit codes (for scripting)

`0` online, `1` not on RVCE Wi-Fi, `2` portal not responding / certificate changed,
`3` sign-in rejected, `4` signed in but internet still not working, `5` bad config, `6` cancelled.

## Security and privacy

- **Credentials** are stored only in **Windows Credential Manager** (*Control Panel > Credential Manager >
  Windows Credentials*, entry `RVCE-Connect:CaptivePortal`). They are tied to your Windows account and protected by Windows.
  The tool never writes your password to a file, never prints it, and never logs it. In memory the password stays a
  `SecureString`, and the request body containing it is wiped right after it is sent.
- **Credentials go only to the official portal**: HTTPS, host `172.16.0.4`, port `8090`, with the certificate
  you confirmed (or a publicly trusted renewal of it for `rvce-fw.rvce.edu.in`). Anything else is refused.
- **One attempt per run.** Timeouts and rejections are reported, never retried immediately, so your account
  can't be locked out by repeated submissions.
- **Network traffic:** the Microsoft connectivity-check URL and the RVCE portal only. Nothing else is probed or scanned.
- The browser is only ever opened on the portal's own `https` page.

## Permissions needed

| Permission | Why | Required? |
|---|---|---|
| **Run a local PowerShell script** | The launchers use `-ExecutionPolicy Bypass` for that one process only. Your system policy is not changed. | Yes |
| **Location access for desktop apps** (Windows 11 24H2 and later) | Windows hides the Wi-Fi network name (SSID) from `netsh` unless location is allowed: *Settings > Privacy & security > Location* > turn on *Location services* and *Let desktop apps access your location*. Without it the tool falls back to the Windows network-profile name, which is usually still `RVCE`. | Recommended |
| **Windows Credential Manager** (your own user store) | Only if you choose to save credentials. No admin needed. | Optional |
| **Administrator** | Not needed. | No |

## Configuration (`app\config.json`)

`app\config.json` is created from `app\config.default.json` the first time you run the tool. Edit your
`config.json`, not the default (the default is what other people get). Old FortiGate-era settings
(`172.16.0.2:1003`, 60-second checks) and the earlier 25-minute default are migrated automatically.

| Key | Meaning |
|---|---|
| `Ssid` | Expected Wi-Fi name (`RVCE`). |
| `PortalHost`, `PortalPort` | The only place credentials may be sent (`172.16.0.4`, `8090`). Change only if RVCE IT changes the portal. |
| `PinnedCertSha256` | Filled in automatically when you confirm the certificate, and updated on renewals. |
| `PortalCertName` | Name a renewed portal certificate must be issued to (`rvce-fw.rvce.edu.in`). Set to `""` to be asked about every new certificate. |
| `CredentialTarget` | Name of the Credential Manager entry. |
| `TimeoutSeconds`, `VerifyAttempts`, `VerifyIntervalSeconds` | Network timeout and how long to keep checking after sign-in. |
| `WatchIntervalSeconds` | How often the watcher does a full internet check (default 1800 = 30 min, minimum 60). |
| `UseKeepalive`, `KeepaliveSeconds` | Whether and how often the watcher sends the portal's keep-alive (default on, 180 s). |
| `AutoSignInCooldownMinutes`, `MaxAutoSignInFailures` | Watcher limits on automatic sign-in (defaults 5 and 3). |

Files kept in `%LOCALAPPDATA%\RVCE-Connect\` (your user folder, not synced to OneDrive):
`watch.log` (connection history) and `session.json` (which username the tool last signed in with, used for
keep-alive and sign-out; no password).

## Troubleshooting

- **"Connected to Wi-Fi, but the network name could not be read"**: turn on Location access (see Permissions).
- **"Different certificate"**: it is not a trusted renewal for `rvce-fw.rvce.edu.in`, so don't sign in. Check with IT. If the change is genuine, run `app\RVCE-Connect.cmd -ResetCertificatePin`.
- **Sign-in rejected**: the dialog shows the portal's reason. If your password changed, run `app\RVCE-Connect.cmd -ForgetCredential`
  and sign in again.
- **"extra verification step"**: the portal asked for something this tool doesn't support (for example a one-time code).
  Sign in with `app\RVCE-Connect.cmd -BrowserOnly`.
- **Signed in but no internet**: wait a few seconds and run `app\RVCE-Connect.cmd -Status`. The gateway sometimes takes a moment.
- **Shortcuts or `RVCE-Connect.exe` missing**: run `Setup.cmd`.
- **"Missing file ... Keep the 'app' folder next to this program"**: the `.exe` was moved away from the `app` folder.
  Keep them together, or run `Setup.cmd` again in the new place.
- **Antivirus warns about the .exe**: it's the launcher built from `app\Launcher.cs`. Rebuild it with `Setup.cmd`,
  or run the scripts with `app\RVCE-Connect.cmd` instead.

## Uninstall

Double-click RVCE Disconnect, then run `app\RVCE-Connect.cmd -RemoveStartup` and `app\RVCE-Connect.cmd -ForgetCredential`.
Then delete this folder, the two desktop shortcuts and `%LOCALAPPDATA%\RVCE-Connect`.
