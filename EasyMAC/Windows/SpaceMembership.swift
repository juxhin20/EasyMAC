import CoreGraphics
import Foundation

/// Which windows belong to the desktop(s) currently shown.
///
/// During a trackpad swipe between desktops the on-screen window list contains the windows of *both*
/// desktops for as long as the gesture lasts, which made the strip grow and shrink. macOS only switches
/// the "current space" when the swipe completes, so keeping windows whose space is current gives one
/// clean change per swipe. Private SkyLight calls via dlsym (same as SpacesService); if unavailable,
/// nothing is filtered.
enum SpaceMembership {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: ConnectionFn? = symbol("SLSMainConnectionID")
    private static let spacesForWindows: SpacesForWindowsFn? = symbol("SLSCopySpacesForWindows")
    private static let displaySpaces: DisplaySpacesFn? = symbol("SLSCopyManagedDisplaySpaces")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = skylight, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// IDs of windows that are on screen but belong to a desktop that is *not* current (mid-swipe).
    static func windowsOffCurrentSpace(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard let connection, let spacesForWindows, let displaySpaces else { return [] }
        let cid = connection()
        guard let displays = displaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let current = Set(displays.compactMap { (($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value })
        guard !current.isEmpty else { return [] }
        var off = Set<CGWindowID>()
        for id in ids {
            guard let spaces = spacesForWindows(cid, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber],
                  !spaces.isEmpty else { continue } // no space info (or on all desktops): keep
            if current.isDisjoint(with: spaces.map(\.uint64Value)) { off.insert(id) }
        }
        return off
    }
}
