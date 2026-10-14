import AppKit
import AudioToolbox
import CoreAudio

/// Output volume / mute through CoreAudio, built-in display brightness through DisplayServices
/// (private, resolved with dlsym — the same call System Settings uses). Every setter returns
/// false when the device doesn't support it, so the caller can let macOS handle the key instead.
enum SystemControls {

    // MARK: - Volume

    private static var outputDevice: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static var volume: Float? {
        guard let device = outputDevice else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setVolume(_ value: Float) -> Bool {
        guard let device = outputDevice else { return false }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = Float32(min(max(value, 0), 1))
        let ok = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        if ok && v > 0 && isMuted == true { setMuted(false) }
        return ok
    }

    static var isMuted: Bool? {
        guard let device = outputDevice else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyMute)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = outputDevice else { return false }
        var addr = address(kAudioDevicePropertyMute)
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: - Brightness (built-in display)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetFn? = symbol("DisplayServicesGetBrightness")
    private static let setBrightnessFn: SetFn? = symbol("DisplayServicesSetBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = displayServices, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetOnlineDisplayList(8, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var brightness: Float? {
        guard let display = builtInDisplay, let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func setBrightness(_ value: Float) -> Bool {
        guard let display = builtInDisplay, let setBrightnessFn else { return false }
        return setBrightnessFn(display, min(max(value, 0), 1)) == 0
    }
}
