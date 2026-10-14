import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class NotchDropModel {
    enum Phase: Equatable { case hidden, waiting, targeted, added(Int) }
    var phase: Phase = .hidden
    var icons: [NSImage] = []
}

/// Black shelf growing out of the notch while files are dragged.
struct NotchDropView: View {
    let model: NotchDropModel
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var accent: Color { Color(nsColor: Settings.shared.sidebarAccent.nsColor) }
    private var open: Bool { model.phase != .hidden }
    private var targeted: Bool { model.phase == .targeted }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 10) {
                switch model.phase {
                case .added(let count):
                    HStack(spacing: -10) {
                        ForEach(Array(model.icons.prefix(3).enumerated()), id: \.offset) { _, icon in
                            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                        }
                    }
                    Text("\(count) added to Tray").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                default:
                    Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(targeted ? accent : .white)
                        .symbolEffect(.bounce, value: targeted)
                    Text(targeted ? "Release to add to Tray" : "Drop here → Tray")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(targeted ? accent : Color.white.opacity(0.25),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: targeted ? [] : [5, 4]))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .padding(.bottom, 8)
        }
        .frame(width: notchWidth + 220)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous).fill(.black))
        .scaleEffect(x: open ? 1 : 0.55, y: open ? 1 : 0.3, anchor: .top)
        .opacity(open ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Accepts file drops; tells the controller about enter / exit / drop.
final class DropTargetView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Log.app.notice("Notch drop: drag entered (\(self.urls(sender).count) files)")
        guard !urls(sender).isEmpty else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let list = urls(sender)
        Log.app.notice("Notch drop: performed with \(list.count) files")
        guard !list.isEmpty else { return false }
        onDrop?(list)
        return true
    }
}

/// Drag files to the notch → they land in the Tray. Click the notch → Tray opens under it.
///
/// Cost when idle: one global mouse-down/drag/up monitor that only peeks at the drag pasteboard's
/// change count (no work unless a *file* drag starts). The drop panel exists only during a drag;
/// the click target is a tiny transparent window exactly over the camera housing (no menu items there).
@MainActor
final class NotchDropController {
    private unowned let state: AppState
    private let model = NotchDropModel()
    private var clickPanel: NotchPanel?
    private var monitors: [Any] = []
    private var dragChangeCount = 0
    private var dragActive = false
    private var hideTask: Task<Void, Never>?
    private var droppedThisDrag = false
    private var releaseWatch: Timer?

    init(state: AppState) {
        self.state = state
    }

    func update() {
        let enabled = state.settings.notchTray && NSScreen.notchScreen != nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        clickPanel?.orderOut(nil)
        clickPanel = nil
        guard enabled else { return }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragChangeCount = NSPasteboard(name: .drag).changeCount }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.mouseDragged()
                self?.trackCursor()
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        }) { monitors.append(m) }
        installClickTarget()
    }

    // MARK: - Drag detection

    private func mouseDragged() {
        guard !dragActive else { return }
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != dragChangeCount, pasteboard.types?.contains(.fileURL) == true {
            Log.app.notice("Notch drop: file drag started")
        }
        guard pasteboard.changeCount != dragChangeCount,
              pasteboard.types?.contains(.fileURL) == true else { return }
        dragActive = true
        droppedThisDrag = false
        showDropZone()
        // Some drag sources swallow the mouse-up; watch the button state while (and only while) dragging.
        releaseWatch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trackCursor()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.dragEnded() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    private var shelfContainsCursor: Bool {
        guard let panel = clickPanel else { return false }
        return panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    /// Highlight follows the cursor directly (doesn't rely on drag-destination callbacks).
    private func trackCursor() {
        guard dragActive, model.phase == .waiting || model.phase == .targeted else { return }
        let inside = shelfContainsCursor
        if inside != (model.phase == .targeted) {
            model.phase = inside ? .targeted : .waiting
            if inside { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    private func dragEnded() {
        guard dragActive else { return }
        dragActive = false
        releaseWatch?.invalidate()
        releaseWatch = nil
        // Released over the shelf: take the files from the drag pasteboard ourselves. Works even when
        // macOS doesn't route the drop to us (it never did for windows over the menu bar).
        if shelfContainsCursor, !droppedThisDrag,
           let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            Log.app.notice("Notch drop: added \(urls.count) files on release")
            dropped(urls)
            return
        }
        // Give performDragOperation a moment; if nothing was dropped, close.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            if case .added = self.model.phase { return }
            self.hideDropZone()
        }
    }

    // MARK: - Drop zone
    //
    // One persistent window over the notch does both jobs. macOS only offers a drop to windows that
    // existed when the drag began, so the shelf can't be created on demand: this window sits over the
    // camera housing all the time (tiny, invisible, catches clicks) and grows into the shelf while
    // files are dragged.

    private func showDropZone() {
        guard let screen = NSScreen.notchScreen, let notch = screen.notchRect, let panel = clickPanel else { return }
        hideTask?.cancel()
        let width = notch.width + 220
        let height = notch.height + 60
        panel.setFrame(NSRect(x: notch.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        panel.level = .popUpMenu // below the system drag layer, above the menu bar
        model.phase = .waiting
    }

    private func dropped(_ urls: [URL]) {
        guard !droppedThisDrag else { return }
        droppedThisDrag = true
        state.files.addToTray(urls)
        model.icons = urls.prefix(3).map { NSWorkspace.shared.icon(forFile: $0.path) }
        model.phase = .added(urls.count)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.hideDropZone()
        }
    }

    private func hideDropZone() {
        model.phase = .hidden
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, self.model.phase == .hidden, !self.dragActive,
                  let panel = self.clickPanel, let notch = NSScreen.notchScreen?.notchRect else { return }
            panel.setFrame(notch, display: true)
            panel.level = .statusBar
        }
    }

    // MARK: - The notch window (click → Tray, drops → Tray)

    private func installClickTarget() {
        guard let screen = NSScreen.notchScreen, let notch = screen.notchRect else { return }
        let panel = NotchPanel(level: .statusBar, ignoresMouse: false)
        panel.hasShadow = false
        panel.setFrame(notch, display: false)

        let container = NotchClickView(frame: NSRect(origin: .zero, size: notch.size))
        container.autoresizingMask = [.width, .height]
        container.onClick = { [weak self] in
            guard let self, self.model.phase == .hidden, let notch = NSScreen.notchScreen?.notchRect else { return }
            self.state.shelf.toggle(.tray, below: notch)
        }
        let host = NSHostingView(rootView: NotchDropView(model: model, notchWidth: notch.width, notchHeight: notch.height))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.unregisterDraggedTypes()
        container.addSubview(host)

        let target = DropTargetView(frame: container.bounds)
        target.autoresizingMask = [.width, .height]
        target.onTargeted = { [weak self] on in
            guard let self, self.model.phase == .waiting || self.model.phase == .targeted else { return }
            self.model.phase = on ? .targeted : .waiting
            if on { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        target.onDrop = { [weak self] urls in self?.dropped(urls) }
        target.onClick = container.onClick
        container.addSubview(target) // topmost: receives drags and clicks

        panel.contentView = container
        panel.orderFrontRegardless()
        clickPanel = panel
    }
}

/// Nearly invisible (alpha 0.01 so it receives clicks) area over the camera housing.
final class NotchClickView: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.01).setFill()
        dirtyRect.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
