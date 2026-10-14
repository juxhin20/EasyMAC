import AppKit
import SwiftUI

/// Snap wheel: hold the trigger key (fn by default), move the mouse toward a direction, release.
///
/// - A quick tap does nothing (the ring only appears after `radialHoldDelay` or once the mouse moves).
/// - Pressing any other key while armed cancels (so fn+arrow, fn+F-keys keep working).
/// - Esc cancels while the ring is visible.
/// Needs Accessibility (global key monitors).
@MainActor
final class RadialSnapController {
    private enum Phase {
        case idle
        case armed(origin: CGPoint)
        case active(origin: CGPoint)
    }

    private unowned let state: AppState
    private var settings: Settings { state.settings }
    private var phase = Phase.idle
    private var monitors: [Any] = []
    private var armTask: Task<Void, Never>?
    private var targetTask: Task<SnapController.Target?, Never>?
    private var lastScreen: NSScreen?

    private let model = RadialModel()
    private lazy var ringPanel: FloatingPanel = {
        let panel = FloatingPanel(level: .popUpMenu, ignoresMouse: true)
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: AnyView(RadialRingView(model: model)))
        return panel
    }()
    private lazy var previewPanel: FloatingPanel = {
        FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2), ignoresMouse: true)
    }()
    private var previewStyle: (PanelStyle, AccentChoice)?
    private var previewVisible = false

    init(state: AppState) {
        self.state = state
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        stop()
        guard settings.radialEnabled, AXIsProcessTrusted() else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event) }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
            return event
        }) { monitors.append(m) }
        Log.radial.info("Snap wheel armed with trigger \(self.settings.radialTrigger.rawValue, privacy: .public)")
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        cancel()
    }

    // MARK: - Events

    private func flagsChanged(_ event: NSEvent) {
        let trigger = settings.radialTrigger
        let pressed: Bool
        if trigger == .fn {
            pressed = event.modifierFlags.contains(.function)
        } else {
            guard event.keyCode == trigger.keyCode else { return }
            pressed = event.modifierFlags.contains(trigger.flag)
        }

        switch (phase, pressed) {
        case (.idle, true):
            let origin = NSEvent.mouseLocation
            phase = .armed(origin: origin)
            armTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.settings.radialHoldDelay ?? 0.15))
                guard !Task.isCancelled, let self, case .armed = self.phase else { return }
                self.activate(origin: origin)
            }
        case (.armed, false):
            cancel()
        case (.active, false):
            commit()
        default:
            break
        }
    }

    private func mouseMoved() {
        switch phase {
        case .idle:
            return
        case .armed(let origin):
            let p = NSEvent.mouseLocation
            if hypot(p.x - origin.x, p.y - origin.y) > 6 { activate(origin: origin) }
        case .active(let origin):
            update(origin: origin)
        }
    }

    private func keyDown(_ event: NSEvent) {
        switch phase {
        case .idle: return
        case .armed: cancel()
        case .active: if event.keyCode == 53 { cancel() } // Esc
        }
    }

    // MARK: - Phases

    private func activate(origin: CGPoint) {
        armTask?.cancel()
        phase = .active(origin: origin)
        targetTask = Task { [state, settings] in
            settings.radialTarget == .underCursor ? await state.snap.targetUnderCursor() : await state.snap.focusedTarget()
        }

        model.accent = Color(nsColor: settings.radialAccent.nsColor)
        model.centerHasAction = settings.radialCenterAction != .none
        model.direction = .center
        model.appeared = false
        let size = RadialRingView.diameter + 40
        ringPanel.setFrame(NSRect(x: origin.x - size / 2, y: origin.y - size / 2, width: size, height: size), display: true)
        ringPanel.alphaValue = 1
        ringPanel.orderFrontRegardless()
        DispatchQueue.main.async { [model] in model.appeared = true }
        haptic()
        update(origin: origin, force: true)
    }

    private func update(origin: CGPoint, force: Bool = false) {
        let p = NSEvent.mouseLocation
        let direction = LayoutEngine.radialDirection(dx: p.x - origin.x, dy: p.y - origin.y, deadZone: 14)
        let screen = NSScreen.withMouse
        guard force || direction != model.direction || !(screen?.isSameDisplay(as: lastScreen) ?? false) else { return }
        if direction != model.direction { haptic() }
        model.set(direction)
        lastScreen = screen
        showPreview()
    }

    private func currentAction() -> SnapAction? {
        model.direction.snapAction ?? settings.radialCenterAction.snapAction
    }

    private func targetFrameAX(current: CGRect?) -> CGRect? {
        guard let action = currentAction(), let screen = lastScreen ?? NSScreen.withMouse else { return nil }
        return LayoutEngine.snap(action, in: state.usableAreaAX(screen), gap: settings.layoutGap, current: current)
    }

    private func showPreview() {
        guard settings.radialShowPreview else { return }
        Task { [weak self] in
            guard let self else { return }
            let target = await self.targetTask?.value
            guard case .active = self.phase else { return }
            guard let frameAX = self.targetFrameAX(current: target?.frame) else {
                self.hidePreview()
                return
            }
            self.placePreview(Coordinates.axToAppKit(frameAX, primaryHeight: NSScreen.primaryHeight), from: target?.frame)
        }
    }

    private func placePreview(_ frame: NSRect, from windowFrameAX: CGRect?) {
        let style = (settings.panelStyle, settings.radialAccent)
        if previewStyle.map({ $0 != style }) ?? true {
            previewStyle = style
            let host = NSHostingView(rootView: AnyView(SnapPreviewView(accent: Color(nsColor: settings.radialAccent.nsColor))))
            previewPanel.contentView = PanelBackground.make(style: style.0 == .dark ? .frosted : style.0, cornerRadius: 14, content: host)
        }
        if previewVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                previewPanel.animator().setFrame(frame, display: true)
            }
        } else {
            let start = windowFrameAX.map { Coordinates.axToAppKit($0, primaryHeight: NSScreen.primaryHeight) } ?? frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
            previewPanel.setFrame(start, display: false)
            previewPanel.alphaValue = 0
            previewPanel.orderFrontRegardless()
            ringPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                previewPanel.animator().setFrame(frame, display: true)
                previewPanel.animator().alphaValue = 1
            }
            previewVisible = true
        }
    }

    private func hidePreview() {
        guard previewVisible else { return }
        previewVisible = false
        let panel = previewPanel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.previewVisible else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func hideRing() {
        model.appeared = false
        let panel = ringPanel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        })
    }

    private func commit() {
        let action = currentAction()
        let targetTask = targetTask
        let screen = lastScreen ?? NSScreen.withMouse
        phase = .idle
        hideRing()
        hidePreview()
        guard let action else { return }
        Task { [state, settings] in
            guard let target = await targetTask?.value, let screen else { return }
            let frame = LayoutEngine.snap(action, in: state.usableAreaAX(screen), gap: settings.layoutGap, current: target.frame)
            await state.snap.apply(frame, to: target)
        }
    }

    private func cancel() {
        armTask?.cancel()
        armTask = nil
        if case .active = phase {
            hideRing()
            hidePreview()
        }
        phase = .idle
        targetTask = nil
        lastScreen = nil
    }

    private func haptic() {
        guard settings.radialHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
