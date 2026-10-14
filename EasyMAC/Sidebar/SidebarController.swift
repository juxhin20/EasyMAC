import AppKit
import Observation
import SwiftUI

/// Owns the strip panel: placement, show/hide + auto-hide animation, hover preview, and turning
/// polling/capturing on only while the strip is actually on screen.
@MainActor
final class SidebarController {
    let model = SidebarModel()

    private unowned let state: AppState
    private let panel = SidebarPanel()
    private let preview: HoverPreviewController
    private var settings: Settings { state.settings }

    private var style: PanelStyle?
    private(set) var isRevealed = false
    private var autoRevealed = false
    private var hotkeyRevealed = false
    private var mouseEnteredSinceReveal = false
    private var peeking = false
    private var menuOpen = false
    private var currentScreen: NSScreen?
    private var mouseMonitors: [Any] = []
    private var concealTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var lastMouseEvent = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init(state: AppState) {
        self.state = state
        preview = HoverPreviewController(thumbnails: state.thumbnails)
        model.onHoverChange = { [weak self] id in self?.hoverChanged(id) }
    }

    func start() {
        buildContent()
        currentScreen = resolveScreen()
        state.windows.displayFilter = { [weak self] frame in
            guard let self, let screen = self.currentScreen else { return true }
            return NSScreen.screen(forAXRect: frame)?.isSameDisplay(as: screen) == true
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentScreen = self.resolveScreen()
                self.relayout(animated: false)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                self?.mouseMoved()
            }
        })

        observeContent()
        installMouseMonitors()
        applyVisibility(animated: true)
    }

    // MARK: - Public control

    var screen: NSScreen? { currentScreen }

    /// Width the pinned strip occupies on its edge (0 when hidden or auto-hiding).
    var reservedWidth: CGFloat {
        guard settings.sidebarEnabled, !settings.autoHide else { return 0 }
        return metrics.panelWidth + 8
    }


    /// Hotkey / menu: with auto-hide on, toggles a temporary reveal; otherwise shows/hides the strip.
    func toggle() {
        if settings.autoHide && settings.sidebarEnabled {
            if isRevealed {
                autoRevealed = false
                hotkeyRevealed = false
            } else {
                autoRevealed = true
                hotkeyRevealed = true
                mouseEnteredSinceReveal = false
            }
            applyVisibility(animated: true)
        } else {
            settings.sidebarEnabled.toggle()
        }
    }

    /// Temporarily shows the strip (keyboard switcher).
    func beginPeek() {
        peeking = true
        applyVisibility(animated: true)
    }

    func endPeek() {
        peeking = false
        applyVisibility(animated: true)
    }

    func settingsChanged() {
        if settings.panelStyle != style {
            buildContent()
            preview.styleChanged()
        }
        currentScreen = resolveScreen()
        if !settings.autoHide { autoRevealed = false }
        state.spaces.refresh()
        installMouseMonitors()
        state.thumbnails.restartTimer()
        applyVisibility(animated: true)
        relayout(animated: true)
    }

    func hidePreview() {
        hoverTask?.cancel()
        preview.hide()
        state.thumbnails.stopHover()
    }

    // MARK: - Visibility

    private var shouldBeVisible: Bool {
        peeking || (settings.sidebarEnabled && (!settings.autoHide || autoRevealed))
    }

    private func applyVisibility(animated: Bool) {
        let visible = shouldBeVisible
        state.windows.setPolling(visible)
        state.thumbnails.setActive(visible)
        if visible && !isRevealed {
            reveal(animated: animated)
        } else if !visible && isRevealed {
            conceal(animated: animated)
        }
    }

    private func reveal(animated: Bool) {
        isRevealed = true
        currentScreen = resolveScreen()
        state.windows.requestRefresh(forceSweep: true)
        state.thumbnails.update(visible: displayedWindows)
        state.thumbnails.refreshVisibleSoon()
        let target = targetFrame()
        guard animated else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.setFrame(offscreen(target), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func conceal(animated: Bool) {
        isRevealed = false
        hidePreview()
        model.hoveredID = nil
        let target = offscreen(panel.frame)
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Layout

    private var metrics: SidebarMetrics {
        SidebarMetrics(thumbWidth: settings.thumbnailSize.width, showTitles: settings.showTitles, showFooter: settings.showFooter,
                       spaceCount: settings.showSpaces ? state.spaces.spaces.count : 0)
    }

    private var displayedWindows: [WindowInfo] {
        SidebarModel.displayed(state.windows.windows, max: settings.maxVisible)
    }

    private func resolveScreen() -> NSScreen? {
        switch settings.sidebarDisplay {
        case .main: return NSScreen.screens.first ?? NSScreen.main
        case .mouse: return NSScreen.withMouse
        case .specific: return NSScreen.screen(withStableID: settings.specificDisplayID) ?? NSScreen.screens.first
        }
    }

    private func targetFrame() -> NSRect {
        guard let screen = currentScreen ?? NSScreen.main else { return panel.frame }
        let m = metrics
        let visible = screen.visibleFrame
        let height = min(m.contentHeight(windowCount: displayedWindows.count, chipCount: state.workspaces.workspaces.count),
                         visible.height * 0.9)
        let width = m.panelWidth
        let x = settings.sidebarEdge == .left ? visible.minX + 8 : visible.maxX - 8 - width
        return NSRect(x: x, y: visible.midY - height / 2, width: width, height: height).integral
    }

    private func offscreen(_ frame: NSRect) -> NSRect {
        frame.offsetBy(dx: settings.sidebarEdge == .left ? -(frame.width * 0.7) : frame.width * 0.7, dy: 0)
    }

    private func relayout(animated: Bool) {
        guard isRevealed else { return }
        let target = targetFrame()
        guard target != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    private func buildContent() {
        style = settings.panelStyle
        let host = TrackingHostingView(rootView: AnyView(SidebarView(state: state, model: model)))
        host.onMouse = { [weak self] point in
            guard let self else { return }
            if point != nil { self.mouseEnteredSinceReveal = true }
            self.model.mouseMoved(point)
        }
        panel.contentView = PanelBackground.make(style: settings.panelStyle, cornerRadius: SidebarMetrics.cornerRadius, content: host)
    }

    private func observeContent() {
        withObservationTracking {
            _ = state.windows.windows
            _ = state.workspaces.workspaces
            _ = state.spaces.spaces
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.thumbnails.update(visible: self.displayedWindows)
                self.relayout(animated: true)
                self.observeContent()
            }
        }
    }

    // MARK: - Mouse (auto-hide, follow-mouse display)

    private func installMouseMonitors() {
        let needed = settings.autoHide || settings.sidebarDisplay == .mouse
        if needed == !mouseMonitors.isEmpty { return }
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        guard needed else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func mouseMoved() {
        let now = Date()
        guard now.timeIntervalSince(lastMouseEvent) > 1.0 / 30 else { return }
        lastMouseEvent = now
        let mouse = NSEvent.mouseLocation

        if settings.sidebarDisplay == .mouse, !panel.frame.insetBy(dx: -20, dy: -20).contains(mouse),
           let screen = NSScreen.withMouse, !screen.isSameDisplay(as: currentScreen) {
            currentScreen = screen
            state.windows.settingsChanged()
            state.spaces.refresh()
            if isRevealed {
                panel.setFrame(targetFrame(), display: true)
            }
        }

        guard settings.autoHide, settings.sidebarEnabled, !peeking else { return }
        if !isRevealed {
            if isAtEdge(mouse) {
                autoRevealed = true
                hotkeyRevealed = false
                mouseEnteredSinceReveal = true
                applyVisibility(animated: true)
            }
            return
        }

        var keepZone = panel.frame.insetBy(dx: -24, dy: -24)
        if preview.isVisible { keepZone = keepZone.union(panel.frame.insetBy(dx: -520, dy: 0)) }
        if keepZone.contains(mouse) { mouseEnteredSinceReveal = true }
        let keep = keepZone.contains(mouse) || menuOpen || model.isDragging || (hotkeyRevealed && !mouseEnteredSinceReveal)
        if keep {
            concealTask?.cancel()
            concealTask = nil
        } else if concealTask == nil {
            concealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.concealTask = nil
                self.autoRevealed = false
                self.hotkeyRevealed = false
                self.applyVisibility(animated: true)
            }
        }
    }

    /// The 4px hot strip along the chosen edge of the sidebar's display.
    private func isAtEdge(_ point: CGPoint) -> Bool {
        guard let screen = currentScreen else { return false }
        let frame = screen.frame
        guard point.y >= frame.minY, point.y <= frame.maxY else { return false }
        switch settings.sidebarEdge {
        case .left: return point.x <= frame.minX + 4 && point.x >= frame.minX - 1
        case .right: return point.x >= frame.maxX - 5 && point.x <= frame.maxX + 1
        }
    }

    // MARK: - Hover preview

    private func hoverChanged(_ id: CGWindowID?) {
        hoverTask?.cancel()
        guard settings.hoverPreview, let id, let window = state.windows.windows.first(where: { $0.windowID == id }) else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self else { return }
                self.preview.hide()
                self.state.thumbnails.stopHover()
            }
            return
        }
        if preview.isVisible {
            showPreview(window)
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.settings.hoverDelay ?? 0.3))
            guard !Task.isCancelled, let self, self.model.hoveredID == id else { return }
            self.showPreview(window)
        }
    }

    private func showPreview(_ window: WindowInfo) {
        guard let cell = model.cellFrames[window.windowID], let screen = currentScreen ?? NSScreen.main else { return }
        let frame = panel.frame
        let anchor = CGRect(x: frame.minX + cell.minX, y: frame.maxY - cell.maxY, width: cell.width, height: cell.height)
        preview.show(window, anchor: anchor, stripFrame: frame, edge: settings.sidebarEdge, screen: screen)
        state.thumbnails.startHover(window)
    }
}
