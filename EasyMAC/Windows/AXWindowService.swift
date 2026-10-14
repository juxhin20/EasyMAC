import AppKit
import ApplicationServices

/// Private but long-stable HIServices call mapping an AX window to its CGWindowID. See NOTES.md.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct AXWindowSnapshot: Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let subrole: String?

    /// Standard windows and dialogs; skips palettes, sheets, popovers and other chrome.
    var isUserWindow: Bool {
        guard let subrole else { return true }
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }
}

struct AXSweepResult: Sendable {
    let readablePIDs: Set<pid_t>
    let windows: [AXWindowSnapshot]
}

struct AXFocusedWindow: Sendable {
    let pid: pid_t
    let windowID: CGWindowID?
    let frame: CGRect
}

/// All Accessibility work runs on one serial queue, never on the main thread:
/// AX calls block while the target app is busy. Each app element gets a 0.5s messaging timeout,
/// and apps that keep timing out are skipped for a while during background sweeps.
final class AXWindowService: @unchecked Sendable {
    static let shared = AXWindowService()

    private let queue = DispatchQueue(label: "com.appalbania.easymac.ax", qos: .userInitiated)
    private let timeout: Float = 0.5
    /// pid → time until which background sweeps skip it (touched only on `queue`).
    private var slowUntil: [pid_t: Date] = [:]

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Queries

    func sweep(pids: [pid_t]) async -> AXSweepResult {
        await run { [self] in
            var readable = Set<pid_t>()
            var windows: [AXWindowSnapshot] = []
            let now = Date()
            for pid in pids {
                if let until = slowUntil[pid], until > now { continue }
                let started = Date()
                let app = application(pid)
                guard let list = windowList(app) else {
                    markSlowIfNeeded(pid, started: started)
                    continue
                }
                readable.insert(pid)
                for window in list {
                    if let snapshot = snapshot(window, pid: pid) { windows.append(snapshot) }
                }
                markSlowIfNeeded(pid, started: started)
            }
            return AXSweepResult(readablePIDs: readable, windows: windows)
        }
    }

    func windows(pid: pid_t) async -> [AXWindowSnapshot] {
        await run { [self] in
            guard let list = windowList(application(pid)) else { return [] }
            return list.compactMap { snapshot($0, pid: pid) }
        }
    }

