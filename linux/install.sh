#!/usr/bin/env bash
# Claude-RTL Kit — Linux installer (idempotent). Ubuntu/Debian, official claude-desktop apt package.
#
#   bash linux/install.sh              # full install (or re-install / upgrade)
#   bash linux/install.sh --status     # what is installed
#   bash linux/install.sh --check      # only the environment + prior-patch scan, no changes
#   bash linux/install.sh --smoke-test # launch the patched copy for 20s with a throwaway profile
#   bash linux/install.sh --uninstall
#
# What it does (mirrors mac/install.sh):
#   1. checks Linux, the claude-desktop package, Node >= 18 + npm, systemd --user
#   2. scans for PREVIOUS RTL patches (in-place patches of the package, foreign units/hooks)
#   3. copies the vendored patch engine (liorshaya/claude-desktop-rtl v0.2.21 + Code-tab fix)
#      and these Linux scripts to ~/.local/share/claude-rtl and runs the test suite
#   4. builds ~/.local/lib/claude-rtl from a COPY of /usr/lib/claude-desktop (the package is
#      never modified, no root needed); if Claude-RTL is running, builds claude-rtl-next and
#      swaps it in the moment Claude-RTL quits
#   5. installs a launcher (~/.local/bin/claude-rtl + app-menu entry "Claude-RTL") and a user
#      systemd path unit that re-patches after every apt upgrade of claude-desktop
#   6. verifies the result
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$KIT/source/claude-desktop-rtl"
ORIG="/usr/lib/claude-desktop"
INSTALL_DIR="$HOME/.local/share/claude-rtl"       # engine/ linux/ tools/
ENGINE="$INSTALL_DIR/engine"
LINUX="$INSTALL_DIR/linux"
TOOLS="$INSTALL_DIR/tools"
DEST="$HOME/.local/lib/claude-rtl"
NEXT="$DEST-next"
BIN="$HOME/.local/bin/claude-rtl"
# Must match the app_id patch.sh gives the copy (package.json "desktopName"); both default
# to the same value and honour the same override, so they cannot drift.
RTL_DESKTOP_NAME="${CLAUDE_RTL_DESKTOP_NAME:-com.anthropic.ClaudeRTL.desktop}"
WMCLASS="${RTL_DESKTOP_NAME%.desktop}"
DESKTOP="$HOME/.local/share/applications/$RTL_DESKTOP_NAME"
LEGACY_DESKTOP="$HOME/.local/share/applications/claude-rtl.desktop"
UNIT_DIR="$HOME/.config/systemd/user"
LOG_DIR="$HOME/.local/state/claude-rtl"
MODE="${1:---install}"

