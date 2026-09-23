import AppKit
import ApplicationServices
import Foundation
import Darwin

private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser.path
private let stateDir = signalStateDir
private let activeDir = stateDir + "/active"
private let modeFile = stateDir + "/mode"
private let styleFile = stateDir + "/magsafe-style"
private let rawOverrideFile = stateDir + "/raw-style-override"
private let offFile = stateDir + "/off"
private let keyboardOffFile = stateDir + "/keyboard-off"
private let magsafeOffFile = stateDir + "/magsafe-off"
private let pulseFile = stateDir + "/pulse"
private let doneFile = stateDir + "/done"
private let daemonLog = stateDir + "/daemon.log"
private let cliBin = stateDir + "/bin/phosignal"
private let loginPlist = home + "/Library/LaunchAgents/io.github.hanpuli.phosignal.ui.plist"
private let uiLog = stateDir + "/ui.log"

private func appLog(_ message: String) {
    try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    let line = f.string(from: Date()) + " " + message + "\n"
    if !fm.fileExists(atPath: uiLog) { fm.createFile(atPath: uiLog, contents: nil) }
    if let h = FileHandle(forWritingAtPath: uiLog) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}

struct SignalMode {
    let id: String
    let name: String
    let subtitle: String
    let detail: String
    let symbol: String
}

private let signalModes: [SignalMode] = [
    .init(
        id: "smart",
        name: "Smart",
        subtitle: "Battery-aware MagSafe, medium keyboard breathe, clear attention and completion flashes.",
        detail: "Keyboard 25–90% · 3.2s · full green blink / charging amber · attention ×4 · done ×2",
        symbol: "wand.and.stars"
    ),
    .init(
        id: "focus",
        name: "Focus",
        subtitle: "Slow, gentle keyboard breathe with a low-distraction MagSafe work rhythm.",
        detail: "Keyboard 14–62% · 5.4s · MagSafe breathe rhythm · attention ×4 · done ×2",
        symbol: "moon.stars.fill"
    ),
    .init(
        id: "agent",
        name: "Agent-aware",
        subtitle: "Differentiate ChatGPT, Codex and concurrent agents with source-aware MagSafe states.",
        detail: "Keyboard 22–82% · 3.6s · source-aware MagSafe · attention ×4 · done ×2",
        symbol: "person.2.wave.2.fill"
    ),
    .init(
        id: "sprint",
        name: "Sprint",
        subtitle: "Fast, bright keyboard breathe with stronger attention and completion feedback.",
        detail: "Keyboard 38–100% · 1.75s · green/amber alternate · attention ×6 · done ×3",
        symbol: "bolt.fill"
    ),
    .init(
        id: "quiet",
        name: "Quiet",
        subtitle: "Low, slow keyboard breathe with minimal persistent MagSafe flashing.",
        detail: "Keyboard 8–30% · 7.2s · steady charge colour · attention ×3 · done ×1",
        symbol: "speaker.slash.fill"
    ),
    .init(
        id: "custom",
        name: "Custom",
        subtitle: "Independent presets with editable keyboard, source and event behaviour.",
        detail: "Edit and preview in Profile Settings.",
        symbol: "slider.horizontal.3"
    )
]

struct RawStyle {
    let id: String
    let name: String
}

private let rawStyles: [RawStyle] = [
    .init(id: "adaptive", name: "Adaptive"),
    .init(id: "green-blink", name: "Green blink"),
    .init(id: "traffic", name: "Green ⇄ amber (0.8s)"),
    .init(id: "amber-slow", name: "Amber slow flash"),
    .init(id: "amber-fast", name: "Amber fast flash"),
    .init(id: "green-breathe", name: "Green breathe rhythm"),
    .init(id: "amber-breathe", name: "Amber breathe rhythm"),
    .init(id: "solid-green", name: "Solid green"),
    .init(id: "solid-amber", name: "Solid amber")
]

private func freshNullHandle() -> FileHandle? {
    FileHandle(forWritingAtPath: "/dev/null")
}

