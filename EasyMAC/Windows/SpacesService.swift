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

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnection: ConnectionFn? = symbol("SLSMainConnectionID") ?? symbol("CGSMainConnectionID")
    private static let copyManagedDisplaySpaces: CopySpacesFn? = symbol("SLSCopyManagedDisplaySpaces") ?? symbol("CGSCopyManagedDisplaySpaces")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = skylight, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    var currentIndex: Int? { spaces.first { $0.id == currentID }?.index }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard let connection = Self.mainConnection?(),
              let raw = Self.copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else {
            if !spaces.isEmpty { spaces = [] }
            return
        }
        let screenID = screenProvider()?.stableID
        // One entry per display (or a single "Main" entry when displays share Spaces).
        let display = raw.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(screenID ?? "") == .orderedSame }
            ?? raw.first { ($0["Display Identifier"] as? String) == "Main" }
            ?? raw.first
        guard let display else { return }

        let list = (display["Spaces"] as? [[String: Any]]) ?? []
        var result: [SpaceInfo] = []
        for (i, space) in list.enumerated() {
            guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (space["id64"] as? NSNumber)?.uint64Value else { continue }
            let type = (space["type"] as? NSNumber)?.intValue ?? 0
            result.append(SpaceInfo(id: id, index: i + 1, isFullscreen: type == 4))
        }
        let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        if result != spaces { spaces = result }
        if current != currentID { currentID = current }
    }

    func switchTo(_ space: SpaceInfo) {
        refresh()
        guard !switching, let current = currentIndex, current != space.index else { return }
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
