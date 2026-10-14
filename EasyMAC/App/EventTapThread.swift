import CoreGraphics
import Foundation

/// A dedicated thread + run loop for CGEventTaps. Taps on the main thread make every keystroke and
/// scroll on the Mac wait whenever EasyMAC's UI is busy (that was the menu/scroll lag); here they never do.
final class EventTapThread: Thread, @unchecked Sendable {
    static let shared: EventTapThread = {
        let thread = EventTapThread()
        thread.name = "com.appalbania.easymac.eventtaps"
        thread.qualityOfService = .userInteractive
        thread.start()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private var loop: CFRunLoop?

    override func main() {
        loop = CFRunLoopGetCurrent()
        // Keep the run loop alive even with no sources yet.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    var runLoop: CFRunLoop? {
        if loop == nil { ready.wait(); ready.signal() }
        return loop
    }

    /// Creates a tap and attaches it to this thread's run loop.
    func addTap(mask: CGEventMask, callback: CGEventTapCallBack) -> (CFMachPort, CFRunLoopSource)? {
        guard let loop = runLoop,
              let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return nil }
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopWakeUp(loop)
        return (tap, source)
    }

    func removeTap(_ tap: CFMachPort, _ source: CFRunLoopSource) {
        CGEvent.tapEnable(tap: tap, enable: false)
        if let loop = runLoop { CFRunLoopRemoveSource(loop, source, .commonModes) }
    }
}