log()  { printf 'kit: %s\n' "$*"; }
warn() { printf 'kit: WARNING — %s\n' "$*" >&2; }
die()  { printf 'kit: ERROR — %s\n' "$*" >&2; exit 1; }
pkg_version() { dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || echo '?'; }
stamp_get()   { sed -n "s/^$2=//p" "$1/claude-rtl.stamp" 2>/dev/null | head -n1; }
# ps, not pgrep: from a sandboxed Claude Code session pgrep cannot see the host app's own
# main process, and missing it would let us replace a running copy.
running_at()  { ps -axo command | grep -F "$1/claude-desktop" | grep -v grep >/dev/null 2>&1; }
markers_in()  { LC_ALL=C grep -a -o -E 'claude-rtl-styles|claude-rtl-payload-v1|claude-rtl-font|claude-rtl-engine|claude-rtl-uidir' "$1" 2>/dev/null | sort -u | tr '\n' ' '; }
asar_unpacked_count() {
  local a="$1" jlen; [ -s "$a" ] || { echo -1; return 0; }
  jlen="$(od -An -tu4 -j12 -N4 "$a" 2>/dev/null | tr -d ' ' || true)"
  case "$jlen" in ''|*[!0-9]*) echo -1; return 0 ;; esac
  head -c "$((16 + jlen))" "$a" | tail -c "$jlen" | grep -o '"unpacked":true' | wc -l | tr -d ' ' || true
}
have_systemd_user() { command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. environment ----
check_env() {
  [ "$(uname -s)" = "Linux" ] || die "Linux only (this is $(uname -s))."
  [ -x "$ORIG/claude-desktop" ] || die "Claude Desktop is not installed at $ORIG — install the official package first (https://claude.com/download)."
  [ -f "$ORIG/resources/app.asar" ] || die "unexpected layout: no app.asar in $ORIG/resources."
  command -v dpkg-query >/dev/null || warn "dpkg not found — version stamps will read '?'."
  if ! command -v node >/dev/null; then
    die "Node.js not found. Install it (e.g. https://nodejs.org or nvm), then re-run."
  fi
  local major; major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$major" -ge 18 ] || die "Node >= 18 required, have $(node -v)."
  command -v npm >/dev/null || die "npm missing (comes with Node)."
  NODE_DIR="$(dirname "$(command -v node)")"
  if have_systemd_user; then SYSTEMD_OK=1; else SYSTEMD_OK=0; warn "systemd --user not available — the auto-repatch watcher will be skipped."; fi
  command -v notify-send >/dev/null || log "  (notify-send missing — the watcher will just log, no desktop notifications)"
  local distro; distro="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -r)"
  log "env OK — $distro, claude-desktop $(pkg_version), node $(node -v) at $NODE_DIR"
  [ -d "$SRC/build" ] || die "vendored source missing at $SRC."
  grep -q 'epitaxy-user-turn' "$SRC/dom/surfaces.js" || die "vendored source lacks the Code-tab fix (patches/0001-code-tab-surface.patch)."
  local sb; sb="$(stat -c '%U:%a' "$ORIG/chrome-sandbox" 2>/dev/null || echo '?')"
  [ "$sb" = "root:4755" ] || warn "$ORIG/chrome-sandbox is $sb (expected root:4755) — the copy's sandbox may fail to start."
}

# ------------------------------------------------------- 2. previous patches scan ----
scan_prior() {
  local problems=0
  log "scanning for previous RTL patches…"

  # (a) Was the PACKAGE patched in place (any project)? markers + dpkg md5 verification.
  local markers verify
  markers="$(markers_in "$ORIG/resources/app.asar")"
  verify="$(dpkg --verify claude-desktop 2>/dev/null | grep -E 'resources/app.asar|claude-desktop/claude-desktop$' || true)"
  if [ -n "$markers" ]; then
    problems=1
    warn "the ORIGINAL $ORIG/resources/app.asar carries RTL markers (${markers}) — it was patched in place."
    warn "this kit needs a clean package:  sudo apt reinstall claude-desktop   then re-run."
  elif [ -n "$verify" ]; then
    problems=1
    warn "dpkg --verify reports the package's app.asar/binary differ from what apt installed:"
    printf '%s\n' "$verify" | sed 's/^/kit:   /' >&2
    warn "reinstall a clean package:  sudo apt reinstall claude-desktop   then re-run."
  else
    log "  original $ORIG is clean (dpkg --verify OK, no RTL markers)."
  fi
  local maint; maint="$(dpkg-query -W -f='${Maintainer}' claude-desktop 2>/dev/null || echo '')"
  case "$maint" in *Anthropic*) ;; '') log "  note: claude-desktop is not a dpkg package here (manual install?) — proceeding on layout alone." ;;
    *) warn "claude-desktop package maintainer is '$maint', not Anthropic (community build, e.g. aaddrick/claude-desktop-debian?) — layout may differ; proceeding since $ORIG looks right." ;; esac

  # (b) foreign systemd user units / apt hooks from other RTL projects
  local p
  for p in "$UNIT_DIR"/*.service "$UNIT_DIR"/*.path "$UNIT_DIR"/*.timer; do
    [ -e "$p" ] || continue
    case "$(basename "$p")" in claude-rtl-watch.*) continue ;; *claude*rtl*|*rtl*claude*|*claudertl*) FOREIGN_UNITS+=("$p") ;; esac
  done
  for p in "${FOREIGN_UNITS[@]}"; do log "  foreign RTL systemd unit found: $p"; done
  for p in /etc/apt/apt.conf.d/*; do
    [ -e "$p" ] || continue
    if grep -q -i -E 'rtl' "$p" 2>/dev/null; then log "  note: apt hook mentioning RTL: $p (root-owned, left alone — review it yourself)"; fi
  done

  # (c) previous copy (ours or another project's) — replaced by the build, just report
  if [ -d "$DEST" ]; then
    log "  existing $DEST (claude-desktop $(stamp_get "$DEST" pkg_version), markers: $(markers_in "$DEST/resources/app.asar")) — will be replaced."
  fi
  [ -d "$INSTALL_DIR/engine" ] && log "  existing source at $INSTALL_DIR — will be refreshed."

  # (d) other Claude installs (flatpak / snap / AppImage) — not touched, just reported
  command -v flatpak >/dev/null && flatpak list 2>/dev/null | grep -i -q claude && log "  note: a flatpak Claude exists — not covered by this kit."
  command -v snap >/dev/null && snap list 2>/dev/null | grep -i -q claude && log "  note: a snap Claude exists — not covered by this kit."
  ls "$HOME"/Applications/*laude*.AppImage "$HOME"/.local/bin/*laude*.AppImage >/dev/null 2>&1 && log "  note: a Claude AppImage exists — not covered by this kit."
  return "$problems"
}

remove_foreign_units() {
  local p name
  mkdir -p "$UNIT_DIR/disabled-by-claude-rtl-kit"
  for p in "${FOREIGN_UNITS[@]}"; do
    name="$(basename "$p")"
    systemctl --user disable --now "$name" >/dev/null 2>&1 || true
    mv "$p" "$UNIT_DIR/disabled-by-claude-rtl-kit/"
    log "  disabled foreign unit $name (moved to $UNIT_DIR/disabled-by-claude-rtl-kit/)."
  done
  systemctl --user daemon-reload 2>/dev/null || true
}

# ------------------------------------------------------------------ 3. source ----
install_source() {
  mkdir -p "$ENGINE" "$LINUX" "$LOG_DIR"
  if command -v rsync >/dev/null; then
    rsync -a --delete --exclude node_modules --exclude dist "$SRC/" "$ENGINE/"
  else
    rm -rf "$ENGINE"; mkdir -p "$ENGINE"; cp -a "$SRC/." "$ENGINE/"; rm -rf "$ENGINE/node_modules" "$ENGINE/dist"
  fi
  cp "$KIT/linux/patch.sh" "$KIT/linux/watch.sh" "$KIT/linux/swap-when-quit.sh" "$LINUX/"
  cp "$KIT/VERSIONS.md" "$INSTALL_DIR/KIT-VERSIONS.md" 2>/dev/null || true
  log "source installed → $INSTALL_DIR (upstream v0.2.21 + Code-tab fix, see VERSIONS.md)"
  log "running the test suite…"
  ( cd "$ENGINE" && node --test engine/__tests__/*.test.js dom/__tests__/*.test.js build/__tests__/*.test.js >"$LOG_DIR/tests.log" 2>&1 ) \
    || die "tests failed — see $LOG_DIR/tests.log"
  grep -E '^ℹ (tests|pass|fail)' "$LOG_DIR/tests.log" | tr '\n' ' '; echo
}

# ------------------------------------------------------------------- 4. build ----
build_app() {
  if running_at "$DEST"; then
    warn "Claude-RTL is running (you are probably inside it). Building $NEXT and swapping when it quits."
    rm -rf "$NEXT"
    ( DEST_DIR="$NEXT" CLAUDE_RTL_TOOLS="$TOOLS" bash "$LINUX/patch.sh" --install ) || die "build failed."
    setsid nohup bash "$LINUX/swap-when-quit.sh" >>"$LOG_DIR/swap.log" 2>&1 </dev/null &
    SWAP_PENDING=1
  else
    ( CLAUDE_RTL_TOOLS="$TOOLS" bash "$LINUX/patch.sh" --install ) || die "build failed."
    SWAP_PENDING=0
  fi
}

# ---------------------------------------------------------------- 5. launcher ----
install_launcher() {
  mkdir -p "$(dirname "$BIN")" "$(dirname "$DESKTOP")"
  cat > "$BIN" <<SH
#!/usr/bin/env bash
# Claude-RTL launcher (claude-rtl-kit). Same account + chats as the original Claude
# (shared ~/.config/Claude), so the original must not be running at the same time.
exec "$DEST/claude-desktop" "\$@"
SH
  chmod +x "$BIN"
  sed -e "s#__DEST__#$DEST#g" -e "s#__WMCLASS__#$WMCLASS#g" "$KIT/linux/claude-rtl.desktop" > "$DESKTOP"
  # Pre-app_id installs put the entry at claude-rtl.desktop, where it claimed the ORIGINAL's
  # StartupWMClass and made window→entry matching ambiguous. Drop it.
  [ -f "$LEGACY_DESKTOP" ] && rm -f "$LEGACY_DESKTOP" && log "  removed the old claude-rtl.desktop entry (its WM class collided with the original's)."
  command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
  log "launcher: $BIN + app-menu entry \"Claude-RTL\" ($DESKTOP, app_id $WMCLASS)"
  # A pinned dock icon is a per-user choice, so it is never changed here — but say so when
  # the pinned entry is the original's, since that icon launches the unpatched Claude.
  if command -v gsettings >/dev/null && gsettings get org.gnome.shell favorite-apps 2>/dev/null | grep -q "'com.anthropic.Claude.desktop'"; then
    log "  note: your dock has the ORIGINAL Claude pinned. To pin this one instead:"
    log "        gsettings set org.gnome.shell favorite-apps \"\$(gsettings get org.gnome.shell favorite-apps | sed \"s/'com.anthropic.Claude.desktop'/'$RTL_DESKTOP_NAME'/\")\""
  fi
}

# ----------------------------------------------------------------- 5. watcher ----
install_watcher() {
  [ "$SYSTEMD_OK" = "1" ] || { warn "no systemd --user: skipping the watcher. Re-run install.sh after each Claude update."; return 0; }
  mkdir -p "$UNIT_DIR" "$LOG_DIR"
  cp "$KIT/linux/claude-rtl-watch.path" "$UNIT_DIR/claude-rtl-watch.path"
  sed -e "s#__WATCH_SH__#$LINUX/watch.sh#g" -e "s#__LOG__#$LOG_DIR/watch.log#g" \
      -e "s#__PATH__#$NODE_DIR:/usr/local/bin:/usr/bin:/bin#g" \
      "$KIT/linux/claude-rtl-watch.service" > "$UNIT_DIR/claude-rtl-watch.service"
  systemctl --user daemon-reload
  systemctl --user enable --now claude-rtl-watch.path >/dev/null 2>&1 || die "systemctl --user enable claude-rtl-watch.path failed."
  log "watcher active (systemd user path unit claude-rtl-watch.path; PATH includes $NODE_DIR)."
}

# ------------------------------------------------------------------ 6. verify ----
verify() {
  local app="$1"
  [ -d "$app" ] || die "verify: $app missing."
  local v_orig v_app payload fix want got sb
  v_orig="$(pkg_version)"; v_app="$(stamp_get "$app" pkg_version)"
  payload="$(LC_ALL=C grep -a -c 'claude-rtl-payload-v1' "$app/resources/app.asar" || true)"
  fix="$(LC_ALL=C grep -a -c 'epitaxy-user-turn' "$app/resources/app.asar" || true)"
  want="$(asar_unpacked_count "$ORIG/resources/app.asar")"; got="$(asar_unpacked_count "$app/resources/app.asar")"
  [ -x "$app/claude-desktop" ] || die "verify: $app/claude-desktop is not executable."
  [ "$v_orig" = "$v_app" ] || die "verify: version mismatch (package $v_orig, patched copy built from $v_app)."
  [ "${payload:-0}" -gt 0 ] || die "verify: payload not found in $app."
  [ "${fix:-0}" -gt 0 ] || die "verify: Code-tab fix not found in $app."
  [ "$want" = "$got" ] || die "verify: unpacked-binary count differs (original $want, patched $got)."
  sb="$(stat -L -c '%U:%a' "$app/chrome-sandbox" 2>/dev/null || echo '?')"
  [ "$sb" = "root:4755" ] || die "verify: chrome-sandbox in the copy resolves to $sb, expected root:4755."
  [ -z "$(markers_in "$ORIG/resources/app.asar")" ] || die "verify: the ORIGINAL package now carries RTL markers — it must never be modified."
  LC_ALL=C grep -a -q -F "\"desktopName\": \"$RTL_DESKTOP_NAME\"" "$app/resources/app.asar" \
    || die "verify: $app does not carry desktopName=$RTL_DESKTOP_NAME — it would share the original's app_id and the dock could not tell the two apart."
  local clash
  clash="$(grep -l "^StartupWMClass=$WMCLASS\$" "$HOME/.local/share/applications"/*.desktop /usr/share/applications/*.desktop 2>/dev/null | grep -v -F "$DESKTOP" | tr '\n' ' ')"
  [ -z "$clash" ] || warn "another desktop entry also declares StartupWMClass=$WMCLASS: $clash — window matching may be ambiguous."
  log "verified $app — claude-desktop $v_app (app $(stamp_get "$app" app_version)), payload in $payload bundles, Code-tab fix present, $got unpacked binaries, sandbox helper OK, package untouched"
}

# A real launch with a throwaway profile: proves the copy starts, opens a window, spawns
# renderers, and hits none of the known failure modes (sandbox refusal, asar/integrity
# errors). Shows a login window for ~20s, then kills it. The shared-profile launch (same
# chats) is left to the user, since the original Claude is usually running at this point.
cmd_smoke_test() {
  [ -x "$DEST/claude-desktop" ] || die "nothing to test — install first."
  local prof log_f n
  prof="$(mktemp -d)"; log_f="$prof/stderr.log"
  log "launching $DEST/claude-desktop with a throwaway profile for 20s…"
  ( setsid nohup "$DEST/claude-desktop" --user-data-dir="$prof/profile" >"$log_f" 2>&1 </dev/null & )
  sleep 20
  n="$(ps -axo command | grep -F "$DEST/claude-desktop" | grep -v grep | grep -c -- "--type=renderer" || true)"
  local bad; bad="$(grep -i -E 'sandbox|integrity|asar|refusing|Failed to load|crash' "$log_f" | grep -v -i 'chrome-sandbox.*ok' || true)"
  pkill -f "$DEST/claude-desktop" 2>/dev/null || true
  sleep 2; pkill -9 -f "$DEST/claude-desktop" 2>/dev/null || true
  local booted; booted="$(grep -c -E 'boot: done|mainView' "$prof/profile/logs/main.log" 2>/dev/null || echo 0)"
  rm -rf "$prof"
  [ "${n:-0}" -gt 0 ] || die "smoke test: no renderer process appeared (stderr: $(head -c 400 "$log_f" 2>/dev/null))."
  [ -z "$bad" ] || die "smoke test: suspicious stderr:\n$bad"
  log "smoke test OK — window + $n renderer process(es), main view booted ($booted log lines), no sandbox/asar errors."
}

cmd_status() {
  echo "original : $ORIG claude-desktop $(pkg_version)  ($( [ -z "$(markers_in "$ORIG/resources/app.asar")" ] && [ -z "$(dpkg --verify claude-desktop 2>/dev/null | grep -E 'app.asar|claude-desktop/claude-desktop$')" ] && echo 'clean' || echo 'MODIFIED'); running: $(running_at "$ORIG" && echo yes || echo no))"
  if [ -d "$DEST" ]; then
    echo "patched  : $DEST built from claude-desktop $(stamp_get "$DEST" pkg_version) on $(stamp_get "$DEST" patched_at)  (Code-tab fix: $(LC_ALL=C grep -a -q 'epitaxy-user-turn' "$DEST/resources/app.asar" && echo yes || echo no); running: $(running_at "$DEST" && echo yes || echo no))"
  else echo "patched  : not installed"; fi
  [ -d "$NEXT" ] && echo "pending  : $NEXT (claude-desktop $(stamp_get "$NEXT" pkg_version)) — swaps in when Claude-RTL quits (or: bash linux/swap-when-quit.sh --now)"
  if [ -f "$ENGINE/build/build-payload.js" ]; then
    echo "source   : $INSTALL_DIR (Code-tab fix in source: $(grep -q 'epitaxy-user-turn' "$ENGINE/dom/surfaces.js" && echo yes || echo no))"
  else echo "source   : not installed"; fi
  echo "launcher : $( [ -x "$BIN" ] && echo "$BIN" || echo 'missing' ), menu entry $( [ -f "$DESKTOP" ] && echo "present ($RTL_DESKTOP_NAME, app_id $WMCLASS)" || echo missing )"
  if have_systemd_user; then
    echo "watcher  : $(systemctl --user is-active claude-rtl-watch.path 2>/dev/null || echo 'not active') — PATH=$(sed -n 's/^Environment=PATH=//p' "$UNIT_DIR/claude-rtl-watch.service" 2>/dev/null)"
  else echo "watcher  : systemd --user not available"; fi
  echo "logs     : $LOG_DIR/watch.log, $LOG_DIR/swap.log, $LOG_DIR/tests.log"
}

cmd_uninstall() {
  running_at "$DEST" && die "Claude-RTL is running — quit it first, then re-run --uninstall. (The original Claude is never touched.)"
  if have_systemd_user; then
    systemctl --user disable --now claude-rtl-watch.path >/dev/null 2>&1 || true
    systemctl --user stop claude-rtl-watch.service >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/claude-rtl-watch.path" "$UNIT_DIR/claude-rtl-watch.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  pkill -f "$LINUX/swap-when-quit.sh" 2>/dev/null || true
  rm -rf "$DEST" "$NEXT" "$(dirname "$DEST")/.$(basename "$DEST").staging" "$(dirname "$DEST")/.$(basename "$DEST").previous" "$DEST.previous"
  rm -f "$BIN" "$DESKTOP" "$LEGACY_DESKTOP"
  # Leave a pin pointing at a removed entry behind? Drop it from the dock's favourites.
  if command -v gsettings >/dev/null && gsettings get org.gnome.shell favorite-apps 2>/dev/null | grep -q "'$RTL_DESKTOP_NAME'"; then
    gsettings set org.gnome.shell favorite-apps "$(gsettings get org.gnome.shell favorite-apps | sed -e "s/'$RTL_DESKTOP_NAME', //" -e "s/, '$RTL_DESKTOP_NAME'//" -e "s/'$RTL_DESKTOP_NAME'//")" 2>/dev/null \
      && log "  unpinned Claude-RTL from the dock."
  fi
  # The app registers its own resources/chrome-native-host with Chrome on every launch;
  # if the copy was the last to run, point the manifest back at the package.
  local m
  for m in "$HOME"/.config/*/NativeMessagingHosts/com.anthropic.claude_browser_extension.json "$HOME"/.config/*/*/NativeMessagingHosts/com.anthropic.claude_browser_extension.json; do
    [ -f "$m" ] && grep -q -F "$DEST/" "$m" && sed -i "s#$DEST/#$ORIG/#g" "$m" && log "  Chrome native-host manifest re-pointed to the package: $m"
  done
  command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
  log "removed $DEST, the launcher and the watcher. Source kept at $INSTALL_DIR (delete it if you want). $ORIG untouched."
}

