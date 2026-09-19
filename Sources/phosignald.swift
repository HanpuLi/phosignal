// PhoSignal daemon: local AI-agent activity -> keyboard backlight + MagSafe LED.
// State root defaults to ~/Library/Application Support/PhoSignal/:
//   active/<session_id> exists while a source is active; markers older than 20 minutes are stale
//   done / pulse are one-shot completion / attention events; off is the master output switch
//   keyboard-off / magsafe-off disable one output channel without stopping source detection
// Keyboard output uses private CoreBrightness; MagSafe uses the ACLC-only privileged helper.
// See `phosignal style`; adaptive means green blink when full, amber-slow otherwise.
import Foundation
import ObjectiveC

let home = signalHome
let stateDir = signalStateDir
let activeDir = stateDir + "/active"
let origFile = stateDir + "/orig"
let userLevelFile = stateDir + "/userlevel"
let magsafeStyleFile = stateDir + "/magsafe-style"
let modeFile = stateDir + "/mode"
let rawStyleOverrideFile = stateDir + "/raw-style-override"
let keyboardOffFile = stateDir + "/keyboard-off"
let magsafeOffFile = stateDir + "/magsafe-off"
let previewModeFile = stateDir + "/preview-mode"
let previewSourceFile = stateDir + "/preview-source"
let previewMarkerFile = activeDir + "/_preview"
let defaultLevel: Float = 0.5
let defaultMagsafeStyle = "adaptive"
let defaultMode = "smart"
let validModes = signalValidModes
let validMagsafeStyles = signalBaseMagStyles
let magsafeBin = ProcessInfo.processInfo.environment["PHOSIGNAL_MAGSAFE_HELPER"]
    ?? "/Library/PrivilegedHelperTools/io.github.hanpuli.phosignal.magsafe-led"
let staleSec: TimeInterval = 20 * 60
let fm = FileManager.default

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
    FileHandle.standardError.write((f.string(from: Date()) + " " + s + "\n").data(using: .utf8)!)
}

final class KB {
    typealias FQ = @convention(c) (AnyObject, Selector, UInt64) -> Float
    typealias BQ = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    typealias BFQ = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    typealias BBQ = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    static let sGet = NSSelectorFromString("brightnessForKeyboard:")
    static let sSet = NSSelectorFromString("setBrightness:forKeyboard:")
    static let sAuto = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
    static let sEnAuto = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
    static let sSup = NSSelectorFromString("isBacklightSuppressedOnKeyboard:")
    static let sDim = NSSelectorFromString("isBacklightDimmedOnKeyboard:")
    static let sSusp = NSSelectorFromString("suspendIdleDimming:forKeyboard:")
    let c: NSObject
    let ids: [UInt64]
    let fGet: FQ, fSet: BFQ, fAuto: BQ, fEnAuto: BBQ, fSup: BQ, fSusp: BBQ, fDim: BQ

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              let g = cls.instanceMethod(for: KB.sGet), let s = cls.instanceMethod(for: KB.sSet),
              let a = cls.instanceMethod(for: KB.sAuto), let ea = cls.instanceMethod(for: KB.sEnAuto),
              let su = cls.instanceMethod(for: KB.sSup), let sd = cls.instanceMethod(for: KB.sSusp),
              let dm = cls.instanceMethod(for: KB.sDim) else { return nil }
        fGet = unsafeBitCast(g, to: FQ.self); fSet = unsafeBitCast(s, to: BFQ.self)
        fAuto = unsafeBitCast(a, to: BQ.self); fEnAuto = unsafeBitCast(ea, to: BBQ.self)
        fSup = unsafeBitCast(su, to: BQ.self); fSusp = unsafeBitCast(sd, to: BBQ.self); fDim = unsafeBitCast(dm, to: BQ.self)
        let obj = cls.init()
        c = obj
        ids = (obj.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber])?.map { $0.uint64Value } ?? []
        if ids.isEmpty { return nil }
    }
    var brightness: Float { fGet(c, KB.sGet, ids[0]) }
    var autoEnabled: Bool { fAuto(c, KB.sAuto, ids[0]) }
    var suppressed: Bool { fSup(c, KB.sSup, ids[0]) }
    var dimmed: Bool { fDim(c, KB.sDim, ids[0]) }
    func set(_ v: Float) { for k in ids { _ = fSet(c, KB.sSet, v, k) } }
    func enableAuto(_ on: Bool) { for k in ids { _ = fEnAuto(c, KB.sEnAuto, on, k) } }
    func suspendIdleDim(_ on: Bool) { for k in ids { _ = fSusp(c, KB.sSusp, on, k) } }
}

