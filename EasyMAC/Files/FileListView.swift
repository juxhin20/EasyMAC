import AppKit
import SwiftUI

/// Compact file list: small icon + name rows. Click / ⌘-click / ⇧-click select, Space previews
/// (Quick Look), Return opens, drag the selection into any app (Chrome, WhatsApp, Mail…).
struct FileListView: View {
    let model: ShelfListModel
    let shelf: FileShelf
    let isFloating: Bool
    let actions: ShelfActions

    @State private var dropTargeted = false
    private var settings: Settings { Settings.shared }
    private var source: ShelfSource { model.source }
    private var accent: Color { Color(nsColor: settings.sidebarAccent.nsColor) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if source != .tray || !shelf.tray.isEmpty {
                searchField
            }
            Divider().opacity(0.5)
            if model.files.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(model.files) { file in
                            FileRow(file: file, model: model, accent: accent, actions: actions)
                        }
                    }
                    .padding(6)
                }
            }
            if model.selection.count > 1 {
                Text("\(model.selection.count) selected · drag or Space")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .background(Color.primary.opacity(0.05))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTargeted ? accent : Color.white.opacity(0.12), lineWidth: dropTargeted ? 2 : 0.5)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard source == .tray else { return false }
            shelf.addToTray(urls)
            return true
        } isTargeted: { dropTargeted = $0 && source == .tray }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: source.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(source == .tray ? accent : Color(red: 0.27, green: 0.6, blue: 0.98))
            Text(source.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(model.totalCount >= FileShelf.maxItems ? "\(FileShelf.maxItems)+" : "\(model.totalCount)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if source == .tray && !shelf.tray.isEmpty {
                headerButton("trash", help: "Empty tray (files stay where they are)") { shelf.clearTray() }
            }
            if case .folder(let path) = source {
                headerButton("arrow.up.forward.app", help: "Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
            headerButton(isFloating ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: isFloating ? "Back into the strip" : "Float on top of all apps", action: actions.toggleFloat)
            headerButton("xmark", help: "Close", action: actions.close)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(WindowDragHandle())
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.tertiary)
            TextField("Search", text: Binding(get: { model.query }, set: { model.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: source == .tray ? "tray.and.arrow.down" : "folder")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(source == .tray ? "Drop files here to keep them handy" : (model.query.isEmpty ? "Folder is empty" : "No matches"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    /// "now", "5m", "3h", "2d", or a short date.
    static func shortAge(_ date: Date) -> String {
        guard date != .distantPast else { return "" }
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// Callbacks the list needs from its window/controller.
struct ShelfActions {
    var toggleFloat: () -> Void
    var close: () -> Void
    var preview: () -> Void
    var focusList: () -> Void
}

/// One row. Reads only its own selection/hover state, so hovering doesn't re-render the list.
private struct FileRow: View {
    let file: ShelfFile
    let model: ShelfListModel
    let accent: Color
    let actions: ShelfActions

    var body: some View {
        let selected = model.isSelected(file)
        let hovered = model.hoveredID == file.id
        HStack(spacing: 7) {
            Image(nsImage: FileShelf.icon(file))
                .frame(width: 18, height: 18)
            Text(file.name)
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(FileListView.shortAge(file.date))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? accent : (hovered ? Color.primary.opacity(0.09) : .clear)))
        .opacity(file.exists ? 1 : 0.4)
        .overlay(FileRowInteraction(file: file, model: model, actions: actions))
        .help(file.url.path)
    }
}

/// AppKit layer for a row: Finder-style click selection, double-click open, multi-file drag
/// (an `NSDraggingSession` with every selected file) and the right-click menu.
private struct FileRowInteraction: NSViewRepresentable {
    let file: ShelfFile
    let model: ShelfListModel
    let actions: ShelfActions

    func makeNSView(context: Context) -> RowView { RowView() }

    func updateNSView(_ view: RowView, context: Context) {
        view.file = file
        view.model = model
        view.actions = actions
    }

    final class RowView: NSView, NSDraggingSource {
        var file: ShelfFile?
        var model: ShelfListModel?
        var actions: ShelfActions?
        private var downEvent: NSEvent?
        private var tracking: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            MainActor.assumeIsolated { model?.hoveredID = file?.id }
        }

        override func mouseExited(with event: NSEvent) {
            MainActor.assumeIsolated { if model?.hoveredID == file?.id { model?.hoveredID = nil } }
        }

        override func mouseDown(with event: NSEvent) {
            downEvent = event
            MainActor.assumeIsolated {
                guard let file, let model else { return }
                actions?.focusList()
                if event.clickCount >= 2 {
                    if file.exists { FileShelf.open(file) }
                    return
                }
                // Plain click on an already-selected row keeps a multi-selection for dragging.
                if event.modifierFlags.intersection([.command, .shift]).isEmpty, model.isSelected(file), model.selection.count > 1 {
                    return
                }
                model.click(file, modifiers: event.modifierFlags)
            }
        }

        override func mouseUp(with event: NSEvent) {
            MainActor.assumeIsolated {
                // Finish the "click inside a multi-selection" case: no drag happened → select just this row.
                guard let file, let model, event.clickCount == 1,
                      event.modifierFlags.intersection([.command, .shift]).isEmpty,
                      model.selection.count > 1, model.isSelected(file) else { return }
                model.click(file, modifiers: [])
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard hypot(dx, dy) > 3 else { return }
            downEvent = nil
            let urls: [URL] = MainActor.assumeIsolated {
                guard let file, let model else { return [] }
                model.ensureSelected(file)
                return model.selectedURLs
            }
            guard !urls.isEmpty else { return }
            let items: [NSDraggingItem] = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(min(index, 4)) * 3
                item.setDraggingFrame(NSRect(x: offset, y: -offset, width: 28, height: 28), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: down, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic, .link] : .copy
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            do {
                guard let file, let model else { return nil }
                model.ensureSelected(file)
                let files = model.selectedFiles
                let menu = NSMenu()
                let count = files.count
                menu.addItem(ClosureMenuItem(count > 1 ? "Open \(count) Files" : "Open") { files.filter(\.exists).forEach(FileShelf.open) })
                menu.addItem(ClosureMenuItem("Quick Look") { [weak self] in self?.actions?.preview() })
                menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url)) })
                menu.addItem(ClosureMenuItem(count > 1 ? "Copy \(count) Files" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(files.map { $0.url as NSURL })
                })
                menu.addItem(.separator())
                if model.source == .tray {
                    menu.addItem(ClosureMenuItem(count > 1 ? "Remove \(count) from Tray" : "Remove from Tray") {
                        files.forEach { AppState.shared.files.removeFromTray($0.url.path) }
                    })
                } else {
                    menu.addItem(ClosureMenuItem(count > 1 ? "Add \(count) to Tray" : "Add to Tray") {
                        AppState.shared.files.addToTray(files.map(\.url))
                    })
                }
                return menu
            }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// Lets the header drag the (borderless) floating window around.
struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
