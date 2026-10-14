import AppKit
import Observation
@preconcurrency import ScreenCaptureKit

/// Captures window thumbnails with ScreenCaptureKit single-frame screenshots.
///
/// - Only runs while the sidebar is visible (`setActive`).
/// - Visible thumbnails refresh every `Settings.refreshInterval` seconds; the hovered window at ~2 fps.
/// - At most 3 captures are in flight; requests for a window already being captured are dropped.
/// One observable box per window so a new capture only re-renders that window's cell.
@MainActor @Observable
final class ThumbnailBox {
    var image: NSImage?
}

@MainActor @Observable
final class ThumbnailService {
    @ObservationIgnored private var boxes: [CGWindowID: ThumbnailBox] = [:]
    private(set) var hoverImage: NSImage?
    private(set) var hoverImageID: CGWindowID?

    @ObservationIgnored private let settings = Settings.shared
    @ObservationIgnored private var stamps: [CGWindowID: Date] = [:]
    @ObservationIgnored private var content: SCShareableContent?
    @ObservationIgnored private var contentStamp = Date.distantPast
    @ObservationIgnored private var contentLoading = false
    @ObservationIgnored private var inFlight = Set<CGWindowID>()
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hoverTimer: Timer?
    @ObservationIgnored private var visible: [WindowInfo] = []
    @ObservationIgnored private var hovered: WindowInfo?
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored var canCapture: () -> Bool = { CGPreflightScreenCaptureAccess() }

    private let maxConcurrent = 3

    func box(_ id: CGWindowID) -> ThumbnailBox {
        if let box = boxes[id] { return box }
        let box = ThumbnailBox()
        boxes[id] = box
        return box
    }

    func image(_ id: CGWindowID) -> NSImage? { boxes[id]?.image }

    // MARK: - Control

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            restartTimer()
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            stopHover()
        }
    }

    func restartTimer() {
        timer?.invalidate()
        guard isActive else { return }
        let interval = min(max(settings.refreshInterval, 1), 10)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Windows currently shown in the strip. New windows get a thumbnail right away.
    func update(visible windows: [WindowInfo]) {
        let changedSet = Set(windows.map(\.windowID)) != Set(visible.map(\.windowID))
        visible = windows
        if changedSet { contentStamp = .distantPast }
        let alive = Set(windows.map(\.windowID))
        if boxes.keys.contains(where: { !alive.contains($0) }) {
            boxes = boxes.filter { alive.contains($0.key) }
            stamps = stamps.filter { alive.contains($0.key) }
        }
        guard isActive else { return }
        for window in windows where image(window.windowID) == nil && !window.isOffscreen {
            enqueue(window, hover: false)
        }
    }

    func startHover(_ window: WindowInfo) {
        hovered = window
        if hoverImageID != window.windowID {
            hoverImageID = window.windowID
            hoverImage = image(window.windowID)
        }
        hoverTimer?.invalidate()
        guard isActive, !window.isOffscreen else { return }
        enqueue(window, hover: true)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hovered = self.hovered else { return }
                self.enqueue(hovered, hover: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func stopHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hovered = nil
    }

    /// Forces fresh thumbnails, e.g. right after the sidebar slides in.
    func refreshVisibleSoon() {
        tick(maxAge: 0.5)
    }

    // MARK: - Work

    private func tick(maxAge: TimeInterval? = nil) {
        guard isActive, settings.showThumbnails, canCapture() else { return }
        let age = maxAge ?? max(settings.refreshInterval - 0.25, 0.75)
        let now = Date()
        for window in visible where !window.isOffscreen {
            if let stamp = stamps[window.windowID], now.timeIntervalSince(stamp) < age { continue }
            enqueue(window, hover: false)
        }
    }

    private func enqueue(_ window: WindowInfo, hover: Bool) {
        guard settings.showThumbnails, canCapture() else { return }
        let key = hover ? window.windowID | 0x8000_0000 : window.windowID
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let pixelWidth: CGFloat = hover ? 960 : settings.thumbnailSize.width * 2.4
        let pixelHeight: CGFloat = hover ? 720 : settings.thumbnailSize.width * 2.4

        Task {
            defer { inFlight.remove(key) }
            await acquire()
            defer { release() }
            guard isActive else { return }
            guard let image = await capture(window.windowID, maxWidth: pixelWidth, maxHeight: pixelHeight) else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            if hover {
                if hovered?.windowID == window.windowID {
                    hoverImage = nsImage
                    hoverImageID = window.windowID
                }
            } else {
                box(window.windowID).image = nsImage
                stamps[window.windowID] = Date()
            }
        }
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func shareableWindow(_ id: CGWindowID) async -> SCWindow? {
        let now = Date()
        let stale = now.timeIntervalSince(contentStamp) > 10
        let missing = content?.windows.contains { $0.windowID == id } != true
        if stale || (missing && now.timeIntervalSince(contentStamp) > 0.75) {
            await reloadContent()
        }
        return content?.windows.first { $0.windowID == id }
    }

    private func reloadContent() async {
        if contentLoading {
            while contentLoading { try? await Task.sleep(for: .milliseconds(20)) }
            return
        }
        contentLoading = true
        defer {
            contentLoading = false
            contentStamp = Date()
        }
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            Log.thumbnails.error("SCShareableContent failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func capture(_ id: CGWindowID, maxWidth: CGFloat, maxHeight: CGFloat) async -> CGImage? {
        guard let window = await shareableWindow(id) else { return nil }
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(maxWidth / size.width, maxHeight / size.height, 2)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.thumbnails.debug("Capture of \(id) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