let magsafeQueue = DispatchQueue(label: "io.github.hanpuli.phosignal.magsafe")
func magsafe(_ mode: String) {
    guard fm.isExecutableFile(atPath: magsafeBin) else { return }
    magsafeQueue.async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", magsafeBin, mode]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { log("magsafe: \(error)") }
    }
}

var gStop = false
final class SignalEngine {
    let kb: KB?
    var working = false
    var keyboardOwned = false
    var origB: Float = 0
    var origAuto = true
    var t0 = Date()
    var userLevel: Float? = Float((try? String(contentsOfFile: userLevelFile, encoding: .utf8)) ?? "")
    var magMode = ""
    var magStep = 0
    var nextMagEvent = Date.distantPast
    var cachedMagStyle = defaultMagsafeStyle
    var effectiveMagStyle = ""
    var lastMagStyleRead = Date.distantPast
    var cachedMode = defaultMode
    var lastModeRead = Date.distantPast
    var cachedProfileStore = SignalProfiles.load()
    var lastProfileStoreRead = Date.distantPast
    var batteryPercent = -1
    var batteryCharged = false
    var batteryOnAC = false
    var lastBatteryCheck = Date.distantPast
    init(kb: KB?) { self.kb = kb }

    // brightnessForKeyboard: returns effective brightness; lid/dimming/user-zero can all read as 0.
    // Never learn or restore that transient zero as the user preference.
    func sampleUserLevel() {
        guard let kb, !working, !kb.suppressed, !kb.dimmed else { return }
        let b = kb.brightness
        if b > 0.02, b != userLevel { userLevel = b; try? "\(b)".write(toFile: userLevelFile, atomically: true, encoding: .utf8) }
    }
    var restoreLevel: Float { userLevel ?? defaultLevel }
    var keyboardOutputEnabled: Bool { !fm.fileExists(atPath: keyboardOffFile) }
    var magsafeOutputEnabled: Bool { !fm.fileExists(atPath: magsafeOffFile) }

    func acquireKeyboardIfNeeded() {
        guard let kb, working, keyboardOutputEnabled, !keyboardOwned else { return }
        origB = kb.brightness
        origAuto = kb.autoEnabled
        try? "\(origB) \(origAuto)".write(toFile: origFile, atomically: true, encoding: .utf8)
        kb.enableAuto(false)
        kb.suspendIdleDim(true)
        keyboardOwned = true
        log("keyboard output acquired (current \(origB), auto=\(origAuto))")
    }

    func releaseKeyboardIfNeeded() {
        guard keyboardOwned else { return }
        guard let kb else {
            keyboardOwned = false
            try? fm.removeItem(atPath: origFile)
            return
        }
        kb.set(restoreLevel)
        kb.suspendIdleDim(false)
        if origAuto { kb.enableAuto(true) }
        try? fm.removeItem(atPath: origFile)
        keyboardOwned = false
        log("keyboard output released (restore \(restoreLevel))")
    }

    func setMag(_ mode: String, force: Bool = false) {
        guard force || mode != magMode else { return }
        magMode = mode
        magsafe(mode)
    }

    @discardableResult
    func loadMode(force: Bool = false) -> String {
        let now = Date()
        if force || now.timeIntervalSince(lastModeRead) >= 1.0 {
            lastModeRead = now
            let raw = ((try? String(contentsOfFile: modeFile, encoding: .utf8)) ?? defaultMode)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = validModes.contains(raw) ? raw : defaultMode
            if mode != cachedMode {
                cachedMode = mode
                effectiveMagStyle = ""
                magStep = 0
                nextMagEvent = .distantPast
                log("mode → \(mode)")
            }
        }
        return cachedMode
    }

    @discardableResult
    func loadProfileStore(force: Bool = false) -> SignalProfileStore {
        let now = Date()
        if force || now.timeIntervalSince(lastProfileStoreRead) >= 0.5 {
            lastProfileStoreRead = now
            let fresh = SignalProfiles.load()
            if fresh != cachedProfileStore {
                cachedProfileStore = fresh
                t0 = Date()
                resetMagPattern()
                log("profile store hot-reload revision=\(fresh.revision)")
            }
        }
        return cachedProfileStore
    }

