import Foundation

/// JSON persistence for workspaces with a schema `version` for migrations.
///
/// - v0: bare `[Workspace]` array (pre-release builds)
/// - v1: `{ "version": 1, "workspaces": [...] }`
final class WorkspaceStore {
    static let currentVersion = 1

    struct FileFormat: Codable {
        var version: Int
        var workspaces: [Workspace]
    }

    enum StoreError: Error {
        case unsupportedVersion(Int)
    }

    let fileURL: URL

    init(fileURL: URL = WorkspaceStore.defaultURL) {
        self.fileURL = fileURL
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EasyMAC", isDirectory: true).appendingPathComponent("workspaces.json")
    }

    /// Loads workspaces, migrating older formats in place. A missing file yields `[]`.
    /// A corrupt file is moved aside (never silently overwritten) and yields `[]`.
    func load() throws -> [Workspace] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()

        if let file = try? decoder.decode(FileFormat.self, from: data) {
            if file.version > Self.currentVersion {
                throw StoreError.unsupportedVersion(file.version)
            }
            if file.version < Self.currentVersion {
                try save(file.workspaces)
            }
            return file.workspaces
        }

        if let legacy = try? decoder.decode([Workspace].self, from: data) {
            try save(legacy)
            return legacy
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        return []
    }

    func save(_ workspaces: [Workspace]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(version: Self.currentVersion, workspaces: workspaces))
        try data.write(to: fileURL, options: .atomic)
    }
}