private func closePipe(_ pipe: Pipe) {
    try? pipe.fileHandleForReading.close()
    try? pipe.fileHandleForWriting.close()
}

@discardableResult
private func run(_ executable: String, _ args: [String], wait: Bool = true) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args

    if !wait {
        let stdout = freshNullHandle()
        let stderr = freshNullHandle()
        p.standardOutput = stdout
        p.standardError = stderr
        defer {
            try? stdout?.close()
            try? stderr?.close()
        }
        do {
            try p.run()
            return ""
        } catch {
            return ""
        }
    }

    let pipe = Pipe()
    let stderr = freshNullHandle()
    p.standardOutput = pipe
    p.standardError = stderr
    defer {
        closePipe(pipe)
        try? stderr?.close()
    }

    do {
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

private func systemImage(_ name: String, size: CGFloat = 16, weight: NSFont.Weight = .regular) -> NSImage? {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return img.withSymbolConfiguration(config)
}

private func templateSystemImage(_ name: String, size: CGFloat = 16, weight: NSFont.Weight = .regular) -> NSImage? {
    guard let img = systemImage(name, size: size, weight: weight)?.copy() as? NSImage else { return nil }
    img.isTemplate = true
    return img
}

private func label(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = NSFont.systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.lineBreakMode = .byTruncatingTail
    return f
}

private func wrappingLabel(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor,
    lines: Int = 2
) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text)
    f.font = NSFont.systemFont(ofSize: size, weight: weight)
    f.textColor = color
    f.maximumNumberOfLines = lines
    f.lineBreakMode = .byWordWrapping
    f.cell?.wraps = true
    f.cell?.isScrollable = false
    f.setContentCompressionResistancePriority(.required, for: .vertical)
    return f
}

final class CardHitButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ModeButton: NSControl {
    let modeID: String
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private let checkView = NSImageView()
    private let hitButton = CardHitButton(title: "", target: nil, action: nil)
    private var selectedState = false

    init(mode: SignalMode, target: AnyObject?, action: Selector?) {
        modeID = mode.id
        super.init(frame: .zero)

        self.target = target
        self.action = action
        focusRingType = .none
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 66).isActive = true

        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        iconView.image = systemImage(mode.symbol, size: 19, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = mode.name
        titleField.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byClipping
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.required, for: .vertical)

        subtitleField.stringValue = mode.subtitle
        subtitleField.font = NSFont.systemFont(ofSize: 10.5)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 2
        subtitleField.lineBreakMode = .byWordWrapping
        subtitleField.cell?.wraps = true
        subtitleField.cell?.isScrollable = false
        subtitleField.setContentCompressionResistancePriority(.required, for: .vertical)

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        checkView.image = systemImage("checkmark.circle.fill", size: 15, weight: .semibold)
        checkView.imageScaling = .scaleProportionallyDown
        checkView.translatesAutoresizingMaskIntoConstraints = false

        hitButton.isBordered = false
        hitButton.focusRingType = .none
        hitButton.setButtonType(.momentaryChange)
        hitButton.target = self
        hitButton.action = #selector(hitPressed(_:))
        hitButton.translatesAutoresizingMaskIntoConstraints = false
        hitButton.toolTip = mode.subtitle

