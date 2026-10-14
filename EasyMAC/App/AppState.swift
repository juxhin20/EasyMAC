import AppKit
import Observation

/// Root object wiring services and controllers together, plus the user-facing actions.
/// Services are individually `@Observable`; views observe them directly.
@MainActor
final class AppState {
    static let shared = AppState()

    let settings = Settings.shared
    let launchAtLogin = LaunchAtLogin.shared
    let permissions = PermissionManager()
    let windows = WindowService()
    let thumbnails = ThumbnailService()
    let workspaces = WorkspaceManager()
    let toast = ToastController()

    lazy var sidebar = SidebarController(state: self)
    lazy var snap = SnapController(state: self)
    lazy var radial = RadialSnapController(state: self)
    lazy var switcher = SwitcherController(state: self)
    lazy var settingsWindow = SettingsWindowController(state: self)
    lazy var onboarding = OnboardingWindowController(state: self)
    private lazy var restorer = WorkspaceRestorer(area: { [unowned self] in self.usableAreaAX($0) })
    private var settingsObserver: NSObjectProtocol?
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start(launchedAtLogin: Bool) {
        guard !started else { return }
        started = true
        Log.app.info("EasyMAC \(Bundle.main.shortVersion, privacy: .public) starting (login launch: \(launchedAtLogin))")

        applyActivationPolicy()
        launchAtLogin.enableOnFirstRun()

        windows.startObserving()
        HotkeyController.register(self)
        sidebar.start()
        radial.start()

        permissions.onChange = { [weak self] accessibility, _ in
            guard let self else { return }
            self.radial.start()
            self.windows.requestRefresh(forceSweep: true)
            if !accessibility && self.settings.hasCompletedOnboarding {
                // Permission revoked while running: walk the user back through onboarding.
                self.onboarding.show()
            }
        }
        permissions.startMonitoring(interval: 2)

        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated { self?.settingsChanged(key: key) }
        }

