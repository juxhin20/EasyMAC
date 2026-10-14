import CoreGraphics
import Foundation

struct WindowInfo: Identifiable, Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    var title: String
    /// AX / CoreGraphics coordinates (top-left origin of the primary display).
    var frame: CGRect
    var isMinimized: Bool
    var isAppHidden: Bool
    var lastActivated: Date
    var isPinned = false
    var isActive = false

    var id: CGWindowID { windowID }
    var displayTitle: String { title.isEmpty ? appName : title }
    var isOffscreen: Bool { isMinimized || isAppHidden }

    var stateLabel: String? {
        if isMinimized { return "Minimized" }
        if isAppHidden { return "Hidden" }
        return nil
    }
}
