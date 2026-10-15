import AppKit
import Observation
import ServiceManagement

enum SidebarEdge: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

enum SidebarDisplay: String, CaseIterable, Identifiable {
    case main, mouse, specific
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: "Main display"
        case .mouse: "Display with mouse"
        case .specific: "Specific display"
        }
    }
}

enum WindowScope: String, CaseIterable, Identifiable {
    case allDisplays, sidebarDisplay
    var id: String { rawValue }
    var title: String { self == .allDisplays ? "All displays" : "Sidebar's display only" }
}

enum ThumbnailSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var width: CGFloat {
        switch self {
        case .small: 64
        case .medium: 88
        case .large: 120
        }
    }
    var title: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }
}

enum WindowOrdering: String, CaseIterable, Identifiable {
    case recent, stable
    var id: String { rawValue }
    var title: String { self == .recent ? "Recently used" : "Order opened" }
}

enum PanelStyle: String, CaseIterable, Identifiable {
    case glass, frosted, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .frosted: "Frosted"
        case .dark: "Dark"
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case appAlbania, system
    var id: String { rawValue }
    var title: String { self == .appAlbania ? "AppAlbania red" : "System accent" }
    var nsColor: NSColor { self == .appAlbania ? Brand.nsRed : .controlAccentColor }
}

enum RadialTrigger: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fn: "fn / 🌐 (Globe)"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        }
    }
    var keyCode: UInt16 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: .function
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        }
    }
}

enum RadialCenterAction: String, CaseIterable, Identifiable {
    case maximize, almostMaximize, center, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .maximize: "Maximize"
        case .almostMaximize: "Almost maximize"
        case .center: "Center"
        case .none: "Do nothing"
        }
    }
    var snapAction: SnapAction? {
        switch self {
        case .maximize: .maximize
        case .almostMaximize: .almostMaximize
        case .center: .center
        case .none: nil
        }
    }
}

enum RadialTarget: String, CaseIterable, Identifiable {
    case focused, underCursor
    var id: String { rawValue }
    var title: String { self == .focused ? "Focused window" : "Window under the cursor" }
}

