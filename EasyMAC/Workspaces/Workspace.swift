import CoreGraphics
import Foundation

struct Workspace: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    /// 1...9 → restore hotkey slot (⌥1…⌥9 by default).
    var hotkeyIndex: Int?
    var items: [WorkspaceItem]
    /// When set, windows are tiled with this preset on restore instead of using saved frames.
    var layout: LayoutPreset?

    init(id: UUID = UUID(), name: String, colorHex: String, hotkeyIndex: Int? = nil,
         items: [WorkspaceItem] = [], layout: LayoutPreset? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.hotkeyIndex = hotkeyIndex
        self.items = items
        self.layout = layout
    }

    var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return String([a, b]).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    static let palette = ["#D22027", "#0A84FF", "#30D158", "#FF9F0A", "#BF5AF2", "#64D2FF", "#FF375F", "#FFD60A", "#8E8E93"]
}

struct WorkspaceItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var bundleID: String
    var appName: String?
    /// Used for launching when the app is not running.
    var appPath: String?
    /// Match hint, e.g. "RentalX" inside a VS Code window title.
    var titleContains: String?
    /// 0...1 fractions of the target screen's visible frame (AX coordinates, top-left origin).
    var relativeFrame: CGRect
    /// Display UUID (preferred) or localized name.
    var screenID: String?
    /// Optional launch arguments. Existing file/folder paths are opened with the app instead.
    var launchArgs: [String]?

    init(id: UUID = UUID(), bundleID: String, appName: String? = nil, appPath: String? = nil,
         titleContains: String? = nil, relativeFrame: CGRect, screenID: String? = nil, launchArgs: [String]? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.appPath = appPath
        self.titleContains = titleContains
        self.relativeFrame = relativeFrame
        self.screenID = screenID
        self.launchArgs = launchArgs
    }
}
