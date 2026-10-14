import AppKit
import SwiftUI

struct OnboardingView: View {
    let state: AppState
    let onDone: () -> Void

    private var permissions: PermissionManager { state.permissions }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                Text("Welcome to EasyMAC")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("A compact strip of live window thumbnails, one-click workspaces and a snap wheel.\nTwo permissions and you're ready.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 22)

            VStack(spacing: 10) {
                PermissionRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Focus, move and resize windows; the fn snap wheel and hotkeys.",
                    granted: permissions.accessibilityGranted,
                    action: { permissions.requestAccessibility() }
                )
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Live thumbnails and window titles. Optional — app icons are shown without it.",
                    granted: permissions.screenRecordingGranted,
                    action: { permissions.requestScreenRecording() }
                )
            }
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 8) {
                if SystemTweaks.stageManagerEnabled {
                    Tip(symbol: "rectangle.3.group", text: "Stage Manager is on. EasyMAC works best with it off.") {
                        Button("Open Desktop & Dock") { SystemTweaks.openDesktopAndDockSettings() }
                    }
                }
                if !permissions.screenRecordingGranted && permissions.screenRecordingRequested {
                    Tip(symbol: "arrow.clockwise", text: "Just allowed Screen Recording? macOS applies it after a relaunch.") {
                        Button("Relaunch EasyMAC") { PermissionManager.relaunch() }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Spacer(minLength: 12)

            HStack {
                Text("EasyMAC by AppAlbania")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(permissions.accessibilityGranted ? "Get Started" : "Continue Without Accessibility") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(Brand.red)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .onChange(of: permissions.allGranted) { _, granted in
            guard granted else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                onDone()
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Brand.red)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.red.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow…", action: action)
                    .controlSize(.regular)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: granted)
    }
}

private struct Tip<Accessory: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            accessory().controlSize(.small)
        }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private unowned let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(state: state) { [weak self] in self?.finish() })
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        window?.centerOnMouseScreen()
        state.permissions.startMonitoring(interval: 1)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func finish() {
        state.settings.hasCompletedOnboarding = true
        window?.close()
        state.settingsWindow.show()
    }

    func windowWillClose(_ notification: Notification) {
        state.permissions.startMonitoring(interval: 2)
        state.radial.start()
        window = nil
    }
}
