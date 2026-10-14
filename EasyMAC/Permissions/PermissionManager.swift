import AppKit
import ApplicationServices
import Observation

/// Last known permission state, readable from any thread at zero cost.
/// Asking macOS directly is slow (`CGPreflightScreenCaptureAccess` ≈ 9 ms, `AXIsProcessTrusted`
/// ≈ 1.5 ms, both XPC to the privacy daemon) — calling them per window / per tick on the main thread
/// caused visible stutter in menus. They're only ever queried on a background queue now.
enum PermissionCache {
    nonisolated(unsafe) static var accessibility = AXIsProcessTrusted()
    nonisolated(unsafe) static var screenRecording = CGPreflightScreenCaptureAccess()
}

@MainActor @Observable
final class PermissionManager {
    private(set) var accessibilityGranted = PermissionCache.accessibility
    private(set) var screenRecordingGranted = PermissionCache.screenRecording
    /// Set once we asked the system for screen recording; the grant often needs a relaunch to apply.
    private(set) var screenRecordingRequested = false

    var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    @ObservationIgnored var onChange: ((_ accessibility: Bool, _ screenRecording: Bool) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checking = false

    /// Queries macOS off the main thread; updates state (and notifies) only when something changed.
    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            let (ax, sr) = await Task.detached(priority: .utility) {
                (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
            }.value
            PermissionCache.accessibility = ax
            PermissionCache.screenRecording = sr
            checking = false
            guard ax != accessibilityGranted || sr != screenRecordingGranted else { return }
            Log.permissions.info("Permissions changed: accessibility=\(ax) screenRecording=\(sr)")
            accessibilityGranted = ax
            screenRecordingGranted = sr
            onChange?(ax, sr)
        }
    }

    /// 1 s while onboarding is open, every few seconds otherwise (to notice revocations).
    func startMonitoring(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = interval * 0.3
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    func requestScreenRecording() {
        screenRecordingRequested = true
        if !CGRequestScreenCaptureAccess() {
            openScreenRecordingSettings()
        }
        refresh()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Reads / fixes system settings that interfere with EasyMAC.
enum SystemTweaks {
    /// `AppleFnUsageType`: 0 = Do Nothing, 1 = Change Input Source, 2 = Emoji & Symbols, 3 = Dictation.
    static var fnKeyUsage: Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
    }

    static var fnKeyDoesSomething: Bool { (fnKeyUsage ?? 2) != 0 }

    static func setFnKeyToDoNothing() {
        run("/usr/bin/defaults", ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"])
    }

    static var stageManagerEnabled: Bool {
        CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// macOS 26: System Settings → Menu Bar ("Allow in the Menu Bar" per app).
    static func openMenuBarSettings() {
        for id in ["com.apple.ControlCenter-Settings.extension", "com.apple.MenuBar-Settings.extension"] {
            if let url = URL(string: "x-apple.systempreferences:" + id), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openDesktopAndDockSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private static func run(_ path: String, _ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }
}
