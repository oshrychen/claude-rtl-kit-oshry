#!/usr/bin/env bash
# linux/patch.sh — build ~/.local/lib/claude-rtl from a COPY of /usr/lib/claude-desktop,
# inject the RTL payload into every renderer/preload bundle + the force-ui-direction switch
# into the main entry, and swap the result into place atomically. NEVER touches the apt
# package's files (no root needed). Linux port of source/claude-desktop-rtl/desktop/patch.sh.
#
#   linux/patch.sh [--install] | --uninstall | --status | --fuses
#
# Env overrides: ORIG_DIR, DEST_DIR, CLAUDE_RTL_ENGINE (patch source tree),
#                CLAUDE_RTL_TOOLS (npm dir with @electron/asar), CLAUDE_RTL_PAYLOAD,
#                CLAUDE_RTL_FLIP_FUSE=1 (see "fuse" below — off by default).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORIG_DIR="${ORIG_DIR:-/usr/lib/claude-desktop}"
DEST_DIR="${DEST_DIR:-$HOME/.local/lib/claude-rtl}"
# The patch engine (engine/ + dom/ + build/): the installed copy next to this script, or
# the vendored tree in the kit when run from the repo.
if [ -n "${CLAUDE_RTL_ENGINE:-}" ]; then ENGINE="$CLAUDE_RTL_ENGINE"
elif [ -d "$SCRIPT_DIR/../engine/build" ]; then ENGINE="$(cd "$SCRIPT_DIR/../engine" && pwd)"
else ENGINE="$(cd "$SCRIPT_DIR/../source/claude-desktop-rtl" && pwd)"; fi
TOOLS="${CLAUDE_RTL_TOOLS:-$HOME/.local/share/claude-rtl/tools}"
PAYLOAD="${CLAUDE_RTL_PAYLOAD:-$ENGINE/dist/payload.js}"

MARKER="claude-rtl-payload-v1"        # build-payload.js stamps this into the IIFE
# Wayland app_id / X11 WM_CLASS for the copy. Chromium derives it from package.json
# "desktopName" (the app calls app.setDesktopName() itself at startup, which is why a
# CHROME_DESKTOP in the environment is ignored and the --class switch is rejected outright
# by the app's own argument parser — both verified on claude-desktop 2.110.1). Left at the
# original's value, BOTH desktop entries claim StartupWMClass=com.anthropic.Claude, GNOME
# cannot tell which entry a window belongs to, and the dock shows no "running" dot. The
# copy therefore gets its own id; install.sh names its .desktop file to match.
RTL_DESKTOP_NAME="${CLAUDE_RTL_DESKTOP_NAME:-com.anthropic.ClaudeRTL.desktop}"
UIDIR_MARKER="claude-rtl-uidir"       # marks the main-entry switch (idempotency)
STAMP_NAME="claude-rtl.stamp"         # written into DEST_DIR; read by watch.sh / install.sh
UNPACK_GLOB_FALLBACK="**/*.node,**/github-mcp-server"
UNPACK_GLOB=""

# Built at STAGE, swapped into DEST_DIR only when complete and verified. BACKUP holds the
# previous copy for the instant between the two renames so a late failure can roll back.
PARENT="$(dirname "$DEST_DIR")"
NAME="$(basename "$DEST_DIR")"
STAGE="$PARENT/.$NAME.staging"
BACKUP="$PARENT/.$NAME.previous"

WORK=""
die() { echo "patch: ERROR — $*" >&2; exit 1; }
log() { echo "patch: $*"; }
cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  rm -rf "$STAGE"
  if [ -d "$BACKUP" ]; then
    if [ -d "$DEST_DIR" ]; then rm -rf "$BACKUP"; else mv "$BACKUP" "$DEST_DIR"; fi
  fi
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers ----
pkg_version() { dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || echo '?'; }
stamp_get()   { sed -n "s/^$2=//p" "$1/$STAMP_NAME" 2>/dev/null | head -n1; }
asar_sha()    { sha256sum "$1" | cut -d' ' -f1; }

# ps, not pgrep: from a sandboxed Claude Code session pgrep cannot see the host app's own
# main process, and missing it would let us replace a running copy.
running_at() { ps -axo command | grep -F "$1/claude-desktop" | grep -v grep >/dev/null 2>&1; }

