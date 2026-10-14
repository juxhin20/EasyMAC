import AppKit

/// Applies snap actions and layout presets to real windows.
@MainActor
final class SnapController {
    private let ax = AXWindowService.shared
    private let settings = Settings.shared
    private unowned let state: AppState
    /// Frame before the first snap, so ⌃⌥⌫ can put a window back.
    private var originalFrames: [CGWindowID: CGRect] = [:]

    init(state: AppState) {
        self.state = state
    }

    struct Target: Sendable {
        let pid: pid_t
        let windowID: CGWindowID?
        let frame: CGRect
    }

    /// Focused window of the frontmost app.
    func focusedTarget() async -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let focused = await ax.focusedWindow(pid: app.processIdentifier) else { return nil }
        return Target(pid: focused.pid, windowID: focused.windowID, frame: focused.frame)
    }

    /// Topmost window under the mouse.
    func targetUnderCursor() async -> Target? {
        let point = Coordinates.appKitToAX(NSEvent.mouseLocation, primaryHeight: NSScreen.primaryHeight)
        let own = ProcessInfo.processInfo.processIdentifier
        let record = await Task.detached { CGWindowRecord.windowUnder(point, excludingPID: own) }.value
        guard let record else { return nil }
        return Target(pid: record.pid, windowID: record.id, frame: record.bounds)
    }

    func snapFocused(_ action: SnapAction) async {
        guard let target = await focusedTarget() else {
            NSSound.beep()
            return
        }
        let screen = NSScreen.screen(forAXRect: target.frame) ?? NSScreen.main
        guard let screen else { return }
        let area = state.usableAreaAX(screen)
        let gap = settings.layoutGap
        let resolved = settings.cycleSnapSizes ? LayoutEngine.cycled(action, current: target.frame, in: area, gap: gap) : action
        await apply(LayoutEngine.snap(resolved, in: area, gap: gap, current: target.frame), to: target)
    }

    func apply(_ frame: CGRect, to target: Target) async {
        if let id = target.windowID, originalFrames[id] == nil {
            originalFrames[id] = target.frame
        }
        await ax.setFrame(frame, windowID: target.windowID, pid: target.pid)
        Log.layout.debug("Placed window \(target.windowID ?? 0) at \(frame.debugDescription, privacy: .public)")
    }

    func restoreFocused() async {
        guard let target = await focusedTarget(), let id = target.windowID, let original = originalFrames.removeValue(forKey: id) else {
            NSSound.beep()
            return
        }
        await ax.setFrame(original, windowID: id, pid: target.pid)
    }

    /// Tiles the visible windows of the display under the mouse, most recent first.
    func tileVisible(_ preset: LayoutPreset) async {
        await state.windows.refresh(forceSweep: true)
        guard let screen = NSScreen.withMouse else { return }
        let windows = state.windows.allWindows
            .filter { !$0.isOffscreen && NSScreen.screen(forAXRect: $0.frame) == screen }
            .sorted { $0.lastActivated > $1.lastActivated }
            .prefix(12)
        guard !windows.isEmpty else { return }
        let frames = LayoutEngine.frames(for: preset, count: windows.count, in: state.usableAreaAX(screen), gap: settings.layoutGap)
        for (window, frame) in zip(windows, frames) {
            if originalFrames[window.windowID] == nil { originalFrames[window.windowID] = window.frame }
            await ax.setFrame(frame, windowID: window.windowID, pid: window.pid)
        }
    }
}