    func previewMode() -> String? {
        guard fm.fileExists(atPath: previewMarkerFile),
              let raw = try? String(contentsOfFile: previewModeFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              validModes.contains(raw) else { return nil }
        return raw
    }

    func currentProfile(forceStore: Bool = false) -> SignalProfileConfig {
        let mode = previewMode() ?? loadMode()
        return SignalProfiles.profile(for: mode, store: loadProfileStore(force: forceStore))
    }

    func resolveProfileStyle(_ rawStyle: String, profile: SignalProfileConfig) -> String {
        var style = rawStyle
        if style == "inherit" {
            style = batteryFull ? profile.fullStyle : profile.otherStyle
        }
        if style == "adaptive" {
            style = batteryFull ? "green-blink" : "amber-slow"
        }
        return style
    }

    func previewSource() -> String? {
        guard fm.fileExists(atPath: previewMarkerFile),
              let source = try? String(contentsOfFile: previewSourceFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              ["default", "chatgpt", "codex", "claude", "other", "concurrent"].contains(source)
        else { return nil }
        return source
    }

    func sourceStyle(_ source: String, profile: SignalProfileConfig) -> String {
        switch source {
        case "chatgpt": return profile.chatgptStyle
        case "codex": return profile.codexStyle
        case "claude": return profile.claudeStyle
        case "other": return profile.otherAgentStyle
        case "concurrent": return profile.concurrentStyle
        default: return "inherit"
        }
    }

    func activeAgentStyle(profile: SignalProfileConfig) -> String {
        if let source = previewSource() {
            return sourceStyle(source, profile: profile)
        }

        let files = (try? fm.contentsOfDirectory(atPath: activeDir)) ?? []
        let live = files.filter { f in
            let p = activeDir + "/" + f
            guard let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return false }
            return Date().timeIntervalSince(m) <= staleSec
        }
        let hasChatGPT = live.contains("chatgpt-ui")
        let hasCodex = live.contains { $0 == "codex-exec-process" || $0.hasPrefix("codex-") }
        let hasClaude = live.contains { UUID(uuidString: $0) != nil || $0.hasPrefix("claude-") }
        let hasOther = live.contains {
            $0 != "chatgpt-ui" &&
            $0 != "codex-exec-process" && !$0.hasPrefix("codex-") &&
            UUID(uuidString: $0) == nil && !$0.hasPrefix("claude-") &&
            !$0.hasPrefix("_")
        }
        let sourceCount = [hasChatGPT, hasCodex, hasClaude, hasOther].filter { $0 }.count
        if sourceCount > 1 { return profile.concurrentStyle }
        if hasChatGPT { return profile.chatgptStyle }
        if hasCodex { return profile.codexStyle }
        if hasClaude { return profile.claudeStyle }
        if hasOther { return profile.otherAgentStyle }
        return "inherit"
    }

    @discardableResult
    func loadMagsafeStyle(force: Bool = false) -> String {
        let now = Date()
        if force || now.timeIntervalSince(lastMagStyleRead) >= 1.0 {
            lastMagStyleRead = now
            let raw = ((try? String(contentsOfFile: magsafeStyleFile, encoding: .utf8)) ?? defaultMagsafeStyle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let style = validMagsafeStyles.contains(raw) ? raw : defaultMagsafeStyle
            if style != cachedMagStyle {
                cachedMagStyle = style
                effectiveMagStyle = ""
                magStep = 0
                nextMagEvent = .distantPast
                log("MagSafe style → \(style)")
            }
        }
        return cachedMagStyle
    }

    func refreshBattery(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastBatteryCheck) >= 30 else { return }
        lastBatteryCheck = now
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "batt"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return }
            if let re = try? NSRegularExpression(pattern: #"([0-9]+)%"#),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                batteryPercent = Int(text[r]) ?? batteryPercent
            }
            batteryCharged = text.localizedCaseInsensitiveContains("; charged;")
            batteryOnAC = text.localizedCaseInsensitiveContains("AC Power")
        } catch {
            log("battery read failed: \(error)")
        }
    }

    var batteryFull: Bool { batteryCharged || batteryPercent >= 100 }

    func resetMagPattern() {
        effectiveMagStyle = ""
        magStep = 0
        nextMagEvent = .distantPast
    }

    func updateMagPattern(force: Bool = false) {
        if !magsafeOutputEnabled {
            if effectiveMagStyle != "disabled" || magMode != "auto" {
                setMag("auto", force: true)
                effectiveMagStyle = "disabled"
                magStep = 0
                nextMagEvent = .distantFuture
                log("MagSafe output disabled; returned to firmware")
            }
            return
        }
        if effectiveMagStyle == "disabled" {
            effectiveMagStyle = ""
            magStep = 0
            nextMagEvent = .distantPast
        }
        refreshBattery()
        let profile = currentProfile()
        let hasRawOverride = fm.fileExists(atPath: rawStyleOverrideFile)
        let requested = hasRawOverride ? loadMagsafeStyle() : activeAgentStyle(profile: profile)
        let style = resolveProfileStyle(requested, profile: profile)
        if style != effectiveMagStyle {
            effectiveMagStyle = style
            magStep = 0
            nextMagEvent = .distantPast
            log("MagSafe effective style \(style) (battery=\(batteryPercent)% charged=\(batteryCharged))")
        }

        let now = Date()
        guard force || now >= nextMagEvent else { return }

        func step(_ sequence: [(String, Double)]) {
            let item = sequence[magStep % sequence.count]
            setMag(item.0)
            magStep += 1
            nextMagEvent = now.addingTimeInterval(item.1)
        }

        switch style {
        case "green-blink":
            step([("green", 0.72), ("off", 0.72)])
        case "traffic":
            // Hold each traffic colour for 0.8s so both colours remain visually distinct.
            step([("green", 0.80), ("amber", 0.80)])
        case "amber-slow":
            setMag("amber-slow"); nextMagEvent = now.addingTimeInterval(20)
        case "amber-fast":
            setMag("amber-fast"); nextMagEvent = now.addingTimeInterval(20)
        case "green-breathe":
            // ACLC has no brightness levels; breathe patterns vary duty cycle/timing, not PWM intensity.
            step([
                ("green", 0.14), ("off", 0.34),
                ("green", 0.20), ("off", 0.26),
                ("green", 0.30), ("off", 0.18),
                ("green", 0.52), ("off", 0.16),
                ("green", 0.30), ("off", 0.18),
                ("green", 0.20), ("off", 0.26),
                ("green", 0.14), ("off", 0.48)
            ])
        case "amber-breathe":
            step([
                ("amber", 0.14), ("off", 0.34),
                ("amber", 0.20), ("off", 0.26),
                ("amber", 0.30), ("off", 0.18),
                ("amber", 0.52), ("off", 0.16),
                ("amber", 0.30), ("off", 0.18),
                ("amber", 0.20), ("off", 0.26),
                ("amber", 0.14), ("off", 0.48)
            ])
        case "solid-green":
            setMag("green"); nextMagEvent = now.addingTimeInterval(20)
        case "solid-amber":
            setMag("amber"); nextMagEvent = now.addingTimeInterval(20)
        default:
            setMag("amber-slow"); nextMagEvent = now.addingTimeInterval(20)
        }
    }

    func enter() {
        working = true; t0 = Date()
        acquireKeyboardIfNeeded()
        refreshBattery(force: true)
        _ = loadMode(force: true)
        _ = loadProfileStore(force: true)
        if fm.fileExists(atPath: rawStyleOverrideFile) { _ = loadMagsafeStyle(force: true) }
        resetMagPattern(); updateMagPattern(force: true)
        log("▶ active (keyboard=\(keyboardOutputEnabled ? "on" : "off"), MagSafe=\(magsafeOutputEnabled ? "on" : "off"), userLevel \(userLevel.map { "\($0)" } ?? "unknown→\(defaultLevel)"), battery=\(batteryPercent)%)")
    }
    func leave() {
        releaseKeyboardIfNeeded()
        setMag("auto", force: true); resetMagPattern()
        working = false
        log("■ idle (outputs returned to system)")
    }
    func eventMag(_ style: String, phaseOn: Bool, cycle: Int) {
        let resolved = style == "adaptive" ? (batteryFull ? "green-blink" : "amber-slow") : style
        switch resolved {
        case "amber-fast", "amber-slow":
            if cycle == 0 && phaseOn { setMag(resolved, force: true) }
        case "solid-green":
            if cycle == 0 && phaseOn { setMag("green", force: true) }
        case "solid-amber":
            if cycle == 0 && phaseOn { setMag("amber", force: true) }
        case "traffic":
            setMag(phaseOn ? "green" : "amber", force: true)
        case "amber-breathe":
            setMag(phaseOn ? "amber" : "off", force: true)
        default:
            setMag(phaseOn ? "green" : "off", force: true)
        }
    }

    // Event feedback temporarily borrows only enabled channels and restores them afterwards.
    func blink(_ n: Int, on: Double, off: Double, keyboard: Bool = true, magsafeStyle: String? = nil) {
        let keyboardEnabled = keyboardOutputEnabled && keyboard && kb != nil
        let magsafeEnabled = magsafeOutputEnabled && magsafeStyle != nil
        let owned = keyboardOwned
        var b: Float = 0, a = true
        if keyboardEnabled, !owned, let kb { b = kb.brightness; a = kb.autoEnabled; kb.enableAuto(false) }

        for i in 0..<n {
            if keyboardEnabled, let kb { kb.set(1.0) }
            if magsafeEnabled, let style = magsafeStyle { eventMag(style, phaseOn: true, cycle: i) }
            Thread.sleep(forTimeInterval: on)
            if keyboardEnabled, let kb { kb.set(0) }
            if magsafeEnabled, let style = magsafeStyle { eventMag(style, phaseOn: false, cycle: i) }
            Thread.sleep(forTimeInterval: off)
        }

        if keyboardEnabled, !owned, let kb { kb.set(b > 0.02 ? b : restoreLevel); if a { kb.enableAuto(true) } }
        if magsafeEnabled {
            if working { resetMagPattern(); updateMagPattern(force: true) }
            else { setMag("auto", force: true) }
        }
    }

    func keyboardValue(profile: SignalProfileConfig, elapsed: Double) -> Float {
        let lo = profile.keyboardLo
        let hi = profile.keyboardHi
        let period = max(profile.keyboardPeriod, 0.1)
        let phase = (elapsed / period).truncatingRemainder(dividingBy: 1.0)
        let unit: Double
        switch profile.keyboardPattern {
        case "steady":
            unit = 1
        case "triangle":
            unit = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        case "pulse":
            unit = pow(max(0, sin(Double.pi * phase)), 6)
        default:
            unit = 0.5 - 0.5 * cos(2 * Double.pi * phase)
        }
        return lo + (hi - lo) * Float(unit)
    }
    func recoverAfterCrash() {
        guard let s = try? String(contentsOfFile: origFile, encoding: .utf8) else { return }
        let parts = s.split(separator: " ")
        if let kb {
            kb.set(restoreLevel)
            if parts.count == 2, parts[1] == "true" { kb.enableAuto(true) }
            kb.suspendIdleDim(false)
        }
        setMag("auto", force: true)
        try? fm.removeItem(atPath: origFile)
        log("recovered outputs after unclean daemon exit")
    }
    func activeCount() -> Int {
        var n = 0
        for f in (try? fm.contentsOfDirectory(atPath: activeDir)) ?? [] {
            let p = activeDir + "/" + f
            guard let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { continue }
            let maxAge: TimeInterval = f == "_preview" ? 30 : staleSec
            if Date().timeIntervalSince(m) > maxAge { try? fm.removeItem(atPath: p); log("removed stale session \(f)") } else { n += 1 }
        }
        return n
    }
    func takeFlag(_ name: String) -> Bool {
        let p = stateDir + "/" + name
        guard fm.fileExists(atPath: p) else { return false }
        try? fm.removeItem(atPath: p); return true
    }
    func run() -> Never {
        try? fm.createDirectory(atPath: activeDir, withIntermediateDirectories: true)
        recoverAfterCrash()
        log("PhoSignal daemon started, keyboard ids \(kb?.ids.description ?? "unavailable"), userLevel \(userLevel.map { "\($0)" } ?? "unknown")")
        var idleTicks = 0
        while true {
            if gStop { if working { leave() }; log("received termination signal; exiting"); exit(0) }
            let off = fm.fileExists(atPath: stateDir + "/off")
            let n = activeCount()
            let pulse = takeFlag("pulse"), done = takeFlag("done")
            if off { if working { leave() }; usleep(500_000); continue }
            let profile = currentProfile()
            if pulse {
                blink(profile.approval.flashes, on: profile.approval.on, off: profile.approval.off,
                      keyboard: profile.approval.keyboard,
                      magsafeStyle: profile.approval.magsafe ? profile.approval.style : nil)
            }
            if done {
                blink(profile.done.flashes, on: profile.done.on, off: profile.done.off,
                      keyboard: profile.done.keyboard,
                      magsafeStyle: profile.done.magsafe ? profile.done.style : nil)
            }
            if n > 0 {
                if !working { enter() }
                let liveProfile = currentProfile()
                let t = Date().timeIntervalSince(t0)
                if keyboardOutputEnabled, let kb {
                    acquireKeyboardIfNeeded()
                    kb.set(keyboardValue(profile: liveProfile, elapsed: t))
                } else {
                    releaseKeyboardIfNeeded()
                }
                updateMagPattern()
                usleep(50_000)
            } else {
                if working { leave() }
                idleTicks += 1; if idleTicks % 7 == 0 { sampleUserLevel() }   // learn a safe user level every ~2s while idle
                usleep(300_000)
            }
        }
    }
}