        // `open EasyMAC.app --args -settingsTab workspaces` jumps straight to a tab (handy for support/testing).
        if let raw = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["settingsTab"] as? String,
           let tab = SettingsTab(rawValue: raw) {
            settingsWindow.show(tab: tab)
        } else if !settings.hasCompletedOnboarding || !permissions.accessibilityGranted {
            onboarding.show()
        } else if settings.showSettingsOnLaunch && !launchedAtLogin {
            settingsWindow.show()
        }
    }

    func willTerminate() {
        workspaces.saveNow()
    }

    private func settingsChanged(key: String?) {
        switch key {
        case "showDockIcon":
            applyActivationPolicy()
        case "radialEnabled", "radialTrigger":
            radial.start()
        case "hasCompletedOnboarding", "showSettingsOnLaunch":
            break
        default:
            windows.settingsChanged()
            sidebar.settingsChanged()
        }
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    // MARK: - Geometry

    /// Area windows may occupy on `screen` (AX coordinates): the visible frame minus the pinned strip.
    func usableAreaAX(_ screen: NSScreen) -> CGRect {
        var area = screen.visibleFrameAX
        let reserved = sidebar.reservedWidth
        guard settings.reserveSidebarSpace, reserved > 0, screen.isSameDisplay(as: sidebar.screen) else { return area }
        area.size.width -= reserved
        if settings.sidebarEdge == .left { area.origin.x += reserved }
        return area
    }

    // MARK: - Windows

    func focus(_ window: WindowInfo) {
        sidebar.hidePreview()
        windows.noteActivated(window.windowID)
        Task {
            let ok = await AXWindowService.shared.focus(windowID: window.windowID, pid: window.pid)
            if !ok {
                // Window vanished (IDs get reused): at least bring its app forward.
                NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
            }
            windows.requestRefresh()
        }
    }

    func toggleMinimize(_ window: WindowInfo) {
        Task {
            await AXWindowService.shared.setMinimized(!window.isMinimized, windowID: window.windowID, pid: window.pid)
            windows.requestRefresh(forceSweep: true)
        }
    }

    func close(_ window: WindowInfo) {
        Task {
            await AXWindowService.shared.close(windowID: window.windowID, pid: window.pid)
            try? await Task.sleep(for: .milliseconds(150))
            windows.requestRefresh(forceSweep: true)
        }
    }

    func hideApp(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?.hide()
    }

    func quitApp(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
    }

    func toggleSidebar() {
        sidebar.toggle()
    }

    // MARK: - Workspaces

    /// Snapshot of the windows on the display under the mouse (or all displays when it has none).
    private func currentWindowsForSaving() async -> [WindowInfo] {
        await windows.refresh(forceSweep: true)
        let all = windows.allWindows.filter { !$0.isOffscreen }.sorted { $0.lastActivated > $1.lastActivated }
        guard let screen = NSScreen.withMouse else { return all }
        let onScreen = all.filter { NSScreen.screen(forAXRect: $0.frame)?.isSameDisplay(as: screen) == true }
        return onScreen.isEmpty ? all : onScreen
    }

    func saveCurrentAsWorkspace() {
        Task {
            let current = await currentWindowsForSaving()
            createWorkspace(with: current)
        }
    }

    func createWorkspace(with windows: [WindowInfo]) {
        let items = workspaces.makeItems(from: windows, area: usableAreaAX)
        guard !items.isEmpty else {
            toast.show("No windows to save", symbol: "exclamationmark.triangle.fill")
            return
        }
        let apps = orderedAppNames(windows)
        let name = apps.prefix(2).joined(separator: " + ") + (apps.count > 2 ? " +\(apps.count - 2)" : "")
        let workspace = Workspace(name: name.isEmpty ? "Workspace \(workspaces.workspaces.count + 1)" : name,
                                  colorHex: workspaces.nextColor,
                                  hotkeyIndex: workspaces.nextFreeHotkey,
                                  items: items)
        workspaces.add(workspace)
        let hotkey = workspace.hotkeyIndex.flatMap { HotkeyController.workspaceShortcutText($0) }
        toast.show("Saved “\(workspace.name)”" + (hotkey.map { " — \($0)" } ?? ""), symbol: "square.stack.3d.up.fill")
    }

    func updateWorkspaceWithCurrentWindows(_ id: UUID) {
        Task {
            guard var workspace = workspaces.workspace(id) else { return }
            let current = await currentWindowsForSaving()
            workspace.items = workspaces.makeItems(from: current, area: usableAreaAX)
            workspaces.update(workspace)
            toast.show("Updated “\(workspace.name)”", symbol: "arrow.triangle.2.circlepath")
        }
    }

    func addWindow(_ windowID: CGWindowID, toWorkspace id: UUID) {
        guard var workspace = workspaces.workspace(id), let window = windows.window(windowID) else { return }
        let others = windows.allWindows.filter { $0.bundleID == window.bundleID && $0.windowID != windowID }
        guard var item = workspaces.makeItems(from: [window], area: usableAreaAX).first else { return }
        if !others.isEmpty { item.titleContains = WindowMatcher.suggestHint(title: window.title, appName: window.appName) }
        workspace.items.append(item)
        workspaces.update(workspace)
        toast.show("Added \(window.appName) to “\(workspace.name)”", symbol: "plus.circle.fill")
    }

    func restoreWorkspace(_ id: UUID) {
        guard let workspace = workspaces.workspace(id), workspaces.restoringID == nil else { return }
        workspaces.setRestoring(id)
        Task {
            let report = await restorer.restore(workspace)
            workspaces.setRestoring(nil)
            windows.requestRefresh(forceSweep: true)
            if report.missing.isEmpty {
                toast.show("“\(workspace.name)” — \(report.placed) window\(report.placed == 1 ? "" : "s")", symbol: "square.stack.3d.up.fill")
            } else {
                toast.show("“\(workspace.name)” — missing \(report.missing.joined(separator: ", "))", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func restoreWorkspace(hotkey index: Int) {
        guard let workspace = workspaces.workspace(hotkey: index) else {
            toast.show("No workspace on slot \(index)", symbol: "questionmark.circle.fill")
            return
        }
        restoreWorkspace(workspace.id)
    }

    private func orderedAppNames(_ windows: [WindowInfo]) -> [String] {
        var seen = Set<String>()
        return windows.map(\.appName).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Windows (UI)

    func openSettings(_ tab: SettingsTab? = nil, workspace: UUID? = nil) {
        settingsWindow.show(tab: tab, workspace: workspace)
    }
}
