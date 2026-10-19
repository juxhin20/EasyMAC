import AppKit
import SwiftUI

/// One small row in the strip: icon + name (+ count for the tray).
struct ShelfRow: View {
    let source: ShelfSource
    let state: AppState
    let accent: Color
    let width: CGFloat

    @State private var hovered = false
    @State private var targeted = false

    private var isOpen: Bool { state.shelf.isFloating(source) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : source.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(source == .tray ? accent : Color(red: 0.27, green: 0.6, blue: 0.98))
                .frame(width: 13)
            Text(source.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if source == .tray, !state.files.tray.isEmpty {
                Text("\(state.files.tray.count)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 12)
                    .background(Capsule().fill(accent))
            }
            if isOpen {
                Circle().fill(accent).frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: SidebarMetrics.fileRow)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(targeted ? accent.opacity(0.25) : (hovered ? Color.primary.opacity(0.10) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { state.toggleShelf(source) }
        .dropDestination(for: URL.self) { urls, _ in
            guard source == .tray else { return false }
            state.files.addToTray(urls)
            return true
        } isTargeted: { targeted = $0 && source == .tray }
        .help(source == .tray ? "Tray — drop files here, click to see them" : "\(source.title) — click to see files")
        .contextMenu {
            Button(isOpen ? "Close Floating Window" : "Open as Floating Window") { state.shelf.toggleFloat(source) }
            if case .folder(let path) = source {
                Button("Open in Finder") { FileShelf.openFolder(URL(fileURLWithPath: path)) }
            }
            if source == .tray && !state.files.tray.isEmpty {
                Button("Empty Tray") { state.files.clearTray() }
            }
        }
    }
}
