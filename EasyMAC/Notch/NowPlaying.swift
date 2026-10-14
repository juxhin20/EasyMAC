import AppKit
import Observation

/// What's playing, for the notch.
///
/// - Spotify and Apple Music broadcast every play/pause/track change as distributed notifications —
///   no permission needed. Spotify artwork comes from its public oEmbed endpoint.
/// - On launch, Spotify's current state is read once via AppleScript (asks for Automation permission
///   the first time).
/// - Anything else (browsers, YouTube…) via the system MediaRemote framework when macOS allows it
///   (macOS 15.4+ restricts it for most apps; then only Spotify/Music show).
/// Controls send the standard media keys, so they act on whatever is playing.
@MainActor @Observable
final class NowPlaying {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    private(set) var appBundleID: String?

    var hasTrack: Bool { !title.isEmpty }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored private var mediaRemoteTimer: Timer?
    @ObservationIgnored private var lastAppSource: Date = .distantPast

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.applySpotify(info) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.applyMusic(info) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let self, bundle == self.appBundleID { self.clear() }
            }
        })
        readSpotifyOnce()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMediaRemote() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        mediaRemoteTimer = timer
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        mediaRemoteTimer?.invalidate()
        mediaRemoteTimer = nil
        clear()
    }

    private func clear() {
        title = ""
        artist = ""
        isPlaying = false
        artwork = nil
        appBundleID = nil
    }

    // MARK: - Spotify / Music

    private func applySpotify(_ info: [AnyHashable: Any]) {
        lastAppSource = Date()
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? artist
        isPlaying = state == "Playing"
        appBundleID = "com.spotify.client"
        if let trackID = info["Track ID"] as? String { loadSpotifyArtwork(trackID) }
    }

    private func applyMusic(_ info: [AnyHashable: Any]) {
        lastAppSource = Date()
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? artist
        isPlaying = state == "Playing"
        appBundleID = "com.apple.Music"
        artwork = AppIconCache.icon(bundleID: "com.apple.Music")
    }

    private func loadSpotifyArtwork(_ trackID: String) {
        if let cached = artworkCache[trackID] { artwork = cached; return }
        artwork = AppIconCache.icon(bundleID: "com.spotify.client")
        let trackURL = trackID.hasPrefix("spotify:track:")
            ? "https://open.spotify.com/track/" + trackID.dropFirst("spotify:track:".count)
            : trackID
        guard var components = URLComponents(string: "https://open.spotify.com/oembed") else { return }
        components.queryItems = [URLQueryItem(name: "url", value: trackURL)]
        guard let url = components.url else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumb = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)),
                  let (imageData, _) = try? await URLSession.shared.data(from: thumb),
                  let image = NSImage(data: imageData) else { return }
            artworkCache[trackID] = image
            if appBundleID == "com.spotify.client" { artwork = image }
        }
    }

    /// Spotify only announces changes; read the current track once so the notch is right at launch.
    private func readSpotifyOnce() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else { return }
        let script = """
        tell application "Spotify"
            if player state is stopped then return ""
            return (player state as string) & "\\n" & (name of current track) & "\\n" & (artist of current track) & "\\n" & (id of current track)
        end tell
        """
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? ""
            let parts = result.components(separatedBy: "\n")
            guard parts.count == 4 else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.title.isEmpty else { return }
                    self.applySpotify(["Player State": parts[0].capitalized, "Name": parts[1], "Artist": parts[2], "Track ID": parts[3]])
                }
            }
        }
    }

    // MARK: - MediaRemote (anything else, when macOS allows it)

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    nonisolated(unsafe) private static let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    private static let getInfo: GetInfoFn? = mediaRemote.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingInfo") }.map { unsafeBitCast($0, to: GetInfoFn.self) }

    private func pollMediaRemote() {
        // Spotify/Music notifications are authoritative while they're active.
        guard Date().timeIntervalSince(lastAppSource) > 5 || appBundleID == nil, let getInfo = Self.getInfo else { return }
        getInfo(DispatchQueue.main) { [weak self] info in
            let title = info?["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info?["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            let art = (info?["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.appBundleID == nil || self.appBundleID == "mediaremote" else { return }
                    if title.isEmpty {
                        if self.appBundleID == "mediaremote" { self.clear() }
                        return
                    }
                    self.title = title
                    self.artist = artist
                    self.isPlaying = rate > 0
                    self.artwork = art
                    self.appBundleID = "mediaremote"
                }
            }
        }
    }

    // MARK: - Controls (standard media keys → act on whatever is playing)

    static func playPause() { postMediaKey(16) }
    static func next() { postMediaKey(17) }
    static func previous() { postMediaKey(18) }

    private static func postMediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
