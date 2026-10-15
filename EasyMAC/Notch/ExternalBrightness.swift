import AppKit
import IOKit

/// Brightness keys for the screen under the pointer when it's an external monitor.
///
/// macOS can't change a third-party monitor's brightness. When the monitor answers DDC/CI (the
/// standard monitor control channel, read through IOAVService like MonitorControl / Lunar do) its real
/// backlight is changed; otherwise the picture is dimmed through the display's gamma table, which
/// works on every screen and is undone when EasyMAC quits. DDC is slow (~50 ms a message), so writes
/// run on their own queue and only the latest level is sent; the event tap never waits on a monitor.
enum ExternalBrightness {
    private final class Monitor: @unchecked Sendable {
        let service: CFTypeRef?          // DDC channel; nil = dim the picture
        let maxValue: Int
        var level: Float
        var originalGamma: [[CGGammaValue]]?
        init(service: CFTypeRef?, maxValue: Int, level: Float) {
            self.service = service
            self.maxValue = maxValue
            self.level = level
        }
    }

    private static let queue = DispatchQueue(label: "com.appalbania.easymac.ddc", qos: .userInitiated)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var monitors: [CGDirectDisplayID: Monitor] = [:]
    nonisolated(unsafe) private static var pendingWrites: [CGDirectDisplayID: Float] = [:]

    // MARK: - Pointer

    /// The display under the pointer, or nil when it's the built-in screen. Safe on any thread.
    static func externalDisplayUnderPointer() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0,
              CGDisplayIsBuiltin(id) == 0 else { return nil }
        return id
    }

    // MARK: - Level

    /// Current level (0…1). Monitors not probed yet are treated as full brightness, dimmed in software.
    static func level(of display: CGDirectDisplayID) -> Float {
        lock.withLock { monitors[display]?.level } ?? 1
    }

    static func set(_ value: Float, on display: CGDirectDisplayID) {
        let value = min(max(value, 0), 1)
        let monitor: Monitor = lock.withLock {
            let m = monitors[display] ?? Monitor(service: nil, maxValue: 100, level: 1)
            monitors[display] = m
            m.level = value
            return m
        }
        if monitor.service != nil {
            let first = lock.withLock { () -> Bool in
                defer { pendingWrites[display] = value }
                return pendingWrites[display] == nil
            }
            if first { queue.async { flushWrite(display) } }
        } else {
            applyGamma(monitor, display)
        }
    }

    /// Sends the newest pending level; presses that arrive while a write is in flight are merged.
    private static func flushWrite(_ display: CGDirectDisplayID) {
        guard let (monitor, value) = lock.withLock({ () -> (Monitor, Float)? in
            guard let v = pendingWrites.removeValue(forKey: display), let m = monitors[display] else { return nil }
            return (m, v)
        }), let service = monitor.service else { return }
        DDC.write(service, vcp: 0x10, value: Int((value * Float(monitor.maxValue)).rounded()))
    }

    // MARK: - Software dimming

    private static func applyGamma(_ monitor: Monitor, _ display: CGDirectDisplayID) {
        if monitor.originalGamma == nil {
            guard let table = readGamma(display) else { return }
            monitor.originalGamma = table
        }
        guard let original = monitor.originalGamma else { return }
        let f = monitor.level
        var r = original[0].map { $0 * f }, g = original[1].map { $0 * f }, b = original[2].map { $0 * f }
        CGSetDisplayTransferByTable(display, UInt32(r.count), &r, &g, &b)
    }

    private static func readGamma(_ display: CGDirectDisplayID) -> [[CGGammaValue]]? {
        let capacity = Int(CGDisplayGammaTableCapacity(display))
        guard capacity > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: capacity), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, UInt32(capacity), &r, &g, &b, &count) == .success, count > 0 else { return nil }
        return [Array(r.prefix(Int(count))), Array(g.prefix(Int(count))), Array(b.prefix(Int(count)))]
    }

    // MARK: - Lifecycle

    /// Finds external monitors and asks each over DDC for its brightness (in the background).
    /// Called at start and whenever displays change or wake — macOS resets the gamma table then,
    /// so software-dimmed screens get their level back.
    static func refresh() {
        queue.async {
            let found = DDC.externalServices()
            let online = onlineExternalDisplays()
            var probed: [CGDirectDisplayID: (CFTypeRef, Int, Float)] = [:]
            for display in online {
                if let service = DDC.match(display, in: found), let (current, maxValue) = DDC.readBrightness(service) {
                    probed[display] = (service, maxValue, Float(current) / Float(maxValue))
                }
            }
            let dimmed: [(Monitor, CGDirectDisplayID)] = lock.withLock {
                var result: [(Monitor, CGDirectDisplayID)] = []
                var next: [CGDirectDisplayID: Monitor] = [:]
                for display in online {
                    let old = monitors[display]
                    if let (service, maxValue, level) = probed[display] {
                        next[display] = Monitor(service: service, maxValue: maxValue, level: level)
                    } else {
                        let m = Monitor(service: nil, maxValue: 100, level: old?.service == nil ? (old?.level ?? 1) : 1)
                        next[display] = m
                        if m.level < 1 { result.append((m, display)) }
                    }
                }
                monitors = next
                return result
            }
            // The system just restored the real curves: capture them again, then re-dim.
            for (monitor, display) in dimmed { applyGamma(monitor, display) }
            Log.app.notice("External brightness: \(online.count) display(s), DDC on \(probed.count)")
        }
    }

    /// Puts every software-dimmed screen back to normal (option off, or quitting).
    static func restoreAll() {
        let hadDimmed = lock.withLock {
            let any = monitors.values.contains { $0.service == nil && $0.originalGamma != nil }
            monitors = [:]
            return any
        }
        if hadDimmed { CGDisplayRestoreColorSyncSettings() }
    }

    private static func onlineExternalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }
}

