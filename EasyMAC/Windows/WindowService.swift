import AppKit
import Observation

/// One row of `CGWindowListCopyWindowInfo`, parsed off the main thread.
struct CGWindowRecord: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: CGRect
    let layer: Int
    let alpha: Double

    /// Front-to-back list of on-screen windows in the current Space.
    static func onScreen() -> [CGWindowRecord] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return CGWindowRecord(
                id: id,
                pid: pid,
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }

    /// Topmost normal window under an AX-space point, ignoring EasyMAC's own panels.
    static func windowUnder(_ point: CGPoint, excludingPID: pid_t) -> CGWindowRecord? {
        onScreen().first { $0.layer == 0 && $0.pid != excludingPID && $0.alpha > 0 && $0.bounds.contains(point) }
    }
}

/// Enumerates user windows: on-screen ones via CoreGraphics (cheap, z-ordered) plus minimized /
/// hidden ones via Accessibility. Polls only while someone needs the list (sidebar visible).
@MainActor @Observable
final class WindowService {
    /// Sorted for display (pinned → recent/stable), filtered by display scope.
    private(set) var windows: [WindowInfo] = []
    /// Every known user window regardless of display scope, MRU order.
    @ObservationIgnored private(set) var allWindows: [WindowInfo] = []
    private(set) var pinned: [CGWindowID] = []

    /// Returns `true` when a window frame (AX coords) belongs to the sidebar's display.
    @ObservationIgnored var displayFilter: ((CGRect) -> Bool)?

    @ObservationIgnored private let ax = AXWindowService.shared
    @ObservationIgnored private let settings = Settings.shared
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activation: [CGWindowID: Date] = [:]
    @ObservationIgnored private var firstSeen: [CGWindowID: Date] = [:]
    @ObservationIgnored private var axWindows: [CGWindowID: AXWindowSnapshot] = [:]
    @ObservationIgnored private var axReadable: Set<pid_t> = []
    @ObservationIgnored private var lastSweep = Date.distantPast
    @ObservationIgnored private var lastTop: CGWindowID?
    @ObservationIgnored private var lastOnScreen = Set<CGWindowID>()
    /// Confirmed non-user windows → owning pid (forgotten when that app quits; IDs get reused).
    @ObservationIgnored private var rejected: [CGWindowID: pid_t] = [:]
    @ObservationIgnored private var sweeping = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var pendingForceSweep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var apps: [pid_t: (bundleID: String?, name: String, regular: Bool)] = [:]

    private static let ignoredOwners: Set<String> = ["Window Server", "Dock", "Control Center", "Notification Center", "Spotlight", "Screenshot"]
    private static let minimumSize: CGFloat = 120

    // MARK: - Lifecycle

