#!/usr/bin/env bash
# linux/swap-when-quit.sh — waits until ~/.local/lib/claude-rtl is no longer running, then
# replaces it with the freshly built ~/.local/lib/claude-rtl-next. Needed when the patch was
# built from INSIDE Claude-RTL (a running copy must not be replaced). install.sh / watch.sh
# start it detached; with --now it swaps immediately if the app is not running.
set -uo pipefail
DEST="${DEST_DIR:-$HOME/.local/lib/claude-rtl}"
NEXT="${NEXT_DIR:-$DEST-next}"
log() { echo "[$(date '+%F %T')] swap: $*"; }
notify() { command -v notify-send >/dev/null && notify-send -a Claude-RTL "Claude-RTL" "$1" >/dev/null 2>&1 || true; }
running() { ps -axo command | grep -F "$DEST/claude-desktop" | grep -v grep >/dev/null 2>&1; }

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
if mv "$NEXT" "$DEST" && [ -x "$DEST/claude-desktop" ] && LC_ALL=C grep -a -q 'claude-rtl-payload-v1' "$DEST/resources/app.asar"; then
  rm -rf "$DEST.previous"
  log "done → $DEST ($(sed -n 's/^pkg_version=//p' "$DEST/claude-rtl.stamp" 2>/dev/null))"
  notify "Claude-RTL updated. You can open it now."
else
  log "swap failed — restoring the previous copy."
  rm -rf "$DEST"; [ -d "$DEST.previous" ] && mv "$DEST.previous" "$DEST"
  notify "Claude-RTL swap failed — previous copy restored."
  exit 1
fi
