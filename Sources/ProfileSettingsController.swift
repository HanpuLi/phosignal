import AppKit
import Foundation

private let profileModeOptions: [(id: String, name: String)] = [
    ("smart", "Smart"),
    ("focus", "Focus"),
    ("agent", "Agent-aware"),
    ("sprint", "Sprint"),
    ("quiet", "Quiet"),
    ("custom", "Custom")
]

private let profileKeyboardPatternOptions: [(id: String, name: String)] = [
    ("breathe", "Smooth breathe"),
    ("triangle", "Triangle"),
    ("pulse", "Pulse"),
    ("steady", "Steady")
]

private let profileMagStyleOptions: [(id: String, name: String)] = [
    ("adaptive", "Battery adaptive"),
    ("green-blink", "Green blink"),
    ("traffic", "Green ⇄ amber (0.8s each)"),
    ("amber-slow", "Amber slow flash"),
    ("amber-fast", "Amber fast flash"),
    ("green-breathe", "Green breathe rhythm"),
    ("amber-breathe", "Amber breathe rhythm"),
    ("solid-green", "Solid green"),
    ("solid-amber", "Solid amber")
]

private let profileSourceStyleOptions: [(id: String, name: String)] =
    [("inherit", "Inherit profile default")] + profileMagStyleOptions

private let profilePreviewSourceOptions: [(id: String, name: String)] = [
    ("default", "Profile default"),
    ("chatgpt", "ChatGPT"),
    ("codex", "Codex"),
    ("claude", "Claude Code"),
    ("other", "Other agent"),
    ("concurrent", "Concurrent agents")
]

private func profileModeName(_ id: String) -> String {
    profileModeOptions.first(where: { $0.id == id })?.name ?? id
}

private func profilePatternName(_ id: String) -> String {
    profileKeyboardPatternOptions.first(where: { $0.id == id })?.name ?? id
}

private func profileMagName(_ id: String, source: Bool = false) -> String {
    let options = source ? profileSourceStyleOptions : profileMagStyleOptions
    return options.first(where: { $0.id == id })?.name ?? id
}

private func modeSummary(_ mode: String) -> String {
    let store = SignalProfiles.load()
    let p = SignalProfiles.profile(for: mode, store: store)
    let state: String
    if mode == "custom" {
        state = store.activeCustomPreset
    } else {
        state = SignalProfiles.isCustomized(mode, store: store) ? "customised" : "default"
    }
    return "Keyboard \(Int(p.keyboardLo * 100))–\(Int(p.keyboardHi * 100))% · \(String(format: "%.1f", p.keyboardPeriod))s · \(profilePatternName(p.keyboardPattern)) · \(state)"
}

final class ProfileSettingsController: NSViewController {
    private var store = SignalProfiles.load()
    private(set) var editingMode: String
    private var isLoading = false
    private var dirty = false
    private var autosaveTimer: Timer?

    private let modePopup = NSPopUpButton()
    private let customRow = NSStackView()
    private let presetPopup = NSPopUpButton()
    private let nameField = NSTextField()

