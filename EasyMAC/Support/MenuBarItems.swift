import AppKit

/// Creates EasyMAC's extra menu bar icons with a stable, per-icon autosave name.
///
/// macOS remembers ⌘-drag removal and position per autosave name. Unnamed items get "Item-0",
/// "Item-1"… by creation order, which changes between launches — hiding one icon could hide another
/// (or all). With fixed names each icon keeps its own state, and a ⌘-drag removal switches the
/// matching setting off so it can be turned back on in Settings.
@MainActor
enum MenuBarItems {
    private static var observations: [String: NSKeyValueObservation] = [:]
    private static var removalHandlers: [String: () -> Void] = [:]
    private static var createdAt: [String: Date] = [:]
    /// True when macOS hides our icons right after we add them (System Settings → Menu Bar has
    /// EasyMAC switched off). Settings shows a hint instead of fighting the system.
    static var blockedBySystem = false

    static func make(_ name: String, onUserRemoved: @escaping @MainActor () -> Void) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "easymac." + name
        item.behavior = .removalAllowed
        item.isVisible = true // the setting is the source of truth; it's on if we're creating it
        removalHandlers[name] = onUserRemoved
        createdAt[name] = Date()
        observations[name] = item.observe(\.isVisible, options: [.new]) { _, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Hidden instantly = macOS blocking the app, not a ⌘-drag: keep the setting on.
                    if Date().timeIntervalSince(MenuBarItems.createdAt[name] ?? .distantPast) < 3 {
                        MenuBarItems.blockedBySystem = true
                        return
                    }
                    MenuBarItems.removalHandlers[name]?()
                }
            }
        }
        return item
    }

    static func remove(_ item: NSStatusItem, name: String) {
        observations[name] = nil
        removalHandlers[name] = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    /// One-time cleanup of the old index-based keys that caused icons to disappear together.
    static func cleanUpLegacyKeys() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && key.contains(" Item-") {
            defaults.removeObject(forKey: key)
        }
        moveNextToClockOnce()
    }

    /// On a notch Mac, icons that don't fit beside the notch are hidden from the left — and new
    /// icons start at the far left, so ours vanished first whenever an app with a long menu was in
    /// front. Done once: start them right next to the clock (⌘-dragging them elsewhere still sticks).
    private static func moveNextToClockOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "menuBarIconsNextToClock") else { return }
        defaults.set(true, forKey: "menuBarIconsNextToClock")
        // Preferred position = distance from the right edge of the screen.
        for (offset, name) in ["clipboard", "files", "awake"].enumerated() {
            defaults.set(200 + offset * 2, forKey: "NSStatusItem Preferred Position easymac." + name)
        }
    }
}
