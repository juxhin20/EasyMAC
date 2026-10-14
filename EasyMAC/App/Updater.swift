import AppKit
import Observation
import Sparkle

/// Sparkle auto-updates. Feed: SUFeedURL in Info.plist (appalbania.com/easymac/appcast.xml),
/// updates are EdDSA-signed (SUPublicEDKey). Checks daily by default.
@MainActor @Observable
final class Updater {
    @ObservationIgnored private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloads: Bool {
        get {
            access(keyPath: \.automaticallyDownloads)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloads) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