    func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification, let pid {
                        self.apps[pid] = nil
                        AppIconCache.forget(pid: pid)
                    }
                    self.requestRefresh(forceSweep: true)
                }
            })
        }
    }

    /// Polls every second while `active`; the timer is fully stopped otherwise (no idle cost).
    func setPolling(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRefresh() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            requestRefresh(forceSweep: true)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func requestRefresh(forceSweep: Bool = false) {
        Task { await refresh(forceSweep: forceSweep) }
    }

    // MARK: - Pinning

    func togglePin(_ id: CGWindowID) {
        if let index = pinned.firstIndex(of: id) {
            pinned.remove(at: index)
        } else {
            pinned.append(id)
        }
        resort()
    }

    /// Moves `id` to just before `target` among pinned windows (pinning it if needed).
    func movePinned(_ id: CGWindowID, before target: CGWindowID) {
        guard id != target else { return }
        pinned.removeAll { $0 == id }
        if let index = pinned.firstIndex(of: target) {
            pinned.insert(id, at: index)
        } else {
            pinned.append(id)
        }
        resort()
    }

    func window(_ id: CGWindowID) -> WindowInfo? {
        allWindows.first { $0.windowID == id }
    }

    /// Marks a window as just used (immediate MRU feedback after clicking it).
    func noteActivated(_ id: CGWindowID) {
        activation[id] = Date()
        resort()
    }

    // MARK: - Refresh

    func refresh(forceSweep: Bool = false) async {
        if isRefreshing {
            pendingRefresh = true
            pendingForceSweep = pendingForceSweep || forceSweep
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if pendingRefresh {
                let force = pendingForceSweep
                pendingRefresh = false
                pendingForceSweep = false
                requestRefresh(forceSweep: force)
            }
        }

        let records = await Task.detached(priority: .userInitiated) { CGWindowRecord.onScreen() }.value
        let excluded = Set(settings.excludedBundleIDs)
        let now = Date()

        var candidates: [CGWindowRecord] = []
        for record in records {
            guard record.layer == 0, record.alpha > 0, record.pid != ownPID,
                  record.bounds.width >= Self.minimumSize, record.bounds.height >= Self.minimumSize,
                  !Self.ignoredOwners.contains(record.owner) else { continue }
            let app = appInfo(record.pid)
            if let bundle = app.bundleID, excluded.contains(bundle) { continue }
            candidates.append(record)
            if firstSeen[record.id] == nil {
                firstSeen[record.id] = now
                // First sighting: seed MRU from z-order so the initial list looks right.
                activation[record.id] = now.addingTimeInterval(-Double(candidates.count) * 0.001 - 1)
            }
        }

        let hasUnconfirmed = candidates.contains { axWindows[$0.id] == nil && (firstSeen[$0.id] ?? now) > lastSweep }
        let currentIDs = Set(candidates.map(\.id))
        let disappeared = !lastOnScreen.subtracting(currentIDs).isEmpty // minimized or closed: ask AX which
        lastOnScreen = currentIDs
        let sweepDue = forceSweep || hasUnconfirmed || disappeared || now.timeIntervalSince(lastSweep) > 4.0
        // Never wait for the AX sweep (one slow app can take ~0.5 s): publish now from the fast CG list,
        // sweep in the background, and refresh again quietly when it finishes.
        if sweepDue, PermissionCache.accessibility {
            startBackgroundSweep(candidates: candidates, excluded: excluded)
        }

        var result: [WindowInfo] = []
        var onScreen = Set<CGWindowID>()
        for record in candidates {
            let snapshot = axWindows[record.id]
            // Skip only windows a sweep has *confirmed* are not user windows (invisible helpers, palettes).
            // Unknown windows — e.g. the ones on a desktop you just swiped to — show immediately.
            if rejected[record.id] == record.pid { continue }
            if let snapshot, !snapshot.isUserWindow { continue }
            let app = appInfo(record.pid)
            onScreen.insert(record.id)
            result.append(WindowInfo(
                windowID: record.id,
                pid: record.pid,
                bundleID: app.bundleID,
                appName: app.name.isEmpty ? record.owner : app.name,
                title: record.title.isEmpty ? (snapshot?.title ?? "") : record.title,
                frame: record.bounds,
                isMinimized: false,
                isAppHidden: false,
                lastActivated: activation[record.id] ?? now
            ))
        }

        // Minimized windows and windows of hidden apps are not in the on-screen list.
        for snapshot in axWindows.values where !onScreen.contains(snapshot.windowID) {
            guard snapshot.isUserWindow, snapshot.pid != ownPID,
                  snapshot.frame.width >= Self.minimumSize, snapshot.frame.height >= Self.minimumSize else { continue }
            let app = appInfo(snapshot.pid)
            if let bundle = app.bundleID, excluded.contains(bundle) { continue }
            let hidden = NSRunningApplication(processIdentifier: snapshot.pid)?.isHidden ?? false
            guard snapshot.isMinimized || hidden else { continue } // other Spaces / fullscreen: skip
            if firstSeen[snapshot.windowID] == nil {
                firstSeen[snapshot.windowID] = now
                activation[snapshot.windowID] = now.addingTimeInterval(-3600)
            }
            result.append(WindowInfo(
                windowID: snapshot.windowID,
                pid: snapshot.pid,
                bundleID: app.bundleID,
                appName: app.name,
                title: snapshot.title,
                frame: snapshot.frame,
                isMinimized: snapshot.isMinimized,
                isAppHidden: hidden && !snapshot.isMinimized,
                lastActivated: activation[snapshot.windowID] ?? now
            ))
        }

        // MRU: whichever window is frontmost now was the last one used.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let top = candidates.first(where: { onScreen.contains($0.id) }), top.id != lastTop {
            lastTop = top.id
            if top.pid == frontPID { activation[top.id] = now }
        }
        let activeID = candidates.first { onScreen.contains($0.id) && $0.pid == frontPID }?.id
        for i in result.indices {
            result[i].lastActivated = activation[result[i].windowID] ?? now
            result[i].isActive = result[i].windowID == activeID
        }

        // Forget windows that are gone (IDs get reused, so stale state must not leak).
        let alive = Set(result.map(\.windowID))
        firstSeen = firstSeen.filter { alive.contains($0.key) || onScreen.contains($0.key) }
        if rejected.count > 200 { rejected.removeAll() }
        rejected = rejected.filter { NSRunningApplication(processIdentifier: $0.value) != nil }
        activation = activation.filter { alive.contains($0.key) }
        pinned.removeAll { !alive.contains($0) }

        allWindows = result
        resort()
    }

    private func startBackgroundSweep(candidates: [CGWindowRecord], excluded: Set<String>) {
        guard !sweeping else { return }
        sweeping = true
        let onScreenAtStart = candidates.map { ($0.id, $0.pid) }
        Task {
            await sweep(extraPIDs: candidates.map(\.pid), excluded: excluded)
            // A window that was on screen while its (readable) app listed its windows, but isn't in that
            // list, is an invisible helper — remember that so it never flickers in again.
            for (id, pid) in onScreenAtStart where axReadable.contains(pid) && axWindows[id] == nil {
                rejected[id] = pid
            }
            sweeping = false
            requestRefresh()
        }
    }

    private func sweep(extraPIDs: [pid_t], excluded: Set<String>) async {
        var pids = Set(extraPIDs)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            if let bundle = app.bundleIdentifier, excluded.contains(bundle) { continue }
            pids.insert(app.processIdentifier)
        }
        let result = await ax.sweep(pids: Array(pids))
        var map: [CGWindowID: AXWindowSnapshot] = [:]
        for window in result.windows where map[window.windowID] == nil { map[window.windowID] = window }
        axWindows = map
        axReadable = result.readablePIDs
        lastSweep = Date()
    }

    private func resort() {
        var list = allWindows
        let pinnedSet = Set(pinned)
        for i in list.indices { list[i].isPinned = pinnedSet.contains(list[i].windowID) }

        if settings.windowScope == .sidebarDisplay, let displayFilter {
            list = list.filter { $0.isPinned || displayFilter($0.frame) }
        }

        let pinnedList = pinned.compactMap { id in list.first { $0.windowID == id } }
        var rest = list.filter { !$0.isPinned }
        switch settings.ordering {
        case .recent:
            rest.sort { ($0.lastActivated, $0.windowID) > ($1.lastActivated, $1.windowID) }
        case .stable:
            rest.sort {
                let a = firstSeen[$0.windowID] ?? .distantFuture, b = firstSeen[$1.windowID] ?? .distantFuture
                return (a, $0.windowID) < (b, $1.windowID)
            }
        }
        let sorted = pinnedList + rest
        if sorted != windows { windows = sorted }
    }

    func settingsChanged() { resort() }

    private func appInfo(_ pid: pid_t) -> (bundleID: String?, name: String, regular: Bool) {
        if let cached = apps[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let info = (app?.bundleIdentifier, Workspace.clean(app?.localizedName ?? ""), app?.activationPolicy == .regular)
        apps[pid] = info
        return info
    }
}
