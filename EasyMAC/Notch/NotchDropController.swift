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

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let list = urls(sender)
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
    private var dropPanel: NotchPanel?
    private var clickPanel: NotchPanel?
    private var monitors: [Any] = []
    private var dragChangeCount = 0
    private var dragActive = false
    private var hideTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func update() {
        let enabled = state.settings.notchTray && NSScreen.notchScreen != nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        clickPanel?.orderOut(nil)
        clickPanel = nil
        dropPanel?.orderOut(nil)
        dropPanel = nil
        guard enabled else { return }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragChangeCount = NSPasteboard(name: .drag).changeCount }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
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
        guard pasteboard.changeCount != dragChangeCount,
              pasteboard.types?.contains(.fileURL) == true else { return }
        dragActive = true
        showDropZone()
    }

    private func dragEnded() {
        guard dragActive else { return }
        dragActive = false
        // Give performDragOperation a moment; if nothing was dropped, close.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            if case .added = self.model.phase { return }
            self.hideDropZone()
        }
    }

    // MARK: - Drop zone

    private func showDropZone() {
        guard let screen = NSScreen.notchScreen, let notch = screen.notchRect else { return }
        hideTask?.cancel()
        let panel = dropPanel ?? makeDropPanel(screen: screen, notch: notch)
        dropPanel = panel
        panel.orderFrontRegardless()
        model.phase = .waiting
    }

    private func makeDropPanel(screen: NSScreen, notch: NSRect) -> NotchPanel {
        let panel = NotchPanel(level: .screenSaver, ignoresMouse: false)
        panel.hasShadow = false
        let width = notch.width + 220
        let height = notch.height + 60
        panel.setFrame(NSRect(x: notch.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: false)
        let target = DropTargetView(frame: NSRect(origin: .zero, size: panel.frame.size))
        target.autoresizingMask = [.width, .height]
        target.onTargeted = { [weak self] on in
            guard let self, self.model.phase == .waiting || self.model.phase == .targeted else { return }
            self.model.phase = on ? .targeted : .waiting
            if on { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        target.onDrop = { [weak self] urls in self?.dropped(urls) }
        let host = NSHostingView(rootView: NotchDropView(model: model, notchWidth: notch.width, notchHeight: notch.height))
        host.frame = target.bounds
        host.autoresizingMask = [.width, .height]
        target.addSubview(host)
        panel.contentView = target
        return panel
    }

    private func dropped(_ urls: [URL]) {
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
        let panel = dropPanel
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            if self.model.phase == .hidden { panel?.orderOut(nil) }
        }
    }

    // MARK: - Click the notch → Tray

    private func installClickTarget() {
        guard let screen = NSScreen.notchScreen, let notch = screen.notchRect else { return }
        let panel = NotchPanel(level: .statusBar, ignoresMouse: false)
        panel.hasShadow = false
        panel.setFrame(notch, display: false)
        let view = NotchClickView(frame: NSRect(origin: .zero, size: notch.size))
        view.onClick = { [weak self] in
            guard let self, let notch = NSScreen.notchScreen?.notchRect else { return }
            self.state.shelf.toggle(.tray, below: notch)
        }
        panel.contentView = view
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