// ---- CLI ----
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "status"
let kb = KB()
switch cmd {
case "daemon":
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .global()); s.setEventHandler { gStop = true }; s.resume(); return s
    }
    _ = sources
    SignalEngine(kb: kb).run()
case "get", "status":
    let ul = (try? String(contentsOfFile: userLevelFile, encoding: .utf8)) ?? "unknown"
    let g = SignalEngine(kb: kb); g.refreshBattery(force: true)
    let persistentMode = g.loadMode(force: true)
    let previewMode = g.previewMode()
    let mode = previewMode ?? persistentMode
    let rawOverride = fm.fileExists(atPath: rawStyleOverrideFile)
    let style = rawOverride ? g.loadMagsafeStyle(force: true) : defaultMagsafeStyle
    let keyboardEnabled = !fm.fileExists(atPath: keyboardOffFile)
    let magsafeEnabled = !fm.fileExists(atPath: magsafeOffFile)
    let store = g.loadProfileStore(force: true)
    let profile = SignalProfiles.profile(for: mode, store: store)
    let requested = rawOverride ? style : g.activeAgentStyle(profile: profile)
    let effective = !magsafeEnabled ? "system" : g.resolveProfileStyle(requested, profile: profile)
    let previewTag = previewMode.map { _ in " [PREVIEW \(g.previewSource() ?? "default")]" } ?? ""
    if let kb {
        print("keyboard=\(kb.brightness)  auto=\(kb.autoEnabled)  suppressed=\(kb.suppressed)  dimmed=\(kb.dimmed)  rememberedUserLevel=\(ul)")
    } else {
        print("keyboard=unavailable  rememberedUserLevel=\(ul)")
    }
    print("mode=\(mode)\(previewTag)  MagSafe=\(effective)\(rawOverride && magsafeEnabled ? " [DEBUG override \(style)]" : "")  battery=\(g.batteryPercent)% charged=\(g.batteryCharged) AC=\(g.batteryOnAC)")
    let off = fm.fileExists(atPath: stateDir + "/off")
    print("outputs keyboard=\(keyboardEnabled ? "on" : "OFF")  MagSafe=\(magsafeEnabled ? "on" : "OFF")")
    let act = ((try? fm.contentsOfDirectory(atPath: activeDir)) ?? []).map { f -> String in
        let m = ((try? fm.attributesOfItem(atPath: activeDir + "/" + f))?[.modificationDate] as? Date) ?? Date()
        return "\(f)(\(Int(Date().timeIntervalSince(m)))s)"
    }
    print("master=\(off ? "OFF" : "on")  activeSessions=\(act.isEmpty ? "none" : act.joined(separator: " "))")
