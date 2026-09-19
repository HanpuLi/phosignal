#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STATE="$HOME/Library/Application Support/PhoSignal"
BIN_DIR="$STATE/bin"
ZIP="$ROOT/.build/release/PhoSignal-$VERSION.zip"
HELPER_SRC="$ROOT/.build/release/magsafe-led"
APP_DST="/Applications/PhoSignal.app"
HELPER_DST="/Library/PrivilegedHelperTools/io.github.hanpuli.phosignal.magsafe-led"
DAEMON_PLIST="$HOME/Library/LaunchAgents/io.github.hanpuli.phosignal.daemon.plist"
UI_PLIST="$HOME/Library/LaunchAgents/io.github.hanpuli.phosignal.ui.plist"
USER_NAME="$(id -un)"
UID_NUM="$(id -u)"
INSTALL_HOOKS=1
NO_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --no-hooks) INSTALL_HOOKS=0 ;;
    --no-build) NO_BUILD=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( ! NO_BUILD )); then "$ROOT/scripts/build.sh"; fi
[[ -f "$ZIP" && -x "$HELPER_SRC" && -x "$ROOT/.build/release/phosignal-cli" ]] || { echo "build artifacts missing" >&2; exit 1; }

APP_STAGE="$(mktemp -d /tmp/phosignal-install.XXXXXX)"
SUDOERS_TMP=""
cleanup() {
  rm -rf "$APP_STAGE"
  [[ -n "$SUDOERS_TMP" ]] && rm -f "$SUDOERS_TMP" || true
}
trap cleanup EXIT
ditto -x -k "$ZIP" "$APP_STAGE"
APP_SRC="$APP_STAGE/PhoSignal.app"
codesign --verify --deep --strict "$APP_SRC"

mkdir -p "$STATE" "$BIN_DIR" "$HOME/Library/LaunchAgents" "$STATE/backups"
stamp="$(date +%Y%m%d-%H%M%S)"

# launchd may cache code-signing responsibility for a direct executable.
# Unload before replacing the daemon binary; do not substitute kickstart -k.
launchctl bootout "gui/$UID_NUM/io.github.hanpuli.phosignal.daemon" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/io.github.hanpuli.phosignal.ui" 2>/dev/null || true
pkill -x PhoSignal 2>/dev/null || true
sleep 0.3

if [[ -d "$APP_DST" ]]; then
  ditto "$APP_DST" "$STATE/backups/PhoSignal.app.$stamp" 2>/dev/null || true
fi
if [[ -x "$BIN_DIR/phosignal" ]]; then
  cp -p "$BIN_DIR/phosignal" "$STATE/backups/phosignal.$stamp" || true
fi

install -m 755 "$ROOT/.build/release/phosignal-cli" "$BIN_DIR/phosignal"
install -m 755 "$ROOT/.build/release/phosignal-hook.py" "$BIN_DIR/phosignal-hook.py"

# ACLC is the only privileged surface. The helper exposes no arbitrary/raw SMC command.
sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$HELPER_SRC" "$HELPER_DST"
SUDOERS_TMP="$(mktemp /tmp/phosignal-sudoers.XXXXXX)"
{
  printf "# PhoSignal: restricted ACLC helper only.\n"
  printf "%s ALL=(root) NOPASSWD: %s read, %s auto, %s off, %s green, %s amber, %s amber-slow, %s amber-fast\n" "$USER_NAME" "$HELPER_DST" "$HELPER_DST" "$HELPER_DST" "$HELPER_DST" "$HELPER_DST" "$HELPER_DST" "$HELPER_DST"
} > "$SUDOERS_TMP"
sudo visudo -cf "$SUDOERS_TMP" >/dev/null
sudo install -o root -g wheel -m 440 "$SUDOERS_TMP" /etc/sudoers.d/phosignal

sudo rm -rf "$APP_DST"
sudo ditto "$APP_SRC" "$APP_DST"
sudo xattr -cr "$APP_DST" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DST"

cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.hanpuli.phosignal.daemon</string>
  <key>ProgramArguments</key><array>
    <string>$BIN_DIR/phosignal</string><string>daemon</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PHOSIGNAL_STATE_DIR</key><string>$STATE</string>
    <key>PHOSIGNAL_MAGSAFE_HELPER</key><string>$HELPER_DST</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/daemon.log</string>
  <key>StandardErrorPath</key><string>$STATE/daemon.log</string>
</dict></plist>
PLIST
plutil -lint "$DAEMON_PLIST" >/dev/null

cat > "$UI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.hanpuli.phosignal.ui</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/open</string><string>-gj</string><string>$APP_DST</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
plutil -lint "$UI_PLIST" >/dev/null

PHOSIGNAL_STATE_DIR="$STATE" PHOSIGNAL_MAGSAFE_HELPER="$HELPER_DST" "$BIN_DIR/phosignal" profiles init >/dev/null
if (( INSTALL_HOOKS )); then
  /usr/bin/python3 "$ROOT/scripts/configure-hooks.py" --install --hook-path "$BIN_DIR/phosignal-hook.py"
fi

launchctl bootstrap "gui/$UID_NUM" "$DAEMON_PLIST"
launchctl bootstrap "gui/$UID_NUM" "$UI_PLIST"
open -gj "$APP_DST"
sleep 1

if ! launchctl print "gui/$UID_NUM/io.github.hanpuli.phosignal.daemon" | grep -q "state = running"; then
  echo "PhoSignal daemon failed to start" >&2
  tail -40 "$STATE/daemon.log" >&2 || true
  exit 1
fi
if ! pgrep -x PhoSignal >/dev/null; then
  echo "PhoSignal menu-bar app failed to start" >&2
  exit 1
fi
if ! sudo -n "$HELPER_DST" read >/dev/null 2>&1; then
  echo "MagSafe helper/sudoers verification failed" >&2
  exit 1
fi

echo "Installed PhoSignal $VERSION"
echo "App: $APP_DST"
echo "State: $STATE"
echo "CLI: $BIN_DIR/phosignal"
echo "Next: \"$BIN_DIR/phosignal\" doctor"
