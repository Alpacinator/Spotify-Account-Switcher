# Spotify Account Switcher
A PowerShell script for Windows that lets you save multiple Spotify desktop accounts and switch between them instantly, without ever clicking the logout button.

## Quick start
**[Download spotify-account-switcher.ps1](https://github.com/Alpacinator/Spotify-Account-Switcher/releases/latest/download/spotify-account-switcher.ps1)**

Before running, you need to unblock the file, because Windows flags scripts downloaded from the internet as untrusted:

1. Right-click the downloaded file and choose **Properties**
2. At the bottom of the General tab, check **Unblock**
3. Click **OK**

After that, right-click the file and choose **Run with PowerShell**.

If you still get an execution policy error after unblocking, open PowerShell in the folder containing the script and run:
```powershell
powershell -ExecutionPolicy Bypass -File ".\spotify-account-switcher.ps1"
```
That runs it once without changing any system settings. If you want to be able to double-click it going forward, see [Setup](#setup).


## Why

Spotify's desktop app has no built-in account switching. The only official path is to log out and log back in, which is a problem: logging out invalidates your session on the server, meaning any saved credentials become useless. If you want to switch between two accounts regularly, a personal account and a work or family account, for example, you are stuck re-entering passwords every time.

This script sidesteps that entirely. It saves each account's authentication blob directly from Spotify's local `prefs` file, then restores it when you want to switch. The server session is never touched. Your credentials stay valid indefinitely.

### Why not just use Spicetify or a browser extension?

The Spotify desktop app runs in a sandboxed Chromium renderer. The authentication cookie (`sp_dc`) that controls your session is flagged `HttpOnly`, so page JavaScript cannot read or write it. The Spicetify extension environment has no filesystem access either. After extensive testing, including probing `Spicetify.Platform.Session`, the cookie store, IndexedDB, and live token swapping, none of these paths can reach the credential layer. The only thing that works is operating on the files directly, from outside the app.


## How it works

Spotify stores login credentials locally in:

```
%APPDATA%\Roaming\Spotify\prefs
```

Specifically these four fields:

```
autologin.username
autologin.canonical_username
autologin.blob
autologin.saved_credentials
```

The `autologin.blob` is an encrypted credential that Spotify uses to authenticate without requiring a password. As long as the account is not logged out via the app or the Spotify website, this blob stays valid.

When you save an account, the script copies these fields plus the per-user data folder from `%APPDATA%\Roaming\Spotify\Users\` into a named profile stored at:

```
%APPDATA%\Roaming\Spotify\AccountProfiles\<label>\
```

When you switch to a saved account, the script:

1. Stops Spotify
2. Writes the saved credentials back into `prefs`
3. Deletes `%LOCALAPPDATA%\Spotify\dbrts`, a session cache that overrides `prefs` on startup if left in place
4. Swaps the per-user data folder
5. Restarts Spotify


## Requirements

- Windows 10 or 11
- Spotify desktop app installed via the **classic installer** (not the Microsoft Store version, could work but didn't test it)
- PowerShell 5.1 or later

## Usage

Double-click the script or run it from PowerShell with no arguments:

```powershell
.\spotify-account-switcher.ps1
```

A window appears showing all your saved account cards. Click a card to switch to that account. Spotify will stop and restart automatically.

If that doesn't work, try launching it like this:

```powershell
powershell -ExecutionPolicy Bypass -File ".\spotify-account-switcher.ps1"
```

### Command line

Switch by label (case-insensitive):

```powershell
.\spotify-account-switcher.ps1 -user Bob
```

Switch by position in the saved list (first user is 1):

```powershell
.\spotify-account-switcher.ps1 -userid 2
```


## Adding a second account

1. Open the GUI and click **+ Add user**
2. Choose **Prepare for a new login**
3. If your current account is not already saved, you will be offered the chance to save it first
4. The script clears the autologin fields from `prefs`, removes dbrts, and launches Spotify, which opens the login screen
5. Log in with the new account
6. Close Spotify
7. Open the GUI again, click **+ Add user**, choose **Save current account**, and give it a label

From this point, both accounts appear as cards and you can switch freely.


## Files

The script stores everything under `%APPDATA%\Roaming\Spotify\AccountProfiles\`. Each profile is a folder named after its label, containing:

```
meta.json      label, username, and save timestamp
auth.json      the four autologin fields from prefs
userdata\      copy of the Spotify Users subfolder for this account
```

Nothing is written outside of the Spotify data directory and the Windows Startup folder (if you enable the startup option).

---

## Caveats

- Only works with the **classic installer** build of Spotify. The Microsoft Store version stores data in a different location under `%LOCALAPPDATA%\Packages\` and has not been tested.
- If Spotify pushes an update that changes how it stores credentials, the blob format may change and saved profiles may stop working. Re-saving the profile after logging in again may fix it.
- The script must be run from its original path if you use the startup option, since the shortcut points to the file's location at the time you enabled it. If you move the file, disable and re-enable the startup checkbox.
