import AppKit
import Observation
import SwiftUI

extension NSScreen {
    /// The camera housing in AppKit coordinates, if this screen has one.
    var notchRect: NSRect? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return NSRect(x: frame.minX + left.maxX, y: frame.maxY - safeAreaInsets.top,
                      width: right.minX - left.maxX, height: safeAreaInsets.top)
    }

    static var notchScreen: NSScreen? { screens.first { $0.notchRect != nil } }
}

@MainActor @Observable
final class NotchModel {
    enum Kind: Equatable { case volume, brightness }
    var kind: Kind = .volume
    var level: Float = 0
    var muted = false
    var visible = false
    // Keep Awake pill
    var awakeProgress: Double = 1   // remaining fraction; 1 when indefinite
    var awakeIndefinite = true
}

/// Black shape that grows out of the notch: icon, green level bar, percentage.
struct NotchHUDView: View {
    let model: NotchModel
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var symbol: String {
        switch model.kind {
        case .brightness: return model.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if model.muted || model.level <= 0.001 { return "speaker.slash.fill" }
            return model.level < 0.34 ? "speaker.wave.1.fill" : (model.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }

    var body: some View {
        let level = model.muted ? 0 : CGFloat(model.level)
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24)
                    .contentTransition(.symbolEffect(.replace))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.green.opacity(0.22))
                        Capsule().fill(model.kind == .brightness ? Color.yellow : Color.green)
                            .frame(width: max(proxy.size.width * level, level > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
                Text(model.muted ? "Muted" : "\(Int((model.level * 100).rounded()))%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
        }
        .frame(width: max(notchWidth + 120, 300))
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous).fill(.black))
        .scaleEffect(x: model.visible ? 1 : 0.6, y: model.visible ? 1 : 0.3, anchor: .top)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: model.visible)
        .animation(.easeOut(duration: 0.12), value: model.level)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Small black tab to the right of the notch while Keep Awake is on: a cup inside a ring
/// that empties as the time runs out (full ring when indefinite).
struct AwakePillView: View {
    let model: NotchModel
    let height: CGFloat

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(Color.purple.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: model.awakeProgress)
                    .stroke(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: model.awakeProgress)
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: height * 0.32, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: height * 0.72, height: height * 0.72)
            .padding(.trailing, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UnevenRoundedRectangle(bottomTrailingRadius: 10, style: .continuous).fill(.black))
    }
}

/// Notch HUD for volume / brightness / mute (replaces the system popup) and the Keep Awake pill.
///
/// Media keys are caught with a CGEventTap (needs Accessibility). A key is only swallowed when
/// EasyMAC actually changed the value; otherwise macOS handles it as usual — so keys never break.
@MainActor
final class NotchController {
    private unowned let state: AppState
    private let model = NotchModel()
    private var hudPanel: FloatingPanel?
    private var pillPanel: FloatingPanel?
    private var hideTask: Task<Void, Never>?
    private var pillTimer: Timer?
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    nonisolated(unsafe) static weak var shared: NotchController?

    init(state: AppState) {
        self.state = state
        NotchController.shared = self
    }

