import AppKit
import Observation

@MainActor @Observable
final class WorkspaceManager {
    private(set) var workspaces: [Workspace] = []
    private(set) var restoringID: UUID?
    private(set) var loadError: String?

    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
        do {
            workspaces = try store.load()
        } catch {
            loadError = error.localizedDescription
            Log.workspaces.error("Loading workspaces failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    func workspace(hotkey index: Int) -> Workspace? { workspaces.first { $0.hotkeyIndex == index } }

    var nextFreeHotkey: Int? {
        let used = Set(workspaces.compactMap(\.hotkeyIndex))
        return (1...9).first { !used.contains($0) }
    }

    var nextColor: String {
        Workspace.palette[workspaces.count % Workspace.palette.count]
    }

    func add(_ workspace: Workspace) {
        workspaces.append(workspace)
        persist()
    }

    func update(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var workspace = workspace
        // Hotkey slots are unique: taking a slot frees it elsewhere.
        if let slot = workspace.hotkeyIndex {
            for i in workspaces.indices where i != index && workspaces[i].hotkeyIndex == slot {
                workspaces[i].hotkeyIndex = nil
            }
        }
        workspace.name = workspace.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Workspace" : workspace.name
        workspaces[index] = workspace
        persist()
    }

    func delete(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setRestoring(_ id: UUID?) {
        restoringID = id
    }

    /// Builds workspace items from live windows, storing frames relative to each window's display.
    func makeItems(from windows: [WindowInfo], area: (NSScreen) -> CGRect) -> [WorkspaceItem] {
        let perApp = Dictionary(grouping: windows, by: { $0.bundleID ?? "" }).mapValues(\.count)
        return windows.compactMap { window in
            guard let bundleID = window.bundleID else { return nil }
            let screen = NSScreen.screen(forAXRect: window.frame) ?? NSScreen.main
            let area = screen.map(area) ?? window.frame
            let hint = (perApp[bundleID] ?? 0) > 1 ? WindowMatcher.suggestHint(title: window.title, appName: window.appName) : nil
            return WorkspaceItem(
                bundleID: bundleID,
                appName: window.appName,
                appPath: NSRunningApplication(processIdentifier: window.pid)?.bundleURL?.path,
                titleContains: hint,
                relativeFrame: Coordinates.relative(window.frame, in: area),
                screenID: screen?.stableID
            )
        }
    }

    private func persist() {
        saveTask?.cancel()
        let snapshot = workspaces
        let store = store
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try store.save(snapshot)
            } catch {
                Log.workspaces.error("Saving workspaces failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flushes pending writes (called on quit).
    func saveNow() {
        saveTask?.cancel()
        try? store.save(workspaces)
    }
}
