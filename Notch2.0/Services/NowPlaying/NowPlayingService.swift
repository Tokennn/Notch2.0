import AppKit
import Foundation
import MediaPlayer
import Darwin

final class NowPlayingService {
    private let pollQueue = DispatchQueue(label: "notch2.now-playing.poll", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let browserProbe = BrowserNowPlayingBrowserProbe()
    private let desktopPlayerProbe = DesktopPlayerNowPlayingProbe()
    private var onUpdate: ((NowPlayingSnapshot?) -> Void)?
    private var lastSignature: String?
    private var spotifyObserver: NSObjectProtocol?
    private var musicObserver: NSObjectProtocol?
    private var latestSpotifySnapshot: NowPlayingSnapshot?
    private var latestSpotifySnapshotDate: Date?
    private var lastSpotifyStartupProbeAt: Date?
    private let spotifyStartupProbeInterval: TimeInterval = 1.4
    private var spotifyStartupProbeRetryAfter: Date?
    private var webPlayerDetectionEnabled: Bool {
        let defaults = UserDefaults.standard
        if let storedValue = defaults.object(forKey: "EnableWebPlayerDetection") as? Bool {
            return storedValue
        }

        return true
    }
    private var systemNowPlayingCenterEnabled: Bool {
        let defaults = UserDefaults.standard
        if let storedValue = defaults.object(forKey: "EnableSystemNowPlayingCenter") as? Bool {
            return storedValue
        }

        return true
    }

    func start(onUpdate: @escaping (NowPlayingSnapshot?) -> Void) {
        pollQueue.async { [weak self] in
            guard let self else { return }
            self.onUpdate = onUpdate
            self.startTimer()
            self.startRealtimeObservers()
            self.pollNowPlaying()
        }
    }

    func stop() {
        pollQueue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.stopRealtimeObservers()
            self?.onUpdate = nil
            self?.lastSignature = nil
            self?.latestSpotifySnapshot = nil
            self?.latestSpotifySnapshotDate = nil
            self?.lastSpotifyStartupProbeAt = nil
            self?.spotifyStartupProbeRetryAfter = nil
        }
    }

    func applyLocalSnapshotOverride(_ snapshot: NowPlayingSnapshot) {
        pollQueue.async { [weak self] in
            guard let self else { return }

            if snapshot.sourceApp == "com.spotify.client" {
                self.latestSpotifySnapshot = snapshot
                self.latestSpotifySnapshotDate = Date()
            }

            self.dispatch(snapshot: snapshot)
        }
    }

    private func startTimer() {
        timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.35)
        timer.setEventHandler { [weak self] in
            self?.pollNowPlaying()
        }