    func focusedWindow(pid: pid_t) async -> AXFocusedWindow? {
        await run { [self] in
            let app = application(pid)
            guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute),
                  let frame = frame(of: window) else { return nil }
            return AXFocusedWindow(pid: pid, windowID: windowID(of: window), frame: frame)
        }
    }

    func frame(windowID: CGWindowID, pid: pid_t) async -> CGRect? {
        await run { [self] in
            findWindow(pid: pid, windowID: windowID).flatMap { frame(of: $0) }
        }
    }

    // MARK: - Actions

    /// Raises one specific window, even when its app has many (Chrome, VS Code).
    /// Returns `false` when the window no longer exists (IDs are validated before acting).
    @discardableResult
    func focus(windowID: CGWindowID, pid: pid_t) async -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let unhid = await MainActor.run { () -> Bool in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            if app.isHidden { app.unhide() }
            return true
        }
        guard unhid else { return false }

        let result: (found: Bool, fronted: Bool) = await run { [self] in
            guard let window = findWindow(pid: pid, windowID: windowID) else { return (false, false) }
            if bool(window, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            let fronted = SkyLight.makeFrontWindow(pid: pid, windowID: windowID)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return (true, fronted)
        }
        guard result.found else { return false }
        if !result.fronted {
            await MainActor.run {
                _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
        }
        return true
    }

    /// Moves/resizes a window (AX coordinates). `windowID == nil` targets the app's focused window.
    @discardableResult
    func setFrame(_ frame: CGRect, windowID: CGWindowID?, pid: pid_t) async -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier {
            // AX-setting our own windows from a background thread crashes AppKit; use NSWindow directly.
            return await MainActor.run {
                let window = NSApp.windows.first { CGWindowID($0.windowNumber) == windowID && $0.isVisible }
                    ?? NSApp.keyWindow ?? NSApp.mainWindow
                guard let window, !(window is NSPanel) else { return false }
                window.setFrame(Coordinates.axToAppKit(frame, primaryHeight: NSScreen.primaryHeight), display: true, animate: true)
                return true
            }
        }
        return await run { [self] in
            let app = application(pid)
            let window: AXUIElement?
            if let windowID {
                window = findWindow(pid: pid, windowID: windowID)
            } else {
                window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
            }
            guard let window else { return false }
            if bool(window, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            let ok = apply(frame, to: window, app: app)
            if !ok { Log.ax.notice("App \(pid) refused resize (Electron/Java apps sometimes do)") }
            return ok
        }
    }

    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) async {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        await run { [self] in
            guard let window = findWindow(pid: pid, windowID: windowID) else { return }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFTypeRef)
        }
    }

    func close(windowID: CGWindowID, pid: pid_t) async {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        await run { [self] in
            guard let window = findWindow(pid: pid, windowID: windowID),
                  let button = element(window, kAXCloseButtonAttribute) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    // MARK: - Helpers (call on `queue` only)

    private func markSlowIfNeeded(_ pid: pid_t, started: Date) {
        if Date().timeIntervalSince(started) > Double(timeout) * 0.9 {
            slowUntil[pid] = Date().addingTimeInterval(20)
            Log.ax.notice("pid \(pid) is not responding to Accessibility; skipping for 20s")
        }
    }

    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func windowList(_ app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }

    private func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let p = copy(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func snapshot(_ window: AXUIElement, pid: pid_t) -> AXWindowSnapshot? {
        guard let id = windowID(of: window), let frame = frame(of: window) else { return nil }
        return AXWindowSnapshot(
            windowID: id,
            pid: pid,
            title: string(window, kAXTitleAttribute) ?? "",
            frame: frame,
            isMinimized: bool(window, kAXMinimizedAttribute) ?? false,
            subrole: string(window, kAXSubroleAttribute)
        )
    }

    private func findWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard let list = windowList(application(pid)) else { return nil }
        return list.first { self.windowID(of: $0) == windowID }
    }

    private func apply(_ frame: CGRect, to window: AXUIElement, app: AXUIElement) -> Bool {
        // "Enhanced UI" (set by VoiceOver-aware apps like Chrome) animates every AX resize; turn it off briefly.
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, false as CFTypeRef) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFTypeRef) } }

        // size → position → size: apps clamp size against the current screen before moving.
        let sized = set(size: frame.size, on: window)
        let moved = set(position: frame.origin, on: window)
        let resized = set(size: frame.size, on: window)
        return moved && (sized || resized)
    }

    private func set(position: CGPoint, on window: AXUIElement) -> Bool {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private func set(size: CGSize, on window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }
}

/// Private SkyLight calls used by window switchers (AltTab, etc.) to make one specific window key
/// without the app activating its other windows. Resolved at runtime; absent symbols fall back to
/// `NSRunningApplication.activate()`. See NOTES.md.
private enum SkyLight {
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    nonisolated(unsafe) private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated(unsafe) private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static let setFront: SetFrontFn? = symbol(skylight, "_SLPSSetFrontProcessWithOptions")
    private static let postEvent: PostEventFn? = symbol(skylight, "SLPSPostEventRecordTo")
    private static let getPSN: GetPSNFn? = symbol(defaultHandle, "GetProcessForPID")

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func makeFrontWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFront, let postEvent, let getPSN else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == 0 else { return false }
        guard setFront(&psn, windowID, 0x200 /* kCPSUserGenerated */) == .success else { return false }

        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: windowID) { raw in
            for i in 0..<4 { bytes[0x3C + i] = raw[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        for phase: UInt8 in [0x01, 0x02] {
            bytes[0x08] = phase
            bytes.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress { _ = postEvent(&psn, base) }
            }
        }
        return true
    }
}