/// User preferences, persisted in `UserDefaults` (same storage `@AppStorage` uses).
/// A plain `@Observable` class so AppKit controllers and SwiftUI views share one source of truth.
@MainActor @Observable
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("EasyMACSettingsDidChange")

    @ObservationIgnored private let defaults = UserDefaults.standard

    // General
    var hasCompletedOnboarding: Bool { didSet { store(hasCompletedOnboarding, "hasCompletedOnboarding") } }
    var showDockIcon: Bool { didSet { store(showDockIcon, "showDockIcon") } }
    var showSettingsOnLaunch: Bool { didSet { store(showSettingsOnLaunch, "showSettingsOnLaunch") } }
    var sidebarEnabled: Bool { didSet { store(sidebarEnabled, "sidebarEnabled") } }
    var sidebarEdge: SidebarEdge { didSet { store(sidebarEdge.rawValue, "sidebarEdge") } }
    var sidebarDisplay: SidebarDisplay { didSet { store(sidebarDisplay.rawValue, "sidebarDisplay") } }
    var specificDisplayID: String { didSet { store(specificDisplayID, "specificDisplayID") } }
    var autoHide: Bool { didSet { store(autoHide, "autoHide") } }
    var autoHideInFullscreen: Bool { didSet { store(autoHideInFullscreen, "autoHideInFullscreen") } }
    var windowScope: WindowScope { didSet { store(windowScope.rawValue, "windowScope") } }
    var hideOthersOnRestore: Bool { didSet { store(hideOthersOnRestore, "hideOthersOnRestore") } }

    // Appearance
    var thumbnailSize: ThumbnailSize { didSet { store(thumbnailSize.rawValue, "thumbnailSize") } }
    var maxVisible: Int { didSet { store(maxVisible, "maxVisible") } }
    var showTitles: Bool { didSet { store(showTitles, "showTitles") } }
    var refreshInterval: Double { didSet { store(refreshInterval, "refreshInterval") } }
    var hoverPreview: Bool { didSet { store(hoverPreview, "hoverPreview") } }
    var hoverDelay: Double { didSet { store(hoverDelay, "hoverDelay") } }
    var ordering: WindowOrdering { didSet { store(ordering.rawValue, "ordering") } }
    var panelStyle: PanelStyle { didSet { store(panelStyle.rawValue, "panelStyle") } }
    var sidebarAccent: AccentChoice { didSet { store(sidebarAccent.rawValue, "sidebarAccent") } }
    var showThumbnails: Bool { didSet { store(showThumbnails, "showThumbnails") } }
    var showFooter: Bool { didSet { store(showFooter, "showFooter") } }
    var showSpaces: Bool { didSet { store(showSpaces, "showSpaces") } }
    var showFiles: Bool { didSet { store(showFiles, "showFiles") } }
    var showAwakeIcon: Bool { didSet { store(showAwakeIcon, "showAwakeIcon") } }
    var clipboardEnabled: Bool { didSet { store(clipboardEnabled, "clipboardEnabled") } }
    var clipboardLimit: Int { didSet { store(clipboardLimit, "clipboardLimit") } }
    var showClipboardIcon: Bool { didSet { store(showClipboardIcon, "showClipboardIcon") } }
    var clipboardPasteDirectly: Bool { didSet { store(clipboardPasteDirectly, "clipboardPasteDirectly") } }
    var showMenuBarIcon: Bool { didSet { store(showMenuBarIcon, "showMenuBarIcon") } }
    var notchHUD: Bool { didSet { store(notchHUD, "notchHUD") } }
    var volumeStepPercent: Int { didSet { store(volumeStepPercent, "volumeStepPercent") } }
    var brightnessStepPercent: Int { didSet { store(brightnessStepPercent, "brightnessStepPercent") } }
    var minBrightnessPercent: Int { didSet { store(minBrightnessPercent, "minBrightnessPercent") } }
    var brightnessFollowsPointer: Bool { didSet { store(brightnessFollowsPointer, "brightnessFollowsPointer") } }
    var notchAirDrop: Bool { didSet { store(notchAirDrop, "notchAirDrop") } }
    var notchTray: Bool { didSet { store(notchTray, "notchTray") } }
    var notchAwakeIndicator: Bool { didSet { store(notchAwakeIndicator, "notchAwakeIndicator") } }
    var awakeMode: AwakeMode { didSet { store(awakeMode.rawValue, "awakeMode") } }
    var awakeLastDuration: Double { didSet { store(awakeLastDuration, "awakeLastDuration") } }
    var mouseScrollDirection: MouseScrollDirection { didSet { store(mouseScrollDirection.rawValue, "mouseScrollDirection") } }
    var reverseMouseHorizontal: Bool { didSet { store(reverseMouseHorizontal, "reverseMouseHorizontal") } }
    var sidebarCollapsed: Bool { didSet { store(sidebarCollapsed, "sidebarCollapsed") } }
    var showCollapseArrow: Bool { didSet { store(showCollapseArrow, "showCollapseArrow") } }
    var stripIconsOnly: Bool { didSet { store(stripIconsOnly, "stripIconsOnly") } }
    var stripShowTray: Bool { didSet { store(stripShowTray, "stripShowTray") } }
    var stripShowFolders: Bool { didSet { store(stripShowFolders, "stripShowFolders") } }
    var stripShowWorkspaces: Bool { didSet { store(stripShowWorkspaces, "stripShowWorkspaces") } }
    var showFilesIcon: Bool { didSet { store(showFilesIcon, "showFilesIcon") } }
    var clipboardRetentionDays: Int { didSet { store(clipboardRetentionDays, "clipboardRetentionDays") } }
    var showTray: Bool { didSet { store(showTray, "showTray") } }
    var shelfSort: ShelfSort { didSet { store(shelfSort.rawValue, "shelfSort") } }
    var shelfAlwaysOnTop: Bool { didSet { store(shelfAlwaysOnTop, "shelfAlwaysOnTop") } }

    // Layouts
    var layoutGap: Double { didSet { store(layoutGap, "layoutGap") } }
    var quickTilePreset: LayoutPreset { didSet { store(quickTilePreset.rawValue, "quickTilePreset") } }
    var cycleSnapSizes: Bool { didSet { store(cycleSnapSizes, "cycleSnapSizes") } }
    var reserveSidebarSpace: Bool { didSet { store(reserveSidebarSpace, "reserveSidebarSpace") } }

    // Snap wheel
    var radialEnabled: Bool { didSet { store(radialEnabled, "radialEnabled") } }
    var radialTrigger: RadialTrigger { didSet { store(radialTrigger.rawValue, "radialTrigger") } }
    var radialHoldDelay: Double { didSet { store(radialHoldDelay, "radialHoldDelay") } }
    var radialCenterAction: RadialCenterAction { didSet { store(radialCenterAction.rawValue, "radialCenterAction") } }
    var radialTarget: RadialTarget { didSet { store(radialTarget.rawValue, "radialTarget") } }
    var radialShowPreview: Bool { didSet { store(radialShowPreview, "radialShowPreview") } }
    var radialHaptics: Bool { didSet { store(radialHaptics, "radialHaptics") } }
    var radialAccent: AccentChoice { didSet { store(radialAccent.rawValue, "radialAccent") } }

    // Excluded apps
    var excludedBundleIDs: [String] { didSet { store(excludedBundleIDs, "excludedBundleIDs") } }

    static let defaultExcluded = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
    ]

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            d.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }

        hasCompletedOnboarding = bool("hasCompletedOnboarding", false)
        showDockIcon = bool("showDockIcon", false)
        showSettingsOnLaunch = bool("showSettingsOnLaunch", true)
        sidebarEnabled = bool("sidebarEnabled", true)
        sidebarEdge = choice("sidebarEdge", SidebarEdge.left)
        sidebarDisplay = choice("sidebarDisplay", SidebarDisplay.main)
        specificDisplayID = d.string(forKey: "specificDisplayID") ?? ""
        autoHide = bool("autoHide", false)
        autoHideInFullscreen = bool("autoHideInFullscreen", true)
        windowScope = choice("windowScope", WindowScope.allDisplays)
        hideOthersOnRestore = bool("hideOthersOnRestore", false)

        thumbnailSize = choice("thumbnailSize", ThumbnailSize.medium)
        maxVisible = int("maxVisible", 12)
        showTitles = bool("showTitles", false)
        refreshInterval = double("refreshInterval", 3)
        hoverPreview = bool("hoverPreview", true)
        hoverDelay = double("hoverDelay", 0.3)
        ordering = choice("ordering", WindowOrdering.recent)
        panelStyle = choice("panelStyle", PanelStyle.glass)
        sidebarAccent = choice("sidebarAccent", AccentChoice.appAlbania)
        showThumbnails = bool("showThumbnails", true)
        showFooter = bool("showFooter", true)
        showSpaces = bool("showSpaces", false)
        showFiles = bool("showFiles", true)
        showAwakeIcon = bool("showAwakeIcon", true)
        clipboardEnabled = bool("clipboardEnabled", true)
        clipboardLimit = int("clipboardLimit", 60)
        clipboardPasteDirectly = bool("clipboardPasteDirectly", true)
        showClipboardIcon = bool("showClipboardIcon", true)
        notchHUD = bool("notchHUD", true)
        showMenuBarIcon = bool("showMenuBarIcon", true)
        notchAwakeIndicator = bool("notchAwakeIndicator", true)
        notchTray = bool("notchTray", true)
        notchAirDrop = bool("notchAirDrop", true)
        volumeStepPercent = int("volumeStepPercent", 6)
        brightnessStepPercent = int("brightnessStepPercent", 6)
        minBrightnessPercent = int("minBrightnessPercent", 10)
        brightnessFollowsPointer = bool("brightnessFollowsPointer", true)
        awakeMode = choice("awakeMode", AwakeMode.display)
        awakeLastDuration = double("awakeLastDuration", 0)
        showTray = bool("showTray", true)
        showFilesIcon = bool("showFilesIcon", true)
        stripShowTray = bool("stripShowTray", true)
        stripIconsOnly = bool("stripIconsOnly", false)
        sidebarCollapsed = bool("sidebarCollapsed", false)
        showCollapseArrow = bool("showCollapseArrow", true)
        stripShowFolders = bool("stripShowFolders", true)
        stripShowWorkspaces = bool("stripShowWorkspaces", true)
        mouseScrollDirection = d.string(forKey: "mouseScrollDirection").flatMap(MouseScrollDirection.init(rawValue:))
            ?? (bool("reverseMouseScroll", false) ? .standard : .system)
        reverseMouseHorizontal = bool("reverseMouseHorizontal", false)
        clipboardRetentionDays = int("clipboardRetentionDays", 0)
        shelfSort = choice("shelfSort", ShelfSort.newest)
        shelfAlwaysOnTop = bool("shelfAlwaysOnTop", true)

        layoutGap = double("layoutGap", 8)
        quickTilePreset = choice("quickTilePreset", LayoutPreset.halves)
        cycleSnapSizes = bool("cycleSnapSizes", true)
        reserveSidebarSpace = bool("reserveSidebarSpace", true)

        radialEnabled = bool("radialEnabled", true)
        radialTrigger = choice("radialTrigger", RadialTrigger.fn)
        radialHoldDelay = double("radialHoldDelay", 0.15)
        radialCenterAction = choice("radialCenterAction", RadialCenterAction.maximize)
        radialTarget = choice("radialTarget", RadialTarget.focused)
        radialShowPreview = bool("radialShowPreview", true)
        radialHaptics = bool("radialHaptics", true)
        radialAccent = choice("radialAccent", AccentChoice.system)

        excludedBundleIDs = d.stringArray(forKey: "excludedBundleIDs") ?? Settings.defaultExcluded
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: key)
    }
}

/// Launch at login via `SMAppService.mainApp` (macOS 13+).
@MainActor @Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var isEnabled = false
    private(set) var needsApproval = false
    private(set) var lastError: String?

    private init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Turns auto-start on the very first time the app runs, so EasyMAC "just works" after a reboot.
    func enableOnFirstRun() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { set(true) }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
