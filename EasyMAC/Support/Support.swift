import AppKit
import os
import SwiftUI

enum Log {
    static let subsystem = "com.appalbania.easymac"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let windows = Logger(subsystem: subsystem, category: "windows")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
    static let workspaces = Logger(subsystem: subsystem, category: "workspaces")
    static let layout = Logger(subsystem: subsystem, category: "layout")
    static let radial = Logger(subsystem: subsystem, category: "radial")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}

enum Brand {
    static let redHex = "#D22027"
    static let red = Color(hex: redHex)
    static let nsRed = NSColor(hex: redHex)
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = parseHex(hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        let (r, g, b) = parseHex(hex)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

private func parseHex(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)
    guard cleaned.count == 6 else { return (0.5, 0.5, 0.5) }
    return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
}

extension NSScreen {
    /// The screen holding the menu bar; AppKit's global origin is its bottom-left corner.
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }

    var visibleFrameAX: CGRect { Coordinates.appKitToAX(visibleFrame, primaryHeight: NSScreen.primaryHeight) }
    var frameAX: CGRect { Coordinates.appKitToAX(frame, primaryHeight: NSScreen.primaryHeight) }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Stable across launches and resolution changes (display UUID), falls back to the name.
    var stableID: String {
        if let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return localizedName
    }

    func isSameDisplay(as other: NSScreen?) -> Bool {
        guard let other else { return false }
        if let a = displayID, let b = other.displayID { return a == b }
        return frame == other.frame
    }

    static func screen(withStableID id: String?) -> NSScreen? {
        guard let id else { return nil }
        return screens.first { $0.stableID == id } ?? screens.first { $0.localizedName == id }
    }

    static var withMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }

    /// The screen showing most of an AX-space rect.
    static func screen(forAXRect rect: CGRect) -> NSScreen? {
        let appKit = Coordinates.axToAppKit(rect, primaryHeight: primaryHeight)
        var best: (NSScreen, CGFloat)?
        for screen in screens {
            let overlap = screen.frame.intersection(appKit)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.1 ?? 0) { best = (screen, area) }
        }
        if let best { return best.0 }
        let center = CGPoint(x: appKit.midX, y: appKit.midY)
        return screens.first { NSMouseInRect(center, $0.frame, false) } ?? main
    }
}

/// Small cache so cells don't hit NSRunningApplication on every redraw.
@MainActor
enum AppIconCache {
    private static var byPID: [pid_t: NSImage] = [:]
    private static var byBundle: [String: NSImage] = [:]

    static func icon(pid: pid_t) -> NSImage? {
        if let cached = byPID[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        if let icon { byPID[pid] = icon }
        return icon
    }

    static func icon(bundleID: String) -> NSImage? {
        if let cached = byBundle[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        byBundle[bundleID] = icon
        return icon
    }

    static func forget(pid: pid_t) { byPID[pid] = nil }
}

/// Template icon for the menu bar: a window with a thumbnail strip on the left.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            NSColor.black.set()
            let outline = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: 16.5, height: 12.5), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5
            outline.stroke()
            for i in 0..<3 {
                NSBezierPath(roundedRect: NSRect(x: 3, y: 2.8 + CGFloat(i) * 3.1, width: 4, height: 2.2), xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "1" }
}

extension NSWindow {
    /// `center()` uses the key screen, which may be another display; use the one the user is looking at.
    func centerOnMouseScreen() {
        guard let screen = NSScreen.withMouse else { center(); return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + visible.height * 0.08))
    }
}
