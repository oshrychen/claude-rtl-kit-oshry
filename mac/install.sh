#!/usr/bin/env bash
# Claude-RTL Kit — macOS installer (idempotent).
#
#   bash mac/install.sh            # full install (or re-install / upgrade)
#   bash mac/install.sh --status   # what is installed
#   bash mac/install.sh --check    # only the environment + prior-patch scan, no changes
#   bash mac/install.sh --uninstall
#
# What it does:
#   1. checks macOS, Node >= 18, Xcode CLT (codesign), /Applications/Claude.app
#   2. scans for PREVIOUS RTL patches (any project) and cleans what it safely can
#   3. copies the vendored source (liorshaya/claude-desktop-rtl v0.2.21 + Code-tab fix)
#      to ~/Applications/claude-desktop-rtl and runs its test suite
#   4. builds ~/Applications/Claude-RTL.app from a COPY of the original (never touches
#      /Applications/Claude.app); if Claude-RTL is running, builds Claude-RTL-next.app and
#      swaps it in the moment Claude-RTL quits
#   5. installs the LaunchAgent that re-patches after every Claude update, with the real
#      Node directory on its PATH
#   6. verifies the result
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$KIT/source/claude-desktop-rtl"
INSTALL_DIR="$HOME/Applications/claude-desktop-rtl"
ORIG="/Applications/Claude.app"
DEST="$HOME/Applications/Claude-RTL.app"
NEXT="$HOME/Applications/Claude-RTL-next.app"
WATCH_LABEL="com.claude-rtl.watcher"
WATCH_PLIST="$HOME/Library/LaunchAgents/$WATCH_LABEL.plist"
MODE="${1:---install}"

log()  { printf 'kit: %s\n' "$*"; }
warn() { printf 'kit: WARNING — %s\n' "$*" >&2; }
die()  { printf 'kit: ERROR — %s\n' "$*" >&2; exit 1; }
ver()  { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo '?'; }
# ps, not pgrep: from a sandboxed Claude Code session pgrep cannot see the host app's own
# main process, and missing it would let us replace a running bundle.
running_dest() { ps -axo command | grep -F "$DEST/Contents/" | grep -v grep >/dev/null 2>&1; }

# SHA-256 of the asar header JSON — what Electron's ElectronAsarIntegrity compares.
asar_header_hash() {
  local a="$1" jlen
  jlen="$(od -An -tu4 -j12 -N4 "$a" | tr -d ' ')"
  head -c "$((16 + jlen))" "$a" | tail -c "$jlen" | shasum -a 256 | cut -d' ' -f1
}

