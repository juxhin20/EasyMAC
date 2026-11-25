import AppKit
import SwiftUI

/// Borderless, non-activating floating panel: clicks never steal focus from the app you're working in.
class FloatingPanel: NSPanel {
    init(level: NSWindow.Level, ignoresMouse: Bool = false) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true // must come before `level`: setting it resets the level to .floating
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = ignoresMouse
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// macOS sometimes pins an all-desktops panel to a single desktop (a hidden panel keeps the
    /// desktop it was last on; also after a display is unplugged or the Mac wakes), so it opens on
    /// Desktop 1 or vanishes when you switch. Re-applying the behavior unpins it.
    ///
    /// `isOnActiveSpace` alone isn't enough: right after a trackpad swipe it can still report the
    /// old desktop, so the window server's own list of the panel's desktops is checked as well.
    func rejoinAllSpacesIfNeeded() {
        guard isVisible, collectionBehavior.contains(.canJoinAllSpaces), isPinnedToOneSpace else { return }
        Log.app.info("panel \(self.windowNumber) pinned to one desktop (onActive=\(self.isOnActiveSpace)), rejoining all")
        resetSpaceBehavior()
        super.orderFrontRegardless()
    }

    /// Checks again once the desktop-switch animation (a slow trackpad swipe) has settled.
    func rejoinAllSpacesSoon() {
        rejoinAllSpacesIfNeeded()
        for delay in [0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rejoinAllSpacesIfNeeded() }
        }
    }

    private var isPinnedToOneSpace: Bool {
        if !isOnActiveSpace { return true }
        guard let spaces = WindowSpaces.spaces(of: CGWindowID(windowNumber)) else { return false }
        return spaces.count <= 1 && WindowSpaces.desktopCount > 1
    }

    private func resetSpaceBehavior() {
        let behavior = collectionBehavior
        collectionBehavior = []
        collectionBehavior = behavior
    }

    override func orderFrontRegardless() {
        // A hidden panel remembers the desktop it was last shown on; unpin it before showing.
        if !isVisible, collectionBehavior.contains(.canJoinAllSpaces) { resetSpaceBehavior() }
        super.orderFrontRegardless()
        rejoinAllSpacesIfNeeded()
    }
}

/// Which desktops a window is on, straight from the window server (private SkyLight calls,
/// resolved with `dlsym`; nil when unavailable).
enum WindowSpaces {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: ConnectionFn? = symbol("SLSMainConnectionID") ?? symbol("CGSMainConnectionID")
    private static let spacesForWindows: SpacesForWindowsFn? = symbol("SLSCopySpacesForWindows") ?? symbol("CGSCopySpacesForWindows")
    private static let displaySpaces: DisplaySpacesFn? = symbol("SLSCopyManagedDisplaySpaces") ?? symbol("CGSCopyManagedDisplaySpaces")

    private static func symbol<T>(_ name: String) -> T? {
        guard let skylight, let pointer = dlsym(skylight, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func spaces(of window: CGWindowID) -> [UInt64]? {
        guard let cid = connection?(), let copy = spacesForWindows,
              let raw = copy(cid, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return raw.map(\.uint64Value)
    }

    /// Desktops across all displays (fullscreen apps included).
    static var desktopCount: Int {
        guard let cid = connection?(), let copy = displaySpaces,
              let raw = copy(cid)?.takeRetainedValue() as? [[String: Any]] else { return 0 }
        return raw.reduce(0) { $0 + (($1["Spaces"] as? [Any])?.count ?? 0) }
    }
}

/// Hosting view that reacts to the first click (panel is never key) and reports the mouse position
/// in top-left coordinates via an always-active tracking area (works while EasyMAC is inactive).
final class TrackingHostingView: NSHostingView<AnyView> {
    var onMouse: ((CGPoint?) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouse?(nil)
    }

    private func report(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onMouse?(isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y))
    }
}

enum PanelBackground {
    /// Rounded material background hosting `content`. Uses Liquid Glass on macOS 26 when chosen.
    @MainActor
    static func make(style: PanelStyle, cornerRadius: CGFloat, content: NSView) -> NSView {
        if style == .glass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let container = NSView()
        let effect = NSVisualEffectView()
        effect.material = style == .dark ? .hudWindow : .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: cornerRadius)
        if style == .dark { effect.appearance = NSAppearance(named: .vibrantDark) }
        effect.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Small HUD message ("Saved workspace …", "Restored …").
@MainActor
final class ToastController {
    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        let panel = self.panel ?? FloatingPanel(level: .statusBar, ignoresMouse: true)
        self.panel = panel
        let view = NSHostingView(rootView: AnyView(
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Brand.red)
                Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .fixedSize()
        ))
        let size = view.fittingSize
        let background = PanelBackground.make(style: Settings.shared.panelStyle, cornerRadius: size.height / 2, content: view)
        panel.contentView = background
        guard let screen = NSScreen.withMouse else { return }
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 90, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: {
                MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
            })
        }
    }
}