case "on": try? fm.removeItem(atPath: stateDir + "/off"); print("on")
case "off": fm.createFile(atPath: stateDir + "/off", contents: nil); print("off (daemon will restore outputs)")
case "output":
    let channels = ["keyboard": keyboardOffFile, "magsafe": magsafeOffFile]
    if args.count <= 2 {
        print("keyboard \(fm.fileExists(atPath: keyboardOffFile) ? "off" : "on")")
        print("magsafe \(fm.fileExists(atPath: magsafeOffFile) ? "off" : "on")")
    } else {
        let channel = args[2].lowercased()
        guard let flag = channels[channel] else {
            print("unknown output \(channel); choices: keyboard magsafe"); exit(2)
        }
        if args.count <= 3 {
            print("\(channel) \(fm.fileExists(atPath: flag) ? "off" : "on")")
        } else {
            let state = args[3].lowercased()
            guard state == "on" || state == "off" else {
                print("state must be on or off"); exit(2)
            }
            try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            if state == "on" { try? fm.removeItem(atPath: flag) }
            else { fm.createFile(atPath: flag, contents: nil) }
            print("\(channel) → \(state)")
        }
    }
case "mode":
    if args.count <= 2 {
        let raw = ((try? String(contentsOfFile: modeFile, encoding: .utf8)) ?? defaultMode).trimmingCharacters(in: .whitespacesAndNewlines)
        print("mode: \(validModes.contains(raw) ? raw : defaultMode)")
        print("choices: \(validModes.sorted().joined(separator: " "))")
    } else {
        let mode = args[2]
        guard validModes.contains(mode) else {
            print("unknown mode \(mode); choices: \(validModes.sorted().joined(separator: " "))"); exit(2)
        }
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try? (mode + "\n").write(toFile: modeFile, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: rawStyleOverrideFile)
        print("mode → \(mode) (debug override cleared)")
    }
