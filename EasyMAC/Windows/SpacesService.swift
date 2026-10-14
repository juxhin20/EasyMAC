import AppKit
import Observation

struct SpaceInfo: Identifiable, Equatable, Sendable {
    let id: UInt64
    let index: Int          // 1-based position on its display
    let isFullscreen: Bool
}

/// Lists Mission Control desktops ("Spaces") and switches between them.
///
/// Reading uses the private `SLSCopyManagedDisplaySpaces` (same family as the SkyLight calls in
/// AXWindowService), resolved with `dlsym`; if it's missing the row simply stays empty.
/// Switching posts the system's own shortcuts: ⌃1…⌃9 when "Switch to Desktop N" is enabled,
/// otherwise repeated ⌃← / ⌃→ (on by default in macOS). See NOTES.md.
@MainActor @Observable
final class SpacesService {
    private(set) var spaces: [SpaceInfo] = []
    private(set) var currentID: UInt64?

    /// Display the strip lives on; spaces are per display when "Displays have separate Spaces" is on.
    @ObservationIgnored var screenProvider: () -> NSScreen? = { NSScreen.main }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var switching = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastClick: (id: UInt64, time: Date)?
    @ObservationIgnored private var lastSwitch = Date.distantPast

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated private static let mainConnection: ConnectionFn? = symbol("SLSMainConnectionID") ?? symbol("CGSMainConnectionID")
    nonisolated private static let copyManagedDisplaySpaces: CopySpacesFn? = symbol("SLSCopyManagedDisplaySpaces") ?? symbol("CGSCopyManagedDisplaySpaces")

    nonisolated private static func symbol<T>(_ name: String) -> T? {
        guard let handle = skylight, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    var currentIndex: Int? { spaces.first { $0.id == currentID }?.index }
    var isCurrentFullscreen: Bool { spaces.first { $0.id == currentID }?.isFullscreen ?? false }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Adding/removing desktops in Mission Control posts no notification, so poll (cheap: one
    /// WindowServer call, publishes only on change) while the row is on screen.
    func setPolling(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    @ObservationIgnored private var refreshing = false

    /// The WindowServer call runs off the main thread; results are applied on main.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let screenID = screenProvider()?.stableID
        Task {
            let parsed = await Task.detached(priority: .utility) { Self.read(screenID: screenID) }.value
            refreshing = false
            guard let parsed else {
                if !spaces.isEmpty { spaces = [] }
                return
            }
            if parsed.spaces != spaces { spaces = parsed.spaces }
            if parsed.current != currentID { currentID = parsed.current }
        }
    }

    nonisolated private static func read(screenID: String?) -> (spaces: [SpaceInfo], current: UInt64?)? {
        guard let connection = mainConnection?(),
              let raw = copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return parse(raw, screenID: screenID)
    }

    nonisolated private static func parse(_ raw: [[String: Any]], screenID: String?) -> (spaces: [SpaceInfo], current: UInt64?) {
        // One entry per display (or a single "Main" entry when displays share Spaces).
        let display = raw.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(screenID ?? "") == .orderedSame }
            ?? raw.first { ($0["Display Identifier"] as? String) == "Main" }
            ?? raw.first
        guard let display else { return ([], nil) }

        let list = (display["Spaces"] as? [[String: Any]]) ?? []
        var result: [SpaceInfo] = []
        for (i, space) in list.enumerated() {
            guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (space["id64"] as? NSNumber)?.uint64Value else { continue }
            let type = (space["type"] as? NSNumber)?.intValue ?? 0
            result.append(SpaceInfo(id: id, index: i + 1, isFullscreen: type == 4))
        }
        let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        return (result, current)
    }

    /// Single click switches right away; a second click on the same desktop (double-click)
    /// opens Mission Control there, showing all of that desktop's windows spread out.
    func clicked(_ space: SpaceInfo) {
        let now = Date()
        if let last = lastClick, last.id == space.id, now.timeIntervalSince(last.time) <= NSEvent.doubleClickInterval {
            lastClick = nil
            showOverview()
            return
        }
        lastClick = (space.id, now)
        switchTo(space)
    }

    /// Opens Mission Control once the desktop switch animation has finished.
    private func showOverview() {
        let wait = max(0, 0.45 - Date().timeIntervalSince(lastSwitch))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    func switchTo(_ space: SpaceInfo) {
        refresh()
        guard !switching, let current = currentIndex, current != space.index else { return }
        lastSwitch = Date()
        currentID = space.id // light up the clicked desktop right away; macOS confirms via notification
        if space.index <= 9, Self.desktopShortcutEnabled(space.index) {
            postControl(keyCode: Self.digitKeyCodes[space.index - 1])
            return
        }
        // Step with ⌃← / ⌃→ (Mission Control "Move left/right a space").
        let delta = space.index - current
        let key: CGKeyCode = delta > 0 ? 124 : 123
        switching = true
        Task {
            for _ in 0..<abs(delta) {
                postControl(keyCode: key)
                try? await Task.sleep(for: .milliseconds(40))
            }
            switching = false
        }
    }

    private static let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// True when ⌃1…⌃N jump straight to a desktop (one slide instead of one per desktop in between).
    var directSwitchingEnabled: Bool {
        let n = min(max(spaces.count, 2), 9)
        return (1...n).allSatisfy { Self.desktopShortcutEnabled($0) }
    }

    /// Turns on Mission Control's "Switch to Desktop 1–9" (⌃1…⌃9) and applies it without logging out.
    func enableDirectSwitching() {
        let ascii = [49, 50, 51, 52, 53, 54, 55, 56, 57]
        for n in 1...9 {
            let value: [String: Any] = [
                "enabled": true,
                "value": ["parameters": [ascii[n - 1], Int(Self.digitKeyCodes[n - 1]), 262144], "type": "standard"],
            ]
            var all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
            all[String(117 + n)] = value
            CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, all as CFDictionary, "com.apple.symbolichotkeys" as CFString)
        }
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        task.arguments = ["-u"]
        try? task.run()
    }

    /// "Switch to Desktop N" = symbolic hot key 118…126; off by default in macOS.
    private static func desktopShortcutEnabled(_ n: Int) -> Bool {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any],
              let entry = all[String(117 + n)] as? [String: Any] else { return false }
        return (entry["enabled"] as? Bool) == true
    }

    private func postControl(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = [.maskControl, .maskSecondaryFn]
            if keyCode < 100 { event.flags = .maskControl } // digits: plain ⌃
            event.post(tap: .cghidEventTap)
        }
    }
}
