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

/// Panel allowed to sit in the menu bar / notch strip (AppKit normally pushes windows below it).
final class NotchPanel: FloatingPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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

/// The notch grows sideways (same height): icon + label on the left wing, a slim level bar and the
/// number on the right wing — it reads as part of the notch, nothing hangs below the menu bar.
struct NotchHUDView: View {
    let model: NotchModel
    let notchWidth: CGFloat
    let height: CGFloat

    static let wing: CGFloat = 116

    private var symbol: String {
        switch model.kind {
        case .brightness: return model.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if model.muted || model.level <= 0.001 { return "speaker.slash.fill" }
            return model.level < 0.34 ? "speaker.wave.1.fill" : (model.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }

    private var title: String {
        switch model.kind {
        case .brightness: "Brightness"
        case .volume: model.muted ? "Muted" : "Volume"
        }
    }

    private var tint: Color { model.kind == .brightness ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 0.3, green: 0.85, blue: 0.45) }

    var body: some View {
        let level = model.muted ? 0 : CGFloat(model.level)
        HStack(spacing: 0) {
            // Left wing
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: height * 0.38, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height * 0.6)
                Text(title)
                    .font(.system(size: height * 0.36, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.leading, height * 0.45)
            .frame(width: Self.wing)

            Color.clear.frame(width: notchWidth)

            // Right wing
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.25))
                    Capsule().fill(tint).frame(width: max(52 * level, level > 0 ? 4 : 0))
                }
                .frame(width: 52, height: 4)
                Text("\(Int((model.muted ? 0 : model.level * 100).rounded()))")
                    .font(.system(size: height * 0.38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: 26, alignment: .trailing)
            }
            .padding(.trailing, height * 0.45)
            .frame(width: Self.wing)
        }
        .foregroundStyle(.white)
        .frame(height: height)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: height * 0.42, bottomTrailingRadius: height * 0.42, style: .continuous).fill(.black))
        // Opens outward from the notch.
        .mask(alignment: .center) {
            Rectangle().frame(width: model.visible ? notchWidth + Self.wing * 2 : notchWidth)
        }
        .opacity(model.visible ? 1 : 0.01)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.visible)
        .animation(.easeOut(duration: 0.12), value: model.level)
        .animation(.easeOut(duration: 0.15), value: model.kind)
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
    private var hudPanel: NotchPanel?
    private var pillPanel: NotchPanel?
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
        if state.settings.notchHUD && PermissionCache.accessibility {
            installTap()
        } else {
            removeTap()
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) // NX_SYSDEFINED + keyDown
        guard let created = EventTapThread.shared.addTap(mask: mask, callback: notchTapCallback) else {
            Log.app.error("Notch HUD: could not create event tap")
            return
        }
        tap = created.0
        runLoopSource = created.1
    }

    private func removeTap() {
        if let tap, let runLoopSource { EventTapThread.shared.removeTap(tap, runLoopSource) }
        tap = nil
        runLoopSource = nil
    }

    nonisolated func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Runs on the event-tap thread (CoreAudio / DisplayServices are thread-safe). Returns true when
    /// the key was handled and should be swallowed; the HUD is drawn on the main thread.
    nonisolated static func handle(key: Int32, down: Bool, fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        let hud: (NotchModel.Kind, Float, Bool)?
        switch key {
        case 0, 1: // NX_KEYTYPE_SOUND_UP / DOWN
            guard let current = SystemControls.volume else { return false }
            guard down else { return true }
            let base = SystemControls.isMuted == true && key == 0 ? 0 : current
            let target = min(max(((base + (key == 0 ? step : -step)) / step).rounded() * step, 0), 1)
            guard SystemControls.setVolume(target) else { return false }
            if target <= 0 { SystemControls.setMuted(true) }
            hud = (.volume, SystemControls.volume ?? target, SystemControls.isMuted ?? false)
        case 7: // NX_KEYTYPE_MUTE
            guard let muted = SystemControls.isMuted else { return false }
            guard down else { return true }
            guard SystemControls.setMuted(!muted) else { return false }
            hud = (.volume, SystemControls.volume ?? 0, !muted)
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
            guard let current = SystemControls.brightness else { return false }
            guard down else { return true }
            let target = min(max(((current + (key == 2 ? step : -step)) / step).rounded() * step, 0), 1)
            guard SystemControls.setBrightness(target) else { return false }
            hud = (.brightness, target, false)
        default:
            return false
        }
        if let hud {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NotchController.shared?.show(hud.0, level: hud.1, muted: hud.2) }
            }
        }
        return true
    }

    // MARK: - HUD

    /// Shows the HUD with the current volume for a few seconds (`--args -previewNotchHUD YES`), used to
    /// check the look without pressing keys.
    func preview() {
        show(.volume, level: SystemControls.volume ?? 0.5, muted: SystemControls.isMuted ?? false, hold: 6)
    }

    func show(_ kind: NotchModel.Kind, level: Float, muted: Bool, hold: Double = 1.5) {
        guard let screen = NSScreen.notchScreen ?? NSScreen.withMouse else { return }
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let notch = screen.notchRect ?? NSRect(x: screen.frame.midX - 40, y: screen.frame.maxY - barHeight, width: 80, height: barHeight)
        let panel = hudPanel ?? makeHUD(screen: screen, notch: notch)
        hudPanel = panel
        model.kind = kind
        model.level = level
        model.muted = muted
        panel.orderFrontRegardless()
        model.visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled, let self else { return }
            self.model.visible = false
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.hudPanel?.orderOut(nil)
        }
    }

    private func makeHUD(screen: NSScreen, notch: NSRect) -> NotchPanel {
        let panel = NotchPanel(level: .screenSaver, ignoresMouse: true)
        panel.hasShadow = false
        let width = notch.width + NotchHUDView.wing * 2
        panel.setFrame(NSRect(x: notch.midX - width / 2, y: screen.frame.maxY - notch.height, width: width, height: notch.height), display: false)
        panel.contentView = NSHostingView(rootView: NotchHUDView(model: model, notchWidth: notch.width, height: notch.height))
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
            let p = NotchPanel(level: .screenSaver, ignoresMouse: true)
            p.hasShadow = false
            let width = notch.height + 22
            p.setFrame(NSRect(x: notch.maxX - 10, y: notch.minY, width: width, height: notch.height), display: false)
            p.contentView = NSHostingView(rootView: AwakePillView(model: model, height: notch.height))
            return p
        }()
        pillPanel = panel
        // Tucked 10 pt under the notch so the black shapes read as one piece.
        panel.setFrameOrigin(NSPoint(x: notch.maxX - 10, y: notch.minY))
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
    return NotchController.handle(key: key, down: down, fine: fine) ? nil : Unmanaged.passUnretained(event)
}
