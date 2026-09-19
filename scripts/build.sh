#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/release"
GENERATED="$ROOT/.build/generated"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

rm -rf "$BUILD" "$GENERATED"
mkdir -p "$BUILD" "$GENERATED"

cat "$ROOT/Sources/SignalProfiles.swift" "$ROOT/Sources/ProfileSettingsController.swift" "$ROOT/Sources/PhoSignalApp.swift" > "$GENERATED/AppMain.swift"
cat "$ROOT/Sources/SignalProfiles.swift" "$ROOT/Sources/phosignald.swift" > "$GENERATED/DaemonMain.swift"

# Keep CLI and GUI artifact names distinct even on the default case-insensitive macOS filesystem.
xcrun swiftc -O -whole-module-optimization "$GENERATED/DaemonMain.swift" -o "$BUILD/phosignal-cli"
xcrun swiftc -O -whole-module-optimization "$GENERATED/AppMain.swift" -framework AppKit -framework ApplicationServices -o "$BUILD/PhoSignal"
xcrun clang -O2 -Wall -Wextra -Werror "$ROOT/Helpers/magsafe-led.c" -framework IOKit -o "$BUILD/magsafe-led"
xcrun clang -O2 -Wall -Wextra "$ROOT/Integrations/chatgpt-status-watch.c" -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -o "$BUILD/chatgpt-status-watch"
install -m 755 "$ROOT/Integrations/phosignal-hook.py" "$BUILD/phosignal-hook.py"

codesign --force --timestamp=none --sign "$IDENTITY" "$BUILD/phosignal-cli"
codesign --force --timestamp=none --sign "$IDENTITY" "$BUILD/PhoSignal"
codesign --force --timestamp=none --sign "$IDENTITY" "$BUILD/magsafe-led"
codesign --force --timestamp=none --sign "$IDENTITY" "$BUILD/chatgpt-status-watch"

if cmp -s "$BUILD/phosignal-cli" "$BUILD/PhoSignal"; then
    echo "CLI/GUI artifact collision detected" >&2
    exit 1
fi
SMOKE_STATE="$GENERATED/cli-smoke-state"
PHOSIGNAL_STATE_DIR="$SMOKE_STATE" PHOSIGNAL_MAGSAFE_HELPER="/nonexistent/phosignal-helper"     "$BUILD/phosignal-cli" profiles init >/dev/null
PHOSIGNAL_STATE_DIR="$SMOKE_STATE" PHOSIGNAL_MAGSAFE_HELPER="/nonexistent/phosignal-helper"     "$BUILD/phosignal-cli" profiles | grep -q 'profiles revision='

STAGE_ROOT="$(mktemp -d /tmp/phosignal-app.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
APP="$STAGE_ROOT/PhoSignal.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
install -m 755 "$BUILD/PhoSignal" "$APP/Contents/MacOS/PhoSignal"
install -m 755 "$BUILD/chatgpt-status-watch" "$APP/Contents/Helpers/chatgpt-status-watch"

ICON_PNG="$GENERATED/AppIcon-1024.png"
xcrun swift "$ROOT/scripts/make-icon.swift" "$ICON_PNG"
ICONSET="$GENERATED/AppIcon.iconset"
mkdir -p "$ICONSET"
while read -r px name; do
    sips -z "$px" "$px" "$ICON_PNG" --out "$ICONSET/$name" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PhoSignal</string>
  <key>CFBundleIdentifier</key><string>io.github.hanpuli.phosignal</string>
  <key>CFBundleName</key><string>PhoSignal</string>
  <key>CFBundleDisplayName</key><string>PhoSignal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Keep the signed bundle out of Desktop/iCloud: file-provider xattrs can invalidate
# an ad-hoc signature after the fact. Publish a ZIP created from the clean /tmp bundle.
OUTPUT_ZIP="$BUILD/PhoSignal-$VERSION.zip"
rm -f "$OUTPUT_ZIP"
DITTONORSRC=1 ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$OUTPUT_ZIP"

VERIFY_ROOT="$(mktemp -d /tmp/phosignal-verify.XXXXXX)"
DITTONORSRC=1 ditto -x -k --norsrc --noextattr --noacl "$OUTPUT_ZIP" "$VERIFY_ROOT"
codesign --verify --deep --strict "$VERIFY_ROOT/PhoSignal.app"
rm -rf "$VERIFY_ROOT"

printf 'Built PhoSignal %s (%s)\n' "$VERSION" "$OUTPUT_ZIP"
