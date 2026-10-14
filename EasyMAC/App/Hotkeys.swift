import AppKit
import KeyboardShortcuts

// Defaults follow the spec. Option-only combos work because EasyMAC is not sandboxed
// (macOS 15 restricts them for sandboxed apps only). All are rebindable in Settings → Hotkeys.
extension KeyboardShortcuts.Name {
    static let toggleSidebar = Self("toggleSidebar", initial: .init(.s, modifiers: [.option, .shift]))
    static let saveWorkspace = Self("saveWorkspace", initial: .init(.w, modifiers: [.option, .shift]))
    static let windowSwitcher = Self("windowSwitcher", initial: .init(.tab, modifiers: [.option]))
    static let clipboardHistory = Self("clipboardHistory", initial: .init(.v, modifiers: [.option, .shift]))

    static let snapLeft = Self("snapLeft", initial: .init(.leftArrow, modifiers: [.control, .option]))
    static let snapRight = Self("snapRight", initial: .init(.rightArrow, modifiers: [.control, .option]))
    static let snapTop = Self("snapTop", initial: .init(.upArrow, modifiers: [.control, .option]))
    static let snapBottom = Self("snapBottom", initial: .init(.downArrow, modifiers: [.control, .option]))
    static let snapMaximize = Self("snapMaximize", initial: .init(.return, modifiers: [.control, .option]))
    static let snapCenter = Self("snapCenter", initial: .init(.c, modifiers: [.control, .option]))
    static let snapRestore = Self("snapRestore", initial: .init(.delete, modifiers: [.control, .option]))
    static let applyLayout = Self("applyLayout", initial: .init(.l, modifiers: [.control, .option]))

    static let restoreWorkspace1 = Self("restoreWorkspace1", initial: .init(.one, modifiers: [.option]))
    static let restoreWorkspace2 = Self("restoreWorkspace2", initial: .init(.two, modifiers: [.option]))
    static let restoreWorkspace3 = Self("restoreWorkspace3", initial: .init(.three, modifiers: [.option]))
    static let restoreWorkspace4 = Self("restoreWorkspace4", initial: .init(.four, modifiers: [.option]))
    static let restoreWorkspace5 = Self("restoreWorkspace5", initial: .init(.five, modifiers: [.option]))
    static let restoreWorkspace6 = Self("restoreWorkspace6", initial: .init(.six, modifiers: [.option]))
    static let restoreWorkspace7 = Self("restoreWorkspace7", initial: .init(.seven, modifiers: [.option]))
    static let restoreWorkspace8 = Self("restoreWorkspace8", initial: .init(.eight, modifiers: [.option]))
    static let restoreWorkspace9 = Self("restoreWorkspace9", initial: .init(.nine, modifiers: [.option]))

    static let workspaceSlots: [KeyboardShortcuts.Name] = [
        .restoreWorkspace1, .restoreWorkspace2, .restoreWorkspace3, .restoreWorkspace4, .restoreWorkspace5,
        .restoreWorkspace6, .restoreWorkspace7, .restoreWorkspace8, .restoreWorkspace9,
    ]

    static let snapNames: [(KeyboardShortcuts.Name, String)] = [
        (.snapLeft, "Left half (repeat: ⅔ → ⅓)"),
        (.snapRight, "Right half (repeat: ⅔ → ⅓)"),
        (.snapTop, "Top half"),
        (.snapBottom, "Bottom half"),
        (.snapMaximize, "Maximize"),
        (.snapCenter, "Center"),
        (.snapRestore, "Restore previous size"),
        (.applyLayout, "Tile visible windows"),
    ]
}

@MainActor
enum HotkeyController {
    static func register(_ state: AppState) {
        KeyboardShortcuts.onKeyDown(for: .toggleSidebar) { state.toggleSidebar() }
        KeyboardShortcuts.onKeyDown(for: .saveWorkspace) { state.saveCurrentAsWorkspace() }
        KeyboardShortcuts.onKeyDown(for: .windowSwitcher) { state.switcher.advance() }
        KeyboardShortcuts.onKeyDown(for: .clipboardHistory) { if state.settings.clipboardEnabled { state.clipboardPanel.toggle() } }

        let snaps: [(KeyboardShortcuts.Name, SnapAction)] = [
            (.snapLeft, .leftHalf), (.snapRight, .rightHalf), (.snapTop, .topHalf),
            (.snapBottom, .bottomHalf), (.snapMaximize, .maximize), (.snapCenter, .center),
        ]
        for (name, action) in snaps {
            KeyboardShortcuts.onKeyDown(for: name) { Task { await state.snap.snapFocused(action) } }
        }
        KeyboardShortcuts.onKeyDown(for: .snapRestore) { Task { await state.snap.restoreFocused() } }
        KeyboardShortcuts.onKeyDown(for: .applyLayout) { Task { await state.snap.tileVisible(state.settings.quickTilePreset) } }

        for (index, name) in KeyboardShortcuts.Name.workspaceSlots.enumerated() {
            KeyboardShortcuts.onKeyDown(for: name) { state.restoreWorkspace(hotkey: index + 1) }
        }
    }

    static func workspaceShortcutText(_ slot: Int) -> String? {
        guard (1...9).contains(slot) else { return nil }
        return shortcutText(KeyboardShortcuts.Name.workspaceSlots[slot - 1])
    }

    static func shortcutText(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name)?.description
    }
}
