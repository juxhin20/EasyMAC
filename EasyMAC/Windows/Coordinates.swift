import CoreGraphics

/// Conversions between the two coordinate systems macOS uses for windows.
///
/// - **AX / CoreGraphics** (`CGWindowList`, `AXUIElement`): origin at the top-left of the
///   primary display, y grows downwards.
/// - **AppKit** (`NSScreen`, `NSWindow`): origin at the bottom-left of the primary display,
///   y grows upwards.
///
/// The transform is its own inverse, so the same formula converts both ways.
enum Coordinates {
    static func axToAppKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitToAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func appKitToAX(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func axToAppKit(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Expresses `frame` as fractions (0...1) of `container`. Both rects must share a coordinate system.
    static func relative(_ frame: CGRect, in container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        let rel = CGRect(
            x: (frame.minX - container.minX) / container.width,
            y: (frame.minY - container.minY) / container.height,
            width: frame.width / container.width,
            height: frame.height / container.height
        )
        return clampUnit(rel)
    }

    /// Inverse of `relative(_:in:)`.
    static func absolute(_ relative: CGRect, in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + relative.minX * container.width,
            y: container.minY + relative.minY * container.height,
            width: relative.width * container.width,
            height: relative.height * container.height
        ).integral
    }

    /// Keeps a relative rect inside the unit square so windows never restore off-screen.
    static func clampUnit(_ rect: CGRect) -> CGRect {
        let w = min(max(rect.width, 0.05), 1)
        let h = min(max(rect.height, 0.05), 1)
        let x = min(max(rect.minX, 0), 1 - w)
        let y = min(max(rect.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
