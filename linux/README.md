# Claude-RTL on Linux

Linux port of the kit for the official Claude Desktop apt package (`claude-desktop`,
Ubuntu 22.04+/Debian 12+). Same idea as macOS: the package under `/usr/lib/claude-desktop`
is **never modified**. A patched copy is built in user space, so no root is needed.

```bash
bash linux/install.sh --check       # environment + scan for previous RTL patches, no changes
bash linux/install.sh               # install / re-install / upgrade (idempotent)
bash linux/install.sh --status
bash linux/install.sh --smoke-test  # launches the copy for 20s with a throwaway profile
bash linux/install.sh --uninstall
```

Requirements: the official `claude-desktop` package, Node.js ≥ 18 with npm (nvm is fine),
`systemd --user` (for the auto-repatch watcher; optional), `notify-send` (optional).

## What gets installed (all under `$HOME`)

| Path | What |
|---|---|
| `~/.local/lib/claude-rtl/` | the patched copy of `/usr/lib/claude-desktop` (≈580 MB) |
| `~/.local/bin/claude-rtl` | launcher; app-menu entry **Claude-RTL** (`~/.local/share/applications/claude-rtl.desktop`) |
| `~/.local/share/claude-rtl/` | `engine/` (patch source), `linux/` (these scripts), `tools/` (@electron/asar) |
| `~/.config/systemd/user/claude-rtl-watch.{path,service}` | re-patches after every `apt upgrade` of claude-desktop |
| `~/.local/state/claude-rtl/` | `watch.log`, `swap.log`, `tests.log` |

The copy uses the same profile (`~/.config/Claude`) as the original, so it has the same
login and chats. Because of that, **the original Claude and Claude-RTL cannot run at the
same time** — quit one (tray icon → Quit) before starting the other.

## Why a separate copy and not an in-place patch

- `/usr/lib/claude-desktop` is root-owned; an in-place patch needs sudo for every
  (re)patch and gets silently overwritten by the next `apt upgrade`.
- `dpkg --verify` stays clean, so "is the original modified?" remains answerable.
- A separate copy is exactly what the macOS kit does, so the watcher/swap logic is the same.

Two Linux-specific details, both handled by `linux/patch.sh`:

- **Sandbox helper.** Ubuntu 24.04+ restricts unprivileged user namespaces; the package
  allowlists its own binary path through an AppArmor profile. Our copy has no such profile,
  so Chromium falls back to the SUID `chrome-sandbox` helper — which a plain copy loses
  (no root ownership, no setuid). The copy therefore carries a **symlink** to the package's
  root-owned `chrome-sandbox`. Result: full sandbox, no `--no-sandbox`.
- **asar-integrity fuse.** `EnableEmbeddedAsarIntegrityValidation` is on in the Linux build,
  but Electron only implements the check on macOS and Windows; on Linux the modified
  `app.asar` loads as-is (verified on claude-desktop 2.110.1 / Electron 44.2.0). The 228 MB
  binary is left byte-identical. If a future Electron enforces it on Linux, run
  `CLAUDE_RTL_FLIP_FUSE=1 bash linux/install.sh`.

## After a Claude update

`apt upgrade` replaces the package files. The user path unit `claude-rtl-watch.path` sees
that, `watch.sh` waits until dpkg is done and the files are stable, then rebuilds the copy.
If Claude-RTL is running at that moment, it builds `~/.local/lib/claude-rtl-next` and a
detached waiter swaps it in as soon as Claude-RTL quits (desktop notification).

- Log: `~/.local/state/claude-rtl/watch.log`
- Manual re-patch: `bash linux/install.sh`
- Swap by hand if the waiter died: quit Claude-RTL, then `bash linux/swap-when-quit.sh --now`
- Turn the watcher off: `systemctl --user disable --now claude-rtl-watch.path`
  (on again: `systemctl --user enable --now claude-rtl-watch.path`)

## Files

- `install.sh` — orchestration: checks, prior-patch scan, source + tests, build, launcher, watcher, verify.
- `patch.sh` — the build: copy → inject payload into every `.vite/build/*.js` except the
  main entry (`index.pre.js` gets only the `force-ui-direction=ltr` switch) → repack with the
  original's unpacked set → verify markers and unpacked count → atomic swap with rollback.
- `watch.sh`, `swap-when-quit.sh` — update handling (see above).
- `claude-rtl.desktop`, `claude-rtl-watch.path`, `claude-rtl-watch.service` — templates.
- `PROMPT.md` — the prompt this port was built from (kept for the record).

## Dock identity (the "running" dot)

GNOME matches a window to a desktop entry by the window's Wayland `app_id` (X11 `WM_CLASS`),
and Chromium derives that from package.json `desktopName` — the app calls
`app.setDesktopName()` itself at startup, so a `CHROME_DESKTOP` in the environment is ignored
and the `--class` switch is rejected outright by the app's own argument parser (both verified
on 2.110.1). A plain copy therefore announces `com.anthropic.Claude`, exactly like the
original: two desktop entries claim the same `StartupWMClass`, GNOME cannot tell which entry
the window belongs to, and the dock shows **no running dot** on the pinned icon.

`patch.sh` gives the copy its own identity — `desktopName` becomes
`com.anthropic.ClaudeRTL.desktop` — and `install.sh` names its entry to match
(`~/.local/share/applications/com.anthropic.ClaudeRTL.desktop`, `StartupWMClass=com.anthropic.ClaudeRTL`).
Each app then has one unambiguous entry: the dot, the icon and window grouping all land on
the right one. Override with `CLAUDE_RTL_DESKTOP_NAME=...` (both scripts read it).

Pinning is left to you. To swap a pinned original for this one:

```bash
gsettings set org.gnome.shell favorite-apps "$(gsettings get org.gnome.shell favorite-apps | sed "s/'com.anthropic.Claude.desktop'/'com.anthropic.ClaudeRTL.desktop'/")"
```

Side effect worth knowing: the app keeps a generated copy of the original's entry at
`~/.local/share/applications/com.anthropic.Claude.desktop` (two extra dock actions, marked
`X-Claude-Generated`). Since the copy no longer identifies as `com.anthropic.Claude`, running
it removes that generated file; the original recreates it on its next launch, and its
system entry in `/usr/share/applications` is never affected either way.

Chrome extension ("Claude in Chrome"): on every launch the app registers its own
`resources/chrome-native-host` with Chrome, so whichever copy ran last owns the manifest
(`~/.config/google-chrome/NativeMessagingHosts/com.anthropic.claude_browser_extension.json`).
Both work the same; `--uninstall` points it back at the package.

Known limits: Desktop Artifacts are not covered (cross-origin iframe). A first launch may
show a blank window once — quit and reopen.
