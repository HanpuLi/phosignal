#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$(mktemp -d /tmp/phosignal-profile-tests.XXXXXX)"
MAIN="$STATE/main.swift"
BIN="$STATE/profile-tests"
trap 'rm -rf "$STATE"' EXIT

cat "$ROOT/Sources/SignalProfiles.swift" > "$MAIN"
cat >> "$MAIN" <<'SWIFT'

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

var store = SignalProfiles.load()
require(store.version == 2, "default store version")
require(Set(store.builtIns.keys) == Set(signalBuiltInModeIDs), "all built-in modes exist")
require(store.customPresets[store.activeCustomPreset] != nil, "active custom preset exists")
require(!SignalProfiles.isCustomized("smart", store: store), "smart starts at factory default")

var smart = store.builtIns["smart"]!
smart.keyboardLo = 0.33
smart.keyboardHi = 0.33
smart.keyboardPattern = "steady"
smart.chatgptStyle = "traffic"
store.builtIns["smart"] = smart

let customName = SignalProfiles.uniquePresetName("Night", store: store)
store.customPresets[customName] = SignalProfiles.custom
store.activeCustomPreset = customName
let saved = try SignalProfiles.save(store)
require(saved.revision == 1, "first save revision")
require(SignalProfiles.isCustomized("smart", store: saved), "built-in override is detected")

let reloaded = SignalProfiles.load()
let smartReloaded = SignalProfiles.profile(for: "smart", store: reloaded)
require(abs(smartReloaded.keyboardLo - 0.33) < 0.0001, "keyboard low persisted")
require(abs(smartReloaded.keyboardHi - 0.33) < 0.0001, "keyboard high persisted")
require(smartReloaded.keyboardPattern == "steady", "keyboard pattern persisted")
require(smartReloaded.chatgptStyle == "traffic", "source-specific style persisted")
require(reloaded.activeCustomPreset == customName, "active custom preset persisted")

var invalid = smartReloaded
invalid.keyboardLo = 0.91
invalid.keyboardHi = 0.12
invalid.keyboardPeriod = 99
invalid.keyboardPattern = "nonsense"
invalid.fullStyle = "bad-style"
invalid.concurrentStyle = "bad-style"
store = reloaded
store.builtIns["smart"] = invalid
let sanitized = try SignalProfiles.save(store)
let fixed = SignalProfiles.profile(for: "smart", store: sanitized)
require(abs(fixed.keyboardLo - 0.91) < 0.0001, "low clamp preserved")
require(abs(fixed.keyboardHi - 0.91) < 0.0001, "high never falls below low")
require(abs(fixed.keyboardPeriod - 12) < 0.0001, "period clamped")
require(fixed.keyboardPattern == SignalProfiles.smart.keyboardPattern, "invalid pattern falls back")
require(fixed.fullStyle == SignalProfiles.smart.fullStyle, "invalid base style falls back")
require(fixed.concurrentStyle == SignalProfiles.smart.concurrentStyle, "invalid source style falls back")

print("PASS profile-store revision=\(sanitized.revision) state=\(signalStateDir)")
SWIFT

PHOSIGNAL_STATE_DIR="$STATE/state" xcrun swiftc -O "$MAIN" -o "$BIN"
PHOSIGNAL_STATE_DIR="$STATE/state" "$BIN"
