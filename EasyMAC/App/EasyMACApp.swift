import AppKit
import SwiftUI

@main
struct EasyMACApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(state: AppState.shared)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("EasyMAC")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarMenu: View {
    let state: AppState

    private var settings: Settings { state.settings }

    var body: some View {
        Button(sidebarTitle) { state.toggleSidebar() }

        Divider()

        Section("Workspaces") {
            if state.workspaces.workspaces.isEmpty {
                Text("No workspaces yet")
            }
            ForEach(state.workspaces.workspaces) { workspace in
                Button {
                    state.restoreWorkspace(workspace.id)
                } label: {
                    Text(workspace.hotkeyIndex.flatMap { HotkeyController.workspaceShortcutText($0) }
                        .map { "\(workspace.name)    \($0)" } ?? workspace.name)
                }
            }
            Button("Save Current Windows as Workspace") { state.saveCurrentAsWorkspace() }
        }

        Divider()

        Menu("Arrange Windows") {
            ForEach(LayoutPreset.allCases) { preset in
                Button(preset.title) { Task { await state.snap.tileVisible(preset) } }
            }
        }

        Divider()

        if !state.permissions.allGranted {
            Button("Grant Permissions…") { state.onboarding.show() }
        }
        Button("Settings…") { state.openSettings() }
            .keyboardShortcut(",")
        Button("About EasyMAC") { state.openSettings(.about) }

        Divider()

        Button("Quit EasyMAC") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var sidebarTitle: String {
        if settings.autoHide && settings.sidebarEnabled { return "Reveal Sidebar" }
        return settings.sidebarEnabled ? "Hide Sidebar" : "Show Sidebar"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start(launchedAtLogin: Self.wasLaunchedAtLogin())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening EasyMAC again (Finder, Spotlight, Launchpad) shows Settings.
        AppState.shared.openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.willTerminate()
    }

    /// Login-item launches carry `keyAELaunchedAsLogInItem`; very early launches after boot count too.
    private static func wasLaunchedAtLogin() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 120
    }
}
