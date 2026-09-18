#!/usr/bin/env bash
# linux/watch.sh — re-patch after a Claude Desktop update. Run by the user systemd unit
# claude-rtl-watch.service, which claude-rtl-watch.path triggers whenever apt/dpkg replaces
# /usr/lib/claude-desktop/{version,claude-desktop,resources/app.asar}. Waits until dpkg is
# done and the files are stable, then rebuilds the RTL copy. NOT set -e: a transient failure
# must not matter — the next update event retries. Linux port of desktop/watch.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_DIR="${ORIG_DIR:-/usr/lib/claude-desktop}"
DEST_DIR="${DEST_DIR:-$HOME/.local/lib/claude-rtl}"
NEXT_DIR="${NEXT_DIR:-$DEST_DIR-next}"
STAMP="$DEST_DIR/claude-rtl.stamp"
LOG_DIR="${CLAUDE_RTL_LOG_DIR:-$HOME/.local/state/claude-rtl}"
SETTLE_SLEEP="${WATCH_SETTLE_SLEEP:-2}"
SETTLE_STABLE="${WATCH_SETTLE_STABLE:-3}"
SETTLE_GRACE="${WATCH_SETTLE_GRACE:-5}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] watch: $*"; }
notify() { command -v notify-send >/dev/null && notify-send -a Claude-RTL "Claude-RTL" "$1" >/dev/null 2>&1 || true; }
pkg_version() { dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || echo '?'; }
stamp_get() { sed -n "s/^$1=//p" "$STAMP" 2>/dev/null | head -n1; }
running_at() { ps -axo command | grep -F "$1/claude-desktop" | grep -v grep >/dev/null 2>&1; }

[ -d "$DEST_DIR" ] || { log "no patched copy at $DEST_DIR — nothing to do."; exit 0; }
[ -f "$ORIG_DIR/resources/app.asar" ] || { log "original missing or mid-update — nothing to do."; exit 0; }

# Two independent stamps: the dpkg version and the sha256 of the original app.asar the copy
# was built from. Either changing means the package was replaced (apt upgrade, dpkg -i, or a
# reinstall of the same version).
OLD_VER="$(stamp_get pkg_version)"; OLD_SHA="$(stamp_get orig_asar_sha256)"
NEW_VER="$(pkg_version)"
fingerprint() { stat -c '%i:%s:%Y' "$ORIG_DIR/resources/app.asar" "$ORIG_DIR/claude-desktop" "$ORIG_DIR/version" 2>/dev/null | tr '\n' ' '; }

settle() {
  local stable=0 last="" now tries=0
  while [ "$tries" -lt 150 ]; do
    tries=$((tries + 1))
    if ps -axo comm= | grep -q -E '^(dpkg|apt|apt-get|aptd)$'; then
      stable=0; last=""; sleep "$SETTLE_SLEEP"; continue
    fi
    now="$(fingerprint)"
    if [ -n "$now" ] && [ "$now" = "$last" ]; then
      stable=$((stable + 1)); [ "$stable" -ge "$SETTLE_STABLE" ] && return 0
    else stable=0; fi
    last="$now"; sleep "$SETTLE_SLEEP"
  done
  return 1
}

if ! settle; then log "package files did not settle in time — will retry on the next event."; exit 0; fi
sleep "$SETTLE_GRACE"

NEW_VER="$(pkg_version)"
NEW_SHA="$(sha256sum "$ORIG_DIR/resources/app.asar" | cut -d' ' -f1)"
if [ "$NEW_VER" = "$OLD_VER" ] && [ "$NEW_SHA" = "$OLD_SHA" ]; then
  log "no change (claude-desktop $NEW_VER, same app.asar) — nothing to do."
  exit 0
fi
log "update detected: claude-desktop $OLD_VER → $NEW_VER. re-patching…"

mkdir -p "$LOG_DIR"
if running_at "$DEST_DIR"; then
  log "Claude-RTL is running — building $NEXT_DIR, it swaps in when Claude-RTL quits."
  rm -rf "$NEXT_DIR"
  if DEST_DIR="$NEXT_DIR" bash "$SCRIPT_DIR/patch.sh" --install 2>&1; then
    setsid nohup bash "$SCRIPT_DIR/swap-when-quit.sh" >>"$LOG_DIR/swap.log" 2>&1 </dev/null &
    notify "Claude updated to $NEW_VER — RTL rebuilt. Quit Claude-RTL and reopen it to switch."
  else
    log "re-patch FAILED — previous RTL copy kept; will retry on the next event."
    notify "Claude updated but the RTL re-patch failed — the previous RTL copy is still usable."
  fi
else
  if bash "$SCRIPT_DIR/patch.sh" --install 2>&1; then
    log "re-patched to claude-desktop $NEW_VER."
    notify "Claude updated to $NEW_VER — RTL re-applied."
  else
    log "re-patch FAILED — previous RTL copy kept; will retry on the next event."
    notify "Claude updated but the RTL re-patch failed — the previous RTL copy is still usable."
  fi
fi
