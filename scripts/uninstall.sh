#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/Library/Application Support/PhoSignal"
BIN_DIR="$STATE/bin"
APP_DST="/Applications/PhoSignal.app"
HELPER_DST="/Library/PrivilegedHelperTools/io.github.hanpuli.phosignal.magsafe-led"
DAEMON_PLIST="$HOME/Library/LaunchAgents/io.github.hanpuli.phosignal.daemon.plist"
UI_PLIST="$HOME/Library/LaunchAgents/io.github.hanpuli.phosignal.ui.plist"
UID_NUM="$(id -u)"
PURGE=0
for arg in "$@"; do
  case "$arg" in --purge) PURGE=1 ;; *) echo "unknown option: $arg" >&2; exit 2 ;; esac
done

if [[ -x "$BIN_DIR/phosignal" ]]; then
  "$BIN_DIR/phosignal" off >/dev/null 2>&1 || true
fi
if [[ -x "$HELPER_DST" ]]; then sudo -n "$HELPER_DST" auto >/dev/null 2>&1 || true; fi

launchctl bootout "gui/$UID_NUM" "$DAEMON_PLIST" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM" "$UI_PLIST" 2>/dev/null || true
rm -f "$DAEMON_PLIST" "$UI_PLIST"
pkill -x PhoSignal 2>/dev/null || true

/usr/bin/python3 "$ROOT/scripts/configure-hooks.py" --remove --hook-path "$BIN_DIR/phosignal-hook.py" 2>/dev/null || true

sudo rm -rf "$APP_DST"
sudo rm -f "$HELPER_DST" /etc/sudoers.d/phosignal

if (( PURGE )); then
  rm -rf "$STATE"
  echo "Removed PhoSignal and user state."
else
  rm -rf "$BIN_DIR"
  echo "Removed PhoSignal. Preserved settings/logs at: $STATE"
fi