ASAR_BIN=""
ensure_tools() {
  if [ -x "$TOOLS/node_modules/.bin/asar" ]; then ASAR_BIN="$TOOLS/node_modules/.bin/asar"; return 0; fi
  log "installing @electron/asar + @electron/fuses into $TOOLS…"
  mkdir -p "$TOOLS"
  ( cd "$TOOLS" && npm install --no-audit --no-fund --silent --no-package-lock @electron/asar@^4 @electron/fuses@^2 >/dev/null 2>&1 ) \
    || die "npm install of @electron/asar failed (network?)."
  [ -x "$TOOLS/node_modules/.bin/asar" ] || die "asar CLI missing after npm install."
  ASAR_BIN="$TOOLS/node_modules/.bin/asar"
}
asar_extract() { "$ASAR_BIN" extract "$1" "$2"; }
asar_pack()    { "$ASAR_BIN" pack "$1" "$2" --unpack "$UNPACK_GLOB"; }
fuses_read()   { "$TOOLS/node_modules/.bin/electron-fuses" read --app "$1" 2>/dev/null; }

# Build the asar --unpack glob from what the ORIGINAL keeps unpacked (native .node addons,
# github-mcp-server, …), so a binary added by a future Claude version can't end up inside
# the archive where it could never be exec'd.
build_unpack_glob() {
  local dir="$1" pats="" f base pat
  if [ ! -d "$dir" ]; then
    UNPACK_GLOB="{$UNPACK_GLOB_FALLBACK}"; log "WARNING: $dir missing — using the built-in unpack glob."; return 0
  fi
  while IFS= read -r f; do
    base="${f##*/}"
    case "$base" in *[,{}]*) die "unpacked binary '$base' contains , { or } — cannot build an unpack glob." ;; esac
    case "$base" in *.*) pat="**/*.${base##*.}" ;; *) pat="**/$base" ;; esac
    case ",$pats," in *",$pat,"*) ;; *) pats="${pats:+$pats,}$pat" ;; esac
  done < <(find "$dir" -type f)
  [ -n "$pats" ] || pats="$UNPACK_GLOB_FALLBACK"
  UNPACK_GLOB="{$pats}"
}

# Number of entries an asar header marks "unpacked" (header: 4 LE uint32, the 4th at
# offset 12 is the JSON length, JSON starts at 16).
asar_unpacked_count() {
  local a="$1" jlen
  [ -s "$a" ] || { echo -1; return 0; }
  jlen="$(od -An -tu4 -j12 -N4 "$a" 2>/dev/null | tr -d ' ' || true)"
  case "$jlen" in ''|*[!0-9]*) echo -1; return 0 ;; esac
  head -c "$((16 + jlen))" "$a" | tail -c "$jlen" | grep -o '"unpacked":true' | wc -l | tr -d ' ' || true
}
count_occurrences() { LC_ALL=C grep -o -a -F "$1" "$2" | wc -l | tr -d ' ' || true; }

# ------------------------------------------------------------------ status ----
cmd_status() {
  if [ -d "$ORIG_DIR" ]; then echo "original : $ORIG_DIR (claude-desktop $(pkg_version)) — untouched"; else echo "original : MISSING ($ORIG_DIR)"; fi
  if [ -d "$DEST_DIR" ]; then
    echo "patched  : $DEST_DIR (built from claude-desktop $(stamp_get "$DEST_DIR" pkg_version), $(stamp_get "$DEST_DIR" patched_at)) — running: $(running_at "$DEST_DIR" && echo yes || echo no)"
  else echo "patched  : not installed"; fi
}

cmd_fuses() {
  ensure_tools
  echo "original: "; fuses_read "$ORIG_DIR/claude-desktop" | sed 's/^/  /'
  if [ -x "$DEST_DIR/claude-desktop" ]; then echo "patched:"; fuses_read "$DEST_DIR/claude-desktop" | sed 's/^/  /'; fi
}

cmd_uninstall() {
  running_at "$DEST_DIR" && die "$DEST_DIR is running — quit Claude-RTL first."
  rm -rf "$STAGE" "$BACKUP"
  if [ -d "$DEST_DIR" ]; then rm -rf "$DEST_DIR"; log "removed $DEST_DIR (original untouched)."; else log "nothing to remove ($DEST_DIR)."; fi
}

