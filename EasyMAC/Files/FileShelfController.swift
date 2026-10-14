import AppKit
import SwiftUI

/// File panels can become key (for the search field) without activating EasyMAC.
final class FilePanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows file lists: one pop-out next to the strip, plus any number of floating windows (↗).
/// Floating windows remember their position and reopen on launch.
@MainActor
final class FileShelfController {
    private unowned let state: AppState
    private var settings: Settings { state.settings }

    private var popover: FilePanel?
    private var popoverSource: ShelfSource?
    private var floating: [String: FilePanel] = [:]
    private var clickMonitors: [Any] = []
    private var moveObservers: [String: NSObjectProtocol] = [:]

    private static let popoverSize = NSSize(width: 260, height: 360)
    private static let floatingSize = NSSize(width: 230, height: 300)

    init(state: AppState) {
        self.state = state
    }

    var isPopoverOpen: Bool { popover?.isVisible == true }

    func restoreFloating() {
        for id in UserDefaults.standard.stringArray(forKey: "floatingShelves") ?? [] {
            if let source = ShelfSource(id: id) { showFloating(source) }
        }
    }

    // MARK: - Pop-out

    /// Toggles the pop-out for `source`, placed beside the strip at the clicked row.
    func toggle(_ source: ShelfSource, anchorY: CGFloat, stripFrame: NSRect, edge: SidebarEdge, screen: NSScreen) {
        if popoverSource == source, isPopoverOpen {
            closePopover()
            return
        }
        if floating[source.id] != nil {
            floating[source.id]?.orderFrontRegardless()
            return
        }
        state.sidebar.hidePreview()
        let panel = popover ?? makePanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        popover = panel
        popoverSource = source
        panel.contentView = content(for: source, floating: false)

        let size = Self.popoverSize
        let visible = screen.visibleFrame
        let x = edge == .left ? stripFrame.maxX + 8 : stripFrame.minX - 8 - size.width
        let y = min(max(anchorY - size.height + 40, visible.minY + 8), visible.maxY - size.height - 8)
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height).integral
        panel.setFrame(frame.offsetBy(dx: edge == .left ? -6 : 6, dy: 0), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        installOutsideClickMonitor()
    }

    func closePopover() {
        removeClickMonitors()
        guard let panel = popover, panel.isVisible else { return }
        popoverSource = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    private func installOutsideClickMonitor() {
        removeClickMonitors()
        // Clicking anywhere else (another app, the desktop) closes the pop-out; drags out of it don't.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }) { clickMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.closePopover() } }
            return event
        }) { clickMonitors.append(m) }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
    }

    // MARK: - Floating windows

    func toggleFloat(_ source: ShelfSource) {
        if floating[source.id] != nil {
            closeFloating(source)
        } else {
            closePopover()
            showFloating(source)
        }
    }

    func showFloating(_ source: ShelfSource) {
        if let existing = floating[source.id] {
            existing.orderFrontRegardless()
            return
        }
        let panel = makePanel(level: settings.shelfAlwaysOnTop ? .floating : .normal)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content(for: source, floating: true)
        let key = "shelfFrame." + source.id
        if let saved = UserDefaults.standard.string(forKey: key).map(NSRectFromString),
           saved.width > 100, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            panel.setFrame(saved, display: true)
        } else if let screen = NSScreen.withMouse {
            let size = Self.floatingSize
            let offset = CGFloat(floating.count) * 28
            panel.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 24 - offset,
                                  y: screen.visibleFrame.maxY - size.height - 24 - offset,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        floating[source.id] = panel
        moveObservers[source.id] = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: key) }
        }
        persistFloating()
    }

    func closeFloating(_ source: ShelfSource) {
        guard let panel = floating.removeValue(forKey: source.id) else { return }
        if let observer = moveObservers.removeValue(forKey: source.id) { NotificationCenter.default.removeObserver(observer) }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "shelfFrame." + source.id)
        panel.orderOut(nil)
        persistFloating()
    }

    func isFloating(_ source: ShelfSource) -> Bool { floating[source.id] != nil }

    /// Applies "always on top" and closes windows for folders that were removed.
    func settingsChanged() {
        let validIDs = Set(state.files.sources.map(\.id))
        for id in floating.keys where !validIDs.contains(id) {
            if let source = ShelfSource(id: id) { closeFloating(source) }
        }
        for panel in floating.values {
            panel.level = settings.shelfAlwaysOnTop ? .floating : .normal
        }
    }

    private func persistFloating() {
        UserDefaults.standard.set(Array(floating.keys), forKey: "floatingShelves")
    }

    // MARK: - Building

    private func makePanel(level: NSWindow.Level) -> FilePanel {
        let panel = FilePanel(level: level)
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func content(for source: ShelfSource, floating isFloating: Bool) -> NSView {
        let view = FileListView(
            source: source,
            shelf: state.files,
            isFloating: isFloating,
            onToggleFloat: { [weak self] in self?.toggleFloat(source) },
            onClose: { [weak self] in
                if isFloating { self?.closeFloating(source) } else { self?.closePopover() }
            }
        )
        let host = TrackingHostingView(rootView: AnyView(view))
        return PanelBackground.make(style: settings.panelStyle, cornerRadius: 14, content: host)
    }
}
