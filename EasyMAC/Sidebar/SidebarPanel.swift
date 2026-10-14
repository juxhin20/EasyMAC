import AppKit
import Observation
import SwiftUI

/// The strip itself.
final class SidebarPanel: FloatingPanel {
    init() {
        super.init(level: .floating)
    }
}

/// Shared geometry so the controller can size the panel exactly like SwiftUI lays it out.
struct SidebarMetrics: Equatable {
    var thumbWidth: CGFloat
    var showTitles: Bool
    var showFooter = true
    var spaceCount = 0
    var fileRowCount = 0
    var showWorkspaces = true

    static let fileRow: CGFloat = 18

    static let space: CGFloat = 16

    static let padding: CGFloat = 8
    static let spacing: CGFloat = 8
    static let chip: CGFloat = 22
    static let chipSpacing: CGFloat = 6
    static let headerTop: CGFloat = 10
    static let dividerBlock: CGFloat = 13
    static let footer: CGFloat = 26
    static let cornerRadius: CGFloat = 14

    var panelWidth: CGFloat { thumbWidth + Self.padding * 2 }
    var thumbHeight: CGFloat { (thumbWidth * 0.66).rounded() }
    var cellHeight: CGFloat { thumbHeight + (showTitles ? 15 : 0) }
    var chipsPerRow: Int { max(1, Int((thumbWidth + Self.chipSpacing) / (Self.chip + Self.chipSpacing))) }

    func chipsHeight(chipCount: Int) -> CGFloat {
        let rows = CGFloat((chipCount + 1 + chipsPerRow - 1) / chipsPerRow) // +1 for the "+" chip
        return rows * Self.chip + (rows - 1) * Self.chipSpacing
    }

    func cellsHeight(windowCount: Int) -> CGFloat {
        let n = CGFloat(max(windowCount, 1))
        return n * cellHeight + (n - 1) * Self.spacing + Self.spacing // scroll content padding
    }

    /// Desktop switcher row(s) above the footer; 0 when hidden.
    var spacesHeight: CGFloat {
        guard spaceCount > 0 else { return 0 }
        let rows = CGFloat((spaceCount + chipsPerRow - 1) / chipsPerRow)
        return rows * Self.space + (rows - 1) * Self.chipSpacing + Self.dividerBlock
    }

    /// Tray + pinned folder rows; 0 when hidden.
    var filesHeight: CGFloat {
        guard fileRowCount > 0 else { return 0 }
        let n = CGFloat(fileRowCount)
        return n * Self.fileRow + (n - 1) * 2 + Self.dividerBlock
    }

    func contentHeight(windowCount: Int, chipCount: Int) -> CGFloat {
        filesHeight + spacesHeight + Self.headerTop + (showWorkspaces ? chipsHeight(chipCount: chipCount) + Self.dividerBlock : 0) + cellsHeight(windowCount: windowCount) + (showFooter ? Self.footer : Self.padding)
    }
}

@MainActor @Observable
final class SidebarModel {
    var hoveredID: CGWindowID?
    /// Highlighted by the keyboard switcher.
    var selectionID: CGWindowID?
    var dropTargetWorkspace: UUID?
    var isDragging = false

    @ObservationIgnored var cellFrames: [CGWindowID: CGRect] = [:]
    @ObservationIgnored var mouse: CGPoint?
    @ObservationIgnored var onHoverChange: ((CGWindowID?) -> Void)?

    func mouseMoved(_ point: CGPoint?) {
        mouse = point
        updateHover()
    }

    func updateHover() {
        let id = mouse.flatMap { point in cellFrames.first { $0.value.contains(point) }?.key }
        if id != hoveredID {
            hoveredID = id
            onHoverChange?(id)
        }
    }

    /// Windows to show: everything pinned plus the most relevant others, up to the max count.
    static func displayed(_ windows: [WindowInfo], max: Int) -> [WindowInfo] {
        let pinned = windows.filter(\.isPinned)
        let rest = windows.filter { !$0.isPinned }
        return pinned + rest.prefix(Swift.max(0, max - pinned.count))
    }
}

struct CellFramesKey: PreferenceKey {
    static let defaultValue: [CGWindowID: CGRect] = [:]
    static func reduce(value: inout [CGWindowID: CGRect], nextValue: () -> [CGWindowID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
