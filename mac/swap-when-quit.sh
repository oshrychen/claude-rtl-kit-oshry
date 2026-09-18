#!/usr/bin/env bash
# swap-when-quit.sh — waits until ~/Applications/Claude-RTL.app is no longer running, then
# replaces it with the freshly built ~/Applications/Claude-RTL-next.app.
#
# Needed when the patch was built from INSIDE Claude-RTL (a running bundle cannot be
# replaced). Run it detached (install.sh does that), or run it by hand after quitting
# Claude-RTL — with --now it swaps immediately if the app is not running.
set -uo pipefail
DEST="${DEST_APP:-$HOME/Applications/Claude-RTL.app}"
NEXT="${NEXT_APP:-$HOME/Applications/Claude-RTL-next.app}"
log() { echo "[$(date '+%F %T')] swap: $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Claude-RTL\"" >/dev/null 2>&1 || true; }
# ps, not pgrep: pgrep may not see the host app's main process from a sandboxed session.
running() { ps -axo command | grep -F "$DEST/Contents/" | grep -v grep >/dev/null 2>&1; }

[ -d "$NEXT" ] || { log "nothing to swap ($NEXT missing)"; exit 0; }

if [ "${1:-}" = "--now" ]; then
  running && { log "Claude-RTL is still running — quit it first."; exit 1; }
else
  log "waiting for $DEST to quit…"
  i=0
  while running; do
    sleep 2; i=$((i + 1))
    [ "$i" -ge 21600 ] && { log "gave up after 12h — run: bash $0 --now"; exit 0; }
  done
  sleep 2
  log "quit detected — swapping."
fi

rm -rf "$DEST.previous"
[ -d "$DEST" ] && mv "$DEST" "$DEST.previous"
if mv "$NEXT" "$DEST" && codesign --verify --strict "$DEST" >/dev/null 2>&1; then
  rm -rf "$DEST.previous"
  log "done → $DEST (v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null))"
  notify "Claude-RTL updated. You can open it now."
else
  log "swap failed — restoring the previous copy."
  rm -rf "$DEST"; [ -d "$DEST.previous" ] && mv "$DEST.previous" "$DEST"
  notify "Claude-RTL swap failed — previous copy restored."
  exit 1
fi
