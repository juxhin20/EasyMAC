import AppKit

struct RestoreReport {
    var placed = 0
    var launched = 0
    var missing: [String] = []
}

/// Restores a workspace: launches missing apps, waits for their windows, matches windows to items,
/// places them, then raises them in order with the first item focused.
@MainActor
final class WorkspaceRestorer {
    private let ax = AXWindowService.shared
    private let settings = Settings.shared
    private let windowTimeout: TimeInterval = 8
    private let area: (NSScreen) -> CGRect

    init(area: @escaping (NSScreen) -> CGRect) {
        self.area = area
    }

    func restore(_ workspace: Workspace) async -> RestoreReport {
        var report = RestoreReport()
        let items = workspace.items
        guard !items.isEmpty else { return report }

        // 1. Make sure every app is running (launch in parallel, never stealing focus).
        var pids: [String: pid_t] = [:]
        var reopened = Set<String>()
        for bundleID in orderedUnique(items.map(\.bundleID)) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }) {
                pids[bundleID] = running.processIdentifier
            } else if let item = items.first(where: { $0.bundleID == bundleID }), let app = await launch(item) {
                pids[bundleID] = app.processIdentifier
                report.launched += 1
            } else {
                report.missing.append(items.first { $0.bundleID == bundleID }?.appName ?? bundleID)
            }
        }

        // 2. Wait (≤ 8s) until every item can be matched to a window.
        let requests = items.map { MatchRequest(bundleID: $0.bundleID, titleContains: $0.titleContains) }
        var assignment: [Int: UInt32] = [:]
        var candidates: [MatchCandidate] = []
        var candidatePID: [UInt32: pid_t] = [:]
        let started = Date()
        let deadline = started.addingTimeInterval(windowTimeout)
        var previousCount = -1
        repeat {
            candidates.removeAll()
            for (bundleID, pid) in pids {
                for window in await ax.windows(pid: pid) where window.isUserWindow && window.frame.width >= 80 {
                    candidates.append(MatchCandidate(windowID: window.windowID, bundleID: bundleID, title: window.title))
                    candidatePID[window.windowID] = pid
                }
            }
            assignment = WindowMatcher.assign(requests, candidates: candidates)
            if assignment.count == items.count { break }
            // Every app has windows and nothing new appeared: more items than windows, stop waiting.
            let everyAppHasWindow = pids.keys.allSatisfy { bundle in candidates.contains { $0.bundleID == bundle } }
            if everyAppHasWindow && candidates.count == previousCount && Date().timeIntervalSince(started) > 1.5 { break }
            previousCount = candidates.count

            // A running app with no windows (e.g. all closed): ask it to reopen one, once.
            for (bundleID, _) in pids where !reopened.contains(bundleID) && !candidates.contains(where: { $0.bundleID == bundleID }) {
                reopened.insert(bundleID)
                if let item = items.first(where: { $0.bundleID == bundleID }) { _ = await launch(item) }
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline

        // 3. Place windows.
        let layoutFrames = workspace.layout.map { preset -> [CGRect] in
            let screen = NSScreen.screen(withStableID: items.first?.screenID) ?? NSScreen.withMouse ?? NSScreen.main
            return LayoutEngine.frames(for: preset, count: items.count, in: screen.map(area) ?? .zero, gap: settings.layoutGap)
        }
        var placed: [(windowID: CGWindowID, pid: pid_t, frame: CGRect)] = []
        for (index, item) in items.enumerated() {
            guard let windowID = assignment[index], let pid = candidatePID[windowID] else {
                if pids[item.bundleID] != nil { report.missing.append(item.appName ?? item.bundleID) }
                continue
            }
            let frame: CGRect
            if let layoutFrames, index < layoutFrames.count {
                frame = layoutFrames[index]
            } else {
                let screen = NSScreen.screen(withStableID: item.screenID) ?? NSScreen.main
                frame = Coordinates.absolute(item.relativeFrame, in: screen.map(area) ?? .zero)
            }
            if NSRunningApplication(processIdentifier: pid)?.isHidden == true {
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }
            await ax.setFrame(frame, windowID: windowID, pid: pid)
            placed.append((windowID, pid, frame))
        }
        report.placed = placed.count

        // 4. Raise back-to-front so the first item ends on top and focused.
        for entry in placed.reversed() {
            await ax.focus(windowID: entry.windowID, pid: entry.pid)
            try? await Task.sleep(for: .milliseconds(35))
        }

        // 5. Optionally hide everything else.
        if settings.hideOthersOnRestore {
            let keep = Set(items.map(\.bundleID))
            let own = ProcessInfo.processInfo.processIdentifier
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && app.processIdentifier != own && !keep.contains(app.bundleIdentifier ?? "") {
                app.hide()
            }
        }

        // Freshly launched apps sometimes restore their own saved frame a beat later: re-apply once.
        if report.launched > 0 {
            try? await Task.sleep(for: .milliseconds(700))
            for entry in placed {
                await ax.setFrame(entry.frame, windowID: entry.windowID, pid: entry.pid)
            }
        }
        return report
    }

    private func launch(_ item: WorkspaceItem) async -> NSRunningApplication? {
        let url = item.appPath.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID)
        guard let url else {
            Log.workspaces.error("App not installed: \(item.bundleID, privacy: .public)")
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false

        let args = item.launchArgs ?? []
        let paths = args.filter { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
        configuration.arguments = args.filter { !paths.contains($0) }
        do {
            if !paths.isEmpty {
                let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                return try await NSWorkspace.shared.open(urls, withApplicationAt: url, configuration: configuration)
            }
            return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            Log.workspaces.error("Launch failed for \(item.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