    func start() {
        updateTap()
        observeAwake()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hudPanel = nil
                self?.pillPanel?.orderOut(nil)
                self?.pillPanel = nil
                self?.updatePill()
            }
        }
    }

    // MARK: - Event tap

    func updateTap() {
        if state.settings.notchHUD && AXIsProcessTrusted() {
            installTap()
        } else {
            removeTap()
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) // NX_SYSDEFINED + keyDown
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: notchTapCallback, userInfo: nil) else {
            Log.app.error("Notch HUD: could not create event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    nonisolated func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true when the key was handled (and should be swallowed).
    func handle(key: Int32, down: Bool, fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case 0, 1: // NX_KEYTYPE_SOUND_UP / DOWN
            guard down, let current = SystemControls.volume else { return SystemControls.volume != nil }
            let base = SystemControls.isMuted == true && key == 0 ? 0 : current
            let target = ((base + (key == 0 ? step : -step)) / step).rounded() * step
            guard SystemControls.setVolume(target) else { return false }
            if target <= 0 { SystemControls.setMuted(true) }
            show(.volume, level: SystemControls.volume ?? target, muted: SystemControls.isMuted ?? false)
            return true
        case 7: // NX_KEYTYPE_MUTE
            guard down else { return SystemControls.isMuted != nil }
            guard let muted = SystemControls.isMuted, SystemControls.setMuted(!muted) else { return false }
            show(.volume, level: SystemControls.volume ?? 0, muted: !muted)
            return true
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
            guard down else { return SystemControls.brightness != nil }
            guard let current = SystemControls.brightness else { return false }
            let target = min(max(((current + (key == 2 ? step : -step)) / step).rounded() * step, 0), 1)
            guard SystemControls.setBrightness(target) else { return false }
            show(.brightness, level: target, muted: false)
            return true
        default:
            return false
        }
    }

    // MARK: - HUD

    private func show(_ kind: NotchModel.Kind, level: Float, muted: Bool) {
        guard let screen = NSScreen.notchScreen ?? NSScreen.withMouse else { return }
        let notch = screen.notchRect ?? NSRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 32, width: 180, height: 32)
        let panel = hudPanel ?? makeHUD(screen: screen, notch: notch)
        hudPanel = panel
        model.kind = kind
        model.level = level
        model.muted = muted
        panel.orderFrontRegardless()
        model.visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.model.visible = false
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.hudPanel?.orderOut(nil)
        }
    }

    private func makeHUD(screen: NSScreen, notch: NSRect) -> FloatingPanel {
        let panel = FloatingPanel(level: .screenSaver, ignoresMouse: true)
        panel.hasShadow = false
        let width = max(notch.width + 120, 300)
        let height = notch.height + 38
        panel.setFrame(NSRect(x: notch.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: false)
        panel.contentView = NSHostingView(rootView: NotchHUDView(model: model, notchWidth: notch.width, notchHeight: notch.height))
        return panel
    }

    // MARK: - Keep Awake pill

    private func observeAwake() {
        withObservationTracking {
            _ = state.awake.isActive
            _ = state.awake.endDate
            _ = state.settings.notchAwakeIndicator
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updatePill()
                self?.observeAwake()
            }
        }
        updatePill()
    }

    private func updatePill() {
        let active = state.awake.isActive && state.settings.notchAwakeIndicator
        guard active, let screen = NSScreen.notchScreen, let notch = screen.notchRect else {
            pillTimer?.invalidate()
            pillTimer = nil
            pillPanel?.orderOut(nil)
            return
        }
        let start = Date()
        let total = state.awake.endDate.map { $0.timeIntervalSince(start) }
        let panel = pillPanel ?? {
            let p = FloatingPanel(level: .screenSaver, ignoresMouse: true)
            p.hasShadow = false
            let width = notch.height + 22
            // Tucks 10 pt under the notch so the black shapes read as one piece.
            p.setFrame(NSRect(x: notch.maxX - 10, y: notch.minY, width: width, height: notch.height), display: false)
            p.contentView = NSHostingView(rootView: AwakePillView(model: model, height: notch.height))
            return p
        }()
        pillPanel = panel
        panel.orderFrontRegardless()
        refreshProgress(total: total)
        pillTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProgress(total: total) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pillTimer = timer
    }

    private func refreshProgress(total: TimeInterval?) {
        guard let end = state.awake.endDate, let total, total > 0 else {
            model.awakeIndefinite = true
            model.awakeProgress = 1
            return
        }
        model.awakeIndefinite = false
        model.awakeProgress = max(0, min(1, end.timeIntervalSinceNow / total))
    }
}

/// C callback for the event tap: decodes media keys (NX_SYSDEFINED subtype 8) and the dedicated
/// brightness key codes, and asks the controller to handle them on the main thread.
private func notchTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        NotchController.shared?.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    var key: Int32 = -1
    var down = false
    var fine = false
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        let data = ns.data1
        key = Int32((data & 0xFFFF_0000) >> 16)
        down = ((data & 0xFF00) >> 8) == 0xA
        fine = ns.modifierFlags.contains([.option, .shift])
    } else if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == 144 { key = 2; down = true } else if code == 145 { key = 3; down = true }
        fine = event.flags.contains([.maskAlternate, .maskShift])
    }
    guard [0, 1, 2, 3, 7].contains(key) else { return Unmanaged.passUnretained(event) }
    let handled = MainActor.assumeIsolated {
        NotchController.shared?.handle(key: key, down: down, fine: fine) ?? false
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}
