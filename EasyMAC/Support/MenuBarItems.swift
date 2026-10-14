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

    static func make(_ name: String, onUserRemoved: @escaping @MainActor () -> Void) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "easymac." + name
        item.behavior = .removalAllowed
        item.isVisible = true // the setting is the source of truth; it's on if we're creating it
        observations[name] = item.observe(\.isVisible, options: [.new]) { _, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onUserRemoved() } }
        }
        return item
    }

    static func remove(_ item: NSStatusItem, name: String) {
        observations[name] = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    /// One-time cleanup of the old index-based keys that caused icons to disappear together.
    static func cleanUpLegacyKeys() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && key.contains(" Item-") {
            defaults.removeObject(forKey: key)
        }
    }
}