case "style":
    if args.count <= 2 {
        let raw = ((try? String(contentsOfFile: magsafeStyleFile, encoding: .utf8)) ?? defaultMagsafeStyle).trimmingCharacters(in: .whitespacesAndNewlines)
        print("DEBUG MagSafe style: \(validMagsafeStyles.contains(raw) ? raw : defaultMagsafeStyle)  override=\(fm.fileExists(atPath: rawStyleOverrideFile))")
        print("choices: clear \(validMagsafeStyles.sorted().joined(separator: " "))")
    } else {
        let style = args[2]
        if style == "clear" {
            try? fm.removeItem(atPath: rawStyleOverrideFile)
            print("DEBUG MagSafe override cleared")
        } else {
            guard validMagsafeStyles.contains(style) else {
                print("unknown style \(style); choices: \(validMagsafeStyles.sorted().joined(separator: " "))"); exit(2)
            }
            try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try? (style + "\n").write(toFile: magsafeStyleFile, atomically: true, encoding: .utf8)
            fm.createFile(atPath: rawStyleOverrideFile, contents: nil)
            print("DEBUG MagSafe style → \(style) (temporary mode override)")
        }
    }
case "set":
    guard args.count > 2, let v = Float(args[2]) else { print("phosignal set <0-1>"); exit(2) }
    guard let kb else { print("keyboard backlight unavailable"); exit(3) }
    kb.enableAuto(false); kb.set(v); print("set \(v) -> readback \(kb.brightness)")
