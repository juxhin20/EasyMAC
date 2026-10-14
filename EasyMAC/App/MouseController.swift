import AppKit

enum MouseScrollDirection: String, CaseIterable, Identifiable {
    case system, standard, natural
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Same as trackpad (macOS setting)"
        case .standard: "Standard — wheel up scrolls up"
        case .natural: "Natural — content follows the wheel"
        }
    }
}

/// Gives a mouse wheel its own scroll direction, independent of the trackpad.
///
/// macOS has one "natural scrolling" switch for both, and smooth wheels (Logitech MagSpeed) produce
/// scroll events that look exactly like trackpad ones (continuous, with phases and momentum). The one
/// reliable difference: a trackpad / Magic Mouse reports finger touches (gesture events) while you
/// scroll, a wheel never does. So: scrolling within 0.35 s of a touch = trackpad, otherwise = mouse;
/// momentum keeps the source of the scroll that started it. Runs on the event-tap thread.
@MainActor
final class MouseController {
    private unowned let state: AppState
    nonisolated(unsafe) private var tap: (CFMachPort, CFRunLoopSource)?
    nonisolated(unsafe) static var invertVertical = false
    nonisolated(unsafe) static var invertHorizontal = false
    nonisolated(unsafe) static var lastTouch: UInt64 = 0          // mach time of last trackpad touch
    nonisolated(unsafe) static var lastScrollWasTrackpad = false
    nonisolated(unsafe) static weak var shared: MouseController?

    init(state: AppState) {
        self.state = state
        MouseController.shared = self
    }

    static var systemNatural: Bool {
        CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
    }

    func update() {
        let direction = state.settings.mouseScrollDirection
        let natural = Self.systemNatural
        let invert = (direction == .standard && natural) || (direction == .natural && !natural)
        Self.invertVertical = invert
        Self.invertHorizontal = invert && state.settings.reverseMouseHorizontal
        Log.app.notice("Mouse: direction=\(direction.rawValue, privacy: .public) systemNatural=\(natural) invert=\(invert) ax=\(PermissionCache.accessibility)")
        if invert && PermissionCache.accessibility {
            guard tap == nil else { return }
            // scrollWheel + gesture (29): gesture events carry the trackpad's finger touches.
            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue) | CGEventMask(1 << 29)
            tap = EventTapThread.shared.addTap(mask: mask, callback: mouseTapCallback)
            Log.app.notice("Mouse: scroll tap \(self.tap == nil ? "FAILED" : "installed", privacy: .public)")
        } else if let tap {
            EventTapThread.shared.removeTap(tap.0, tap.1)
            self.tap = nil
        }
    }

    nonisolated func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap.0, enable: true) }
    }
}

private let touchWindow: UInt64 = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return 350_000_000 * UInt64(info.denom) / UInt64(info.numer) // 0.35 s in mach units
}()

private func mouseTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MouseController.shared?.reenable()
        return Unmanaged.passUnretained(event)
    }
    let now = mach_absolute_time()
    if type.rawValue == 29 { // gesture = fingers on the trackpad / Magic Mouse
        MouseController.lastTouch = now
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    let trackpad: Bool
    if momentum != 0 {
        trackpad = MouseController.lastScrollWasTrackpad // glide continues the scroll that started it
    } else {
        trackpad = now &- MouseController.lastTouch < touchWindow
        MouseController.lastScrollWasTrackpad = trackpad
    }

    guard !trackpad else { return Unmanaged.passUnretained(event) }

    // Read everything first: writing the line delta makes macOS recompute the point / fixed-point
    // deltas, so flipping them one by one would flip them straight back (the "nothing happens" bug).
    let line1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let line2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    if MouseController.invertVertical {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -line1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point1)
    }
    if MouseController.invertHorizontal {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -line2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -point2)
    }
    return Unmanaged.passUnretained(event)
}