        self.timer = timer
        timer.resume()
    }

    private func pollNowPlaying() {
        if let spotifySnapshot = liveSpotifySnapshotIfAvailable() {
            dispatch(snapshot: spotifySnapshot)
            return
        }

        if let startupSpotifySnapshot = fetchSpotifyStartupSnapshotIfNeeded() {
            latestSpotifySnapshot = startupSpotifySnapshot
            latestSpotifySnapshotDate = Date()
            dispatch(snapshot: startupSpotifySnapshot)
            return
        }

        let desktopPlayerSnapshot = fetchFromDesktopPlayerProbe()
        if let desktopPlayerSnapshot, desktopPlayerSnapshot.isPlaying {
            dispatch(snapshot: desktopPlayerSnapshot)
            return
        }

        let snapshot = fetchFromBrowserProbeIfEnabled()
            ?? fetchFromMediaPlayerCenterIfEnabled()
            ?? fetchFromMediaRemoteIfEnabled()
            ?? desktopPlayerSnapshot
        dispatch(snapshot: snapshot)
    }

    private func fetchFromMediaPlayerCenterIfEnabled() -> NowPlayingSnapshot? {
        guard systemNowPlayingCenterEnabled else { return nil }
        return fetchFromMediaPlayerCenter()
    }

    private func fetchFromBrowserProbeIfEnabled() -> NowPlayingSnapshot? {
        guard webPlayerDetectionEnabled else { return nil }
        return browserProbe.fetchNowPlaying()
    }

    private func fetchFromDesktopPlayerProbe() -> NowPlayingSnapshot? {
        desktopPlayerProbe.fetchNowPlaying()
    }

    private func fetchFromMediaRemoteIfEnabled() -> NowPlayingSnapshot? {
        // Disabled: this path can trigger repeated kMRMediaRemote "Operation not permitted"
        // errors on some systems and creates noisy logs.
        return nil
    }

    private func dispatch(snapshot: NowPlayingSnapshot?) {
        let signature = makeSignature(for: snapshot)
        let shouldNotify: Bool

        if let snapshot, snapshot.isPlaying {
            shouldNotify = true
        } else {
            shouldNotify = signature != lastSignature
        }

        lastSignature = signature

        guard shouldNotify else { return }
        DispatchQueue.main.async { [onUpdate] in
            onUpdate?(snapshot)
        }
    }

    private func makeSignature(for snapshot: NowPlayingSnapshot?) -> String {
        guard let snapshot else { return "none" }

        // Quantize timeline values so seek/progress jumps still trigger UI refresh,
        // without creating noisy signature churn from tiny floating-point deltas.
        let elapsedBucket = snapshot.elapsedTime.map { String(Int(($0 * 5).rounded())) } ?? ""
        let durationBucket = snapshot.duration.map { String(Int(($0 * 5).rounded())) } ?? ""

        return [
            snapshot.title,
            snapshot.artist,
            snapshot.sourceApp ?? "",
            snapshot.trackIdentifier ?? "",
            snapshot.isPlaying ? "1" : "0",
            elapsedBucket,
            durationBucket
        ].joined(separator: "|")
    }

    private func fetchFromMediaPlayerCenter() -> NowPlayingSnapshot? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return nil }

        let title = (info[MPMediaItemPropertyTitle] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = (info[MPMediaItemPropertyArtist] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if title.isEmpty && artist.isEmpty {
            return nil
        }

        if looksLikeSystemErrorMessage(title) || looksLikeSystemErrorMessage(artist) {
            return nil
        }

        let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval
        let duration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval
        let playbackRate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double
        let artworkData = artworkDataFromNowPlayingInfo(info)

        return NowPlayingSnapshot(
            title: title.isEmpty ? "Lecture en cours" : title,
            artist: artist,
            sourceApp: nil,
            trackIdentifier: nil,
            artworkURLString: nil,
            isPlaying: (playbackRate ?? 0) > 0,
            elapsedTime: elapsed,
            duration: duration,
            artworkData: artworkData
        )
    }

    private func startRealtimeObservers() {
        if spotifyObserver == nil {
            spotifyObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.pollQueue.async { [weak self] in
                    guard let self else { return }
                    self.consumeSpotifyNotification(notification)
                }
            }
        }

        if musicObserver == nil {
            musicObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.Music.playerInfo"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.pollQueue.async { [weak self] in
                    self?.pollNowPlaying()
                }
            }
        }
    }

    private func stopRealtimeObservers() {
        if let spotifyObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyObserver)
            self.spotifyObserver = nil
        }

        if let musicObserver {
            DistributedNotificationCenter.default().removeObserver(musicObserver)
            self.musicObserver = nil
        }
    }

    private func consumeSpotifyNotification(_ notification: Notification) {
        if let snapshot = snapshotFromSpotifyNotification(notification) {
            latestSpotifySnapshot = snapshot
            latestSpotifySnapshotDate = Date()
            dispatch(snapshot: snapshot)
            return
        }

        pollNowPlaying()
    }

    private func liveSpotifySnapshotIfAvailable() -> NowPlayingSnapshot? {
        guard isApplicationRunning(bundleID: "com.spotify.client") else {
            latestSpotifySnapshot = nil
            latestSpotifySnapshotDate = nil
            return nil
        }

        guard var snapshot = latestSpotifySnapshot else { return nil }
        let now = Date()

        if let refinedFromSystem = refinedSpotifySnapshotFromSystemCenter(base: snapshot) {
            snapshot = refinedFromSystem
            latestSpotifySnapshot = snapshot
            latestSpotifySnapshotDate = now
        }

        if snapshot.isPlaying,
           let observedAt = latestSpotifySnapshotDate,
           let elapsed = snapshot.elapsedTime,
           let duration = snapshot.duration,
           duration > 0 {
            let advancedElapsed = min(duration, elapsed + Date().timeIntervalSince(observedAt))
            snapshot = NowPlayingSnapshot(
                title: snapshot.title,
                artist: snapshot.artist,
                sourceApp: snapshot.sourceApp,
                trackIdentifier: snapshot.trackIdentifier,
                artworkURLString: snapshot.artworkURLString,
                isPlaying: snapshot.isPlaying,
                elapsedTime: advancedElapsed,
                duration: duration,
                artworkData: snapshot.artworkData
            )
        }

        return snapshot
    }

    private func refinedSpotifySnapshotFromSystemCenter(base snapshot: NowPlayingSnapshot) -> NowPlayingSnapshot? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return nil }

        let title = (info[MPMediaItemPropertyTitle] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = (info[MPMediaItemPropertyArtist] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let titleMatches = title.isEmpty || title.caseInsensitiveCompare(snapshot.title) == .orderedSame
        let artistMatches = artist.isEmpty || artist.caseInsensitiveCompare(snapshot.artist) == .orderedSame
        guard titleMatches && artistMatches else { return nil }

        let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval
        let duration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double
        let artworkData = artworkDataFromNowPlayingInfo(info) ?? snapshot.artworkData

        guard elapsed != nil || duration != nil || rate != nil else { return nil }

        return NowPlayingSnapshot(
            title: snapshot.title,
            artist: snapshot.artist,
            sourceApp: snapshot.sourceApp,
            trackIdentifier: snapshot.trackIdentifier,
            artworkURLString: snapshot.artworkURLString,
            isPlaying: (rate ?? (snapshot.isPlaying ? 1 : 0)) > 0,
            elapsedTime: elapsed ?? snapshot.elapsedTime,
            duration: duration ?? snapshot.duration,
            artworkData: artworkData
        )
    }

    private func fetchSpotifyStartupSnapshotIfNeeded() -> NowPlayingSnapshot? {
        guard latestSpotifySnapshot == nil else { return nil }
        guard isApplicationRunning(bundleID: "com.spotify.client") else {
            lastSpotifyStartupProbeAt = nil
            spotifyStartupProbeRetryAfter = nil
            return nil
        }

        let now = Date()
        if let retryAfter = spotifyStartupProbeRetryAfter, now < retryAfter {
            return nil
        }

        if let lastProbeAt = lastSpotifyStartupProbeAt,
           now.timeIntervalSince(lastProbeAt) < spotifyStartupProbeInterval {
            return nil
        }
        lastSpotifyStartupProbeAt = now

        guard let raw = spotifyStartupScriptResponse(), raw.isEmpty == false else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 7 else { return nil }

        let trackID = normalizedText(parts[0])
        let title = normalizedText(parts[1])
        let artist = normalizedText(parts[2])
        let state = normalizedText(parts[3]).lowercased()
        var elapsed = normalizedDouble(parts[4])
        var duration = normalizedDouble(parts[5])
        let artworkURL = normalizedText(parts[6])

        guard title.isEmpty == false || artist.isEmpty == false else { return nil }

        if let parsedDuration = duration, parsedDuration > 1_000 {
            duration = parsedDuration / 1_000
        }
        if let parsedElapsed = elapsed, parsedElapsed > 1_000, (duration ?? 0) < 1_000 {
            elapsed = parsedElapsed / 1_000
        }
        if let elapsedValue = elapsed, let durationValue = duration, durationValue > 0, elapsedValue > durationValue {
            elapsed = durationValue
        }

        let isPlaying = state.contains("play")

        return NowPlayingSnapshot(
            title: title.isEmpty ? "Lecture en cours" : title,
            artist: artist,
            sourceApp: "com.spotify.client",
            trackIdentifier: trackID.isEmpty ? nil : trackID,
            artworkURLString: artworkURL.isEmpty ? nil : artworkURL,
            isPlaying: isPlaying,
            elapsedTime: elapsed,
            duration: duration,
            artworkData: nil
        )
    }

    private func spotifyStartupScriptResponse() -> String? {
        let scriptSource = #"""
tell application id "com.spotify.client"
    if not running then return ""
    if player state is stopped then return ""
    set trackID to id of current track
    set trackName to name of current track
    set trackArtist to artist of current track
    set trackState to (player state as string)
    set trackPosition to (player position) as string
    set trackDuration to (duration of current track) as string
    set trackArtworkURL to artwork url of current track
    return trackID & "|||" & trackName & "|||" & trackArtist & "|||" & trackState & "|||" & trackPosition & "|||" & trackDuration & "|||" & trackArtworkURL
end tell
"""#

        guard let script = NSAppleScript(source: scriptSource) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let errorNumber = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            let retryDelay: TimeInterval = (errorNumber == -1743) ? 20 : 5
            spotifyStartupProbeRetryAfter = Date().addingTimeInterval(retryDelay)
            NSLog("Notch2.0 spotify startup probe failed: %@", "\(error)")
            return nil
        }

        spotifyStartupProbeRetryAfter = nil
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedText(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedDouble(_ value: String?) -> Double? {
        let normalized = normalizedText(value).replacingOccurrences(of: ",", with: ".")
        guard normalized.isEmpty == false else { return nil }
        return Double(normalized)
    }

    private func snapshotFromSpotifyNotification(_ notification: Notification) -> NowPlayingSnapshot? {
        guard let userInfo = notification.userInfo else { return nil }

        let title = stringValue(in: userInfo, keys: ["Name", "Track Name", "Title"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if title.isEmpty { return nil }
        if looksLikeSystemErrorMessage(title) { return nil }

        let artist = stringValue(in: userInfo, keys: ["Artist", "Artist Name"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if looksLikeSystemErrorMessage(artist) { return nil }

        let state = stringValue(in: userInfo, keys: ["Player State", "State", "playerState"])?.lowercased() ?? ""
        let isPlaying = state.contains("play")
        let trackIdentifier = spotifyTrackIdentifier(from: userInfo)

        var duration = doubleValue(in: userInfo, keys: ["Duration", "duration"])
        if let parsedDuration = duration, parsedDuration > 1_000 {
            duration = parsedDuration / 1_000
        }

        var elapsed = doubleValue(in: userInfo, keys: ["Playback Position", "Position", "position", "Elapsed"])
        if let parsedElapsed = elapsed, parsedElapsed > 1_000, (duration ?? 0) < 1_000 {
            elapsed = parsedElapsed / 1_000
        }

        let canReuseArtwork =
            latestSpotifySnapshot?.trackIdentifier == trackIdentifier &&
            latestSpotifySnapshot?.title == title &&
            latestSpotifySnapshot?.artist == artist
        let artworkURLString = stringValue(
            in: userInfo,
            keys: [
                "Artwork URL",
                "artwork_url",
                "ArtworkURL",
                "Album Art URL",
                "Cover URL",
                "trackArtworkURL",
                "track_artwork_url"
            ]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedArtworkURL = (artworkURLString?.isEmpty == false)
            ? artworkURLString
            : (canReuseArtwork ? latestSpotifySnapshot?.artworkURLString : nil)

        return NowPlayingSnapshot(
            title: title,
            artist: artist,
            sourceApp: "com.spotify.client",
            trackIdentifier: trackIdentifier,
            artworkURLString: resolvedArtworkURL,
            isPlaying: isPlaying,
            elapsedTime: elapsed,
            duration: duration,
            artworkData: canReuseArtwork ? latestSpotifySnapshot?.artworkData : nil
        )
    }

    private func isApplicationRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    private func stringValue(in dictionary: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }

        return nil
    }

    private func doubleValue(in dictionary: [AnyHashable: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? Double {
                return value
            }

            if let value = dictionary[key] as? NSNumber {
                return value.doubleValue
            }

            if let value = dictionary[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }

        return nil
    }

    private func spotifyTrackIdentifier(from dictionary: [AnyHashable: Any]) -> String? {
        let raw = stringValue(in: dictionary, keys: [
            "Track ID",
            "TrackID",
            "track_id",
            "Spotify URI",
            "spotifyURI",
            "Spotify URL",
            "spotifyURL"
        ])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard raw.isEmpty == false else { return nil }

        if raw.contains("spotify:track:"),
           let trackID = raw.components(separatedBy: "spotify:track:").last,
           trackID.isEmpty == false {
            return trackID
        }

        if raw.contains("open.spotify.com/track/"),
           let url = URL(string: raw),
           let trackID = url.pathComponents.dropFirst().drop(while: { $0 != "track" }).dropFirst().first,
           trackID.isEmpty == false {
            return trackID
        }

        return raw
    }

    private func artworkDataFromNowPlayingInfo(_ info: [String: Any]) -> Data? {
        guard let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else { return nil }

        let preferredSizes = [
            NSSize(width: 600, height: 600),
            NSSize(width: 300, height: 300),
            NSSize(width: 128, height: 128)
        ]

        for size in preferredSizes {
            guard let image = artwork.image(at: size) else { continue }
            if let png = pngData(from: image), png.isEmpty == false {
                return png
            }
            if let tiff = image.tiffRepresentation, tiff.isEmpty == false {
                return tiff
            }
        }

        return nil
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        guard let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func looksLikeSystemErrorMessage(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.isEmpty == false else { return false }

        return normalized.contains("fsfindfolder failed with error")
            || normalized.contains("error=-43")
            || normalized.contains("nsfile")
    }

}

private final class DesktopPlayerNowPlayingProbe {
    private let supportedPlayers = [
        "org.videolan.vlc",
        "com.apple.QuickTimePlayerX"
    ]
    private var probeCooldownUntilByBundle: [String: Date] = [:]
    private var automationPromptAttemptedBundles: Set<String> = []
    private let genericScriptErrorCooldown: TimeInterval = 15
    private let connectionInvalidCooldown: TimeInterval = 2
    private let authorizationDeniedCooldown: TimeInterval = 8

    func fetchNowPlaying() -> NowPlayingSnapshot? {
        var pausedSnapshot: NowPlayingSnapshot?

        for bundleID in supportedPlayers {
            guard isRunning(bundleID: bundleID) else { continue }
            if let cooldownUntil = probeCooldownUntilByBundle[bundleID], cooldownUntil > Date() {
                continue
            }

            let snapshot: NowPlayingSnapshot?
            switch bundleID {
            case "org.videolan.vlc":
                snapshot = probeVLCNowPlaying()
            case "com.apple.QuickTimePlayerX":
                snapshot = probeQuickTimeNowPlaying()
            default:
                snapshot = nil
            }

            guard let snapshot else { continue }
            if snapshot.isPlaying {
                return snapshot
            }
            if pausedSnapshot == nil {
                pausedSnapshot = snapshot
            }
        }

        return pausedSnapshot
    }

    private func probeVLCNowPlaying() -> NowPlayingSnapshot? {
        let bundleID = "org.videolan.vlc"
        guard let raw = runAppleScript(vlcNowPlayingScript(), bundleID: bundleID), raw.isEmpty == false else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        var title = normalizedText(parts[0])
        let artist = normalizedText(parts[1])
        let state = normalizedText(parts[2]).lowercased()
        let elapsedRaw = normalizedDouble(parts[3])
        let durationRaw = normalizedDouble(parts[4])
        let mediaPath = normalizedText(parts[5])

        if title.isEmpty {
            title = mediaTitle(from: mediaPath) ?? ""
        }

        if title.isEmpty && artist.isEmpty {
            return nil
        }

        let duration = normalizeDuration(durationRaw)
        let elapsed = normalizeElapsed(elapsedRaw, duration: duration)
        let isPlaying = state.contains("play")
        let trackIdentifier = mediaPath.isEmpty ? nil : mediaPath

        return NowPlayingSnapshot(
            title: title.isEmpty ? "Lecture en cours" : title,
            artist: artist,
            sourceApp: bundleID,
            trackIdentifier: trackIdentifier,
            artworkURLString: nil,
            isPlaying: isPlaying,
            elapsedTime: elapsed,
            duration: duration,
            artworkData: nil
        )
    }

    private func probeQuickTimeNowPlaying() -> NowPlayingSnapshot? {
        let bundleID = "com.apple.QuickTimePlayerX"
        guard let raw = runAppleScript(quickTimeNowPlayingScript(), bundleID: bundleID), raw.isEmpty == false else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }

        var title = normalizedText(parts[0])
        let rate = normalizedDouble(parts[1]) ?? 0
        let elapsedRaw = normalizedDouble(parts[2])
        let durationRaw = normalizedDouble(parts[3])
        let mediaPath = normalizedText(parts[4])

        if title.isEmpty {
            title = mediaTitle(from: mediaPath) ?? ""
        }
        guard title.isEmpty == false else { return nil }

        let duration = normalizeDuration(durationRaw)
        let elapsed = normalizeElapsed(elapsedRaw, duration: duration)
        let isPlaying = rate > 0.001
        let trackIdentifier = mediaPath.isEmpty ? nil : mediaPath

        return NowPlayingSnapshot(
            title: title,
            artist: "",
            sourceApp: bundleID,
            trackIdentifier: trackIdentifier,
            artworkURLString: nil,
            isPlaying: isPlaying,
            elapsedTime: elapsed,
            duration: duration,
            artworkData: nil
        )
    }

    private func normalizedText(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedDouble(_ value: String?) -> Double? {
        let normalized = normalizedText(value)
        guard normalized.isEmpty == false else { return nil }
        let decimalCandidate = normalized.replacingOccurrences(of: ",", with: ".")
        return Double(decimalCandidate)
    }

    private func normalizeDuration(_ rawValue: Double?) -> TimeInterval? {
        guard var value = sanitizedTime(rawValue) else { return nil }
        if value > 100_000 {
            value /= 1_000
        }
        return value
    }

    private func normalizeElapsed(_ rawValue: Double?, duration: TimeInterval?) -> TimeInterval? {
        guard var value = sanitizedTime(rawValue) else { return nil }

        if value > 100_000 {
            value /= 1_000
        }
        if let duration, duration > 0, value > duration * 10 {
            value /= 1_000
        }
        if let duration, duration > 0 {
            value = min(value, duration)
        }

        return value
    }

    private func sanitizedTime(_ value: Double?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func mediaTitle(from mediaPath: String) -> String? {
        guard mediaPath.isEmpty == false else { return nil }

        if let url = URL(string: mediaPath), let scheme = url.scheme, scheme.isEmpty == false {
            let candidate = url.deletingPathExtension().lastPathComponent
            if candidate.isEmpty == false {
                return candidate
            }
        }

        let candidate = URL(fileURLWithPath: mediaPath).deletingPathExtension().lastPathComponent
        return candidate.isEmpty ? nil : candidate
    }

    private func vlcNowPlayingScript() -> String {
        #"""
tell application id "org.videolan.vlc"
    if not running then return ""
    set isPlaying to false
    try
        set isPlaying to playing
    end try
    set stateName to "paused"
    if isPlaying then set stateName to "playing"
    set itemName to ""
    set itemPath to ""
    set itemDuration to ""
    set itemPosition to ""
    try
        set itemName to (name of current item) as string
    end try
    try
        set itemPath to (path of current item) as string
    end try
    try
        set itemDuration to (duration of current item) as string
    end try
    try
        set itemPosition to (current time) as string
    end try
    if itemName is "" and itemPath is "" then return ""
    return itemName & "|||" & "" & "|||" & stateName & "|||" & itemPosition & "|||" & itemDuration & "|||" & itemPath
end tell
"""#
    }

    private func quickTimeNowPlayingScript() -> String {
        #"""
tell application id "com.apple.QuickTimePlayerX"
    if not running then return ""
    if not (exists document 1) then return ""
    set docRef to document 1
    set docName to ""
    set docPath to ""
    set docRate to ""
    set docCurrentTime to ""
    set docDuration to ""
    try
        set docName to (name of docRef) as string
    end try
    try
        set docPath to (path of docRef) as string
    end try
    try
        set docRate to (rate of docRef) as string
    end try
    try
        set docCurrentTime to (current time of docRef) as string
    end try
    try
        set docDuration to (duration of docRef) as string
    end try
    return docName & "|||" & docRate & "|||" & docCurrentTime & "|||" & docDuration & "|||" & docPath
end tell
"""#
    }

    private func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    private func runAppleScript(_ source: String, bundleID: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            applyProbeCooldown(for: bundleID, errorDescription: "AppleScript init failed")
            return nil
        }

        var error: NSDictionary?
        var result = script.executeAndReturnError(&error)
        var resolvedError = error

        if let errorNumber = (resolvedError?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue,
           errorNumber == -609 {
            usleep(150_000)
            var retryError: NSDictionary?
            let retryResult = script.executeAndReturnError(&retryError)
            if retryError == nil {
                return retryResult.stringValue
            }
            resolvedError = retryError
            result = retryResult
        }

        if let error = resolvedError {
            let errorNumber = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            if errorNumber == -1743 {
                requestAutomationPromptIfNeeded(for: bundleID)
            }
            NSLog("Notch2.0 desktop player probe blocked for %@: %@", bundleID, "\(error)")
            applyProbeCooldown(for: bundleID, errorDescription: "\(error)", errorNumber: errorNumber)
            return nil
        }

        return result.stringValue
    }

    private func requestAutomationPromptIfNeeded(for bundleID: String) {
        guard automationPromptAttemptedBundles.contains(bundleID) == false else { return }
        automationPromptAttemptedBundles.insert(bundleID)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let scriptSource = """
            tell application id "\(bundleID)"
                get name
            end tell
            """

            guard let script = NSAppleScript(source: scriptSource) else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
            if let error {
                NSLog("Notch2.0 automation prompt attempt for %@ failed: %@", bundleID, "\(error)")
            }
        }
    }

    private func applyProbeCooldown(for bundleID: String, errorDescription: String, errorNumber: Int? = nil) {
        if errorNumber == -609 {
            probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(connectionInvalidCooldown)
            return
        }

        if errorNumber == -1743 {
            probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(authorizationDeniedCooldown)
            return
        }

        let lower = errorDescription.lowercased()
        let delay = lower.contains("fsfindfolder failed with error=-43")
            ? 60 * 60 * 8
            : genericScriptErrorCooldown
        probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(delay)
    }
}

private final class BrowserNowPlayingBrowserProbe {
    private struct Candidate {
        let url: String
        let title: String
    }

    private struct OEmbedResponse: Decodable {
        let title: String?
        let author_name: String?
        let thumbnail_url: String?
    }

    private struct EnrichedMetadata {
        let title: String
        let artist: String
        let artworkURLString: String?
    }

    private let supportedBrowsers = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser"
    ]
    private var probeCooldownUntilByBundle: [String: Date] = [:]
    private var oEmbedCacheByURL: [String: EnrichedMetadata] = [:]
    private var oEmbedCooldownUntilByURL: [String: Date] = [:]
    private var automationPromptAttemptedBundles: Set<String> = []
    private let genericScriptErrorCooldown: TimeInterval = 20
    private let fsFindFolderErrorCooldown: TimeInterval = 60 * 60 * 8
    private let connectionInvalidCooldown: TimeInterval = 2
    private let authorizationDeniedCooldown: TimeInterval = 8
    private let oEmbedFailureCooldown: TimeInterval = 90

    func fetchNowPlaying() -> NowPlayingSnapshot? {
        for bundleID in supportedBrowsers {
            guard isRunning(bundleID: bundleID) else { continue }
            if let cooldownUntil = probeCooldownUntilByBundle[bundleID], cooldownUntil > Date() {
                continue
            }
            let candidate = probeBrowserAudibleTabs(bundleID: bundleID)
                ?? probeBrowserActiveMediaTabs(bundleID: bundleID)
            guard let candidate else { continue }

            let enriched = enrichedMetadata(for: candidate.url)
            let title = normalizedText(enriched?.title).isEmpty
                ? cleanedTitle(candidate.title, url: candidate.url)
                : normalizedText(enriched?.title)
            let artist = normalizedText(enriched?.artist).isEmpty
                ? siteName(from: candidate.url)
                : normalizedText(enriched?.artist)
            let artworkURL = normalizedText(enriched?.artworkURLString)
            NSLog("Notch2.0 browser candidate %@ %@ %@", bundleID, title, candidate.url)

            return NowPlayingSnapshot(
                title: title.isEmpty ? "Lecture web" : title,
                artist: artist,
                sourceApp: bundleID,
                trackIdentifier: candidate.url,
                artworkURLString: artworkURL.isEmpty ? nil : artworkURL,
                isPlaying: true,
                elapsedTime: nil,
                duration: nil,
                artworkData: nil
            )
        }

        return nil
    }

    private func probeBrowserAudibleTabs(bundleID: String) -> Candidate? {
        let scriptSource: String
        switch bundleID {
        case "com.apple.Safari":
            scriptSource = safariAudibleTabsScript()
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser":
            scriptSource = chromiumAudibleTabsScript(bundleID: bundleID)
        default:
            return nil
        }

        guard let raw = runAppleScript(scriptSource, bundleID: bundleID), raw.isEmpty == false else { return nil }
        return firstAudibleCandidate(from: raw)
    }

    private func probeBrowserActiveMediaTabs(bundleID: String) -> Candidate? {
        let scriptSource: String
        switch bundleID {
        case "com.apple.Safari":
            scriptSource = safariActiveTabsScript()
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser":
            scriptSource = chromiumActiveTabsScript(bundleID: bundleID)
        default:
            return nil
        }

        guard let raw = runAppleScript(scriptSource, bundleID: bundleID), raw.isEmpty == false else { return nil }

        for line in raw.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { continue }

            let parts = trimmedLine.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }
            let title = normalizedText(parts[0])
            let url = normalizedText(parts[1])
            guard isSupportedMediaURL(url) else { continue }
            guard isLikelyMediaPage(url: url, title: title) else { continue }
            return Candidate(url: url, title: title)
        }

        return nil
    }

    private func firstAudibleCandidate(from rawOutput: String) -> Candidate? {
        for line in rawOutput.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { continue }
            let parts = trimmedLine.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }

            let title = normalizedText(parts[0])
            let url = normalizedText(parts[1])
            guard isSupportedMediaURL(url) else { continue }

            return Candidate(url: url, title: title)
        }
        return nil
    }

    private func safariAudibleTabsScript() -> String {
        #"""
tell application id "com.apple.Safari"
    if (count of windows) is 0 then return ""
    set outputLines to {}
    set previousDelimiters to AppleScript's text item delimiters
    repeat with w in windows
        repeat with tabRef in tabs of w
            try
                if (audible of tabRef) is true then
                    set tabTitle to (name of tabRef) as string
                    set tabURL to (URL of tabRef) as string
                    if tabURL is not "" then
                        set end of outputLines to (tabTitle & "|||" & tabURL)
                    end if
                end if
            end try
        end repeat
    end repeat
    set AppleScript's text item delimiters to linefeed
    set joinedOutput to outputLines as string
    set AppleScript's text item delimiters to previousDelimiters
    return joinedOutput
end tell
"""#
    }

    private func chromiumAudibleTabsScript(bundleID: String) -> String {
        #"""
tell application id "\#(bundleID)"
    if (count of windows) is 0 then return ""
    set outputLines to {}
    set previousDelimiters to AppleScript's text item delimiters
    repeat with w in windows
        repeat with tabRef in tabs of w
            try
                if (audible of tabRef) is true then
                    set tabTitle to (title of tabRef) as string
                    set tabURL to (URL of tabRef) as string
                    if tabURL is not "" then
                        set end of outputLines to (tabTitle & "|||" & tabURL)
                    end if
                end if
            end try
        end repeat
    end repeat
    set AppleScript's text item delimiters to linefeed
    set joinedOutput to outputLines as string
    set AppleScript's text item delimiters to previousDelimiters
    return joinedOutput
end tell
"""#
    }

    private func safariActiveTabsScript() -> String {
        #"""
tell application id "com.apple.Safari"
    if (count of windows) is 0 then return ""
    set outputLines to {}
    set previousDelimiters to AppleScript's text item delimiters
    repeat with w in windows
        try
            set tabRef to current tab of w
            set tabTitle to (name of tabRef) as string
            set tabURL to (URL of tabRef) as string
            if tabURL is not "" then
                set end of outputLines to (tabTitle & "|||" & tabURL)
            end if
        end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    set joinedOutput to outputLines as string
    set AppleScript's text item delimiters to previousDelimiters
    return joinedOutput
end tell
"""#
    }

    private func chromiumActiveTabsScript(bundleID: String) -> String {
        #"""
tell application id "\#(bundleID)"
    if (count of windows) is 0 then return ""
    set outputLines to {}
    set previousDelimiters to AppleScript's text item delimiters
    repeat with w in windows
        try
            set tabRef to active tab of w
            set tabTitle to (title of tabRef) as string
            set tabURL to (URL of tabRef) as string
            if tabURL is not "" then
                set end of outputLines to (tabTitle & "|||" & tabURL)
            end if
        end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    set joinedOutput to outputLines as string
    set AppleScript's text item delimiters to previousDelimiters
    return joinedOutput
end tell
"""#
    }

    private func enrichedMetadata(for mediaURL: String) -> EnrichedMetadata? {
        let normalizedURL = normalizedText(mediaURL)
        guard normalizedURL.isEmpty == false else { return nil }

        if let cached = oEmbedCacheByURL[normalizedURL] {
            return cached
        }

        if let cooldownUntil = oEmbedCooldownUntilByURL[normalizedURL], cooldownUntil > Date() {
            return nil
        }

        guard let endpoint = oEmbedEndpoint(for: normalizedURL) else { return nil }
        guard let response = fetchOEmbed(from: endpoint) else {
            oEmbedCooldownUntilByURL[normalizedURL] = Date().addingTimeInterval(oEmbedFailureCooldown)
            return nil
        }

        let title = normalizedText(response.title)
        let artist = normalizedText(response.author_name)
        let artworkCandidate = normalizedText(response.thumbnail_url)
        let artworkURL = isSupportedMediaURL(artworkCandidate) ? artworkCandidate : nil

        guard title.isEmpty == false || artist.isEmpty == false || artworkURL != nil else { return nil }

        let metadata = EnrichedMetadata(
            title: title,
            artist: artist,
            artworkURLString: artworkURL
        )
        oEmbedCacheByURL[normalizedURL] = metadata
        return metadata
    }

    private func oEmbedEndpoint(for mediaURL: String) -> URL? {
        guard let url = URL(string: mediaURL),
              let host = url.host?.lowercased() else {
            return nil
        }

        let endpointBase: String
        if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" || host == "youtu.be" {
            endpointBase = "https://www.youtube.com/oembed"
        } else if host == "twitch.tv" || host == "www.twitch.tv" {
            endpointBase = "https://www.twitch.tv/oembed"
        } else {
            return nil
        }

        guard var components = URLComponents(string: endpointBase) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: mediaURL),
            URLQueryItem(name: "format", value: "json")
        ]
        return components.url
    }

    private func fetchOEmbed(from endpoint: URL) -> OEmbedResponse? {
        let semaphore = DispatchSemaphore(value: 0)
        var parsedResponse: OEmbedResponse?

        let task = URLSession.shared.dataTask(with: endpoint) { data, _, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            guard let decoded = try? JSONDecoder().decode(OEmbedResponse.self, from: data) else { return }
            parsedResponse = decoded
        }

        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + 1.2)
        if waitResult != .success {
            task.cancel()
            return nil
        }

        return parsedResponse
    }

    private func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    private func runAppleScript(_ source: String, bundleID: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            NSLog("Notch2.0 browser probe: AppleScript init failed for %@", bundleID)
            applyProbeCooldown(for: bundleID, errorDescription: "AppleScript init failed")
            return nil
        }
        var error: NSDictionary?
        var result = script.executeAndReturnError(&error)
        var resolvedError = error

        if let errorNumber = (resolvedError?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue,
           errorNumber == -609 {
            usleep(150_000)
            var retryError: NSDictionary?
            let retryResult = script.executeAndReturnError(&retryError)
            if retryError == nil {
                return retryResult.stringValue
            }
            resolvedError = retryError
            result = retryResult
        }

        if let error = resolvedError {
            let errorNumber = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            if errorNumber == -1743 {
                requestAutomationPromptIfNeeded(for: bundleID)
            }
            NSLog("Notch2.0 browser probe blocked for %@: %@", bundleID, "\(error)")
            applyProbeCooldown(for: bundleID, errorDescription: "\(error)", errorNumber: errorNumber)
            return nil
        }

        return result.stringValue
    }

    private func requestAutomationPromptIfNeeded(for bundleID: String) {
        guard automationPromptAttemptedBundles.contains(bundleID) == false else { return }
        automationPromptAttemptedBundles.insert(bundleID)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let scriptSource = """
            tell application id "\(bundleID)"
                get name
            end tell
            """

            guard let script = NSAppleScript(source: scriptSource) else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
            if let error {
                NSLog("Notch2.0 automation prompt attempt for %@ failed: %@", bundleID, "\(error)")
            }
        }
    }

    private func applyProbeCooldown(for bundleID: String, errorDescription: String, errorNumber: Int? = nil) {
        if errorNumber == -609 {
            probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(connectionInvalidCooldown)
            return
        }

        if errorNumber == -1743 {
            probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(authorizationDeniedCooldown)
            return
        }

        let lower = errorDescription.lowercased()
        let delay = lower.contains("fsfindfolder failed with error=-43")
            ? fsFindFolderErrorCooldown
            : genericScriptErrorCooldown
        probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(delay)
    }

    private func isSupportedMediaURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func normalizedText(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanedTitle(_ title: String, url: String) -> String {
        var cleaned = title
            .replacingOccurrences(of: " - YouTube", with: "")
            .replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - Vimeo", with: "")
            .replacingOccurrences(of: " - Twitch", with: "")
            .replacingOccurrences(of: " - Netflix", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty, let host = URL(string: url)?.host {
            cleaned = host
        }

        return cleaned
    }

    private func siteName(from rawURL: String) -> String {
        guard let url = URL(string: rawURL), let host = url.host?.lowercased() else { return "" }

        switch host {
        case "youtube.com", "www.youtube.com", "music.youtube.com", "youtu.be":
            return "YouTube"
        case "vimeo.com", "www.vimeo.com":
            return "Vimeo"
        case "twitch.tv", "www.twitch.tv":
            return "Twitch"
        case "netflix.com", "www.netflix.com":
            return "Netflix"
        case "primevideo.com", "www.primevideo.com":
            return "Prime Video"
        default:
            return host
        }
    }

    private func isLikelyMediaPage(url rawURL: String, title: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else {
            return false
        }

        let path = url.path.lowercased()
        let normalizedTitle = title.lowercased()

        if host == "youtu.be" {
            return true
        }

        if host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" || host == "music.youtube.com" {
            if path == "/watch" || path.hasPrefix("/watch/") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") {
                return true
            }
            return normalizedTitle.contains("youtube")
        }

        if host == "twitch.tv" || host == "www.twitch.tv" {
            let blockedPrefixes = ["/directory", "/downloads", "/settings", "/p/", "/jobs", "/search"]
            if blockedPrefixes.contains(where: { path.hasPrefix($0) }) {
                return false
            }
            return path.count > 1
        }

        if host == "vimeo.com" || host == "www.vimeo.com" {
            return path.count > 1
        }

        return false
    }
}

private final class MediaRemoteBridge {
    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfoFn: GetNowPlayingInfoFn?
    private let callbackQueue = DispatchQueue(label: "notch2.media-remote.callback")

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_NOW)
        self.handle = handle

        if let handle {
            getNowPlayingInfoFn = Self.resolveSymbol(named: "MRMediaRemoteGetNowPlayingInfo", in: handle)
        } else {
            getNowPlayingInfoFn = nil
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func fetchNowPlaying() -> NowPlayingSnapshot? {
        guard let getNowPlayingInfoFn else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var resolvedDictionary: [String: Any]?

        getNowPlayingInfoFn(callbackQueue) { dictionary in
            if let dictionary {
                resolvedDictionary = Self.normalizeDictionary(dictionary)
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 0.4)
        guard waitResult == .success else { return nil }
        guard let dictionary = resolvedDictionary else { return nil }

        let title = Self.stringValue(in: dictionary, keys: [
            "kMRMediaRemoteNowPlayingInfoTitle",
            "Title"
        ])

        let artist = Self.stringValue(in: dictionary, keys: [
            "kMRMediaRemoteNowPlayingInfoArtist",
            "Artist"
        ])

        let sourceBundleID = Self.stringValue(in: dictionary, keys: [
            "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier",
            "kMRMediaRemoteNowPlayingInfoOriginClientIdentifier",
            "BundleIdentifier"
        ])

        let elapsed = Self.doubleValue(in: dictionary, keys: [
            "kMRMediaRemoteNowPlayingInfoElapsedTime",
            "ElapsedTime"
        ])

        let duration = Self.doubleValue(in: dictionary, keys: [
            "kMRMediaRemoteNowPlayingInfoDuration",
            "Duration"
        ])

        let playbackRate = Self.doubleValue(in: dictionary, keys: [
            "kMRMediaRemoteNowPlayingInfoPlaybackRate",
            "PlaybackRate"
        ])

        let isPlaying = (playbackRate ?? 0) > 0
        let artworkData = Self.artworkData(from: dictionary)

        let resolvedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedArtist = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if resolvedTitle.isEmpty && resolvedArtist.isEmpty {
            return nil
        }
        if Self.looksLikeSystemErrorMessage(resolvedTitle) || Self.looksLikeSystemErrorMessage(resolvedArtist) {
            return nil
        }

        return NowPlayingSnapshot(
            title: resolvedTitle.isEmpty ? "Lecture en cours" : resolvedTitle,
            artist: resolvedArtist,
            sourceApp: sourceBundleID,
            trackIdentifier: nil,
            artworkURLString: nil,
            isPlaying: isPlaying,
            elapsedTime: elapsed,
            duration: duration,
            artworkData: artworkData
        )
    }

    private static func normalizeDictionary(_ dictionary: CFDictionary) -> [String: Any] {
        let source = dictionary as NSDictionary
        var normalized: [String: Any] = [:]

        for (key, value) in source {
            normalized[String(describing: key)] = value
        }

        return normalized
    }

    private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }

        return nil
    }

    private static func doubleValue(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? Double {
                return value
            }

            if let value = dictionary[key] as? NSNumber {
                return value.doubleValue
            }
        }

        return nil
    }

    private static func artworkData(from dictionary: [String: Any]) -> Data? {
        let keys = [
            "kMRMediaRemoteNowPlayingInfoArtworkData",
            "ArtworkData"
        ]

        for key in keys {
            if let data = dictionary[key] as? Data {
                return data
            }

            if let data = dictionary[key] as? NSData {
                return data as Data
            }
        }

        return nil
    }

    private static func looksLikeSystemErrorMessage(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.isEmpty == false else { return false }

        return normalized.contains("fsfindfolder failed with error")
            || normalized.contains("error=-43")
            || normalized.contains("nsfile")
    }

    private static func resolveSymbol<T>(named name: String, in handle: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