case "flash":
    let n = args.count > 2 ? Int(args[2]) ?? 2 : 2
    SignalEngine(kb: kb).blink(n, on: 0.15, off: 0.12)
case "ui":
    guard args.count > 2 else {
        print("phosignal ui <show|accessibility>"); exit(2)
    }
    switch args[2] {
    case "show":
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.github.hanpuli.phosignal.show"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        print("UI show request sent")
    case "accessibility":
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("io.github.hanpuli.phosignal.requestAccessibility"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        print("Accessibility request sent")
    default:
        print("unknown UI action \(args[2]); choices: show accessibility"); exit(2)
    }
case "doctor":
    var failures: [String] = []
    print("PhoSignal doctor")
    print("state: \(stateDir)")
    if let kb {
        print("keyboard: ok ids=\(kb.ids)")
    } else {
        print("keyboard: unavailable (MagSafe-only operation remains possible)")
    }
    if fm.isExecutableFile(atPath: magsafeBin) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", magsafeBin, "read"]
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run(); p.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if p.terminationStatus == 0 { print("magsafe: ok \(text)") }
            else { print("magsafe: helper present but not authorised (\(text))"); failures.append("magsafe") }
        } catch {
            print("magsafe: helper execution failed \(error)"); failures.append("magsafe")
        }
    } else {
        print("magsafe: helper missing at \(magsafeBin)"); failures.append("magsafe")
    }
    let store = SignalProfiles.load()
    print("profiles: ok version=\(store.version) revision=\(store.revision)")
    let service = "gui/\(getuid())/io.github.hanpuli.phosignal.daemon"
    let lp = Process()
    let lpipe = Pipe()
    lp.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    lp.arguments = ["print", service]
    lp.standardOutput = lpipe
    lp.standardError = FileHandle.nullDevice
    do {
        try lp.run(); lp.waitUntilExit()
        let text = String(data: lpipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if text.contains("state = running") { print("daemon: running") }
        else { print("daemon: not running"); failures.append("daemon") }
    } catch {
        print("daemon: launchctl check failed"); failures.append("daemon")
    }
    if failures.isEmpty { print("doctor: PASS") }
    else { print("doctor: FAIL [\(failures.joined(separator: ","))]"); exit(1) }
case "profiles":
    if args.count > 2, args[2] == "init" {
        if fm.fileExists(atPath: signalProfileStoreFile) {
            let existing = SignalProfiles.load()
            print("profiles already exist revision=\(existing.revision)")
        } else {
            do {
                let saved = try SignalProfiles.save(SignalProfiles.defaultStore())
                print("profiles initialised revision=\(saved.revision) custom=\(saved.activeCustomPreset)")
            } catch {
                print("profiles init failed: \(error)"); exit(1)
            }
        }
    } else {
        let store = SignalProfiles.load()
        let changed = signalBuiltInModeIDs.filter { SignalProfiles.isCustomized($0, store: store) }
        print("profiles revision=\(store.revision) file=\(signalProfileStoreFile)")
        print("built-ins customized: \(changed.isEmpty ? "none" : changed.joined(separator: ","))")
        print("custom active=\(store.activeCustomPreset) count=\(store.customPresets.count)")
    }
case "preview":
    guard args.count >= 4 else {
        print("phosignal preview <mode> <default|chatgpt|codex|claude|other|concurrent> [seconds]"); exit(2)
    }
    let mode = args[2]
    let source = args[3]
    let sources = ["default", "chatgpt", "codex", "claude", "other", "concurrent"]
    guard validModes.contains(mode), sources.contains(source) else {
        print("invalid preview arguments"); exit(2)
    }
    let sec = args.count > 4 ? min(max(Double(args[4]) ?? 5, 0.5), 30) : 5
    try? fm.createDirectory(atPath: activeDir, withIntermediateDirectories: true)
    try? (mode + "\n").write(toFile: previewModeFile, atomically: true, encoding: .utf8)
    try? (source + "\n").write(toFile: previewSourceFile, atomically: true, encoding: .utf8)
    fm.createFile(atPath: previewMarkerFile, contents: nil)
    print("preview \(mode)/\(source) \(sec)s …")
    Thread.sleep(forTimeInterval: sec)
    try? fm.removeItem(atPath: previewMarkerFile)
    try? fm.removeItem(atPath: previewModeFile)
    try? fm.removeItem(atPath: previewSourceFile)
    print("preview finished")
case "preview-event":
    guard args.count >= 4 else {
        print("phosignal preview-event <mode> <approval|done>"); exit(2)
    }
    let mode = args[2]
    let event = args[3]
    guard validModes.contains(mode), event == "approval" || event == "done" else {
        print("invalid preview-event arguments"); exit(2)
    }
    try? fm.createDirectory(atPath: activeDir, withIntermediateDirectories: true)
    try? (mode + "\n").write(toFile: previewModeFile, atomically: true, encoding: .utf8)
    try? ("default\n").write(toFile: previewSourceFile, atomically: true, encoding: .utf8)
    fm.createFile(atPath: previewMarkerFile, contents: nil)
    Thread.sleep(forTimeInterval: 0.4)
    fm.createFile(atPath: stateDir + "/" + (event == "approval" ? "pulse" : "done"), contents: nil)
    let profile = SignalProfiles.profile(for: mode)
    let config = event == "approval" ? profile.approval : profile.done
    let duration = min(max(Double(config.flashes) * (config.on + config.off) + 0.8, 1.0), 12.0)
    print("preview event \(mode)/\(event) …")
    Thread.sleep(forTimeInterval: duration)
    try? fm.removeItem(atPath: previewMarkerFile)
    try? fm.removeItem(atPath: previewModeFile)
    try? fm.removeItem(atPath: previewSourceFile)
    print("event preview finished")
case "test":
    let sec = args.count > 2 ? Double(args[2]) ?? 6 : 6
    try? fm.createDirectory(atPath: activeDir, withIntermediateDirectories: true)
    fm.createFile(atPath: activeDir + "/_test", contents: nil)
    print("simulating active session for \(sec)s …"); Thread.sleep(forTimeInterval: sec)
    try? fm.removeItem(atPath: activeDir + "/_test"); fm.createFile(atPath: stateDir + "/done", contents: nil)
    print("simulation complete (current completion feedback queued)")
default:
    print("usage: phosignal daemon | status | doctor | ui <show|accessibility> | profiles [init] | preview <mode> <source> [seconds] | preview-event <mode> <approval|done> | on | off | output [keyboard|magsafe] [on|off] | mode [smart|focus|agent|sprint|quiet|custom] | style [clear|adaptive|green-blink|traffic|amber-slow|amber-fast|green-breathe|amber-breathe|solid-green|solid-amber] | get | set <0-1> | flash [n] | test [seconds]"); exit(2)
}