/// DDC/CI over Apple Silicon's IOAVService (private IOKit calls, resolved at runtime).
private enum DDC {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    nonisolated(unsafe) private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create: CreateFn? = symbol("IOAVServiceCreateWithService")
    private static let readI2C: I2CFn? = symbol("IOAVServiceReadI2C")
    private static let writeI2C: I2CFn? = symbol("IOAVServiceWriteI2C")

    private static func symbol<T>(_ name: String) -> T? {
        guard let iokit, let pointer = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    struct Service {
        let service: CFTypeRef
        let vendor: Int?
        let model: Int?
        let serial: Int?
    }

    /// External AV services, each paired with the attributes of the framebuffer listed before it.
    static func externalServices() -> [Service] {
        guard let create else { return [] }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var attributes: [String: Any]?
        var result: [Service] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                let display = property(entry, "DisplayAttributes") as? [String: Any]
                attributes = display?["ProductAttributes"] as? [String: Any]
            } else if name == "DCPAVServiceProxy", property(entry, "Location") as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                result.append(Service(service: service,
                                      vendor: attributes?["LegacyManufacturerID"] as? Int,
                                      model: attributes?["ProductID"] as? Int,
                                      serial: attributes?["SerialNumber"] as? Int))
                attributes = nil
            }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func match(_ display: CGDirectDisplayID, in services: [Service]) -> CFTypeRef? {
        let vendor = Int(CGDisplayVendorNumber(display)), model = Int(CGDisplayModelNumber(display))
        let serial = Int(CGDisplaySerialNumber(display))
        let candidates = services.filter { $0.vendor == vendor && $0.model == model }
        return (candidates.first { $0.serial == serial } ?? candidates.first)?.service
    }

    /// (current, max) of a VCP feature, or nil when the monitor doesn't answer.
    static func readBrightness(_ service: CFTypeRef) -> (Int, Int)? {
        guard let readI2C, let writeI2C else { return nil }
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, 0x10, 0]
            request[3] = 0x6E ^ 0x82 ^ 0x01 ^ 0x10
            guard writeI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else { return nil }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if readI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               reply[2] == 0x02, reply[3] == 0x00, reply[4] == 0x10,
               reply.dropLast().reduce(UInt8(0x50), ^) == reply[10] {
                let maxValue = Int(reply[6]) << 8 | Int(reply[7])
                let current = Int(reply[8]) << 8 | Int(reply[9])
                if maxValue > 0 { return (min(current, maxValue), maxValue) }
            }
            usleep(40_000)
        }
        return nil
    }

    static func write(_ service: CFTypeRef, vcp: UInt8, value: Int) {
        guard let writeI2C else { return }
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        packet[5] = packet.dropLast().reduce(UInt8(0x6E ^ 0x51), ^)
        // Sent twice: monitors drop a message now and then and DDC has no acknowledgement.
        for _ in 0..<2 {
            _ = writeI2C(service, 0x37, 0x51, &packet, UInt32(packet.count))
            usleep(10_000)
        }
    }
}
