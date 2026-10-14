import AppKit
import SwiftUI

/// Compact file list: small icon + name rows. Drag a row into any app (Chrome, WhatsApp, Mail…),
/// double-click to open, right-click for more. Used both as the strip's pop-out and as a floating window.
struct FileListView: View {
    let source: ShelfSource
    let shelf: FileShelf
    let isFloating: Bool
    let onToggleFloat: () -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var hovered: String?
    @State private var dropTargeted = false
    private var settings: Settings { Settings.shared }

    private var files: [ShelfFile] {
        let all = shelf.files(for: source, sort: settings.shelfSort)
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let files = self.files
        VStack(spacing: 0) {
            header(count: files.count)
            if source != .tray || !shelf.tray.isEmpty {
                searchField
            }
            Divider().opacity(0.5)
            if files.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(files) { file in row(file) }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTargeted ? Color(nsColor: settings.sidebarAccent.nsColor) : Color.white.opacity(0.12),
                              lineWidth: dropTargeted ? 2 : 0.5)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard source == .tray else { return false }
            shelf.addToTray(urls)
            return true
        } isTargeted: { dropTargeted = $0 && source == .tray }
    }

    // MARK: - Pieces

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(source == .tray ? Color(nsColor: settings.sidebarAccent.nsColor) : Color(red: 0.27, green: 0.6, blue: 0.98))
            Text(source.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(count >= FileShelf.maxItems ? "\(FileShelf.maxItems)+" : "\(count)")
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
                         help: isFloating ? "Back into the strip" : "Float on top of all apps", action: onToggleFloat)
            headerButton("xmark", help: "Close", action: onClose)
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
            TextField("Search", text: $query)
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
            Text(source == .tray ? "Drop files here to keep them handy" : (query.isEmpty ? "Folder is empty" : "No matches"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func row(_ file: ShelfFile) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: FileShelf.icon(file))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(file.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.shortAge(file.date))
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovered == file.id ? Color.primary.opacity(0.09) : .clear))
        .opacity(file.exists ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? file.id : (hovered == file.id ? nil : hovered) }
        .onTapGesture(count: 2) { if file.exists { FileShelf.open(file) } }
        .onDrag {
            NSItemProvider(contentsOf: file.url) ?? NSItemProvider(object: file.url as NSURL)
        }
        .help(file.url.path)
        .contextMenu {
            Button("Open") { FileShelf.open(file) }.disabled(!file.exists)
            Button("Show in Finder") { FileShelf.reveal(file) }.disabled(!file.exists)
            Button("Copy") { FileShelf.copy(file) }.disabled(!file.exists)
            Divider()
            if source == .tray {
                Button("Remove from Tray") { shelf.removeFromTray(file.url.path) }
            } else {
                Button("Add to Tray") { shelf.addToTray([file.url]) }
            }
        }
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
