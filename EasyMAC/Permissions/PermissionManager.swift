import AppKit
import ApplicationServices
import Observation

@MainActor @Observable
final class PermissionManager {
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    /// Set once we asked the system for screen recording; the grant often needs a relaunch to apply.
    private(set) var screenRecordingRequested = false

    var allGranted: Bool { accessibilityGranted && screenRecordingGranted }

    @ObservationIgnored var onChange: ((_ accessibility: Bool, _ screenRecording: Bool) -> Void)?
    @ObservationIgnored private var timer: Timer?

    func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        guard ax != accessibilityGranted || sr != screenRecordingGranted else { return }
        Log.permissions.info("Permissions changed: accessibility=\(ax) screenRecording=\(sr)")
        accessibilityGranted = ax
        screenRecordingGranted = sr
        onChange?(ax, sr)
    }

    /// Polls cheaply; 1s while onboarding is open, slower in the background to catch revocations.
    func startMonitoring(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = interval * 0.2
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