FOREIGN_UNITS=()
NODE_DIR=""; SYSTEMD_OK=0
case "$MODE" in
  --status) cmd_status ;;
  --uninstall) cmd_uninstall ;;
  --smoke-test) cmd_smoke_test ;;
  --check)
    check_env; scan_prior || true ;;
  --install)
    check_env
    scan_prior || die "fix the warnings above (a clean package is required), then re-run."
    [ "${#FOREIGN_UNITS[@]}" -gt 0 ] && remove_foreign_units
    install_source
    build_app
    install_launcher
    install_watcher
    if [ "${SWAP_PENDING:-0}" = "1" ]; then
      verify "$NEXT"
      echo
      log "NEXT STEP: quit Claude-RTL. Within a few seconds it is replaced by the new build (notification appears)."
      log "           If nothing happens, run:  bash \"$KIT/linux/swap-when-quit.sh\" --now"
    else
      verify "$DEST"
      echo
      log "DONE. Quit the original Claude (tray icon → Quit) if it is open, then start \"Claude-RTL\" from the app menu or run: claude-rtl"
    fi
    log "Same account and chats as the original. The two cannot run at the same time (shared profile)."
    ;;
  *) die "unknown flag $MODE (use --install | --status | --check | --smoke-test | --uninstall)" ;;
esac
