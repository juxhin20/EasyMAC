import AppKit
import KeyboardShortcuts

/// ⌥Tab-style keyboard switcher over the strip: each press moves the highlight,
/// releasing the modifiers focuses the highlighted window, Esc cancels.
@MainActor
final class SwitcherController {
    private unowned let state: AppState
    private var active = false
    private var index = 0
    private var list: [WindowInfo] = []
    private var monitors: [Any] = []
    private var session = 0

    init(state: AppState) {
        self.state = state
    }

    func advance() {
        if !active {
            list = SidebarModel.displayed(state.windows.windows, max: state.settings.maxVisible)
            guard !list.isEmpty else {
                state.windows.requestRefresh(forceSweep: true)
                return
            }
            active = true
            // Start on the previous window (index 1) like ⌘Tab when the first one is the active one.
            index = list.count > 1 && list[0].isActive ? 1 : 0
            state.sidebar.beginPeek()
            installMonitors()
        } else {
            index = (index + 1) % max(list.count, 1)
        }
        state.sidebar.model.selectionID = list.indices.contains(index) ? list[index].windowID : nil
    }

    private var requiredModifiers: NSEvent.ModifierFlags {
        let modifiers = KeyboardShortcuts.getShortcut(for: .windowSwitcher)?.modifiers ?? [.option]
        return modifiers.intersection([.command, .option, .control])
    }

    private func installMonitors() {
        let flags: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                if !event.modifierFlags.contains(self.requiredModifiers) { self.commit() }
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        let keys: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { self?.finish(focus: false) } // Esc
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }

        // Safety net: if we somehow miss the release, close after 8s.
        session += 1
        let current = session
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.session == current else { return }
            self.finish(focus: false)
        }
    }

    private func commit() {
        finish(focus: true)
    }

    private func finish(focus: Bool) {
        guard active else { return }
        active = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        let selected = list.indices.contains(index) ? list[index] : nil
        state.sidebar.model.selectionID = nil
        state.sidebar.endPeek()
        if focus, let selected { state.focus(selected) }
    }
}
