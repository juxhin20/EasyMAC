import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ClipboardPanelModel {
    var query = ""
    var selectedIndex = 0
}

struct ClipboardView: View {
    let history: ClipboardHistory
    let model: ClipboardPanelModel
    let choose: (ClipItem) -> Void
    let close: () -> Void

    private var accent: Color { Color(nsColor: Settings.shared.sidebarAccent.nsColor) }

    var items: [ClipItem] {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? history.items : history.items.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search clipboard", text: Binding(get: { model.query }, set: { model.query = $0; model.selectedIndex = 0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 180)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.10)))

                Label("Clipboard", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.10)))

                Spacer()
                if !history.items.isEmpty {
                    Button("Clear") { history.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .background(WindowDragHandle().opacity(0))

            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text(history.items.isEmpty ? "Copy something — it shows up here" : "No matches")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, selected: index == model.selectedIndex, accent: accent)
                                    .id(item.id)
                                    .onTapGesture { choose(item) }
                                    .onDrag { Self.provider(for: item) }
                                    .contextMenu {
                                        Button("Paste") { choose(item) }
                                        Button("Copy Only") { history.copy(item); close() }
                                        Divider()
                                        Button("Delete") { history.remove(item) }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: model.selectedIndex) { _, index in
                        guard items.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(items[index].id, anchor: .center) }
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    static func provider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text(let s): NSItemProvider(object: s as NSString)
        case .link(let u): NSItemProvider(object: u as NSURL)
        case .image(let image): NSItemProvider(object: image)
        case .files(let urls): urls.first.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        }
    }
}

private struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    let accent: Color
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(width: 210, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 5) {
                if let id = item.sourceBundleID, let icon = AppIconCache.icon(bundleID: id) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(item.label).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(.black.opacity(0.65)))
            .foregroundStyle(.white)
            .padding(.bottom, 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? accent : Color.white.opacity(hovered ? 0.35 : 0.10), lineWidth: selected ? 3 : 1)
        }
        .scaleEffect(hovered ? 1.03 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
        .help(String(item.searchText.prefix(300)))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text(let s):
            Text(s.prefix(400))
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .background(Color.white.opacity(0.08))
        case .link(let u):
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link").font(.system(size: 18)).foregroundStyle(accent)
                Text(u.host ?? u.absoluteString).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(u.absoluteString).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Color.white.opacity(0.08))
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 210, height: 150)
                .background(Color.white.opacity(0.9))
        case .files(let urls):
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path)).resizable().frame(width: 52, height: 52)
                Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) +\(urls.count - 1)")
                    .font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.08))
        }
    }
}

/// Bottom-of-screen clipboard bar. Opens with ⌥⇧V; ←/→ pick, Return pastes, Esc closes.
@MainActor
final class ClipboardPanelController {
    private unowned let state: AppState
    private let model = ClipboardPanelModel()
    private var panel: FilePanel?
    private var monitors: [Any] = []
    private var statusItem: NSStatusItem?

    init(state: AppState) {
        self.state = state
    }

    /// Optional 📋 menu bar icon: click opens / closes the clipboard bar.
    func updateStatusItem() {
        let wanted = state.settings.clipboardEnabled && state.settings.showClipboardIcon
        if wanted, statusItem == nil {
            let item = MenuBarItems.make("clipboard") { [weak self] in self?.state.settings.showClipboardIcon = false }
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard history")
            image?.isTemplate = true
            item.button?.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            item.button?.toolTip = "Clipboard history (\(HotkeyController.shortcutText(.clipboardHistory) ?? "⌥⇧V"))"
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            statusItem = item
        } else if !wanted, let statusItem {
            MenuBarItems.remove(statusItem, name: "clipboard")
            self.statusItem = nil
        }
    }

    @objc private func statusClicked() {
        toggle()
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard let screen = NSScreen.withMouse else { return }
        model.query = ""
        model.selectedIndex = 0
        let panel = self.panel ?? FilePanel(level: .popUpMenu)
        self.panel = panel
        let view = ClipboardView(history: state.clipboard, model: model,
                                 choose: { [weak self] in self?.choose($0) },
                                 close: { [weak self] in self?.close() })
        panel.contentView = PanelBackground.make(style: .dark, cornerRadius: 22, content: TrackingHostingView(rootView: AnyView(view)))
        let visible = screen.visibleFrame
        let width = min(visible.width - 32, 1400)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.minY + 12, width: width, height: 230)
        panel.setFrame(frame.offsetBy(dx: 0, dy: -24), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func close() {
        removeMonitors()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    private func choose(_ item: ClipItem) {
        state.clipboard.copy(item)
        close()
        guard state.settings.clipboardPasteDirectly else { return }
        // Give the panel a moment to go away so ⌘V lands in the app you were using.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            ClipboardHistory.pasteIntoFrontApp()
        }
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // A normal mouse wheel only scrolls vertically: turn it into sideways scrolling over the cards.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let isOurs = MainActor.assumeIsolated { event.window === self?.panel }
            guard isOurs, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let cg = event.cgEvent?.copy() else { return event }
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            return NSEvent(cgEvent: cg) ?? event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let view = ClipboardView(history: state.clipboard, model: model, choose: { _ in }, close: {})
        let items = view.items
        switch event.keyCode {
        case 53: close(); return true
        case 123: model.selectedIndex = max(0, model.selectedIndex - 1); return true
        case 124: model.selectedIndex = min(max(items.count - 1, 0), model.selectedIndex + 1); return true
        case 36, 76:
            if items.indices.contains(model.selectedIndex) { choose(items[model.selectedIndex]) }
            return true
        default: return false
        }
    }
}