# Claude Desktop's Code tab (like any GUI-launched shell) has a minimal PATH that skips the
# user's shell profile, so an installed Node is often invisible here. Look in the usual
# places before declaring it missing; prepend the first hit so npx works too.
find_node() {
  command -v node >/dev/null 2>&1 && return 0
  local d
  for d in "$HOME/.local/node/bin" /opt/homebrew/bin /usr/local/bin "$HOME/.volta/bin" \
           "$HOME/.local/share/fnm/aliases/default/bin" "$HOME/.fnm/aliases/default/bin" \
           $(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1) \
           $(ls -d /opt/homebrew/opt/node@*/bin 2>/dev/null | sort -V | tail -1); do
    if [ -x "$d/node" ] && [ -x "$d/npx" ]; then
      export PATH="$d:$PATH"
      log "node found outside PATH at $d — added for this run."
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 1. environment ----
check_env() {
  [ "$(uname -s)" = "Darwin" ] || die "macOS only (this is $(uname -s))."
  [ -d "$ORIG" ] || die "Claude Desktop is not installed at $ORIG — install it from https://claude.com/download first."
  [ -f "$ORIG/Contents/Resources/app.asar" ] || die "unexpected layout: no app.asar in $ORIG."
  command -v codesign >/dev/null || die "codesign missing — run: xcode-select --install"
  find_node || true
  if ! command -v node >/dev/null; then
    die "Node.js not found. Install it (https://nodejs.org, or: brew install node), then re-run."
  fi
  local major; major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$major" -ge 18 ] || die "Node >= 18 required, have $(node -v)."
  command -v npx >/dev/null || die "npx missing (comes with Node)."
  NODE_DIR="$(dirname "$(command -v node)")"
  log "env OK — macOS $(sw_vers -productVersion), Claude v$(ver "$ORIG"), node $(node -v) at $NODE_DIR"
  [ -d "$SRC/desktop" ] || die "vendored source missing at $SRC."
  grep -q 'epitaxy-user-turn' "$SRC/dom/surfaces.js" || die "vendored source lacks the Code-tab fix (patches/0001-code-tab-surface.patch)."
}

# ------------------------------------------------------- 2. previous patches scan ----
scan_prior() {
  local problems=0
  log "scanning for previous RTL patches…"

  # (a) Was /Applications/Claude.app patched IN PLACE (ikhd, ChenWolfson, toboly, …)?
  local plist_hash real_hash
  plist_hash="$(/usr/libexec/PlistBuddy -c 'Print :ElectronAsarIntegrity:Resources/app.asar:hash' "$ORIG/Contents/Info.plist" 2>/dev/null || echo '')"
  real_hash="$(asar_header_hash "$ORIG/Contents/Resources/app.asar")"
  local markers
  markers="$(LC_ALL=C grep -a -o -E 'claude-rtl-styles|claude-rtl-payload-v1|claude-rtl-font|claude-rtl-engine' "$ORIG/Contents/Resources/app.asar" | sort -u | tr '\n' ' ')"
  if [ -n "$markers" ] || ! codesign --verify --strict "$ORIG" >/dev/null 2>&1; then
    problems=1
    warn "the ORIGINAL $ORIG is modified (markers: ${markers:-none}; signature $(codesign --verify --strict "$ORIG" >/dev/null 2>&1 && echo OK || echo BROKEN))."
    warn "an in-place patch from another project is installed. This kit needs a clean original:"
    warn "  download Claude from https://claude.com/download and drag it over /Applications/Claude.app, then re-run."
  elif [ -n "$plist_hash" ] && [ "$plist_hash" != "$real_hash" ]; then
    problems=1
    warn "the ORIGINAL's asar integrity hash does not match its Info.plist — it was modified in place. Reinstall Claude from https://claude.com/download and re-run."
  else
    log "  original $ORIG is clean."
  fi

  # (b) LaunchAgents from other RTL projects (ikhd: com.claudertl.autoupdate, etc.)
  local p label
  for p in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -e "$p" ] || continue
    label="$(basename "$p" .plist)"
    [ "$label" = "$WATCH_LABEL" ] && continue
    case "$label" in
      *claudertl*|*claude-rtl*|*claude_rtl*|*ClaudeRtl*|*rtl-watcher*|*rtlwatcher*)
        FOREIGN_AGENTS+=("$p") ;;
    esac
  done
  if [ "${#FOREIGN_AGENTS[@]}" -gt 0 ]; then
    for p in "${FOREIGN_AGENTS[@]}"; do log "  foreign RTL LaunchAgent found: $p"; done
  fi

  # (c) previous Claude-RTL.app (any project) — replaced by the build, just report
  if [ -d "$DEST" ]; then
    local old_markers
    old_markers="$(LC_ALL=C grep -a -o -E 'claude-rtl-styles|claude-rtl-payload-v1|claude-rtl-font' "$DEST/Contents/Resources/app.asar" 2>/dev/null | sort -u | tr '\n' ' ')"
    log "  existing $DEST v$(ver "$DEST") (markers: ${old_markers:-none}) — will be replaced."
  fi
  [ -d "/Applications/Claude RTL.app" ] && log "  note: the liorshaya GUI manager is in /Applications (left alone; this kit uses the CLI path)."
  [ -d "$INSTALL_DIR" ] && log "  existing source at $INSTALL_DIR — will be refreshed."

  return "$problems"
}

remove_foreign_agents() {
  local p label
  for p in "${FOREIGN_AGENTS[@]}"; do
    label="$(basename "$p" .plist)"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    mkdir -p "$HOME/Library/LaunchAgents/disabled-by-claude-rtl-kit"
    mv "$p" "$HOME/Library/LaunchAgents/disabled-by-claude-rtl-kit/"
    log "  disabled foreign agent $label (moved to LaunchAgents/disabled-by-claude-rtl-kit/)."
  done
}