    private let patternPopup = NSPopUpButton()
    private let loSlider = NSSlider(value: 0.2, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let hiSlider = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let periodSlider = NSSlider(value: 3.2, minValue: 0.6, maxValue: 12, target: nil, action: nil)
    private let loValue = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let hiValue = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let periodValue = label("", size: 11, weight: .medium, color: .secondaryLabelColor)

    private var sourceStylePopups: [String: NSPopUpButton] = [:]
    private var baseStylePopups: [String: NSPopUpButton] = [:]

    private var eventKeyboard: [String: NSButton] = [:]
    private var eventMagsafe: [String: NSButton] = [:]
    private var eventStyle: [String: NSPopUpButton] = [:]
    private var eventFlashes: [String: NSStepper] = [:]
    private var eventFlashValue: [String: NSTextField] = [:]
    private var eventOn: [String: NSSlider] = [:]
    private var eventOff: [String: NSSlider] = [:]
    private var eventOnValue: [String: NSTextField] = [:]
    private var eventOffValue: [String: NSTextField] = [:]

    private let saveStatus = label("", size: 10.5, weight: .medium, color: .secondaryLabelColor)
    private let previewSourcePopup = NSPopUpButton()
    private var saveButton: NSButton!

    init(mode: String) {
        editingMode = signalValidModes.contains(mode) ? mode : "smart"
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 660))
        view = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 10
        heading.addArrangedSubview(label("Profile Settings", size: 18, weight: .semibold))
        heading.addArrangedSubview(NSView())
        heading.addArrangedSubview(saveStatus)
        heading.widthAnchor.constraint(equalToConstant: 664).isActive = true
        stack.addArrangedSubview(heading)

        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 10
        let modeTitle = label("Edit profile", size: 11.5, weight: .semibold)
        modeTitle.widthAnchor.constraint(equalToConstant: 82).isActive = true
        modePopup.addItems(withTitles: profileModeOptions.map { $0.name })
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        modeRow.addArrangedSubview(modeTitle)
        modeRow.addArrangedSubview(modePopup)
        let reset = smallButton("Reset profile", #selector(resetCurrentMode))
        reset.toolTip = "Reset only the profile currently being edited."
        modeRow.addArrangedSubview(reset)
        modeRow.addArrangedSubview(NSView())
        stack.addArrangedSubview(modeRow)
        modeRow.widthAnchor.constraint(equalToConstant: 664).isActive = true

        customRow.orientation = .horizontal
        customRow.alignment = .centerY
        customRow.spacing = 7
        let presetTitle = label("Custom preset", size: 11.5, weight: .semibold)
        presetTitle.widthAnchor.constraint(equalToConstant: 82).isActive = true
        customRow.addArrangedSubview(presetTitle)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        presetPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        customRow.addArrangedSubview(presetPopup)
        nameField.placeholderString = "Preset name"
        nameField.widthAnchor.constraint(equalToConstant: 155).isActive = true
        customRow.addArrangedSubview(nameField)
        customRow.addArrangedSubview(smallButton("Rename", #selector(renamePreset)))
        customRow.addArrangedSubview(smallButton("+", #selector(addPreset)))
        customRow.addArrangedSubview(smallButton("Duplicate", #selector(duplicatePreset)))
        customRow.addArrangedSubview(smallButton("Delete", #selector(deletePreset)))
        customRow.widthAnchor.constraint(equalToConstant: 664).isActive = true
        stack.addArrangedSubview(customRow)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(equalToConstant: 664).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: 455).isActive = true

        let keyboardTab = NSTabViewItem(identifier: "keyboard")
        keyboardTab.label = "Keyboard"
        keyboardTab.view = makeKeyboardTab()
        tabs.addTabViewItem(keyboardTab)

        let magsafeTab = NSTabViewItem(identifier: "magsafe")
        magsafeTab.label = "MagSafe"
        magsafeTab.view = makeMagsafeTab()
        tabs.addTabViewItem(magsafeTab)

        let eventTab = NSTabViewItem(identifier: "events")
        eventTab.label = "Events"
        eventTab.view = makeEventsTab()
        tabs.addTabViewItem(eventTab)
        stack.addArrangedSubview(tabs)

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        let note = label("Changes autosave about 0.55s after editing stops. You can also save explicitly.", size: 10.5, color: .secondaryLabelColor)
        bottom.addArrangedSubview(note)
        bottom.addArrangedSubview(NSView())

        previewSourcePopup.addItems(withTitles: profilePreviewSourceOptions.map { $0.name })
        previewSourcePopup.widthAnchor.constraint(equalToConstant: 142).isActive = true
        bottom.addArrangedSubview(previewSourcePopup)

        let preview = smallButton("Preview 5s", #selector(previewWork))
        preview.image = systemImage("play.fill", size: 11, weight: .medium)
        preview.imagePosition = .imageLeading
        bottom.addArrangedSubview(preview)

        saveButton = smallButton("Save", #selector(savePressed))
        saveButton.keyEquivalent = "\r"
        bottom.addArrangedSubview(saveButton)
        bottom.widthAnchor.constraint(equalToConstant: 664).isActive = true
        stack.addArrangedSubview(bottom)

        reloadModeMenu()
        reloadPresetMenu()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadControls()
    }

    override func viewWillDisappear() {
        flushAutosave()
        super.viewWillDisappear()
    }

    deinit { autosaveTimer?.invalidate() }

    func selectMode(_ mode: String) {
        guard signalValidModes.contains(mode) else { return }
        if isViewLoaded {
            flushAutosave()
            editingMode = mode
            reloadModeMenu()
            reloadPresetMenu()
            loadControls()
        } else {
            editingMode = mode
        }
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func makePopup(_ options: [(id: String, name: String)]) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: options.map { $0.name })
        p.target = self
        p.action = #selector(controlChanged(_:))
        return p
    }

    private func select(_ popup: NSPopUpButton, id: String, options: [(id: String, name: String)]) {
        popup.selectItem(at: options.firstIndex(where: { $0.id == id }) ?? 0)
    }

    private func selectedID(_ popup: NSPopUpButton, options: [(id: String, name: String)]) -> String {
        let i = max(0, min(popup.indexOfSelectedItem, options.count - 1))
        return options[i].id
    }

    private func sliderRow(_ title: String, slider: NSSlider, value: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let titleField = label(title, size: 11.5)
        titleField.widthAnchor.constraint(equalToConstant: 112).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 425).isActive = true
        slider.target = self
        slider.action = #selector(controlChanged(_:))
        slider.isContinuous = true
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 64).isActive = true
        row.addArrangedSubview(titleField)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return row
    }

    private func makeKeyboardTab() -> NSView {
        let root = NSView()
        let stack = tabStack(in: root)

        let intro = wrappingLabel(
            "Keyboard output uses continuous brightness. Min/max set the range; period and curve set the motion.",
            size: 11, color: .secondaryLabelColor, lines: 2
        )
        intro.widthAnchor.constraint(equalToConstant: 610).isActive = true
        stack.addArrangedSubview(intro)

        let patternRow = NSStackView()
        patternRow.orientation = .horizontal
        patternRow.alignment = .centerY
        patternRow.spacing = 10
        let pTitle = label("Curve", size: 11.5)
        pTitle.widthAnchor.constraint(equalToConstant: 112).isActive = true
        patternPopup.addItems(withTitles: profileKeyboardPatternOptions.map { $0.name })
        patternPopup.target = self
        patternPopup.action = #selector(controlChanged(_:))
        patternPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        patternRow.addArrangedSubview(pTitle)
        patternRow.addArrangedSubview(patternPopup)
        stack.addArrangedSubview(patternRow)

        stack.addArrangedSubview(sliderRow("Minimum brightness", slider: loSlider, value: loValue))
        stack.addArrangedSubview(sliderRow("Maximum brightness", slider: hiSlider, value: hiValue))
        stack.addArrangedSubview(sliderRow("Period", slider: periodSlider, value: periodValue))

        let hint = wrappingLabel(
            "Smooth breathe uses a cosine curve; triangle ramps evenly; pulse peaks briefly; steady stays at maximum.",
            size: 10.5, color: .tertiaryLabelColor, lines: 2
        )
        hint.widthAnchor.constraint(equalToConstant: 610).isActive = true
        stack.addArrangedSubview(hint)
        return root
    }

    private func tabStack(in root: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor)
        ])
        return stack
    }

    private func styleRow(_ title: String, key: String, source: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let t = label(title, size: 11.5)
        t.widthAnchor.constraint(equalToConstant: 165).isActive = true
        let options = source ? profileSourceStyleOptions : profileMagStyleOptions
        let p = makePopup(options)
        p.widthAnchor.constraint(equalToConstant: 270).isActive = true
        if source { sourceStylePopups[key] = p } else { baseStylePopups[key] = p }
        row.addArrangedSubview(t)
        row.addArrangedSubview(p)
        return row
    }

    private func makeMagsafeTab() -> NSView {
        let root = NSView()
        let stack = tabStack(in: root)
        stack.spacing = 10

        let intro = wrappingLabel(
            "Each profile can override MagSafe by source. Inherit uses the full/not-full profile defaults below.",
            size: 11, color: .secondaryLabelColor, lines: 2
        )
        intro.widthAnchor.constraint(equalToConstant: 610).isActive = true
        stack.addArrangedSubview(intro)

        stack.addArrangedSubview(styleRow("ChatGPT", key: "chatgpt", source: true))
        stack.addArrangedSubview(styleRow("Codex", key: "codex", source: true))
        stack.addArrangedSubview(styleRow("Claude Code", key: "claude", source: true))
        stack.addArrangedSubview(styleRow("Other agent", key: "otherAgent", source: true))
        stack.addArrangedSubview(styleRow("Concurrent agents", key: "concurrent", source: true))
        stack.addArrangedSubview(styleRow("Profile default · full", key: "full", source: false))
        stack.addArrangedSubview(styleRow("Profile default · not full", key: "other", source: false))

        let note = wrappingLabel(
            "ACLC exposes discrete states, not continuous brightness. Breathe effects are timing patterns; green ⇄ amber holds stable 03/04 states for 0.8s each.",
            size: 10.5, color: .tertiaryLabelColor, lines: 2
        )
        note.widthAnchor.constraint(equalToConstant: 610).isActive = true
        stack.addArrangedSubview(note)
        return root
    }

    private func eventSection(_ title: String, key: String) -> NSView {
        let box = NSBox()
        box.title = title
        box.boxType = .primary

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let c = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: c.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                stack.topAnchor.constraint(equalTo: c.topAnchor),
                stack.bottomAnchor.constraint(equalTo: c.bottomAnchor)
            ])
        }

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 14
        let kb = NSButton(checkboxWithTitle: "Keyboard", target: self, action: #selector(controlChanged(_:)))
        let mag = NSButton(checkboxWithTitle: "MagSafe", target: self, action: #selector(controlChanged(_:)))
        eventKeyboard[key] = kb
        eventMagsafe[key] = mag
        top.addArrangedSubview(kb)
        top.addArrangedSubview(mag)
        top.addArrangedSubview(label("MagSafe style", size: 10.5, color: .secondaryLabelColor))
        let style = makePopup(profileMagStyleOptions)
        style.widthAnchor.constraint(equalToConstant: 210).isActive = true
        eventStyle[key] = style
        top.addArrangedSubview(style)
        stack.addArrangedSubview(top)

        let timing = NSStackView()
        timing.orientation = .horizontal
        timing.alignment = .centerY
        timing.spacing = 7

        let flashes = NSStepper()
        flashes.minValue = 1
        flashes.maxValue = 12
        flashes.increment = 1
        flashes.target = self
        flashes.action = #selector(controlChanged(_:))
        eventFlashes[key] = flashes
        let flashValue = label("", size: 11, weight: .medium)
        flashValue.widthAnchor.constraint(equalToConstant: 25).isActive = true
        eventFlashValue[key] = flashValue
        timing.addArrangedSubview(label("Flashes", size: 10.5, color: .secondaryLabelColor))
        timing.addArrangedSubview(flashes)
        timing.addArrangedSubview(flashValue)

        let on = NSSlider(value: 0.15, minValue: 0.05, maxValue: 1.5, target: self, action: #selector(controlChanged(_:)))
        let off = NSSlider(value: 0.15, minValue: 0.05, maxValue: 1.5, target: self, action: #selector(controlChanged(_:)))
        on.isContinuous = true
        off.isContinuous = true
        on.widthAnchor.constraint(equalToConstant: 120).isActive = true
        off.widthAnchor.constraint(equalToConstant: 120).isActive = true
        eventOn[key] = on
        eventOff[key] = off

        let onValue = label("", size: 10.5, color: .secondaryLabelColor)
        let offValue = label("", size: 10.5, color: .secondaryLabelColor)
        onValue.widthAnchor.constraint(equalToConstant: 43).isActive = true
        offValue.widthAnchor.constraint(equalToConstant: 43).isActive = true
        eventOnValue[key] = onValue
        eventOffValue[key] = offValue

        timing.addArrangedSubview(label("On", size: 10.5, color: .secondaryLabelColor))
        timing.addArrangedSubview(on)
        timing.addArrangedSubview(onValue)
        timing.addArrangedSubview(label("Off", size: 10.5, color: .secondaryLabelColor))
        timing.addArrangedSubview(off)
        timing.addArrangedSubview(offValue)
        stack.addArrangedSubview(timing)

        let test = smallButton(key == "approval" ? "Test attention" : "Test done", key == "approval" ? #selector(previewApproval) : #selector(previewDone))
        stack.addArrangedSubview(test)

        box.widthAnchor.constraint(equalToConstant: 615).isActive = true
        box.heightAnchor.constraint(equalToConstant: 160).isActive = true
        return box
    }

    private func makeEventsTab() -> NSView {
        let root = NSView()
        let stack = tabStack(in: root)
        stack.addArrangedSubview(eventSection("Attention / approval", key: "approval"))
        stack.addArrangedSubview(eventSection("Completion / done", key: "done"))
        return root
    }

    private func reloadModeMenu() {
        modePopup.removeAllItems()
        modePopup.addItems(withTitles: profileModeOptions.map { $0.name })
        modePopup.selectItem(at: profileModeOptions.firstIndex(where: { $0.id == editingMode }) ?? 0)
        customRow.isHidden = editingMode != "custom"
    }

    private func reloadPresetMenu() {
        presetPopup.removeAllItems()
        let names = store.customPresets.keys.sorted()
        presetPopup.addItems(withTitles: names)
        if let i = names.firstIndex(of: store.activeCustomPreset) {
            presetPopup.selectItem(at: i)
        }
        nameField.stringValue = store.activeCustomPreset
        customRow.isHidden = editingMode != "custom"
    }

    private func currentProfile() -> SignalProfileConfig {
        SignalProfiles.profile(for: editingMode, store: store)
    }

    private func loadControls() {
        isLoading = true
        defer {
            isLoading = false
            dirty = false
        }

        store = SignalProfiles.load()
        reloadPresetMenu()
        let p = currentProfile()
        select(patternPopup, id: p.keyboardPattern, options: profileKeyboardPatternOptions)
        loSlider.floatValue = p.keyboardLo
        hiSlider.floatValue = p.keyboardHi
        periodSlider.doubleValue = p.keyboardPeriod

        let sources: [String: String] = [
            "chatgpt": p.chatgptStyle,
            "codex": p.codexStyle,
            "claude": p.claudeStyle,
            "otherAgent": p.otherAgentStyle,
            "concurrent": p.concurrentStyle
        ]
        for (key, id) in sources {
            if let popup = sourceStylePopups[key] {
                select(popup, id: id, options: profileSourceStyleOptions)
            }
        }

        if let p1 = baseStylePopups["full"] { select(p1, id: p.fullStyle, options: profileMagStyleOptions) }
        if let p2 = baseStylePopups["other"] { select(p2, id: p.otherStyle, options: profileMagStyleOptions) }

        loadEvent(p.approval, key: "approval")
        loadEvent(p.done, key: "done")
        updateValueLabels()
        updateSaveStatus(saved: true)
    }

    private func loadEvent(_ event: SignalEventConfig, key: String) {
        eventKeyboard[key]?.state = event.keyboard ? .on : .off
        eventMagsafe[key]?.state = event.magsafe ? .on : .off
        if let p = eventStyle[key] { select(p, id: event.style, options: profileMagStyleOptions) }
        eventFlashes[key]?.integerValue = event.flashes
        eventOn[key]?.doubleValue = event.on
        eventOff[key]?.doubleValue = event.off
    }

    private func readEvent(_ key: String, fallback: SignalEventConfig) -> SignalEventConfig {
        SignalEventConfig(
            flashes: min(max(eventFlashes[key]?.integerValue ?? fallback.flashes, 1), 12),
            on: min(max(eventOn[key]?.doubleValue ?? fallback.on, 0.05), 1.5),
            off: min(max(eventOff[key]?.doubleValue ?? fallback.off, 0.05), 1.5),
            keyboard: eventKeyboard[key]?.state == .on,
            magsafe: eventMagsafe[key]?.state == .on,
            style: eventStyle[key].map { selectedID($0, options: profileMagStyleOptions) } ?? fallback.style
        )
    }

    private func profileFromControls() -> SignalProfileConfig {
        let old = currentProfile()
        return SignalProfileConfig(
            keyboardLo: Float(loSlider.doubleValue),
            keyboardHi: Float(hiSlider.doubleValue),
            keyboardPeriod: periodSlider.doubleValue,
            keyboardPattern: selectedID(patternPopup, options: profileKeyboardPatternOptions),
            fullStyle: baseStylePopups["full"].map { selectedID($0, options: profileMagStyleOptions) } ?? old.fullStyle,
            otherStyle: baseStylePopups["other"].map { selectedID($0, options: profileMagStyleOptions) } ?? old.otherStyle,
            chatgptStyle: sourceStylePopups["chatgpt"].map { selectedID($0, options: profileSourceStyleOptions) } ?? old.chatgptStyle,
            codexStyle: sourceStylePopups["codex"].map { selectedID($0, options: profileSourceStyleOptions) } ?? old.codexStyle,
            claudeStyle: sourceStylePopups["claude"].map { selectedID($0, options: profileSourceStyleOptions) } ?? old.claudeStyle,
            otherAgentStyle: sourceStylePopups["otherAgent"].map { selectedID($0, options: profileSourceStyleOptions) } ?? old.otherAgentStyle,
            concurrentStyle: sourceStylePopups["concurrent"].map { selectedID($0, options: profileSourceStyleOptions) } ?? old.concurrentStyle,
            approval: readEvent("approval", fallback: old.approval),
            done: readEvent("done", fallback: old.done)
        ).sanitized(fallback: SignalProfiles.factoryProfile(for: editingMode))
    }

    private func updateValueLabels() {
        loValue.stringValue = "\(Int(loSlider.doubleValue * 100))%"
        hiValue.stringValue = "\(Int(hiSlider.doubleValue * 100))%"
        periodValue.stringValue = String(format: "%.1fs", periodSlider.doubleValue)
        for key in ["approval", "done"] {
            eventFlashValue[key]?.stringValue = "\(eventFlashes[key]?.integerValue ?? 0)"
            eventOnValue[key]?.stringValue = String(format: "%.2fs", eventOn[key]?.doubleValue ?? 0)
            eventOffValue[key]?.stringValue = String(format: "%.2fs", eventOff[key]?.doubleValue ?? 0)
        }
    }

    private func updateSaveStatus(saved: Bool, error: String? = nil) {
        if let error {
            saveStatus.stringValue = "Save failed · \(error)"
            saveStatus.textColor = .systemRed
            saveButton.isEnabled = true
            return
        }
        saveStatus.textColor = saved ? .secondaryLabelColor : .systemOrange
        saveStatus.stringValue = saved ? "Saved · revision \(store.revision)" : "Unsaved changes"
        saveButton.isEnabled = !saved
    }

    private func scheduleAutosave() {
        guard !isLoading else { return }
        dirty = true
        updateValueLabels()
        updateSaveStatus(saved: false)
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            self?.saveDraft()
        }
    }

    private func flushAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        if dirty { saveDraft() }
    }

    private func saveDraft() {
        guard !isLoading else { return }
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        let p = profileFromControls()
        if editingMode == "custom" {
            store.customPresets[store.activeCustomPreset] = p
        } else {
            store.builtIns[editingMode] = p
        }
        do {
            store = try SignalProfiles.save(store)
            dirty = false
            updateSaveStatus(saved: true)
            appLog("profile saved mode=\(editingMode) revision=\(store.revision)")
        } catch {
            dirty = true
            updateSaveStatus(saved: false, error: error.localizedDescription)
            appLog("profile save FAILED mode=\(editingMode): \(error)")
        }
    }

    private func persistStoreSelection() {
        do {
            store = try SignalProfiles.save(store)
            updateSaveStatus(saved: true)
        } catch {
            updateSaveStatus(saved: false, error: error.localizedDescription)
        }
    }

    @objc private func controlChanged(_ sender: NSControl) {
        if sender === loSlider, loSlider.doubleValue > hiSlider.doubleValue {
            hiSlider.doubleValue = loSlider.doubleValue
        } else if sender === hiSlider, hiSlider.doubleValue < loSlider.doubleValue {
            loSlider.doubleValue = hiSlider.doubleValue
        }
        scheduleAutosave()
    }

    @objc private func savePressed() { saveDraft() }

    @objc private func modeChanged() {
        flushAutosave()
        let i = max(0, min(modePopup.indexOfSelectedItem, profileModeOptions.count - 1))
        editingMode = profileModeOptions[i].id
        reloadModeMenu()
        reloadPresetMenu()
        loadControls()
    }

    @objc private func presetChanged() {
        flushAutosave()
        guard let name = presetPopup.titleOfSelectedItem, store.customPresets[name] != nil else { return }
        store.activeCustomPreset = name
        persistStoreSelection()
        loadControls()
    }

    @objc private func addPreset() {
        flushAutosave()
        let name = SignalProfiles.uniquePresetName("Custom", store: store)
        store.customPresets[name] = SignalProfiles.custom
        store.activeCustomPreset = name
        persistStoreSelection()
        reloadPresetMenu()
        loadControls()
    }

    @objc private func duplicatePreset() {
        flushAutosave()
        let name = SignalProfiles.uniquePresetName("\(store.activeCustomPreset) copy", store: store)
        store.customPresets[name] = currentProfile()
        store.activeCustomPreset = name
        persistStoreSelection()
        reloadPresetMenu()
        loadControls()
    }

    @objc private func renamePreset() {
        flushAutosave()
        let desired = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desired.isEmpty, desired != store.activeCustomPreset else {
            nameField.stringValue = store.activeCustomPreset
            return
        }
        guard store.customPresets[desired] == nil,
              let p = store.customPresets.removeValue(forKey: store.activeCustomPreset) else {
            NSSound.beep()
            nameField.stringValue = store.activeCustomPreset
            return
        }
        store.customPresets[desired] = p
        store.activeCustomPreset = desired
        persistStoreSelection()
        reloadPresetMenu()
    }

    @objc private func deletePreset() {
        flushAutosave()
        guard store.customPresets.count > 1 else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete preset “\(store.activeCustomPreset)”?"
        alert.informativeText = "This permanently deletes this custom preset."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.customPresets.removeValue(forKey: store.activeCustomPreset)
        store.activeCustomPreset = store.customPresets.keys.sorted().first ?? "My Preset"
        persistStoreSelection()
        reloadPresetMenu()
        loadControls()
    }

    @objc private func resetCurrentMode() {
        flushAutosave()
        let name = profileModeName(editingMode)
        let alert = NSAlert()
        alert.messageText = "Reset “\(name)” to defaults?"
        alert.informativeText = editingMode == "custom"
            ? "Only this custom preset will be reset. Other presets are unchanged."
            : "Only this built-in profile is reset. Other profiles are unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if editingMode == "custom" {
            store.customPresets[store.activeCustomPreset] = SignalProfiles.custom
        } else {
            store.builtIns[editingMode] = SignalProfiles.factoryProfile(for: editingMode)
        }
        persistStoreSelection()
        loadControls()
        appLog("profile reset mode=\(editingMode)")
    }

    @objc private func previewWork() {
        flushAutosave()
        let i = max(0, min(previewSourcePopup.indexOfSelectedItem, profilePreviewSourceOptions.count - 1))
        let source = profilePreviewSourceOptions[i].id
        appLog("profile preview mode=\(editingMode) source=\(source)")
        _ = run(cliBin, ["preview", editingMode, source, "5"], wait: false)
    }

    @objc private func previewApproval() {
        flushAutosave()
        _ = run(cliBin, ["preview-event", editingMode, "approval"], wait: false)
    }

    @objc private func previewDone() {
        flushAutosave()
        _ = run(cliBin, ["preview-event", editingMode, "done"], wait: false)
    }
}
