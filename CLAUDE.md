# claude-rtl-kit — instructions for the Claude Code agent

You are reading this because a user opened Claude Desktop, pointed the Code tab at this
repository, and wants Hebrew/Arabic right-to-left rendering in Claude Desktop. Do the whole
job yourself, then explain the result to the user in the language they write in (usually
Hebrew). First find out which OS you are on (`uname -s`): Darwin → **macOS** section,
Linux → **Linux** section.

**If the user gave you the repository URL instead of opening the repo folder** (the README
tells people to do exactly that), start by getting the repo onto the machine:
`git clone https://github.com/oshrychen/claude-rtl-kit-oshry.git ~/claude-rtl-kit-oshry`
(or `git -C ~/claude-rtl-kit-oshry pull` if it already exists), then work from that folder.
Everything below assumes you are inside it. The installers must stay at a permanent path,
because the update watcher points back at them — never run them from a temp directory.

## What this kit is

Claude Desktop's chat is loaded from claude.ai, which has no RTL handling for messages
(verified 2026-09-18: no `dir` attribute or bidi CSS on message roots; only the Code/Cowork
tab UI uses `dir="auto"`). This kit installs the community patch
**liorshaya/claude-desktop-rtl v0.2.21** plus one extra fix (their open PR #3, which covers the
Code tab's user turns). The source is vendored as plain files in `source/claude-desktop-rtl`
(no git metadata); `VERSIONS.md` records the upstream commit and the PR commit, and the extra
fix is also at `patches/0001-code-tab-surface.patch`.

The patch never modifies the original Claude installation. On macOS it builds a separate copy
at `~/Applications/Claude-RTL.app` (same login, same chats, same bundle id) and installs a user
LaunchAgent (`com.claude-rtl.watcher`) that rebuilds the copy after every Claude update. On
Linux it does the same with `~/.local/lib/claude-rtl` (built from the root-owned apt package,
without root) and a systemd **user** path unit (`claude-rtl-watch.path`).

Layout:

- `mac/install.sh` — macOS installer (idempotent). `mac/swap-when-quit.sh` — helper.
- `linux/` — Linux installer (`install.sh`, `patch.sh`, `watch.sh`, `swap-when-quit.sh`,
  templates) + `README.md`. `PROMPT.md` is the prompt it was built from, kept for the record.
- `source/claude-desktop-rtl` — the patch engine + payload builder (shared by both OSes).
- `patches/` — extra fixes on top of upstream, as patch files.

## macOS — what to do

1. Run `bash mac/install.sh --check` and read the output. It reports the environment and any
   previous RTL patch (from this or another project).
2. Fix what the check asks for:
   - **Node missing / too old**: ask the user before installing anything. Preferred:
     `brew install node` if Homebrew exists, else the installer from https://nodejs.org.
   - **codesign missing**: `xcode-select --install` (the user must click through the dialog).
   - **Original is MODIFIED**: another project patched `/Applications/Claude.app` in place
     (ikhd, ChenWolfson, toboly, …). The kit refuses to build from a modified original. Tell
     the user to download Claude from https://claude.com/download and drag it over
     `/Applications/Claude.app`, then continue. Do not try to "unpatch" it by hand.
   - **Foreign LaunchAgents** (e.g. `com.claudertl.autoupdate`): `install.sh` disables them
     itself and moves the plist to `~/Library/LaunchAgents/disabled-by-claude-rtl-kit/`.
   - A previous `~/Applications/Claude-RTL.app` from any project (soguy, abd3lraouf, …) is
     simply replaced. A `/Applications/Claude RTL.app` GUI manager is left alone.
3. Run `bash mac/install.sh`. It is idempotent; re-running is safe.
4. **If the session is running inside Claude-RTL itself** (check with
   `ps -axo command | grep -F "Claude-RTL.app/Contents/" | grep -v grep` — use `ps`, not
   `pgrep`, which cannot see the host app's main process from a sandboxed session), the running
   bundle cannot be replaced. `install.sh` handles this: it builds `Claude-RTL-next.app` and
   starts a detached waiter that swaps it in the moment Claude-RTL quits. Tell the user:
   quit Claude-RTL, wait for the notification, reopen it. Fallback if the waiter died:
   `bash mac/swap-when-quit.sh --now` after quitting.
5. Verify with `bash mac/install.sh --status`: patched version == original version, Code-tab
   fix "yes", watcher active with a PATH that contains the real Node directory.
6. You cannot screenshot Claude-RTL from a session hosted by Claude (same bundle id — the
   computer-use tool refuses). Ask the user to check visually and tell them what to look for:
   in the Chat tab a mixed Hebrew/English sentence right-aligned with the English terms in
   the right order and the final period on the left; list bullets on the right; table
   columns starting from the right; quote bar on the right; code blocks still LTR. In the
   Code tab, the user's own messages should now also be right-aligned (that is the extra fix).

Known limits (do not chase them as bugs): Desktop Artifacts render in a cross-origin iframe
the payload cannot enter; Claude-RTL and `/Applications/Claude.app` cannot run at the same
time (shared user-data dir) — quit one before opening the other.

### After a Claude update (macOS)

The watcher rebuilds automatically (log: `~/Library/Logs/claude-rtl-watch.log`). If RTL is
gone after an update, read that log first, then run `bash mac/install.sh` again.

### Removal (macOS)

`bash mac/install.sh --uninstall` removes `~/Applications/Claude-RTL.app` and the watcher.
The original Claude is never touched.

## Linux — what to do

Claude Desktop for Linux is an official beta, installed from Anthropic's apt repo as the
`claude-desktop` package under `/usr/lib/claude-desktop` (root-owned). `linux/install.sh`
builds a patched copy in user space, so no root is needed and the package's files are never
touched. `linux/README.md` has the details and the reasoning; the short version:

1. Run `bash linux/install.sh --check` and read the output. It reports the environment and any
   previous RTL patch (from this or another project).
2. Fix what the check asks for:
   - **Node missing / too old**: ask the user before installing anything. Any Node >= 18 with
     npm works (distro package, nvm, or https://nodejs.org).
   - **Original is MODIFIED** (RTL markers inside the package's `app.asar`, or `dpkg --verify`
     disagreeing): another project patched `/usr/lib/claude-desktop` in place. The kit refuses
     to build from a modified package. Tell the user to run `sudo apt reinstall claude-desktop`,
     then continue. Do not try to "unpatch" it by hand.
   - **Foreign systemd user units** (`*claude*rtl*`): `install.sh` disables them itself and
     moves them to `~/.config/systemd/user/disabled-by-claude-rtl-kit/`.
   - **No `systemd --user`**: the auto-repatch watcher is skipped. Everything else works, but
     the user must re-run `install.sh` after each Claude update.
   - A community package (maintainer is not Anthropic, e.g. `aaddrick/claude-desktop-debian`)
     is only warned about; the build continues as long as the layout matches.
3. Run `bash linux/install.sh`. It is idempotent; re-running is safe.
4. **If the session is running inside Claude-RTL itself** (check with
   `ps -axo command | grep -F "$HOME/.local/lib/claude-rtl/claude-desktop" | grep -v grep` —
   use `ps`, not `pgrep`, which cannot see the host app's main process from a sandboxed
   session), the running copy cannot be replaced. `install.sh` handles this: it builds
   `~/.local/lib/claude-rtl-next` and starts a detached waiter that swaps it in the moment
   Claude-RTL quits. Tell the user: quit Claude-RTL, then reopen it. Fallback if the waiter
   died: `bash linux/swap-when-quit.sh --now` after quitting.
5. Verify with `bash linux/install.sh --status`: the copy was built from the installed package
   version, Code-tab fix "yes", watcher active with a PATH that contains the real Node
   directory. `bash linux/install.sh --smoke-test` launches the copy for 20 seconds with a
   throwaway profile and fails on a missing window, a sandbox refusal or an asar error.
6. Ask the user to check visually and tell them what to look for — the same list as macOS: in
   the Chat tab a mixed Hebrew/English sentence right-aligned with the English terms in the
   right order and the final period on the left; list bullets on the right; table columns
   starting from the right; quote bar on the right; code blocks still LTR. In the Code tab,
   the user's own messages should now also be right-aligned (that is the extra fix).

Three Linux specifics that are deliberate — do not "simplify" them away:

- The copy's `chrome-sandbox` is a **symlink** to the package's root-owned setuid helper. A
  plain copy loses the setuid bit, and the copy is not covered by the package's AppArmor
  userns profile, so Chromium would refuse to start.
- The copy gets its **own Wayland `app_id`** (`com.anthropic.ClaudeRTL`, from package.json
  `desktopName`), and its `.desktop` file is named to match. Sharing the original's id makes
  two entries claim one `StartupWMClass`, and the dock then shows no "running" dot. The
  environment variable and `--class` routes do not work; the app overrides both.
- The asar-integrity fuse is left as shipped, because Electron does not enforce it on Linux.
  `CLAUDE_RTL_FLIP_FUSE=1` flips it if that ever changes.

Pinning to the dock is the user's choice; `linux/README.md` has the one-liner.

Known limits (do not chase them as bugs): Desktop Artifacts render in a cross-origin iframe
the payload cannot enter; Claude-RTL and the original cannot run at the same time (shared
`~/.config/Claude`) — quit one before opening the other.

### After a Claude update (Linux)

`apt upgrade` replaces the package files; `claude-rtl-watch.path` triggers `linux/watch.sh`,
which waits until dpkg is done and the files are stable, then rebuilds the copy (log:
`~/.local/state/claude-rtl/watch.log`). If RTL is gone after an update, read that log first,
then run `bash linux/install.sh` again. Turn the watcher off with
`systemctl --user disable --now claude-rtl-watch.path`.

### Removal (Linux)

`bash linux/install.sh --uninstall` removes the copy, the launcher, the menu entry and the
watcher, and unpins it from the dock. The apt package is never touched.

## Updating the patch itself

`source/claude-desktop-rtl` has no git metadata. To move to a newer upstream:

```bash
git clone https://github.com/liorshaya/claude-desktop-rtl.git /tmp/upstream
cd /tmp/upstream && git checkout <new tag> && git am ../claude-rtl-kit-oshry/patches/*.patch
```

If `git am` fails, upstream may already include the fix (then drop the patch) or the DOM
selectors moved (then re-point them per upstream's `docs/RUNBOOK-adopt-new-claude-version.md`).
Run the tests (`node --test engine/__tests__/*.test.js dom/__tests__/*.test.js build/__tests__/*.test.js`),
copy the tree without `.git`, `dist`, `node_modules` over `source/claude-desktop-rtl`, update
`VERSIONS.md`, re-run the installer, commit.
