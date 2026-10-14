import AppKit
import Observation

/// Where a file list comes from: the tray, or a pinned folder.
enum ShelfSource: Hashable, Identifiable, Sendable {
    case tray
    case folder(String)

    var id: String {
        switch self {
        case .tray: "tray"
        case .folder(let path): path
        }
    }

    var title: String {
        switch self {
        case .tray: "Tray"
        case .folder(let path): FileManager.default.displayName(atPath: path)
        }
    }

    var symbol: String {
        switch self {
        case .tray: "tray.fill"
        case .folder: "folder.fill"
        }
    }

    init?(id: String) {
        if id == "tray" { self = .tray } else if id.hasPrefix("/") { self = .folder(id) } else { return nil }
    }
}

struct ShelfFile: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let date: Date
    let size: Int64?
    let isDirectory: Bool
    let exists: Bool

    var id: String { url.path }
}

enum ShelfSort: String, CaseIterable, Identifiable {
    case newest, name
    var id: String { rawValue }
    var title: String { self == .newest ? "Newest first" : "Name" }
}

/// Pinned folders + the tray. The tray stores **paths only** (no copies); missing files show greyed out.
/// Folders are watched with a vnode source so lists update live while files arrive.
@MainActor @Observable
final class FileShelf {
    private(set) var folders: [String]
    private(set) var tray: [String]
    /// Bumped when a watched folder changes, so open lists reload.
    private(set) var revision = 0

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    static let maxItems = 300

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        folders = defaults.stringArray(forKey: "shelfFolders") ?? [home + "/Downloads", home + "/Desktop"]
        tray = defaults.stringArray(forKey: "trayPaths") ?? []
        watchFolders()
    }

    var sources: [ShelfSource] {
        [.tray] + folders.map { .folder($0) }
    }

    // MARK: - Folders

    func addFolder(_ path: String) {
        guard !folders.contains(path) else { return }
        folders.append(path)
        save()
        watchFolders()
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        save()
        watchFolders()
    }

    func moveFolder(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Tray

    func addToTray(_ urls: [URL]) {
        var added = false
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            tray.removeAll { $0 == path }
            tray.insert(path, at: 0)
            added = true
        }
        if added { save() }
    }

    func removeFromTray(_ path: String) {
        tray.removeAll { $0 == path }
        save()
    }

    func clearTray() {
        tray.removeAll()
        save()
    }

    // MARK: - Listing

    func files(for source: ShelfSource, sort: ShelfSort) -> [ShelfFile] {
        _ = revision
        switch source {
        case .tray:
            return tray.map { Self.file(at: URL(fileURLWithPath: $0)) }
        case .folder(let path):
            let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey, .isDirectoryKey, .fileSizeKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            var files = urls.map { Self.file(at: $0) }
            switch sort {
            case .newest: files.sort { $0.date > $1.date }
            case .name: files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            return Array(files.prefix(Self.maxItems))
        }
    }

    private static func file(at url: URL) -> ShelfFile {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .addedToDirectoryDateKey, .isDirectoryKey, .fileSizeKey])
        let exists = FileManager.default.fileExists(atPath: url.path)
        return ShelfFile(
            url: url,
            name: FileManager.default.displayName(atPath: url.path),
            // "Date added" matches what you see in Finder for Downloads; fall back to modified.
            date: values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize.map(Int64.init),
            isDirectory: values?.isDirectory ?? false,
            exists: exists
        )
    }

    // MARK: - Persistence & watching

    private func save() {
        defaults.set(folders, forKey: "shelfFolders")
        defaults.set(tray, forKey: "trayPaths")
    }

    private func watchFolders() {
        for (path, source) in watchers where !folders.contains(path) {
            source.cancel()
            watchers[path] = nil
        }
        for path in folders where watchers[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.revision += 1 }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[path] = source
        }
    }

    // MARK: - Actions

    static func open(_ file: ShelfFile) {
        NSWorkspace.shared.open(file.url)
    }

    static func reveal(_ file: ShelfFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    static func copy(_ file: ShelfFile) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file.url as NSURL])
    }

    private static var icons: [String: NSImage] = [:]

    static func icon(_ file: ShelfFile) -> NSImage {
        if let cached = icons[file.url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: file.url.path)
        if icons.count > 800 { icons.removeAll() }
        icons[file.url.path] = icon
        return icon
    }
}
