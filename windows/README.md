# Claude-RTL on Windows (beta)

Windows port of the kit. Status: **beta** — the mechanics (extract, inject, repack, fuse, watcher)
are the upstream liorshaya scripts that were verified on real Windows machines, plus this kit's
wrapper which is exercised by a GitHub Actions job on `windows-latest` against the real Claude
package. What has **not** been done yet is a human looking at the result on a Windows screen.
If you run it, please open an issue with what you saw (a screenshot of a mixed Hebrew/English
message is enough).

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Check     # environment + scan for previous RTL patches, no changes
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1            # install / re-install / upgrade
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Status
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Uninstall
```

Requirements: the official Claude Desktop, Node.js 18+ (https://nodejs.org or
`winget install OpenJS.NodeJS.LTS`), Windows PowerShell 5.1 or later (built in).

## Two kinds of Claude install on Windows

Anthropic changed the installer in February 2026, so there are two regimes. The kit detects
which one you have.

| | Squirrel (classic installer) | MSIX (Microsoft Store style, current default) |
|---|---|---|
| Where | `%LOCALAPPDATA%\AnthropicClaude\app-<ver>\` | `C:\Program Files\WindowsApps\Claude_*` |
| Writable by you | yes | no (locked to the system, anti-tamper) |
| What the kit does | patches **in place**, after backing up `claude.exe` and `app.asar` to `*.crtl-bak` | needs an **elevated** PowerShell; takes ownership of the package folder, patches in place, re-signs `claude.exe` with a self-signed certificate and adds it to the machine Trusted Root store so Cowork keeps working |
| Auto-repatch | per-user logon watcher (`HKCU\...\Run\ClaudeRtlWatcher`) | elevated scheduled task `ClaudeRtlMsixWatcher` |
| Undo | `-Uninstall` restores the backups and removes the watcher | `patch-msix.ps1 -Cleanup` from an elevated shell (the kit prints the command) |

Unlike macOS and Linux there is no separate "Claude-RTL" copy on Windows: Squirrel discards the
whole `app-<ver>` folder on every update, and an MSIX package cannot be copied and run. The
original is therefore modified, with a backup. This is the same model every Windows RTL patch
uses (shraga100, ikhd, liorshaya).

**MSIX is the invasive one.** The kit never runs it silently: from a normal shell it explains
what would happen and prints the exact elevated command (`install.ps1 -AcceptMsixChanges`).
If that is more than you want, the upstream one-click installer
(https://github.com/liorshaya/claude-desktop-rtl/releases/latest) does the same steps with a
tray app and bundled Node, but without this kit's Code-tab fix.

## Running it from inside Claude Desktop

If you paste the repo link into Claude's Code tab, Claude Desktop is running while the kit
runs, and a running app's files are locked. The kit does not kill it. It installs the watcher
and tells you to close Claude; the watcher patches the install within about a minute of the
close (it checks every 60 s), and you reopen Claude with RTL. `-StopClaude` patches immediately
instead (that closes Claude, so not from inside the Code tab).

## After a Claude update

Squirrel installs each update into a new `app-<ver>` folder without the patch. The logon
watcher notices the new folder, waits for the update to settle, and re-patches without ever
force-closing a running Claude (if Claude is already running the new version, RTL applies
after the next close/reopen). Log: `%LOCALAPPDATA%\claude-rtl\watch.log`.

## What gets installed

| Path | What |
|---|---|
| `%LOCALAPPDATA%\claude-rtl-kit\claude-desktop-rtl\` | the patch engine + upstream Windows scripts (permanent; the watcher points here) |
| `%LOCALAPPDATA%\AnthropicClaude\app-<ver>\claude.exe.crtl-bak`, `...\resources\app.asar.crtl-bak` | pristine backups (Squirrel) |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\ClaudeRtlWatcher` | logon watcher |
| `%LOCALAPPDATA%\claude-rtl\watch.log` | watcher log |

Previous patches from other projects: the kit detects their markers inside `app.asar`
(shraga100's `rtl-core`, others) and their watchers (`ClaudeRtlPatchWatcher` scheduled task,
`*rtl*` logon entries). It disables the watchers (saved, not deleted) and refuses to patch on
top of a foreign patch: restore that project's backup or reinstall Claude first.

## Files

- `install.ps1` — this kit's wrapper (checks, prior-patch scan, source + tests, patch, watcher, verify).
- The actual work is done by the vendored upstream scripts in
  `source/claude-desktop-rtl/desktop/windows/`: `patch.ps1` (Squirrel), `patch-msix.ps1` (MSIX),
  `watch.ps1`, `inject.mjs`, `preflight.ps1`, `diagnose.ps1`, `cleanup.ps1`.
- `..\.github\workflows\windows-smoke.yml` — the CI job that runs the Squirrel path on a real
  Claude package on every push.
