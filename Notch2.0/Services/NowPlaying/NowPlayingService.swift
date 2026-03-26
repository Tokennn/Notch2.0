import AppKit
import Foundation
import MediaPlayer
import Darwin

final class NowPlayingService {
    private let pollQueue = DispatchQueue(label: "notch2.now-playing.poll", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let browserProbe = BrowserNowPlayingBrowserProbe()
    private var onUpdate: ((NowPlayingSnapshot?) -> Void)?
    private var lastSignature: String?
    private var spotifyObserver: NSObjectProtocol?
    private var musicObserver: NSObjectProtocol?
    private var latestSpotifySnapshot: NowPlayingSnapshot?
    private var latestSpotifySnapshotDate: Date?
    private var webPlayerDetectionEnabled: Bool {
        let defaults = UserDefaults.standard
        if let storedValue = defaults.object(forKey: "EnableWebPlayerDetection") as? Bool {
            return storedValue
        }

        return true
    }
    private var systemNowPlayingCenterEnabled: Bool {
        UserDefaults.standard.bool(forKey: "EnableSystemNowPlayingCenter")
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

        let snapshot = fetchFromBrowserProbeIfEnabled()
            ?? fetchFromMediaPlayerCenterIfEnabled()
            ?? fetchFromMediaRemoteIfEnabled()
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

    private func fetchFromMediaRemoteIfEnabled() -> NowPlayingSnapshot? {
        // Disabled: this path is the source of repeated kMRMediaRemote errors
        // on some machines when no system now-playing client is resolved.
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

        return [
            snapshot.title,
            snapshot.artist,
            snapshot.sourceApp ?? "",
            snapshot.trackIdentifier ?? "",
            snapshot.isPlaying ? "1" : "0",
            snapshot.duration.map { String($0) } ?? ""
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

private final class BrowserNowPlayingBrowserProbe {
    private struct ProbePayload: Decodable {
        let title: String
        let url: String
        let currentTime: Double?
        let duration: Double?
    }

    private struct Candidate {
        let url: String
        let title: String
        let currentTime: Double?
        let duration: Double?
    }

    private let supportedBrowsers = [
        "com.apple.Safari",
        "com.google.Chrome"
    ]
    private var probeCooldownUntilByBundle: [String: Date] = [:]
    private let genericScriptErrorCooldown: TimeInterval = 20
    private let fsFindFolderErrorCooldown: TimeInterval = 60 * 60 * 8

    private let probeJavaScript = #"""
(() => {
  const media = Array.from(document.querySelectorAll('video, audio'))
    .find((element) => {
      const src = element.currentSrc || element.src || "";
      const hasTimeline = Number.isFinite(element.duration) && element.duration > 0;
      return !element.paused && !element.ended && (src.length > 0 || hasTimeline);
    });
  if (!media) return "";
  return JSON.stringify({
    title: document.title || "",
    url: location.href || "",
    currentTime: Number.isFinite(media.currentTime) ? media.currentTime : 0,
    duration: Number.isFinite(media.duration) ? media.duration : 0
  });
})()
"""#

    func fetchNowPlaying() -> NowPlayingSnapshot? {
        for bundleID in supportedBrowsers {
            guard isRunning(bundleID: bundleID) else { continue }
            if let cooldownUntil = probeCooldownUntilByBundle[bundleID], cooldownUntil > Date() {
                continue
            }
            guard let candidate = probeBrowser(bundleID: bundleID) else { continue }

            let cleanedTitle = cleanedTitle(candidate.title, url: candidate.url)
            let artist = siteName(from: candidate.url)

            return NowPlayingSnapshot(
                title: cleanedTitle.isEmpty ? "Lecture web" : cleanedTitle,
                artist: artist,
                sourceApp: bundleID,
                trackIdentifier: candidate.url,
                artworkURLString: nil,
                isPlaying: true,
                elapsedTime: candidate.currentTime,
                duration: candidate.duration,
                artworkData: nil
            )
        }

        return nil
    }

    private func probeBrowser(bundleID: String) -> Candidate? {
        if let audibleCandidate = probeBrowserAudibleTabs(bundleID: bundleID) {
            return audibleCandidate
        }

        let scriptSource: String
        switch bundleID {
        case "com.apple.Safari":
            scriptSource = safariScript()
        case "com.google.Chrome":
            scriptSource = chromeScript()
        default:
            return nil
        }

        guard let raw = runAppleScript(scriptSource, bundleID: bundleID), raw.isEmpty == false else { return nil }

        for line in raw.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { continue }
            guard let data = trimmedLine.data(using: .utf8) else { continue }
            guard let payload = try? JSONDecoder().decode(ProbePayload.self, from: data) else { continue }

            let normalizedURL = payload.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedURL.isEmpty == false else { continue }
            guard isSupportedMediaURL(normalizedURL) else { continue }

            return Candidate(
                url: normalizedURL,
                title: payload.title.trimmingCharacters(in: .whitespacesAndNewlines),
                currentTime: payload.currentTime,
                duration: payload.duration
            )
        }

        return nil
    }

    private func probeBrowserAudibleTabs(bundleID: String) -> Candidate? {
        let scriptSource: String
        switch bundleID {
        case "com.apple.Safari":
            scriptSource = safariAudibleTabsScript()
        case "com.google.Chrome":
            scriptSource = chromeAudibleTabsScript()
        default:
            return nil
        }

        guard let raw = runAppleScript(scriptSource, bundleID: bundleID), raw.isEmpty == false else { return nil }

        for line in raw.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { continue }

            let parts = trimmedLine.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }

            let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSupportedMediaURL(url) else { continue }

            return Candidate(
                url: url,
                title: title,
                currentTime: nil,
                duration: nil
            )
        }

        return nil
    }

    private func safariScript() -> String {
        #"""
tell application id "com.apple.Safari"
    if (count of windows) is 0 then return ""
    set outputLines to {}
    set previousDelimiters to AppleScript's text item delimiters
    repeat with w in windows
        try
            set tabRef to current tab of w
            set probeResult to do JavaScript "PROBE_JS" in tabRef
            if probeResult is not missing value and probeResult is not "" then
                set end of outputLines to probeResult
            end if
        end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    set joinedOutput to outputLines as string
    set AppleScript's text item delimiters to previousDelimiters
    return joinedOutput
end tell
"""#
        .replacingOccurrences(of: "PROBE_JS", with: escapedForAppleScript(probeJavaScript))
    }

    private func chromeScript() -> String {
        #"""
tell application id "com.google.Chrome"
    if (count of windows) is 0 then return ""
    set outputLines to {}
    set previousDelimiters to AppleScript's text item delimiters
    repeat with w in windows
        try
            set tabRef to active tab of w
            set probeResult to execute javascript "PROBE_JS" in tabRef
            if probeResult is not missing value and probeResult is not "" then
                set end of outputLines to probeResult
            end if
        end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    set joinedOutput to outputLines as string
    set AppleScript's text item delimiters to previousDelimiters
    return joinedOutput
end tell
"""#
        .replacingOccurrences(of: "PROBE_JS", with: escapedForAppleScript(probeJavaScript))
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

    private func chromeAudibleTabsScript() -> String {
        #"""
tell application id "com.google.Chrome"
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

    private func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    private func runAppleScript(_ source: String, bundleID: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            applyProbeCooldown(for: bundleID, errorDescription: "AppleScript init failed")
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            applyProbeCooldown(for: bundleID, errorDescription: "\(error)")
            return nil
        }
        return result.stringValue
    }

    private func applyProbeCooldown(for bundleID: String, errorDescription: String) {
        let lower = errorDescription.lowercased()
        let delay = lower.contains("fsfindfolder failed with error=-43")
            ? fsFindFolderErrorCooldown
            : genericScriptErrorCooldown
        probeCooldownUntilByBundle[bundleID] = Date().addingTimeInterval(delay)
    }

    private func escapedForAppleScript(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func isSupportedMediaURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
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
