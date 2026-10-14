import AppKit

/// Reverses the scroll direction of a classic mouse wheel only — trackpads and Magic Mouse
/// (continuous scrolling devices) keep macOS's "natural" setting. One CGEventTap on scroll events,
/// installed only while the option is on. Needs Accessibility.
@MainActor
final class MouseController {
    private unowned let state: AppState
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var source: CFRunLoopSource?
    nonisolated(unsafe) static var reverseVertical = false
    nonisolated(unsafe) static var reverseHorizontal = false
    nonisolated(unsafe) static weak var shared: MouseController?

    init(state: AppState) {
        self.state = state
        MouseController.shared = self
    }

    func update() {
        Self.reverseVertical = state.settings.reverseMouseScroll
        Self.reverseHorizontal = state.settings.reverseMouseScroll && state.settings.reverseMouseHorizontal
        if state.settings.reverseMouseScroll && AXIsProcessTrusted() {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mouseTapCallback, userInfo: nil) else {
            Log.app.error("Mouse: could not create scroll event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func remove() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    nonisolated func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private func mouseTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MouseController.shared?.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { // trackpad / Magic Mouse: leave alone
        return Unmanaged.passUnretained(event)
    }
    if MouseController.reverseVertical {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
    }
    if MouseController.reverseHorizontal {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
    }
    return Unmanaged.passUnretained(event)
}
