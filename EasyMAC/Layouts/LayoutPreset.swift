import Foundation

/// Multi-window tiling presets.
enum LayoutPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case halves
    case sixtyForty
    case thirds
    case mainStack
    case grid
    case maximize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .halves: "Halves 50/50"
        case .sixtyForty: "60 / 40"
        case .thirds: "Thirds"
        case .mainStack: "Main + Stack"
        case .grid: "Grid"
        case .maximize: "Maximize All"
        }
    }

    var symbol: String {
        switch self {
        case .halves: "rectangle.split.2x1"
        case .sixtyForty: "rectangle.leadinghalf.inset.filled"
        case .thirds: "rectangle.split.3x1"
        case .mainStack: "rectangle.righthalf.inset.filled"
        case .grid: "square.grid.2x2"
        case .maximize: "macwindow"
        }
    }
}

/// Single-window snap targets (hotkeys and the snap wheel).
enum SnapAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .center: "Center"
        }
    }
}

/// Direction picked on the snap wheel. Corners map to quarters, edges to halves.
enum RadialDirection: String, CaseIterable, Sendable {
    case center
    case right, topRight, top, topLeft, left, bottomLeft, bottom, bottomRight

    /// Angle in degrees, counter-clockwise from +x (maths convention, y up). `nil` for center.
    var angle: Double? {
        switch self {
        case .center: nil
        case .right: 0
        case .topRight: 45
        case .top: 90
        case .topLeft: 135
        case .left: 180
        case .bottomLeft: 225
        case .bottom: 270
        case .bottomRight: 315
        }
    }

    var snapAction: SnapAction? {
        switch self {
        case .center: nil
        case .right: .rightHalf
        case .topRight: .topRight
        case .top: .topHalf
        case .topLeft: .topLeft
        case .left: .leftHalf
        case .bottomLeft: .bottomLeft
        case .bottom: .bottomHalf
        case .bottomRight: .bottomRight
        }
    }
}
