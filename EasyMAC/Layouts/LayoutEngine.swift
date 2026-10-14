import CoreGraphics
import Foundation

/// Pure frame math. All rects use AX coordinates (top-left origin, y grows down),
/// so "top" means smaller y. Callers convert `NSScreen.visibleFrame` first.
enum LayoutEngine {

    // MARK: - Multi-window presets

    static func frames(for preset: LayoutPreset, count: Int, in area: CGRect, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0, area.width > 0, area.height > 0 else { return [] }
        let gap = max(0, gap)
        let inner = area.insetBy(dx: gap, dy: gap)
        guard count > 1 else { return [inner.integral] }

        switch preset {
        case .maximize:
            return Array(repeating: inner.integral, count: count)
        case .halves:
            return columns(inner, ratios: [0.5, 0.5], count: count, gap: gap)
        case .sixtyForty:
            return columns(inner, ratios: [0.6, 0.4], count: count, gap: gap)
        case .thirds:
            return columns(inner, ratios: [1, 1, 1], count: count, gap: gap)
        case .mainStack:
            let cols = split(inner, ratios: [0.6, 0.4], horizontal: true, gap: gap)
            let stack = split(cols[1], ratios: Array(repeating: 1, count: count - 1), horizontal: false, gap: gap)
            return ([cols[0]] + stack).map(\.integral)
        case .grid:
            let cols = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(cols)))
            let rowRects = split(inner, ratios: Array(repeating: 1, count: rows), horizontal: false, gap: gap)
            var result: [CGRect] = []
            for (r, rowRect) in rowRects.enumerated() {
                let itemsInRow = min(cols, count - r * cols)
                result += split(rowRect, ratios: Array(repeating: 1, count: itemsInRow), horizontal: true, gap: gap)
            }
            return result.map(\.integral)
        }
    }

    /// Splits into columns; extra windows stack inside the later columns so the first
    /// (main) column keeps the fewest windows.
    private static func columns(_ rect: CGRect, ratios: [CGFloat], count: Int, gap: CGFloat) -> [CGRect] {
        let columnCount = min(ratios.count, count)
        let cols = split(rect, ratios: Array(ratios.prefix(columnCount)), horizontal: true, gap: gap)
        let base = count / columnCount
        let extra = count % columnCount
        var result: [CGRect] = []
        for (i, col) in cols.enumerated() {
            let n = base + (i >= columnCount - extra ? 1 : 0)
            result += split(col, ratios: Array(repeating: 1, count: n), horizontal: false, gap: gap)
        }
        return result.map(\.integral)
    }

    /// Splits `rect` along one axis proportionally to `ratios`, leaving `gap` between parts.
    static func split(_ rect: CGRect, ratios: [CGFloat], horizontal: Bool, gap: CGFloat) -> [CGRect] {
        guard !ratios.isEmpty else { return [] }
        let total = ratios.reduce(0, +)
        guard total > 0 else { return [] }
        let length = (horizontal ? rect.width : rect.height) - gap * CGFloat(ratios.count - 1)
        var cursor = horizontal ? rect.minX : rect.minY
        return ratios.map { ratio in
            let size = length * ratio / total
            defer { cursor += size + gap }
            return horizontal
                ? CGRect(x: cursor, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: cursor, width: rect.width, height: size)
        }
    }

    // MARK: - Single-window snapping

    static func snap(_ action: SnapAction, in area: CGRect, gap: CGFloat = 8, current: CGRect? = nil) -> CGRect {
        let gap = max(0, gap)
        let r = area.insetBy(dx: gap, dy: gap)
        let halfW = (r.width - gap) / 2
        let halfH = (r.height - gap) / 2
        let thirdW = (r.width - gap * 2) / 3
        let twoThirdsW = thirdW * 2 + gap

        let frame: CGRect
        switch action {
        case .leftHalf: frame = CGRect(x: r.minX, y: r.minY, width: halfW, height: r.height)
        case .rightHalf: frame = CGRect(x: r.maxX - halfW, y: r.minY, width: halfW, height: r.height)
        case .topHalf: frame = CGRect(x: r.minX, y: r.minY, width: r.width, height: halfH)
        case .bottomHalf: frame = CGRect(x: r.minX, y: r.maxY - halfH, width: r.width, height: halfH)
        case .topLeft: frame = CGRect(x: r.minX, y: r.minY, width: halfW, height: halfH)
        case .topRight: frame = CGRect(x: r.maxX - halfW, y: r.minY, width: halfW, height: halfH)
        case .bottomLeft: frame = CGRect(x: r.minX, y: r.maxY - halfH, width: halfW, height: halfH)
        case .bottomRight: frame = CGRect(x: r.maxX - halfW, y: r.maxY - halfH, width: halfW, height: halfH)
        case .leftThird: frame = CGRect(x: r.minX, y: r.minY, width: thirdW, height: r.height)
        case .centerThird: frame = CGRect(x: r.minX + thirdW + gap, y: r.minY, width: thirdW, height: r.height)
        case .rightThird: frame = CGRect(x: r.maxX - thirdW, y: r.minY, width: thirdW, height: r.height)
        case .leftTwoThirds: frame = CGRect(x: r.minX, y: r.minY, width: twoThirdsW, height: r.height)
        case .rightTwoThirds: frame = CGRect(x: r.maxX - twoThirdsW, y: r.minY, width: twoThirdsW, height: r.height)
        case .maximize: frame = r
        case .almostMaximize:
            let w = area.width * 0.9, h = area.height * 0.9
            frame = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        case .center:
            let size = current?.size ?? CGSize(width: area.width * 0.6, height: area.height * 0.7)
            let w = min(size.width, r.width), h = min(size.height, r.height)
            frame = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        }
        return frame.integral
    }

    /// Rectangle-style cycling: pressing "left" repeatedly goes ½ → ⅔ → ⅓ → ½.
    static func cycled(_ action: SnapAction, current: CGRect?, in area: CGRect, gap: CGFloat = 8) -> SnapAction {
        guard let current else { return action }
        let sequence: [SnapAction]
        switch action {
        case .leftHalf: sequence = [.leftHalf, .leftTwoThirds, .leftThird]
        case .rightHalf: sequence = [.rightHalf, .rightTwoThirds, .rightThird]
        default: return action
        }
        for (i, step) in sequence.enumerated() where Coordinates.approximatelyEqual(snap(step, in: area, gap: gap), current, tolerance: 6) {
            return sequence[(i + 1) % sequence.count]
        }
        return action
    }

    // MARK: - Snap wheel

    /// Maps a mouse offset from the wheel centre to a direction.
    /// `dy` is positive **upwards** (AppKit mouse coordinates).
    static func radialDirection(dx: CGFloat, dy: CGFloat, deadZone: CGFloat = 14) -> RadialDirection {
        guard hypot(dx, dy) > deadZone else { return .center }
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let sector = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        let order: [RadialDirection] = [.right, .topRight, .top, .topLeft, .left, .bottomLeft, .bottom, .bottomRight]
        return order[min(max(sector, 0), order.count - 1)]
    }
}
