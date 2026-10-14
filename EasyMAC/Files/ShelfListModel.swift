import AppKit
import Observation

/// State of one file list (pop-out or floating): the cached listing, search, selection and hover.
/// The listing is only re-read when the folder/tray/sort changes — never per frame or per hover.
@MainActor @Observable
final class ShelfListModel {
    let source: ShelfSource
    private(set) var files: [ShelfFile] = []
    private(set) var totalCount = 0
    private(set) var selection: Set<String> = []
    var hoveredID: String?
    var query = "" { didSet { applyFilter() } }

    @ObservationIgnored private let shelf: FileShelf
    @ObservationIgnored private var all: [ShelfFile] = []
    @ObservationIgnored private var anchor: Int?
    @ObservationIgnored var onSelectionChange: (() -> Void)?

    init(source: ShelfSource, shelf: FileShelf) {
        self.source = source
        self.shelf = shelf
        reload()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = shelf.revision
            _ = shelf.tray
            _ = Settings.shared.shelfSort
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
                self?.observe()
            }
        }
    }

    func reload() {
        all = shelf.files(for: source, sort: Settings.shared.shelfSort)
        totalCount = all.count
        applyFilter()
    }

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        if filtered != files { files = filtered }
        let ids = Set(files.map(\.id))
        if !selection.isSubset(of: ids) { selection = selection.intersection(ids) }
    }

    // MARK: - Selection

    var selectedFiles: [ShelfFile] { files.filter { selection.contains($0.id) } }
    var selectedURLs: [URL] { selectedFiles.filter(\.exists).map(\.url) }

    func isSelected(_ file: ShelfFile) -> Bool { selection.contains(file.id) }

    /// Finder rules: click selects one, ⌘ toggles, ⇧ extends from the last clicked row.
    func click(_ file: ShelfFile, modifiers: NSEvent.ModifierFlags) {
        guard let index = files.firstIndex(of: file) else { return }
        if modifiers.contains(.shift), let anchor {
            let range = min(anchor, index)...max(anchor, index)
            selection = Set(files[range].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
            anchor = index
        } else {
            selection = [file.id]
            anchor = index
        }
        onSelectionChange?()
    }

    /// Right-click / drag on an unselected row acts on that row alone (like Finder).
    func ensureSelected(_ file: ShelfFile) {
        guard !selection.contains(file.id) else { return }
        selection = [file.id]
        anchor = files.firstIndex(of: file)
        onSelectionChange?()
    }

    func move(_ delta: Int, extend: Bool) {
        guard !files.isEmpty else { return }
        let current = files.lastIndex { selection.contains($0.id) } ?? (delta > 0 ? -1 : files.count)
        let next = min(max(current + delta, 0), files.count - 1)
        if extend, let anchor {
            selection = Set(files[min(anchor, next)...max(anchor, next)].map(\.id))
        } else {
            selection = [files[next].id]
            anchor = next
        }
        onSelectionChange?()
    }

    func selectAll() {
        selection = Set(files.map(\.id))
        onSelectionChange?()
    }

    func clearSelection() {
        selection = []
        onSelectionChange?()
    }
}