# ----------------------------------------------------------------- install ----
cmd_install() {
  [ "$(uname -s)" = "Linux" ] || die "Linux only (this is $(uname -s))."
  [ -x "$ORIG_DIR/claude-desktop" ] || die "Claude Desktop binary not found at $ORIG_DIR/claude-desktop."
  [ -f "$ORIG_DIR/resources/app.asar" ] || die "no app.asar under $ORIG_DIR/resources — unexpected layout."
  command -v node >/dev/null || die "node not found on PATH."
  [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 18 ] || die "Node >= 18 required, have $(node -v)."
  command -v npm >/dev/null || die "npm not found on PATH."
  mkdir -p "$PARENT" || die "cannot create $PARENT."
  ( : > "$PARENT/.claude-rtl-write-probe.$$" ) 2>/dev/null || die "$PARENT is not writable."
  rm -f "$PARENT/.claude-rtl-write-probe.$$"
  [ -f "$ENGINE/build/build-payload.js" ] || die "patch engine not found at $ENGINE."

  ensure_tools

  if [ -n "${CLAUDE_RTL_PAYLOAD:-}" ]; then
    log "using provided payload ($PAYLOAD)…"
  else
    log "building payload…"
    ( cd "$ENGINE" && node build/build-payload.js >/dev/null )
  fi
  [ -f "$PAYLOAD" ] || die "payload not found at $PAYLOAD."
  grep -q "$MARKER" "$PAYLOAD" || die "payload missing marker $MARKER — build looks wrong."

  local ORIG_ASAR="$ORIG_DIR/resources/app.asar" ORIG_UNPACKED="$ORIG_DIR/resources/app.asar.unpacked"
  local ORIG_SHA; ORIG_SHA="$(asar_sha "$ORIG_ASAR")"

  log "copying $ORIG_DIR → staging (the package's files are never modified)…"
  rm -rf "$STAGE"
  cp -a "$ORIG_DIR" "$STAGE"
  # The SUID sandbox helper: a copy loses root ownership + setuid and Chromium then refuses
  # to start ("SUID sandbox helper … not configured correctly"), because our copy does not
  # have the package's AppArmor userns allowance (that profile is bound to the original
  # binary path). A symlink to the package's root-owned 4755 helper keeps the sandbox.
  rm -f "$STAGE/chrome-sandbox"
  ln -s "$ORIG_DIR/chrome-sandbox" "$STAGE/chrome-sandbox"

  local ASAR="$STAGE/resources/app.asar"
  WORK="$(mktemp -d)"
  build_unpack_glob "$ORIG_UNPACKED"
  log "unpack glob (derived from the original): $UNPACK_GLOB"

  log "extracting app.asar…"
  asar_extract "$ASAR" "$WORK/app"

  local VITE="$WORK/app/.vite/build"
  [ -d "$VITE" ] || die "expected .vite/build missing — Claude's layout changed; aborting."
  local MAIN_REL MAIN
  MAIN_REL="$(node -p 'require(process.argv[1]).main || ""' "$WORK/app/package.json" 2>/dev/null || true)"
  [ -n "$MAIN_REL" ] || die "cannot read \"main\" from package.json."
  MAIN="$WORK/app/$MAIN_REL"
  [ -f "$MAIN" ] || die "main entry $MAIN_REL missing — aborting."
  local APP_VER; APP_VER="$(node -p 'require(process.argv[1]).version || "?"' "$WORK/app/package.json" 2>/dev/null || echo '?')"

  # --- Own identity for the copy (see RTL_DESKTOP_NAME above) ---
  local from_name
  from_name="$(node - "$WORK/app/package.json" "$RTL_DESKTOP_NAME" <<'JS'
const fs = require('fs');
const [p, name] = process.argv.slice(2);
const re = /("desktopName"\s*:\s*")([^"]*)(")/;
const s = fs.readFileSync(p, 'utf8');
const m = s.match(re);
if (!m) process.exit(1);
if (m[2] !== name) fs.writeFileSync(p, s.replace(re, `$1${name}$3`));
process.stdout.write(m[2]);
JS
  )" || die "no \"desktopName\" in package.json — Claude's layout changed; aborting (the copy would share the original's app_id)."
  log "app_id: $from_name → $RTL_DESKTOP_NAME (so the dock can tell the copy from the original)."

  # --- Inject: payload into every bundle EXCEPT the main entry ---
  local injected=0 skipped=0 f
  for f in "$VITE"/*.js; do
    [ -e "$f" ] || continue
    if [ "$f" -ef "$MAIN" ]; then continue; fi
    if grep -q "$MARKER" "$f"; then skipped=$((skipped+1)); continue; fi
    cat "$PAYLOAD" "$f" > "$f.rtltmp" && mv "$f.rtltmp" "$f"
    injected=$((injected+1))
  done
  log "payload → $injected bundle(s) ($skipped already patched)."

  # --- Main entry: ONLY the window-chrome switch, never the full payload (→ black screen) ---
  if grep -q "$UIDIR_MARKER" "$MAIN"; then
    log "main entry already carries the ui-direction switch."
  else
    printf '%s\n' "/* $UIDIR_MARKER */ try { require('electron').app.commandLine.appendSwitch('force-ui-direction','ltr'); } catch (e) {}" \
      | cat - "$MAIN" > "$MAIN.rtltmp" && mv "$MAIN.rtltmp" "$MAIN"
    log "force-ui-direction=ltr → main entry ($MAIN_REL)."
  fi

  log "repacking app.asar…"
  rm -f "$ASAR"
  asar_pack "$WORK/app" "$ASAR"

  # --- Safety nets (same four as the macOS script) ---
  [ -s "$ASAR" ] || die "repack produced no app.asar — aborting."
  local per want_markers got_markers
  per="$(count_occurrences "$MARKER" "$PAYLOAD")"
  want_markers=$(( (injected + skipped) * per ))
  got_markers="$(count_occurrences "$MARKER" "$ASAR")"
  [ "${got_markers:-0}" -ge "$want_markers" ] \
    || die "repacked app.asar carries $got_markers payload marker(s), expected $want_markers — repack is incomplete."
  if [ -d "$ORIG_UNPACKED" ]; then
    local missing
    missing="$(cd "$ORIG_UNPACKED" && find . -type f | while read -r rel; do
      [ -e "$STAGE/resources/app.asar.unpacked/$rel" ] || echo "$rel"; done)"
    [ -z "$missing" ] || die "repack dropped unpacked binaries: $missing"
  fi
  local want_unpacked got_unpacked
  want_unpacked="$(asar_unpacked_count "$ORIG_ASAR")"
  got_unpacked="$(asar_unpacked_count "$ASAR")"
  if [ "$want_unpacked" -ge 0 ] && [ "$got_unpacked" != "$want_unpacked" ]; then
    die "repack marks $got_unpacked file(s) unpacked but the original marks $want_unpacked — a native binary was packed INSIDE the asar. Unpack glob was: $UNPACK_GLOB"
  fi
  LC_ALL=C grep -a -q -F "\"desktopName\": \"$RTL_DESKTOP_NAME\"" "$ASAR" \
    || die "repacked app.asar does not carry desktopName=$RTL_DESKTOP_NAME — the copy would share the original's app_id."
  log "repack verified ($got_markers payload marker(s), $got_unpacked unpacked binaries, app_id ${RTL_DESKTOP_NAME%.desktop})."

  # --- Fuse: EnableEmbeddedAsarIntegrityValidation is ON in the Linux build, but Electron
  # only implements the check on macOS (Info.plist hash) and Windows (resource); on Linux
  # there is no stored hash and the modified asar loads as-is (verified on 2.110.1 /
  # Electron 44). So the 228MB binary is left byte-identical. CLAUDE_RTL_FLIP_FUSE=1 flips
  # it anyway, should a future Electron start enforcing it on Linux. ---
  if [ "${CLAUDE_RTL_FLIP_FUSE:-0}" = "1" ]; then
    log "flipping EnableEmbeddedAsarIntegrityValidation=off (CLAUDE_RTL_FLIP_FUSE=1)…"
    "$TOOLS/node_modules/.bin/electron-fuses" write --app "$STAGE/claude-desktop" EnableEmbeddedAsarIntegrityValidation=off >/dev/null \
      || die "fuses write failed."
  else
    log "asar-integrity fuse left as shipped (not enforced by Electron on Linux)."
  fi

  cat > "$STAGE/$STAMP_NAME" <<STAMP
