import Foundation

// Shared profile schema for PhoSignal UI + daemon.
// This is the single source of truth for mode defaults, validation, migration and persistence.

let signalHome = NSHomeDirectory()
let signalStateDir = ProcessInfo.processInfo.environment["PHOSIGNAL_STATE_DIR"]
    ?? (signalHome + "/Library/Application Support/PhoSignal")
let signalProfileStoreFile = signalStateDir + "/profiles.json"

let signalBuiltInModeIDs = ["smart", "focus", "agent", "sprint", "quiet"]
let signalValidModes: Set<String> = Set(signalBuiltInModeIDs + ["custom"])
let signalKeyboardPatterns: Set<String> = ["breathe", "triangle", "pulse", "steady"]
let signalBaseMagStyles: Set<String> = [
    "adaptive", "green-blink", "traffic", "amber-slow", "amber-fast",
    "green-breathe", "amber-breathe", "solid-green", "solid-amber"
]
let signalSourceMagStyles: Set<String> = signalBaseMagStyles.union(["inherit"])

struct SignalEventConfig: Codable, Equatable {
    var flashes: Int
    var on: Double
    var off: Double
    var keyboard: Bool
    var magsafe: Bool
    var style: String

    func sanitized(fallback: SignalEventConfig) -> SignalEventConfig {
        SignalEventConfig(
            flashes: min(max(flashes, 1), 12),
            on: min(max(on, 0.05), 1.5),
            off: min(max(off, 0.05), 1.5),
            keyboard: keyboard,
            magsafe: magsafe,
            style: signalBaseMagStyles.contains(style) ? style : fallback.style
        )
    }
}

struct SignalProfileConfig: Codable, Equatable {
    var keyboardLo: Float
    var keyboardHi: Float
    var keyboardPeriod: Double
    var keyboardPattern: String

    var fullStyle: String
    var otherStyle: String

    // "inherit" means use fullStyle/otherStyle for the current battery state.
    var chatgptStyle: String
    var codexStyle: String
    var claudeStyle: String
    var otherAgentStyle: String
    var concurrentStyle: String

    var approval: SignalEventConfig
    var done: SignalEventConfig

    func sanitized(fallback: SignalProfileConfig) -> SignalProfileConfig {
        let lo = min(max(keyboardLo, 0), 1)
        let hi = min(max(keyboardHi, lo), 1)
        func base(_ value: String, _ fallbackValue: String) -> String {
            signalBaseMagStyles.contains(value) ? value : fallbackValue
        }
        func source(_ value: String, _ fallbackValue: String) -> String {
            signalSourceMagStyles.contains(value) ? value : fallbackValue
        }
        return SignalProfileConfig(
            keyboardLo: lo,
            keyboardHi: hi,
            keyboardPeriod: min(max(keyboardPeriod, 0.6), 12),
            keyboardPattern: signalKeyboardPatterns.contains(keyboardPattern) ? keyboardPattern : fallback.keyboardPattern,
            fullStyle: base(fullStyle, fallback.fullStyle),
            otherStyle: base(otherStyle, fallback.otherStyle),
            chatgptStyle: source(chatgptStyle, fallback.chatgptStyle),
            codexStyle: source(codexStyle, fallback.codexStyle),
            claudeStyle: source(claudeStyle, fallback.claudeStyle),
            otherAgentStyle: source(otherAgentStyle, fallback.otherAgentStyle),
            concurrentStyle: source(concurrentStyle, fallback.concurrentStyle),
            approval: approval.sanitized(fallback: fallback.approval),
            done: done.sanitized(fallback: fallback.done)
        )
    }
}

struct SignalProfileStore: Codable, Equatable {
    var version: Int
    var revision: Int
    var activeCustomPreset: String
    var builtIns: [String: SignalProfileConfig]
    var customPresets: [String: SignalProfileConfig]
}

enum SignalProfiles {
    static let smart = SignalProfileConfig(
        keyboardLo: 0.25, keyboardHi: 0.90, keyboardPeriod: 3.2, keyboardPattern: "breathe",
        fullStyle: "green-blink", otherStyle: "amber-slow",
        chatgptStyle: "inherit", codexStyle: "inherit", claudeStyle: "inherit",
        otherAgentStyle: "inherit", concurrentStyle: "inherit",
        approval: SignalEventConfig(flashes: 4, on: 0.15, off: 0.15, keyboard: true, magsafe: true, style: "amber-fast"),
        done: SignalEventConfig(flashes: 2, on: 0.15, off: 0.12, keyboard: true, magsafe: true, style: "green-blink")
    )

    static let focus = SignalProfileConfig(
        keyboardLo: 0.14, keyboardHi: 0.62, keyboardPeriod: 5.4, keyboardPattern: "breathe",
        fullStyle: "green-breathe", otherStyle: "amber-breathe",
        chatgptStyle: "inherit", codexStyle: "inherit", claudeStyle: "inherit",
        otherAgentStyle: "inherit", concurrentStyle: "inherit",
        approval: SignalEventConfig(flashes: 4, on: 0.15, off: 0.15, keyboard: true, magsafe: true, style: "amber-fast"),
        done: SignalEventConfig(flashes: 2, on: 0.18, off: 0.14, keyboard: true, magsafe: true, style: "green-blink")
    )

