import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, snapWheel, layouts, workspaces, hotkeys, excluded, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Sidebar"
        case .snapWheel: "Snap Wheel"
        case .layouts: "Layouts"
        case .workspaces: "Workspaces"
        case .hotkeys: "Hotkeys"
        case .excluded: "Excluded Apps"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "sidebar.left"
        case .snapWheel: "circle.circle.fill"
        case .layouts: "rectangle.split.2x2.fill"
        case .workspaces: "square.stack.3d.up.fill"
        case .hotkeys: "command"
        case .excluded: "eye.slash.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: Brand.red
        case .snapWheel: .blue
        case .layouts: .teal
        case .workspaces: .purple
        case .hotkeys: .orange
        case .excluded: .pink
        case .permissions: .green
        case .about: .indigo
        }
    }
}

@MainActor @Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
    var selectedWorkspace: UUID?
}

struct SettingsView: View {
    let state: AppState
    @Bindable var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { nav.tab }, set: { if let tab = $0 { nav.tab = tab } })) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tab.color.gradient))
                }
                .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch nav.tab {
                case .general: GeneralSettings(state: state)
                case .appearance: AppearanceSettings(state: state)
                case .snapWheel: SnapWheelSettings(state: state)
                case .layouts: LayoutSettings(state: state)
                case .workspaces: WorkspaceEditorView(state: state, nav: nav)
                case .hotkeys: HotkeySettings()
                case .excluded: ExcludedAppsSettings(state: state)
                case .permissions: PermissionSettings(state: state)
                case .about: AboutView()
                }
            }
            .navigationTitle(nav.tab.title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let state: AppState
    @Bindable private var settings = Settings.shared
    private var login: LaunchAtLogin { state.launchAtLogin }

    var body: some View {
        Form {
            Section {
                Toggle("Start EasyMAC at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    HStack {
                        Text("Approve EasyMAC in Login Items to finish.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { login.openLoginItemsSettings() }
                    }
                }
                if let error = login.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                Toggle("Open Settings when EasyMAC is launched manually", isOn: $settings.showSettingsOnLaunch)
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Show sidebar", isOn: $settings.sidebarEnabled)
                Picker("Screen edge", selection: $settings.sidebarEdge) {
                    ForEach(SidebarEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Display", selection: $settings.sidebarDisplay) {
                    ForEach(SidebarDisplay.allCases) { Text($0.title).tag($0) }
                }
                if settings.sidebarDisplay == .specific {
                    Picker("Which display", selection: $settings.specificDisplayID) {
                        ForEach(NSScreen.screens, id: \.stableID) { screen in
                            Text(screen.localizedName).tag(screen.stableID)
                        }
                    }
                }
                Toggle(isOn: $settings.autoHide) {
                    Text("Auto-hide")
                    Text("Slides in when the mouse touches the screen edge, slides out when it leaves.")
                }
                Picker("Show windows from", selection: $settings.windowScope) {
                    ForEach(WindowScope.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Sidebar")
            }

            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { state.updater.automaticallyChecks }, set: { state.updater.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(get: { state.updater.automaticallyDownloads }, set: { state.updater.automaticallyDownloads = $0 }))
                    .disabled(!state.updater.automaticallyChecks)
                HStack {
                    Text(state.updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Never checked")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { state.updater.checkForUpdates() }
                }
            } header: {
                Text("Updates")
            }

            Section {
                Toggle("Hide other apps when restoring a workspace", isOn: $settings.hideOthersOnRestore)
            } header: {
                Text("Workspaces")
            }

            if SystemTweaks.stageManagerEnabled {
                Section {
                    HStack {
                        Label("Stage Manager is on — turn it off for the best experience.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Desktop & Dock…") { SystemTweaks.openDesktopAndDockSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    let state: AppState
    @Bindable private var settings = Settings.shared

    static let intervals: [(Double, String)] = [
        (1, "1 second"), (3, "3 seconds"), (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"),
        (60, "1 minute"), (300, "5 minutes"), (600, "10 minutes"),
    ]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 24) {
                    SidebarMiniPreview(size: settings.thumbnailSize, showTitles: settings.showTitles, accent: Color(nsColor: settings.sidebarAccent.nsColor))
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Thumbnail size", selection: $settings.thumbnailSize) {
                            ForEach(ThumbnailSize.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Style", selection: $settings.panelStyle) {
                            ForEach(PanelStyle.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Accent", selection: $settings.sidebarAccent) {
                            ForEach(AccentChoice.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Show titles under thumbnails", isOn: $settings.showTitles)
                        Toggle("Show “EasyMAC ⚙” footer", isOn: $settings.showFooter)
                    }
                }
            } header: {
                Text("Look")
            }

            Section {
                Toggle("Live thumbnails", isOn: $settings.showThumbnails)
                LabeledContent("Maximum windows shown") {
                    Stepper("\(settings.maxVisible)", value: $settings.maxVisible, in: 3...25)
                }
                Picker(selection: $settings.refreshInterval) {
                    ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                } label: {
                    Text("Refresh thumbnails every")
                    Text("Thumbnails also update instantly when you switch to or resize a window. Background windows refresh 4× slower; on battery everything is 2× slower.")
                }
                Picker("Order", selection: $settings.ordering) {
                    ForEach(WindowOrdering.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Thumbnails")
            }

            Section {
                Toggle("Large preview on hover", isOn: $settings.hoverPreview)
                if settings.hoverPreview {
                    Slider(value: $settings.hoverDelay, in: 0.1...1.0, step: 0.05) {
                        Text("Hover delay")
                    } minimumValueLabel: { Text("0.1s") } maximumValueLabel: { Text("1s") }
                }
            } header: {
                Text("Hover")
            }
        }
        .formStyle(.grouped)
    }
}

/// Tiny live mock of the strip so size/title/accent changes are visible immediately.
private struct SidebarMiniPreview: View {
    let size: ThumbnailSize
    let showTitles: Bool
    let accent: Color

    var body: some View {
        let scale: CGFloat = 0.75
        let w = size.width * scale
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color(hex: Workspace.palette[i]).gradient).frame(width: 12, height: 12)
                }
            }
            .padding(.bottom, 2)
            ForEach(0..<4, id: \.self) { i in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: Workspace.palette[(i + 1) % 9]).opacity(0.6), .black.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: w, height: w * 0.66)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(i == 0 ? accent : .clear, lineWidth: 2)
                        }
                    if showTitles {
                        Capsule().fill(Color.secondary.opacity(0.4)).frame(width: w * 0.7, height: 3)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: size)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showTitles)
    }
}

// MARK: - Snap wheel

private struct SnapWheelSettings: View {
    let state: AppState
    @Bindable private var settings = Settings.shared
    @State private var fnBusy = SystemTweaks.fnKeyDoesSomething
    @State private var demo = RadialModel()
    @State private var demoTimer: Timer?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    RadialRingView(model: demo)
                        .onAppear { startDemo() }
                        .onDisappear { demoTimer?.invalidate() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hold \(settings.radialTrigger == .fn ? "fn" : settings.radialTrigger.title) and move the mouse")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Pick a direction on the wheel and let go — the window snaps there. Edges give halves, corners give quarters, staying in the middle gives \(settings.radialCenterAction.title.lowercased()). Press Esc to cancel.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                Toggle("Enable snap wheel", isOn: $settings.radialEnabled)
                if !state.permissions.accessibilityGranted {
                    Label("Needs Accessibility permission.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Trigger key", selection: $settings.radialTrigger) {
                    ForEach(RadialTrigger.allCases) { Text($0.title).tag($0) }
                }
                Slider(value: $settings.radialHoldDelay, in: 0.05...0.5, step: 0.05) {
                    Text("Hold before showing")
                } minimumValueLabel: { Text("0.05s") } maximumValueLabel: { Text("0.5s") }
                Picker("Middle of the wheel", selection: $settings.radialCenterAction) {
                    ForEach(RadialCenterAction.allCases) { Text($0.title).tag($0) }
                }
                Picker("Moves", selection: $settings.radialTarget) {
                    ForEach(RadialTarget.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Behaviour")
            }

            Section {
                Toggle("Show where the window will land", isOn: $settings.radialShowPreview)
                Toggle("Haptic feedback (trackpad)", isOn: $settings.radialHaptics)
                Picker("Color", selection: $settings.radialAccent) {
                    ForEach(AccentChoice.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Feedback")
            }

            if settings.radialTrigger == .fn && fnBusy {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("The 🌐 / fn key also opens Emoji, Dictation or switches input source.", systemImage: "globe")
                            .font(.system(size: 13, weight: .medium))
                        Text("Set “Press 🌐 key to” → “Do Nothing” so holding fn only drives the snap wheel.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Set to Do Nothing") {
                                SystemTweaks.setFnKeyToDoNothing()
                                fnBusy = SystemTweaks.fnKeyDoesSomething
                            }
                            Button("Open Keyboard Settings") { SystemTweaks.openKeyboardSettings() }
                        }
                    }
                } header: {
                    Text("Tip")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.radialAccent) { demo.accent = Color(nsColor: settings.radialAccent.nsColor) }
    }

    private func startDemo() {
        demo.accent = Color(nsColor: settings.radialAccent.nsColor)
        demo.appeared = true
        let sequence: [RadialDirection] = [.left, .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .center]
        var i = 0
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in
            MainActor.assumeIsolated {
                demo.set(sequence[i % sequence.count])
                i += 1
            }
        }
    }
}

// MARK: - Layouts

private struct LayoutSettings: View {
    let state: AppState
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Slider(value: $settings.layoutGap, in: 0...24, step: 2) {
                        Text("Gap between windows")
                    } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("24") }
                    Text("\(Int(settings.layoutGap)) pt").font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.cycleSnapSizes) {
                    Text("Cycle sizes on repeat")
                    Text("Pressing left/right again goes ½ → ⅔ → ⅓.")
                }
                Toggle(isOn: $settings.reserveSidebarSpace) {
                    Text("Keep windows clear of the sidebar")
                    Text("Snapping, tiling and workspaces leave room for the pinned strip.")
                }
            } header: {
                Text("Snapping")
            }

            Section {
                Picker("“Tile visible windows” uses", selection: $settings.quickTilePreset) {
                    ForEach(LayoutPreset.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(LayoutPreset.allCases) { preset in
                        Button {
                            Task { await state.snap.tileVisible(preset) }
                        } label: {
                            VStack(spacing: 6) {
                                LayoutThumbnail(preset: preset)
                                Text(preset.title).font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Click a layout to apply it now to the windows on the display under your mouse.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Layouts")
            }
        }
        .formStyle(.grouped)
    }
}

struct LayoutThumbnail: View {
    let preset: LayoutPreset
    var count = 3

    var body: some View {
        let area = CGRect(x: 0, y: 0, width: 96, height: 60)
        let frames = LayoutEngine.frames(for: preset, count: preset == .grid ? 4 : count, in: area, gap: 3)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index == 0 ? Brand.red.opacity(0.85) : Color.secondary.opacity(0.45))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(preset == .maximize && index > 0 ? 0 : 1)
            }
        }
        .frame(width: area.width, height: area.height)
    }
}

// MARK: - Hotkeys

private struct HotkeySettings: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Show / hide sidebar", name: .toggleSidebar)
                KeyboardShortcuts.Recorder("Save current windows as workspace", name: .saveWorkspace)
                KeyboardShortcuts.Recorder("Window switcher", name: .windowSwitcher)
            } header: {
                Text("Sidebar")
            }
            Section {
                ForEach(Array(KeyboardShortcuts.Name.snapNames.enumerated()), id: \.offset) { _, entry in
                    KeyboardShortcuts.Recorder(entry.1, name: entry.0)
                }
            } header: {
                Text("Snapping")
            }
            Section {
                ForEach(Array(KeyboardShortcuts.Name.workspaceSlots.enumerated()), id: \.offset) { index, name in
                    KeyboardShortcuts.Recorder("Restore workspace \(index + 1)", name: name)
                }
            } header: {
                Text("Workspaces")
            }
            Section {
                Button("Reset All to Defaults") {
                    KeyboardShortcuts.reset([.toggleSidebar, .saveWorkspace, .windowSwitcher]
                        + KeyboardShortcuts.Name.snapNames.map(\.0)
                        + KeyboardShortcuts.Name.workspaceSlots)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Excluded apps

private struct ExcludedAppsSettings: View {
    let state: AppState
    @Bindable private var settings = Settings.shared
    @State private var selection: String?

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !settings.excludedBundleIDs.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 10) {
                            if let icon = AppIconCache.icon(bundleID: bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 20, height: 20)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(appName(bundleID))
                                Text(bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                settings.excludedBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .tag(bundleID)
                    }
                }
                .frame(minHeight: 220)
            } header: {
                Text("Windows from these apps never appear in the sidebar")
            }
            Section {
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                                if let id = app.bundleIdentifier { settings.excludedBundleIDs.append(id) }
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Restore Defaults") { settings.excludedBundleIDs = Settings.defaultExcluded }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    let state: AppState
    private var permissions: PermissionManager { state.permissions }

    var body: some View {
        Form {
            Section {
                row("Accessibility", "Focus, move and resize windows; snap wheel and hotkeys.", permissions.accessibilityGranted) {
                    permissions.requestAccessibility()
                }
                row("Screen Recording", "Live thumbnails and window titles.", permissions.screenRecordingGranted) {
                    permissions.requestScreenRecording()
                }
            }
            Section {
                HStack {
                    Text("Granted Screen Recording but thumbnails don't show? macOS applies it after a relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch EasyMAC") { PermissionManager.relaunch() }
                }
                Button("Show Welcome Screen") { state.onboarding.show() }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func row(_ title: String, _ detail: String, _ granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow…", action: action) }
        }
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            Text("EasyMAC").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("by AppAlbania").font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.red)
            Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))").font(.caption).foregroundStyle(.secondary)
            Text("A compact window strip, project workspaces and a snap wheel for macOS.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let url = URL(string: "https://appalbania.com") {
                Link("appalbania.com", destination: url).font(.system(size: 13, weight: .medium))
            }
            Spacer()
            Text("© 2026 AppAlbania").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let state: AppState
    private let nav = SettingsNavigation()
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show(tab: SettingsTab? = nil, workspace: UUID? = nil) {
        if let tab { nav.tab = tab }
        if let workspace { nav.selectedWorkspace = workspace }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(state: state, nav: nav))
            let window = NSWindow(contentViewController: host)
            window.title = "EasyMAC Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            host.sizingOptions = []
            window.setContentSize(NSSize(width: 920, height: 640))
            window.contentMinSize = NSSize(width: 860, height: 560)
            self.window = window
            window.centerOnMouseScreen()
        } else if let window, !window.isVisible || !(window.screen?.isSameDisplay(as: NSScreen.withMouse) ?? false) {
            window.centerOnMouseScreen()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
