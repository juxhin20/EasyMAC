import AppKit
import Quartz
import SwiftUI

/// File panels can become key (search field, keyboard, Quick Look) without activating EasyMAC.
/// The panel is in the responder chain, so it controls the shared Quick Look panel.
final class FilePanel: FloatingPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var model: ShelfListModel?
    /// The list whose files Quick Look is currently showing (receives keys while Quick Look is key).
    nonisolated(unsafe) static weak var previewOwner: FilePanel?

    override var canBecomeKey: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    private var previewURLs: [URL] {
        MainActor.assumeIsolated { model?.selectedURLs ?? [] }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = previewURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Arrow keys inside Quick Look move the selection in the list, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            guard let model, model.selection.count <= 1 else { return false }
            switch event.keyCode {
            case 125: model.move(1, extend: false)
            case 126: model.move(-1, extend: false)
            default: return false
            }
            panel.reloadData()
            return true
        }
    }

    /// Space: open/close Quick Look for the selection.
    func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            makeKey() // keep arrows/Space working in the list after closing the preview
        } else if !previewURLs.isEmpty {
            FilePanel.previewOwner = self
            // Show Quick Look but keep this list key: EasyMAC never activates, so if Quick Look took
            // key status the next keystroke would go to the app you were working in.
            makeKey()
            panel.updateController()
            panel.orderFront(nil)
            panel.reloadData()
            makeKey()
        }
    }

    func selectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
    }

    /// Text field has focus → typing goes to search, not to list shortcuts.
    var isEditingText: Bool { firstResponder is NSTextView }
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
    private var keyMonitor: Any?
    private var moveObservers: [String: NSObjectProtocol] = [:]

    private static let popoverSize = NSSize(width: 260, height: 360)
    private static let floatingSize = NSSize(width: 230, height: 300)

    init(state: AppState) {
        self.state = state
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
    }

    /// Finder-style keys for the focused file list. Returns true when handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let fromQuickLook = event.window is QLPreviewPanel
        guard let panel = event.window as? FilePanel ?? (fromQuickLook ? FilePanel.previewOwner : nil),
              let model = panel.model else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editing = panel.isEditingText
        switch event.keyCode {
        case 49 where !editing: // Space
            panel.togglePreview()
            return true
        case 126 where mods.contains(.command): // ⌘↑ back to the parent folder
            model.goBack()
            return true
        case 125 where mods.contains(.command): // ⌘↓ open the selected folder / file
            model.selectedFiles.forEach(model.open)
            return true
        case 125, 126: // ↓ ↑
            if editing { panel.makeFirstResponder(nil) }
            model.move(event.keyCode == 125 ? 1 : -1, extend: mods.contains(.shift))
            return true
        case 36 where !model.selection.isEmpty, 76 where !model.selection.isEmpty: // Return
            model.selectedFiles.forEach(model.open)
            return true
        case 0 where mods.contains(.command) && !editing: // ⌘A
            model.selectAll()
            return true
        case 51 where !editing && model.source == .tray, 117 where !editing && model.source == .tray: // Delete removes from tray
            model.selectedFiles.forEach { state.files.removeFromTray($0.url.path) }
            return true
        case 53: // Esc
            if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible {
                ql.orderOut(nil)
                panel.makeKey()
            } else if panel === popover {
                closePopover()
            } else {
                model.clearSelection()
            }
            return true
        default:
            return false
        }
    }

    var isPopoverOpen: Bool { popover?.isVisible == true }

    // MARK: - Menu bar icon

    private var statusItem: NSStatusItem?
    private lazy var statusMenuDelegate = ShelfStatusMenu(controller: self)

    /// Optional folder icon in the menu bar: lists Tray + pinned folders, opens the list right below.
    func updateStatusItem() {
        let wanted = settings.showFilesIcon && (settings.showTray || settings.showFiles)
        if wanted, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Files & Tray")
            image?.isTemplate = true
            item.button?.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            item.button?.toolTip = "Tray & folders"
            let menu = NSMenu()
            menu.delegate = statusMenuDelegate
            item.menu = menu
            statusItem = item
        } else if !wanted, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    fileprivate func openFromStatusItem(_ source: ShelfSource) {
        guard let frame = statusItem?.button?.window?.frame else { return }
        // Let the menu close first so the pop-out isn't dismissed by its click.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            toggle(source, below: frame)
        }
    }

    fileprivate var statusSources: [ShelfSource] { state.visibleShelfSources }
    fileprivate var trayCount: Int { state.files.tray.count }

    func restoreFloating() {
        for id in UserDefaults.standard.stringArray(forKey: "floatingShelves") ?? [] {
            if let source = ShelfSource(id: id) { showFloating(source) }
        }
    }

    // MARK: - Pop-out

    /// Toggles the pop-out for `source`, placed beside the strip at the clicked row.
    func toggle(_ source: ShelfSource, anchorY: CGFloat, stripFrame: NSRect, edge: SidebarEdge, screen: NSScreen) {
        let size = Self.popoverSize
        let visible = screen.visibleFrame
        let x = edge == .left ? stripFrame.maxX + 8 : stripFrame.minX - 8 - size.width
        let y = min(max(anchorY - size.height + 40, visible.minY + 8), visible.maxY - size.height - 8)
        present(source, frame: NSRect(x: x, y: y, width: size.width, height: size.height).integral, slide: edge == .left ? -6 : 6)
    }

    /// Opens the pop-out right under a menu bar icon.
    func toggle(_ source: ShelfSource, below buttonFrame: NSRect) {
        let size = Self.popoverSize
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = min(max(buttonFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        present(source, frame: NSRect(x: x, y: visible.maxY - size.height - 6, width: size.width, height: size.height).integral, slide: 0)
    }

    private func present(_ source: ShelfSource, frame: NSRect, slide: CGFloat) {
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
        panel.contentView = content(for: source, floating: false, panel: panel)

        panel.setFrame(frame.offsetBy(dx: slide, dy: slide == 0 ? 6 : 0), display: true)
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
        if QLPreviewPanel.sharedPreviewPanelExists(), let ql = QLPreviewPanel.shared(), ql.isVisible { ql.orderOut(nil) }
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
        panel.contentView = content(for: source, floating: true, panel: panel)
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

    private func content(for source: ShelfSource, floating isFloating: Bool, panel: FilePanel) -> NSView {
        let model = ShelfListModel(source: source, shelf: state.files)
        panel.model = model
        model.onSelectionChange = { [weak panel] in panel?.selectionChanged() }
        let actions = ShelfActions(
            toggleFloat: { [weak self] in self?.toggleFloat(source) },
            close: { [weak self] in
                if isFloating { self?.closeFloating(source) } else { self?.closePopover() }
            },
            preview: { [weak panel] in panel?.togglePreview() },
            focusList: { [weak panel] in
                panel?.makeKey()
                panel?.makeFirstResponder(nil)
            }
        )
        let view = FileListView(model: model, shelf: state.files, isFloating: isFloating, actions: actions)
        let host = TrackingHostingView(rootView: AnyView(view))
        return PanelBackground.make(style: settings.panelStyle, cornerRadius: 14, content: host)
    }
}

/// Builds the folder icon's menu each time it opens (counts stay current).
@MainActor
private final class ShelfStatusMenu: NSObject, NSMenuDelegate {
    private unowned let controller: FileShelfController

    init(controller: FileShelfController) {
        self.controller = controller
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for source in controller.statusSources {
            let title = source == .tray && controller.trayCount > 0 ? "Tray (\(controller.trayCount))" : source.title
            let item = ClosureMenuItem(title) { [weak controller] in controller?.openFromStatusItem(source) }
            item.image = NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Files Settings…") { AppState.shared.openSettings(.files) })
    }
}
