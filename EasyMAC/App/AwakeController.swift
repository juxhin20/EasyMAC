import AppKit
import IOKit.pwr_mgt
import Observation

enum AwakeMode: String, CaseIterable, Identifiable {
    case display, system, lidClosed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: "Display"
        case .system: "System only"
        case .lidClosed: "Lid closed"
        }
    }
    var detail: String {
        switch self {
        case .display: "Screen stays on"
        case .system: "Screen may turn off, Mac keeps running"
        case .lidClosed: "Lid can be closed, Mac stays awake"
        }
    }
    var symbol: String {
        switch self {
        case .display: "display"
        case .system: "gearshape.2"
        case .lidClosed: "laptopcomputer"
        }
    }
}

/// Keep-awake ("coffee") in its own small menu bar item: ☕ while active, zzz when the Mac may sleep.
///
/// Display / System only use IOKit power assertions (no permissions, released automatically if
/// EasyMAC quits). Lid closed additionally needs `pmset disablesleep 1`, which requires an admin
/// password; it's always switched back off on stop/quit, and on the next launch if EasyMAC crashed.
@MainActor @Observable
final class AwakeController: NSObject, NSMenuDelegate {
    private(set) var isActive = false
    private(set) var endDate: Date?

    @ObservationIgnored private let settings = Settings.shared
    @ObservationIgnored private var item: NSStatusItem?
    @ObservationIgnored private var assertions: [IOPMAssertionID] = []
    @ObservationIgnored private var lidSleepDisabled = false
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var menuTimer: Timer?
    @ObservationIgnored private weak var statusLine: NSMenuItem?

    static let durations: [(String, TimeInterval?)] = [
        ("10 minutes", 600), ("15 minutes", 900), ("25 minutes", 1500), ("30 minutes", 1800),
        ("1 hour", 3600), ("2 hours", 7200), ("3 hours", 10800), ("4 hours", 14400), ("5 hours", 18000),
        ("Indefinitely", nil),
    ]

    func start() {
        recoverLidSetting()
        updateItemVisibility()
    }

    func updateItemVisibility() {
        if settings.showAwakeIcon {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            updateIcon()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    // MARK: - Control

    func activate(for duration: TimeInterval?) {
        stopAssertions()
        let reason = "EasyMAC Keep Awake" as CFString
        let types: [String]
        switch settings.awakeMode {
        case .display: types = [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep]
        case .system, .lidClosed: types = [kIOPMAssertionTypePreventUserIdleSystemSleep]
        }
        for type in types {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        if settings.awakeMode == .lidClosed && !lidSleepDisabled {
            lidSleepDisabled = Self.setLidSleepDisabled(true)
            if !lidSleepDisabled { settings.awakeMode = .system } // password cancelled → fall back
        } else if settings.awakeMode != .lidClosed && lidSleepDisabled {
            lidSleepDisabled = !Self.setLidSleepDisabled(false)
        }

        isActive = !assertions.isEmpty
        endDate = duration.map { Date().addingTimeInterval($0) }
        settings.awakeLastDuration = duration ?? 0
        endTimer?.invalidate()
        if let duration {
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        }
        updateIcon()
    }

    func stop() {
        stopAssertions()
        if lidSleepDisabled { lidSleepDisabled = !Self.setLidSleepDisabled(false) }
        endTimer?.invalidate()
        endTimer = nil
        isActive = false
        endDate = nil
        updateIcon()
    }

    func toggle() {
        if isActive { stop() } else { activate(for: settings.awakeLastDuration > 0 ? settings.awakeLastDuration : nil) }
    }

    /// Mode change while active re-applies immediately.
    func modeChanged() {
        guard isActive else { return }
        activate(for: endDate.map { max($0.timeIntervalSinceNow, 1) })
    }

    func willTerminate() {
        stopAssertions()
        if lidSleepDisabled { _ = Self.setLidSleepDisabled(false) }
    }

    private func stopAssertions() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }

    // MARK: - Lid closed (pmset)

    /// Runs `pmset -a disablesleep 0/1` with the standard macOS admin prompt.
    private static func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
        var error: NSDictionary?
        NSApp.activate()
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.app.notice("pmset disablesleep failed: \(String(describing: error), privacy: .public)") }
        return error == nil
    }

    /// If EasyMAC died while "Lid closed" was on, sleep would stay disabled — offer to fix it.
    private func recoverLidSetting() {
        guard UserDefaults.standard.bool(forKey: "awakeLidWasDisabled") else { return }
        UserDefaults.standard.set(false, forKey: "awakeLidWasDisabled")
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if output.contains("SleepDisabled\t\t1") || output.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil {
            _ = Self.setLidSleepDisabled(false)
        }
    }

    // MARK: - Menu bar

    private func updateIcon() {
        UserDefaults.standard.set(lidSleepDisabled, forKey: "awakeLidWasDisabled")
        guard let button = item?.button else { return }
        let symbol = isActive ? "cup.and.saucer.fill" : "zzz"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: isActive ? "Keeping Mac awake" : "Mac can sleep")
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.toolTip = isActive ? statusText : "EasyMAC Keep Awake — off"
    }

    private var statusText: String {
        guard isActive else { return "Not active — your Mac can sleep" }
        guard let endDate else { return "Active, indefinitely" }
        let left = max(0, Int(endDate.timeIntervalSinceNow))
        return String(format: "Active, %d:%02d:%02d left", left / 3600, (left % 3600) / 60, left % 60)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status
        menu.addItem(.separator())

        if isActive {
            menu.addItem(withSymbol: "stop.circle", ClosureMenuItem("Stop Keeping Awake") { [weak self] in self?.stop() })
        } else {
            menu.addItem(withSymbol: "cup.and.saucer", ClosureMenuItem("Keep Awake") { [weak self] in
                self?.activate(for: nil)
            })
        }

        let forItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        forItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let durations = NSMenu()
        for (title, seconds) in Self.durations {
            let entry = ClosureMenuItem(title) { [weak self] in self?.activate(for: seconds) }
            if isActive, settings.awakeLastDuration == (seconds ?? 0) { entry.state = .on }
            durations.addItem(entry)
        }
        forItem.submenu = durations
        menu.addItem(forItem)

        // Modes as buttons right in the menu, each with its explanation underneath.
        menu.addItem(.separator())
        for mode in AwakeMode.allCases {
            let entry = ClosureMenuItem(mode.title) { [weak self] in
                self?.settings.awakeMode = mode
                self?.modeChanged()
            }
            entry.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            entry.state = settings.awakeMode == mode ? .on : .off
            if #available(macOS 14.4, *) {
                entry.subtitle = mode.detail
            } else {
                entry.toolTip = mode.detail
            }
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(withSymbol: "gearshape", ClosureMenuItem("Keep Awake Settings…") {
            AppState.shared.openSettings(.general)
        })
    }

    /// Live countdown while the menu is open.
    func menuWillOpen(_ menu: NSMenu) {
        menuTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusLine?.title = self.statusText
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }
}

private extension NSMenu {
    func addItem(withSymbol symbol: String, _ item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        addItem(item)
    }
}