pkg_version=$(pkg_version)
app_version=$APP_VER
orig_asar_sha256=$ORIG_SHA
payload_markers=$got_markers
desktop_name=$RTL_DESKTOP_NAME
patched_at=$(date '+%Y-%m-%d %H:%M:%S')
STAMP

  # --- Atomic install: only now does the live copy get replaced ---
  running_at "$DEST_DIR" && die "$DEST_DIR is running — cannot replace it (install.sh builds a -next copy instead)."
  rm -rf "$BACKUP"
  [ -d "$DEST_DIR" ] && mv "$DEST_DIR" "$BACKUP"
  mv "$STAGE" "$DEST_DIR"
  if [ ! -x "$DEST_DIR/claude-desktop" ] || [ "$(count_occurrences "$MARKER" "$DEST_DIR/resources/app.asar")" -lt "$want_markers" ]; then
    rm -rf "$DEST_DIR"; [ -d "$BACKUP" ] && mv "$BACKUP" "$DEST_DIR"
    die "the installed copy failed verification — rolled back to the previous copy."
  fi
  rm -rf "$BACKUP"
  log "DONE → $DEST_DIR (claude-desktop $(pkg_version), app $APP_VER)"
}

case "${1:---install}" in
  --install)   cmd_install ;;
  --uninstall) cmd_uninstall ;;
  --status)    cmd_status ;;
  --fuses)     cmd_fuses ;;
  -h|--help)   echo "usage: $0 [--install] | --uninstall | --status | --fuses" ;;
  *)           die "unknown flag '$1' (use --install | --uninstall | --status | --fuses)" ;;
esac