# ------------------------------------------------------------------ 3. source ----
install_source() {
  mkdir -p "$INSTALL_DIR"
  rsync -a --delete --exclude node_modules --exclude dist "$SRC/" "$INSTALL_DIR/"
  cp "$KIT/VERSIONS.md" "$INSTALL_DIR/KIT-VERSIONS.md" 2>/dev/null || true
  log "source installed → $INSTALL_DIR (upstream v0.2.21 + Code-tab fix, see VERSIONS.md)"
  log "running the test suite…"
  ( cd "$INSTALL_DIR" && node --test engine/__tests__/*.test.js dom/__tests__/*.test.js build/__tests__/*.test.js >/tmp/claude-rtl-tests.log 2>&1 ) \
    || die "tests failed — see /tmp/claude-rtl-tests.log"
  grep -E '^ℹ (tests|pass|fail)' /tmp/claude-rtl-tests.log | tr '\n' ' '; echo
}

# ------------------------------------------------------------------- 4. build ----
build_app() {
  if running_dest; then
    warn "Claude-RTL is running (you are probably inside it). Building to $NEXT and swapping when it quits."
    rm -rf "$NEXT"
    ( cd "$INSTALL_DIR" && DEST_APP="$NEXT" bash desktop/patch.sh --install ) || die "build failed."
    # Detached waiter: survives this shell and the app that hosts it.
    python3 - "$KIT/mac/swap-when-quit.sh" <<'PY' || true
import os, sys, subprocess
os.setsid() if os.fork() == 0 else sys.exit(0)
log = open(os.path.expanduser('~/Library/Logs/claude-rtl-swap.log'), 'a')
subprocess.Popen(['/bin/bash', sys.argv[1]], stdout=log, stderr=log, stdin=subprocess.DEVNULL)
PY
    SWAP_PENDING=1
  else
    ( cd "$INSTALL_DIR" && bash desktop/patch.sh --install ) || die "build failed."
    SWAP_PENDING=0
  fi
}

# ----------------------------------------------------------------- 5. watcher ----
install_watcher() {
  ( cd "$INSTALL_DIR" && bash desktop/patch.sh --watch ) || die "watcher install failed."
  # launchd has a bare PATH; put the real node dir first so npx works after updates.
  /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:PATH $NODE_DIR:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$WATCH_PLIST"
  launchctl bootout "gui/$(id -u)/$WATCH_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$WATCH_PLIST"
  log "watcher active (PATH includes $NODE_DIR)."
}

# ------------------------------------------------------------------ 6. verify ----
verify() {
  local app="$1"
  [ -d "$app" ] || die "verify: $app missing."
  local v_orig v_app payload fix fuse
  v_orig="$(ver "$ORIG")"; v_app="$(ver "$app")"
  payload="$(LC_ALL=C grep -a -c 'claude-rtl-payload-v1' "$app/Contents/Resources/app.asar" || true)"
  fix="$(LC_ALL=C grep -a -c 'epitaxy-user-turn' "$app/Contents/Resources/app.asar" || true)"
  fuse="$(cd "$INSTALL_DIR" && npx --yes @electron/fuses read --app "$app" 2>/dev/null | grep -i 'AsarIntegrityValidation' | sed 's/^ *//')"
  codesign --verify --strict "$app" >/dev/null 2>&1 || die "verify: $app does not pass codesign --verify."
  [ "$v_orig" = "$v_app" ] || die "verify: version mismatch (original $v_orig, patched $v_app)."
  [ "${payload:-0}" -gt 0 ] || die "verify: payload not found in $app."
  [ "${fix:-0}" -gt 0 ] || die "verify: Code-tab fix not found in $app."
  log "verified $app — v$v_app, payload in $payload bundles, Code-tab fix present, signature OK, $fuse"
}

cmd_status() {
  echo "original : $ORIG v$(ver "$ORIG")  ($(codesign --verify --strict "$ORIG" >/dev/null 2>&1 && echo 'clean' || echo 'MODIFIED'))"
  if [ -d "$DEST" ]; then
    echo "patched  : $DEST v$(ver "$DEST")  (Code-tab fix: $(LC_ALL=C grep -a -q 'epitaxy-user-turn' "$DEST/Contents/Resources/app.asar" && echo yes || echo no); running: $(running_dest && echo yes || echo no))"
  else echo "patched  : not installed"; fi
  [ -d "$NEXT" ] && echo "pending  : $NEXT v$(ver "$NEXT") — swaps in when Claude-RTL quits (or: bash mac/swap-when-quit.sh --now)"
  if [ -f "$INSTALL_DIR/desktop/patch.sh" ]; then
    echo "source   : $INSTALL_DIR (Code-tab fix in source: $(grep -q 'epitaxy-user-turn' "$INSTALL_DIR/dom/surfaces.js" && echo yes || echo no))"
  else echo "source   : not installed"; fi
  echo "watcher  : $(launchctl print "gui/$(id -u)/$WATCH_LABEL" >/dev/null 2>&1 && echo "active — PATH=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$WATCH_PLIST" 2>/dev/null)" || echo 'not active')"
  echo "logs     : ~/Library/Logs/claude-rtl-watch.log, ~/Library/Logs/claude-rtl-swap.log"
}

cmd_uninstall() {
  [ -d "$INSTALL_DIR" ] && ( cd "$INSTALL_DIR" && bash desktop/patch.sh --unwatch; bash desktop/patch.sh --uninstall ) || true
  rm -rf "$NEXT"
  log "removed Claude-RTL.app and the watcher. Source kept at $INSTALL_DIR (delete it if you want). $ORIG untouched."
}

FOREIGN_AGENTS=()
case "$MODE" in
  --status) cmd_status ;;
  --uninstall) cmd_uninstall ;;
  --check)
    check_env; scan_prior || true ;;
  --install)
    check_env
    scan_prior || die "fix the warnings above (a clean original is required), then re-run."
    [ "${#FOREIGN_AGENTS[@]}" -gt 0 ] && remove_foreign_agents
    install_source
    build_app
    install_watcher
    if [ "${SWAP_PENDING:-0}" = "1" ]; then
      verify "$NEXT"
      echo
      log "NEXT STEP: quit Claude-RTL. Within a few seconds it is replaced by the new build (notification appears)."
      log "           If nothing happens, run:  bash \"$KIT/mac/swap-when-quit.sh\" --now"
    else
      verify "$DEST"
      echo
      log "DONE. Quit /Applications/Claude.app if it is open, then open ~/Applications/Claude-RTL.app."
    fi
    log "First launch may show a blank window once (quit & reopen) and one Keychain prompt (Always Allow)."
    ;;
  *) die "unknown flag $MODE (use --install | --status | --check | --uninstall)" ;;
esac