    static let agent = SignalProfileConfig(
        keyboardLo: 0.22, keyboardHi: 0.82, keyboardPeriod: 3.6, keyboardPattern: "breathe",
        fullStyle: "green-breathe", otherStyle: "amber-breathe",
        chatgptStyle: "green-breathe", codexStyle: "amber-breathe", claudeStyle: "inherit",
        otherAgentStyle: "inherit", concurrentStyle: "traffic",
        approval: SignalEventConfig(flashes: 4, on: 0.14, off: 0.14, keyboard: true, magsafe: true, style: "amber-fast"),
        done: SignalEventConfig(flashes: 2, on: 0.15, off: 0.12, keyboard: true, magsafe: true, style: "green-blink")
    )

    static let sprint = SignalProfileConfig(
        keyboardLo: 0.38, keyboardHi: 1.00, keyboardPeriod: 1.75, keyboardPattern: "breathe",
        fullStyle: "traffic", otherStyle: "traffic",
        chatgptStyle: "inherit", codexStyle: "inherit", claudeStyle: "inherit",
        otherAgentStyle: "inherit", concurrentStyle: "inherit",
        approval: SignalEventConfig(flashes: 6, on: 0.11, off: 0.11, keyboard: true, magsafe: true, style: "amber-fast"),
        done: SignalEventConfig(flashes: 3, on: 0.13, off: 0.10, keyboard: true, magsafe: true, style: "green-blink")
    )

    static let quiet = SignalProfileConfig(
        keyboardLo: 0.08, keyboardHi: 0.30, keyboardPeriod: 7.2, keyboardPattern: "breathe",
        fullStyle: "solid-green", otherStyle: "solid-amber",
        chatgptStyle: "inherit", codexStyle: "inherit", claudeStyle: "inherit",
        otherAgentStyle: "inherit", concurrentStyle: "inherit",
        approval: SignalEventConfig(flashes: 3, on: 0.18, off: 0.18, keyboard: true, magsafe: true, style: "amber-fast"),
        done: SignalEventConfig(flashes: 1, on: 0.22, off: 0.16, keyboard: true, magsafe: true, style: "green-blink")
    )

    static let custom = SignalProfileConfig(
        keyboardLo: 0.18, keyboardHi: 0.78, keyboardPeriod: 3.8, keyboardPattern: "breathe",
        fullStyle: "green-blink", otherStyle: "amber-slow",
        chatgptStyle: "green-breathe", codexStyle: "amber-breathe", claudeStyle: "inherit",
        otherAgentStyle: "inherit", concurrentStyle: "traffic",
        approval: SignalEventConfig(flashes: 4, on: 0.15, off: 0.15, keyboard: true, magsafe: true, style: "amber-fast"),
        done: SignalEventConfig(flashes: 2, on: 0.15, off: 0.12, keyboard: true, magsafe: true, style: "green-blink")
    )

    static let factoryBuiltIns: [String: SignalProfileConfig] = [
        "smart": smart, "focus": focus, "agent": agent, "sprint": sprint, "quiet": quiet
    ]

    static func defaultStore() -> SignalProfileStore {
        SignalProfileStore(
            version: 2,
            revision: 0,
            activeCustomPreset: "My Preset",
            builtIns: factoryBuiltIns,
            customPresets: ["My Preset": custom]
        )
    }

    static func factoryProfile(for mode: String) -> SignalProfileConfig {
        mode == "custom" ? custom : (factoryBuiltIns[mode] ?? smart)
    }

    static func sanitize(_ input: SignalProfileStore) -> SignalProfileStore {
        var out = defaultStore()
        out.revision = max(input.revision, 0)

        for mode in signalBuiltInModeIDs {
            let fallback = factoryBuiltIns[mode] ?? smart
            out.builtIns[mode] = (input.builtIns[mode] ?? fallback).sanitized(fallback: fallback)
        }

        var customs: [String: SignalProfileConfig] = [:]
        for (rawName, profile) in input.customPresets {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            customs[name] = profile.sanitized(fallback: custom)
        }
        if customs.isEmpty { customs["My Preset"] = custom }
        out.customPresets = customs
        out.activeCustomPreset = customs[input.activeCustomPreset] != nil
            ? input.activeCustomPreset
            : (customs.keys.sorted().first ?? "My Preset")
        return out
    }

    static func load() -> SignalProfileStore {
        let fm = FileManager.default
        if let data = fm.contents(atPath: signalProfileStoreFile),
           let decoded = try? JSONDecoder().decode(SignalProfileStore.self, from: data) {
            return sanitize(decoded)
        }
        return defaultStore()
    }

    @discardableResult
    static func save(_ input: SignalProfileStore) throws -> SignalProfileStore {
        let fm = FileManager.default
        var out = sanitize(input)
        out.version = 2
        out.revision = max(input.revision, load().revision) + 1
        try fm.createDirectory(atPath: signalStateDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(out)
        try data.write(to: URL(fileURLWithPath: signalProfileStoreFile), options: .atomic)
        return out
    }

    static func profile(for mode: String, store: SignalProfileStore? = nil) -> SignalProfileConfig {
        let s = store ?? load()
        if mode == "custom" {
            return (s.customPresets[s.activeCustomPreset] ?? custom).sanitized(fallback: custom)
        }
        let fallback = factoryProfile(for: mode)
        return (s.builtIns[mode] ?? fallback).sanitized(fallback: fallback)
    }

    static func isCustomized(_ mode: String, store: SignalProfileStore? = nil) -> Bool {
        guard signalValidModes.contains(mode) else { return false }
        let s = store ?? load()
        return profile(for: mode, store: s) != factoryProfile(for: mode)
    }

    static func uniquePresetName(_ base: String, store: SignalProfileStore) -> String {
        if store.customPresets[base] == nil { return base }
        var i = 2
        while store.customPresets["\(base) \(i)"] != nil { i += 1 }
        return "\(base) \(i)"
    }
}