        addSubview(iconView)
        addSubview(textStack)
        addSubview(checkView)
        addSubview(hitButton, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 11),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: checkView.leadingAnchor, constant: -9),

            checkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            checkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 16),
            checkView.heightAnchor.constraint(equalToConstant: 16),

            hitButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            hitButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            hitButton.topAnchor.constraint(equalTo: topAnchor),
            hitButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(mode.name)
        setAccessibilityHelp(mode.subtitle)
        updateSelected(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func hitPressed(_ sender: NSButton) {
        appLog("mode overlay click: \(modeID)")
        _ = sendAction(action, to: target)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let windowRect = self.convert(self.bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            appLog(
                "mode frame \(self.modeID): " +
                "x=\(Int(screenRect.minX)) y=\(Int(screenRect.minY)) " +
                "w=\(Int(screenRect.width)) h=\(Int(screenRect.height))"
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCardColors()
    }

    private func updateCardColors() {
        let accent = NSColor.controlAccentColor
        let base = selectedState
            ? accent.withAlphaComponent(0.24)
            : NSColor.labelColor.withAlphaComponent(0.035)
        let border = selectedState
            ? accent.withAlphaComponent(0.38)
            : NSColor.separatorColor.withAlphaComponent(0.16)

        layer?.backgroundColor = base.cgColor
        layer?.borderColor = border.cgColor
    }

    func updateSelected(_ selected: Bool) {
        selectedState = selected
        iconView.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        checkView.contentTintColor = .controlAccentColor
        checkView.isHidden = !selected
        updateCardColors()
    }
}

final class DebugPanelController: NSViewController {
    private var overrideLabel = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private var rawButtons: [NSButton] = []
    private var timer: Timer?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 475))
        view = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        stack.addArrangedSubview(label("Diagnostics & raw LED states", size: 17, weight: .semibold))
        let explain = wrappingLabel(
            "These controls temporarily override the active profile for low-level MagSafe visual testing. Selecting any normal profile clears the override.",
            size: 11,
            color: .secondaryLabelColor,
            lines: 3
        )
        stack.addArrangedSubview(explain)
        explain.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true

        stack.addArrangedSubview(overrideLabel)

        let grid = NSGridView()
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        for rowStart in stride(from: 0, to: rawStyles.count, by: 3) {
            var row: [NSView] = []
            for offset in 0..<3 {
                let index = rowStart + offset
                if index < rawStyles.count {
                    let raw = rawStyles[index]
                    let b = NSButton(title: raw.name, target: self, action: #selector(rawStylePressed(_:)))
                    b.bezelStyle = .rounded
                    b.controlSize = .regular
                    b.identifier = NSUserInterfaceItemIdentifier(raw.id)
                    b.widthAnchor.constraint(equalToConstant: 136).isActive = true
                    b.heightAnchor.constraint(equalToConstant: 34).isActive = true
                    rawButtons.append(b)
                    row.append(b)
                } else {
                    let empty = NSView()
                    empty.widthAnchor.constraint(equalToConstant: 136).isActive = true
                    row.append(empty)
                }
            }
            grid.addRow(with: row)
        }
        stack.addArrangedSubview(grid)

        let clear = NSButton(title: "Clear raw LED override", target: self, action: #selector(clearOverride))
        clear.bezelStyle = .rounded
        stack.addArrangedSubview(clear)

        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(label("Event previews", size: 13, weight: .semibold))
        let previewRow = NSStackView()
        previewRow.orientation = .horizontal
        previewRow.spacing = 8
        previewRow.addArrangedSubview(actionButton("Attention", "exclamationmark.bubble.fill", #selector(previewApproval)))
        previewRow.addArrangedSubview(actionButton("Done", "checkmark.circle.fill", #selector(previewDone)))
        previewRow.addArrangedSubview(actionButton("4s active preview", "keyboard", #selector(previewWork)))
        stack.addArrangedSubview(previewRow)

        stack.addArrangedSubview(separator())

        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 8
        tools.addArrangedSubview(actionButton("State folder", "folder", #selector(openStateDir)))
        tools.addArrangedSubview(actionButton("Daemon log", "doc.text", #selector(openDaemonLog)))
        tools.addArrangedSubview(actionButton("UI log", "doc.text.magnifyingglass", #selector(openUILog)))
        stack.addArrangedSubview(tools)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 434).isActive = true
        return b
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.image = systemImage(symbol, size: 12, weight: .medium)
        b.imagePosition = .imageLeading
        return b
    }

    func refresh() {
        let overridden = fm.fileExists(atPath: rawOverrideFile)
        let raw = ((try? String(contentsOfFile: styleFile, encoding: .utf8)) ?? "adaptive")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        overrideLabel.stringValue = overridden ? "Debug override: \(raw)" : "No debug override"
        for b in rawButtons {
            let selected = overridden && b.identifier?.rawValue == raw
            b.state = selected ? .on : .off
        }
    }

    @objc private func rawStylePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        _ = run(cliBin, ["style", id])
        refresh()
    }

    @objc private func clearOverride() {
        _ = run(cliBin, ["style", "clear"])
        refresh()
    }

    @objc private func previewApproval() {
        fm.createFile(atPath: pulseFile, contents: Data())
    }

    @objc private func previewDone() {
        fm.createFile(atPath: doneFile, contents: Data())
    }

    @objc private func previewWork() {
        _ = run(cliBin, ["test", "4"], wait: false)
    }

    @objc private func openStateDir() {
        NSWorkspace.shared.open(URL(fileURLWithPath: stateDir))
    }

    @objc private func openDaemonLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: daemonLog))
    }

    @objc private func openUILog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: uiLog))
    }
}

final class PanelController: NSViewController {
    private var statusIcon = NSImageView()
    private var statusTitle = label("Idle", size: 17, weight: .semibold)
    private var statusSubtitle = label("Waiting for agents", size: 11.5, color: .secondaryLabelColor)
    private var batteryLabel = label("—", size: 17, weight: .semibold)
    private var batterySub = label("Battery", size: 10.5, color: .secondaryLabelColor)
    private var enabledSwitch = NSSwitch()
    private var keyboardSwitch = NSSwitch()
    private var magsafeSwitch = NSSwitch()
    private var sourcesLabel = label("", size: 11.5, weight: .medium, color: .secondaryLabelColor)
    private var currentModeLabel = label("", size: 10.5, color: .secondaryLabelColor)
    private var modeDetailLabel = wrappingLabel("", size: 10.5, color: .secondaryLabelColor, lines: 2)
    private var accessibilityLabel = label("", size: 10.5, color: .secondaryLabelColor)
    private var loginSwitch = NSSwitch()
    private var modeButtons: [ModeButton] = []
    private var timer: Timer?
    private var batteryPercent = 0
    private var batteryCharged = false
    private var batteryOnAC = false
    private var selectedMode = "smart"
    private var lastBatteryRefresh = Date.distantPast
    private var lastDaemonHealthRefresh = Date.distantPast
    private var daemonHealthy = true

    var onStatusChange: ((Bool, Bool, Bool) -> Void)?
    var onDebugRequested: (() -> Void)?
    var onSettingsRequested: ((String) -> Void)?
    var onAccessibilityRequested: (() -> Void)?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 452),
            root.heightAnchor.constraint(equalToConstant: 795)
        ])

        let header = makeHeader()
        content.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

        let masterRow = NSStackView()
        masterRow.orientation = .horizontal
        masterRow.alignment = .centerY
        masterRow.spacing = 10

        let masterText = NSStackView()
        masterText.orientation = .vertical
        masterText.alignment = .leading
        masterText.spacing = 3

        let masterTitle = label("PhoSignal", size: 14, weight: .semibold)
        masterTitle.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true

        let masterDescription = label(
            "Physical status follows ChatGPT / Codex / Claude Code",
            size: 10.5,
            color: .secondaryLabelColor
        )
        masterDescription.lineBreakMode = .byClipping
        masterDescription.heightAnchor.constraint(greaterThanOrEqualToConstant: 17).isActive = true

        masterText.addArrangedSubview(masterTitle)
        masterText.addArrangedSubview(masterDescription)

        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        masterRow.addArrangedSubview(masterText)
        masterRow.addArrangedSubview(NSView())
        masterRow.addArrangedSubview(enabledSwitch)
        content.addArrangedSubview(masterRow)
        masterRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

        sourcesLabel.maximumNumberOfLines = 1
        content.addArrangedSubview(sourcesLabel)

        let outputRow = NSStackView()
        outputRow.orientation = .horizontal
        outputRow.alignment = .centerY
        outputRow.spacing = 7
        outputRow.addArrangedSubview(label("Outputs", size: 11.5, weight: .semibold))
        outputRow.addArrangedSubview(NSView())

        let keyboardText = label("Keyboard", size: 10.5, color: .secondaryLabelColor)
        keyboardSwitch.controlSize = .small
        keyboardSwitch.target = self
        keyboardSwitch.action = #selector(toggleKeyboardOutput)
        keyboardSwitch.toolTip = "Disable keyboard control while source detection continues."
        keyboardSwitch.setAccessibilityLabel("KeyboardOutputs")
        outputRow.addArrangedSubview(keyboardText)
        outputRow.addArrangedSubview(keyboardSwitch)

        let magsafeText = label("MagSafe", size: 10.5, color: .secondaryLabelColor)
        magsafeSwitch.controlSize = .small
        magsafeSwitch.target = self
        magsafeSwitch.action = #selector(toggleMagsafeOutput)
        magsafeSwitch.toolTip = "Return MagSafe immediately to the system charge indicator."
        magsafeSwitch.setAccessibilityLabel("MagSafe Outputs")
        outputRow.addArrangedSubview(magsafeText)
        outputRow.addArrangedSubview(magsafeSwitch)
        content.addArrangedSubview(outputRow)
        outputRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

        let chatgptRow = NSStackView()
        chatgptRow.orientation = .horizontal
        chatgptRow.alignment = .centerY
        chatgptRow.spacing = 8
        chatgptRow.addArrangedSubview(label("ChatGPT Desktop", size: 10.5, weight: .semibold))
        chatgptRow.addArrangedSubview(NSView())
        chatgptRow.addArrangedSubview(accessibilityLabel)
        let accessibilityButton = NSButton(title: "Accessibility…", target: self, action: #selector(requestAccessibility))
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.controlSize = .small
        chatgptRow.addArrangedSubview(accessibilityButton)
        content.addArrangedSubview(chatgptRow)
        chatgptRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

        content.addArrangedSubview(separator())

        let modeHeader = NSStackView()
        modeHeader.orientation = .horizontal
        modeHeader.alignment = .firstBaseline
        modeHeader.addArrangedSubview(label("Profiles", size: 14, weight: .semibold))
        modeHeader.addArrangedSubview(NSView())
        modeHeader.addArrangedSubview(currentModeLabel)
        content.addArrangedSubview(modeHeader)
        modeHeader.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

        modeDetailLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        content.addArrangedSubview(modeDetailLabel)

        let modesStack = NSStackView()
        modesStack.orientation = .vertical
        modesStack.alignment = .leading
        modesStack.spacing = 6
        modesStack.translatesAutoresizingMaskIntoConstraints = false
        for mode in signalModes {
            let b = ModeButton(mode: mode, target: self, action: #selector(modePressed(_:)))
            modeButtons.append(b)
            modesStack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        content.addArrangedSubview(modesStack)

        content.addArrangedSubview(separator())

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 10

        let loginText = label("Launch at Login", size: 11.5)
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)

        let settings = NSButton(title: "Profile Settings…", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        settings.image = systemImage("slider.horizontal.3", size: 12, weight: .medium)
        settings.imagePosition = .imageLeading
        settings.controlSize = .small

        let debug = NSButton(title: "Diagnostics…", target: self, action: #selector(openDebug))
        debug.bezelStyle = .rounded
        debug.image = systemImage("wrench.and.screwdriver", size: 12, weight: .medium)
        debug.imagePosition = .imageLeading
        debug.controlSize = .small

        bottom.addArrangedSubview(loginText)
        bottom.addArrangedSubview(loginSwitch)
        bottom.addArrangedSubview(NSView())
        bottom.addArrangedSubview(settings)
        bottom.addArrangedSubview(debug)
        content.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            for (name, control) in [("keyboard", self.keyboardSwitch), ("magsafe", self.magsafeSwitch)] {
                let windowRect = control.convert(control.bounds, to: nil)
                let rect = window.convertToScreen(windowRect)
                appLog("output frame \(name): x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))")
            }
        }
    }

    deinit { timer?.invalidate() }

    private func makeHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13

        statusIcon.image = systemImage("lightbulb.min", size: 25, weight: .semibold)
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .semibold)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.addArrangedSubview(statusTitle)
        text.addArrangedSubview(statusSubtitle)

        let battery = NSStackView()
        battery.orientation = .vertical
        battery.alignment = .trailing
        battery.spacing = 2
        battery.addArrangedSubview(batteryLabel)
        battery.addArrangedSubview(batterySub)

        row.addArrangedSubview(statusIcon)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(battery)
        return row
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    private func readSources() -> [String] {
        guard let files = try? fm.contentsOfDirectory(atPath: activeDir) else { return [] }
        var found = Set<String>()
        let now = Date()
        for file in files {
            let path = activeDir + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(date) > 20 * 60 { continue }
            if file == "chatgpt-ui" { found.insert("ChatGPT") }
            else if file == "codex-exec-process" || file.hasPrefix("codex-") { found.insert("Codex") }
            else if UUID(uuidString: file) != nil || file.hasPrefix("claude-") { found.insert("Claude Code") }
            else if file == "_test" { found.insert("Test") }
            else { found.insert("Agent") }
        }
        return ["ChatGPT", "Codex", "Claude Code", "Test", "Agent"].filter(found.contains)
    }

    private func refreshBattery(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastBatteryRefresh) >= 8 else { return }
        lastBatteryRefresh = now
        let out = run("/usr/bin/pmset", ["-g", "batt"])
        if let r = out.range(of: #"([0-9]+)%"#, options: .regularExpression) {
            batteryPercent = Int(out[r].dropLast()) ?? batteryPercent
        }
        batteryCharged = out.localizedCaseInsensitiveContains("; charged;")
        batteryOnAC = out.localizedCaseInsensitiveContains("AC Power")
    }

    private func refreshDaemonHealth(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDaemonHealthRefresh) >= 3 else { return }
        lastDaemonHealthRefresh = now
        let service = "gui/\(getuid())/io.github.hanpuli.phosignal.daemon"
        let out = run("/bin/launchctl", ["print", service])
        daemonHealthy = out.contains("state = running")
    }

    func refresh() {
        let enabled = !fm.fileExists(atPath: offFile)
        enabledSwitch.state = enabled ? .on : .off
        keyboardSwitch.state = fm.fileExists(atPath: keyboardOffFile) ? .off : .on
        magsafeSwitch.state = fm.fileExists(atPath: magsafeOffFile) ? .off : .on

        if let raw = try? String(contentsOfFile: modeFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           signalModes.contains(where: { $0.id == raw }) {
            selectedMode = raw
        } else {
            selectedMode = "smart"
        }

        refreshBattery()
        refreshDaemonHealth()
        let sources = readSources()
        let working = enabled && daemonHealthy && !sources.isEmpty

        let keyboardEnabled = !fm.fileExists(atPath: keyboardOffFile)
        let magsafeEnabled = !fm.fileExists(atPath: magsafeOffFile)
        let outputNotes = [keyboardEnabled ? nil : "Keyboard off", magsafeEnabled ? nil : "MagSafe off"].compactMap { $0 }
        let activityText = sources.isEmpty ? "Waiting for ChatGPT, Codex or Claude Code" : sources.joined(separator: " · ")

        if !daemonHealthy {
            statusTitle.stringValue = "Daemon error"
            statusSubtitle.stringValue = "PhoSignal daemon is not running; hardware output is unavailable"
            statusIcon.image = systemImage("exclamationmark.triangle.fill", size: 25, weight: .semibold)
            statusIcon.contentTintColor = .systemOrange
        } else {
            statusTitle.stringValue = enabled ? (working ? "Active" : "Idle") : "Paused"
            statusSubtitle.stringValue = enabled
                ? ([activityText] + outputNotes).joined(separator: " · ")
                : "Source detection continues; hardware outputs are paused"
            statusIcon.image = systemImage(
                enabled ? (working ? "lightbulb.max.fill" : "lightbulb.min") : "lightbulb.slash.fill",
                size: 25,
                weight: .semibold
            )
            statusIcon.contentTintColor = working ? .systemGreen : .secondaryLabelColor
        }
        sourcesLabel.stringValue = sources.isEmpty ? "No active agents" : "Active: " + sources.joined(separator: "   ·   ")

        batteryLabel.stringValue = "\(batteryPercent)%"
        batterySub.stringValue = (batteryOnAC ? "⚡︎ " : "") + (batteryCharged ? "Fully charged" : (batteryOnAC ? "On AC power" : "On battery"))

        let selectedProfile = signalModes.first(where: { $0.id == selectedMode }) ?? signalModes[0]
        let modeName = selectedProfile.name
        modeDetailLabel.stringValue = modeSummary(selectedMode)
        let hasDebugOverride = fm.fileExists(atPath: rawOverrideFile)
        currentModeLabel.stringValue = hasDebugOverride ? "\(modeName) · debug override" : modeName
        currentModeLabel.textColor = hasDebugOverride ? .systemOrange : .secondaryLabelColor

        let trusted = AXIsProcessTrusted()
        accessibilityLabel.stringValue = trusted ? "Granted" : "Permission required"
        accessibilityLabel.textColor = trusted ? .systemGreen : .systemOrange

        loginSwitch.state = fm.fileExists(atPath: loginPlist) ? .on : .off
        for b in modeButtons { b.updateSelected(b.modeID == selectedMode) }
        onStatusChange?(enabled, working, daemonHealthy)
    }

    @objc private func toggleEnabled() {
        _ = run(cliBin, [enabledSwitch.state == .on ? "on" : "off"])
        refresh()
    }

    @objc private func modePressed(_ sender: ModeButton) {
        appLog("modePressed action: \(sender.modeID)")
        let output = run(cliBin, ["mode", sender.modeID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appLog("modePressed backend: \(output)")
        selectedMode = sender.modeID
        refresh()
        if sender.modeID == "custom" { onSettingsRequested?("custom") }
    }

    @objc private func toggleKeyboardOutput() {
        let state = keyboardSwitch.state == .on ? "on" : "off"
        let output = run(cliBin, ["output", "keyboard", state])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appLog("keyboard output: \(output)")
        refresh()
    }

    @objc private func toggleMagsafeOutput() {
        let state = magsafeSwitch.state == .on ? "on" : "off"
        let output = run(cliBin, ["output", "magsafe", state])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appLog("magsafe output: \(output)")
        refresh()
    }

    @objc private func requestAccessibility() {
        onAccessibilityRequested?()
    }

    @objc private func openSettings() {
        onSettingsRequested?(selectedMode)
    }

    @objc private func openDebug() {
        onDebugRequested?()
    }

    @objc private func toggleLogin() {
        let service = "gui/\(getuid())/io.github.hanpuli.phosignal.ui"
        if loginSwitch.state == .on {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>io.github.hanpuli.phosignal.ui</string>
              <key>ProgramArguments</key><array>
                <string>/usr/bin/open</string><string>-gj</string><string>/Applications/PhoSignal.app</string>
              </array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            do {
                try plist.write(toFile: loginPlist, atomically: true, encoding: .utf8)
                _ = run("/bin/launchctl", ["bootout", service])
                let output = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", loginPlist])
                appLog("login bootstrap: \(output)")
            } catch {
                appLog("login plist write failed: \(error)")
            }
        } else {
            _ = run("/bin/launchctl", ["bootout", service])
            try? fm.removeItem(atPath: loginPlist)
        }
        refresh()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let panel = PanelController()
    private var debugWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    private var settingsController: ProfileSettingsController?
    private var chatgptWatcher: Process?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("applicationDidFinishLaunching")
        appLog("accessibility trusted=\(AXIsProcessTrusted())")
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAccessibilityRequest(_:)),
            name: Notification.Name("io.github.hanpuli.phosignal.requestAccessibility"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowRequest(_:)),
            name: Notification.Name("io.github.hanpuli.phosignal.show"),
            object: nil
        )

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 452, height: 795)
        popover.contentViewController = panel

        panel.onStatusChange = { [weak self] enabled, working, healthy in
            guard let self, let button = self.statusItem.button else { return }
            let symbol = healthy
                ? (enabled ? (working ? "lightbulb.max.fill" : "lightbulb.min") : "lightbulb.slash.fill")
                : "exclamationmark.triangle.fill"
            button.image = templateSystemImage(symbol, size: 15, weight: .semibold)
            button.contentTintColor = nil
            button.toolTip = healthy
                ? (enabled ? (working ? "PhoSignal · Active" : "PhoSignal · Idle") : "PhoSignal · Paused")
                : "PhoSignal · Daemon error"
        }

        panel.onDebugRequested = { [weak self] in self?.showDebugWindow() }
        panel.onSettingsRequested = { [weak self] mode in self?.showSettingsWindow(mode: mode) }
        panel.onAccessibilityRequested = { [weak self] in self?.requestAccessibility() }

        if let button = statusItem.button {
            button.image = templateSystemImage("lightbulb.min", size: 15, weight: .semibold)
            button.contentTintColor = nil
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "PhoSignal"
        }

        NSApp.applicationIconImage = systemImage("lightbulb.max.fill", size: 128, weight: .semibold)
        startChatGPTWatcher()
        panel.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        DistributedNotificationCenter.default().removeObserver(self)
        chatgptWatcher?.terminate()
    }

    @objc private func handleAccessibilityRequest(_ notification: Notification) {
        appLog("received accessibility request")
        requestAccessibility()
    }

    @objc private func handleShowRequest(_ notification: Notification) {
        showPopover()
    }

    private func startChatGPTWatcher() {
        guard !terminating else { return }
        if let current = chatgptWatcher, current.isRunning { return }

        let watcher = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/chatgpt-status-watch").path
        guard fm.isExecutableFile(atPath: watcher) else {
            appLog("ChatGPT watcher missing: \(watcher)")
            return
        }

        let process = Process()
        let stdout = freshNullHandle()
        let stderr = freshNullHandle()
        process.executableURL = URL(fileURLWithPath: watcher)
        var env = ProcessInfo.processInfo.environment
        env["PHOSIGNAL_STATE_DIR"] = stateDir
        process.environment = env
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.terminating else { return }
                self.chatgptWatcher = nil
                self.startChatGPTWatcher()
            }
        }
        do {
            try process.run()
            try? stdout?.close()
            try? stderr?.close()
            chatgptWatcher = process
            appLog("ChatGPT watcher started pid=\(process.processIdentifier)")
        } catch {
            try? stdout?.close()
            try? stderr?.close()
            appLog("ChatGPT watcher failed: \(error)")
        }
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if let watcher = self.chatgptWatcher, watcher.isRunning {
                watcher.terminate()
                self.chatgptWatcher = nil
            }
            self.startChatGPTWatcher()
            self.panel.refresh()
        }
    }

    private func showSettingsWindow(mode: String) {
        if let existing = settingsWindow, let vc = settingsController {
            vc.selectMode(mode)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vc = ProfileSettingsController(mode: mode)
        let window = NSWindow(contentViewController: vc)
        window.title = "PhoSignal · Profile Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 660))
        window.minSize = NSSize(width: 700, height: 660)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        settingsController = vc
        settingsWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDebugWindow() {
        if let existing = debugWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vc = DebugPanelController()
        let window = NSWindow(contentViewController: vc)
        window.title = "PhoSignal · Diagnostics"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 470, height: 475))
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        debugWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
