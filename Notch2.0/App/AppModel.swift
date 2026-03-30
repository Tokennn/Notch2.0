import SwiftUI
import Combine
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var isEnabled: Bool = true {
        didSet { refreshRuntime() }
    }

    @Published var nowPlayingEnabled: Bool = true {
        didSet { refreshRuntime() }
    }

    @Published var webPlayerDetectionEnabled: Bool = {
        let defaults = UserDefaults.standard
        if let storedValue = defaults.object(forKey: "EnableWebPlayerDetection") as? Bool {
            return storedValue
        }

        return true
    }() {
        didSet {
            UserDefaults.standard.set(webPlayerDetectionEnabled, forKey: "EnableWebPlayerDetection")
            refreshRuntime()
        }
    }

    private let hudCoordinator = HUDCoordinator()
    private let nowPlayingService = NowPlayingService()
    private let playbackControlService = PlaybackControlService()
    private let artworkResolver = ArtworkResolver()

    private var activeTrackKey: String?
    private var artworkRequestsInFlight: Set<String> = []
    private var artworkByTrackKey: [String: Data] = [:]
    private var latestSnapshot: NowPlayingSnapshot?
    private var startupIdleFallbackTask: DispatchWorkItem?
    private var shouldDeferIdleNotchPresentation = false
    private let startupIdleFallbackDelay: TimeInterval = 0.55

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "EnableWebPlayerDetection": true,
            "EnableSystemNowPlayingCenter": true
        ])
        if defaults.object(forKey: "EnableWebPlayerDetection") == nil {
            defaults.set(true, forKey: "EnableWebPlayerDetection")
        }
        if defaults.object(forKey: "EnableSystemNowPlayingCenter") == nil {
            defaults.set(true, forKey: "EnableSystemNowPlayingCenter")
        }
        refreshRuntime()
    }

    private func refreshRuntime() {
        if isEnabled && nowPlayingEnabled {
            playbackControlService.prepareAutomationPromptIfNeeded()
            nowPlayingService.start { [weak self] snapshot in
                Task { @MainActor in
                    self?.handle(nowPlaying: snapshot)
                }
            }
            beginStartupIdleNotchDeferral()
        } else {
            nowPlayingService.stop()
            hudCoordinator.dismissSticky()
            activeTrackKey = nil
            latestSnapshot = nil
            artworkRequestsInFlight.removeAll()
            artworkByTrackKey.removeAll()
            cancelStartupIdleNotchDeferral()
        }
    }

    private func handle(nowPlaying snapshot: NowPlayingSnapshot?) {
        guard isEnabled && nowPlayingEnabled else { return }

        guard let snapshot else {
            latestSnapshot = nil
            activeTrackKey = nil
            guard shouldDeferIdleNotchPresentation == false else { return }
            presentIdleCollapsedNotchIfNeeded()
            return
        }

        if looksLikeSystemErrorMessage(snapshot.title) || looksLikeSystemErrorMessage(snapshot.artist) {
            return
        }

        cancelStartupIdleNotchDeferral()

        latestSnapshot = snapshot

        let trackKey = makeTrackKey(for: snapshot)
        activeTrackKey = trackKey

        if let incomingArtwork = snapshot.artworkData {
            artworkByTrackKey[trackKey] = incomingArtwork
        }

        let resolvedArtworkData = snapshot.artworkData ?? artworkByTrackKey[trackKey]
        presentNowPlaying(snapshot: snapshot, overrideArtworkData: resolvedArtworkData)

        if resolvedArtworkData == nil,
           artworkRequestsInFlight.contains(trackKey) == false {
            artworkRequestsInFlight.insert(trackKey)

            Task { @MainActor [weak self] in
                guard let self else { return }
                let fetched = await self.artworkResolver.fetchArtworkData(for: snapshot)

                self.artworkRequestsInFlight.remove(trackKey)
                guard self.activeTrackKey == trackKey else { return }
                guard let latest = self.latestSnapshot else { return }
                guard let fetched else { return }
                self.artworkByTrackKey[trackKey] = fetched
                self.presentNowPlaying(snapshot: latest, overrideArtworkData: fetched)
            }
        }
    }

    private func presentNowPlaying(snapshot: NowPlayingSnapshot, overrideArtworkData: Data?) {
        let artist = snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle: String?
        if artist.isEmpty == false {
            subtitle = artist
        } else {
            subtitle = sourceName(from: snapshot.sourceApp)
        }

        let payload = HUDPayload(
            title: snapshot.title,
            subtitle: subtitle,
            symbol: "music.note",
            progress: snapshot.progress,
            artwork: overrideArtworkData.flatMap { NSImage(data: $0) },
            isPlaying: snapshot.isPlaying,
            layout: .nowPlaying,
            canExpandFromCollapsed: true,
            onPrevious: { [weak self] in
                self?.goToPreviousTrack()
            },
            onPlayPause: { [weak self] in
                self?.togglePlayPause()
            },
            onNext: { [weak self] in
                self?.goToNextTrack()
            },
            onSeek: { [weak self] progress in
                self?.seekTo(progress: progress)
            }
        )

        // Keep now-playing visible (collapsed after delay in HUDWindowController),
        // even when paused, so users can reopen and inspect the current track.
        hudCoordinator.present(payload, style: .notch, autoHideAfter: nil)
    }

    private func togglePlayPause() {
        guard let current = latestSnapshot else { return }
        let didToggle = playbackControlService.togglePlayback(preferredSourceBundleID: current.sourceApp)
        guard didToggle else { return }

        let toggled = NowPlayingSnapshot(
            title: current.title,
            artist: current.artist,
            sourceApp: current.sourceApp,
            trackIdentifier: current.trackIdentifier,
            artworkURLString: current.artworkURLString,
            isPlaying: !current.isPlaying,
            elapsedTime: current.elapsedTime,
            duration: current.duration,
            artworkData: current.artworkData
        )

        latestSnapshot = toggled
        let trackKey = makeTrackKey(for: toggled)
        let resolvedArtworkData = toggled.artworkData ?? artworkByTrackKey[trackKey]
        presentNowPlaying(snapshot: toggled, overrideArtworkData: resolvedArtworkData)
    }

    private func goToNextTrack() {
        guard let current = latestSnapshot else { return }
        _ = playbackControlService.nextTrack(preferredSourceBundleID: current.sourceApp)
    }

    private func goToPreviousTrack() {
        guard let current = latestSnapshot else { return }
        _ = playbackControlService.previousTrack(preferredSourceBundleID: current.sourceApp)
    }

    private func seekTo(progress: Float) {
        guard let current = latestSnapshot else { return }
        guard let duration = current.duration, duration > 0 else { return }

        let clampedProgress = min(max(progress, 0), 1)
        let didSeek = playbackControlService.seek(
            to: clampedProgress,
            preferredSourceBundleID: current.sourceApp,
            duration: duration
        )
        guard didSeek else { return }

        let updatedElapsed = TimeInterval(clampedProgress) * duration
        let updated = NowPlayingSnapshot(
            title: current.title,
            artist: current.artist,
            sourceApp: current.sourceApp,
            trackIdentifier: current.trackIdentifier,
            artworkURLString: current.artworkURLString,
            isPlaying: current.isPlaying,
            elapsedTime: updatedElapsed,
            duration: current.duration,
            artworkData: current.artworkData
        )

        latestSnapshot = updated
        nowPlayingService.applyLocalSnapshotOverride(updated)
        let trackKey = makeTrackKey(for: updated)
        let resolvedArtworkData = updated.artworkData ?? artworkByTrackKey[trackKey]
        presentNowPlaying(snapshot: updated, overrideArtworkData: resolvedArtworkData)
    }

    private func makeTrackKey(for snapshot: NowPlayingSnapshot) -> String {
        if let trackIdentifier = snapshot.trackIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           trackIdentifier.isEmpty == false {
            return "\(snapshot.sourceApp ?? "")|\(trackIdentifier.lowercased())"
        }

        return [
            snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
    }

    private func sourceName(from bundleID: String?) -> String? {
        guard let bundleID, bundleID.isEmpty == false else { return nil }

        switch bundleID {
        case "com.spotify.client":
            return "Spotify"
        case "org.videolan.vlc":
            return "VLC"
        case "com.apple.QuickTimePlayerX":
            return "QuickTime Player"
        case "com.apple.Safari":
            return "Safari"
        case "com.google.Chrome":
            return "Chrome"
        case "com.brave.Browser":
            return "Brave"
        case "com.microsoft.edgemac":
            return "Edge"
        case "company.thebrowser.Browser":
            return "Arc"
        case "org.mozilla.firefox":
            return "Firefox"
        default:
            return nil
        }
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

    private func presentIdleCollapsedNotchIfNeeded() {
        guard isEnabled && nowPlayingEnabled else { return }

        let payload = HUDPayload(
            title: "Notch",
            subtitle: nil,
            symbol: "music.note",
            progress: nil,
            artwork: nil,
            isPlaying: false,
            layout: .nowPlaying,
            canExpandFromCollapsed: false,
            onPrevious: nil,
            onPlayPause: nil,
            onNext: nil
        )

        hudCoordinator.present(
            payload,
            style: .notch,
            autoHideAfter: nil,
            startCollapsed: true
        )
    }

    private func beginStartupIdleNotchDeferral() {
        cancelStartupIdleNotchDeferral()
        shouldDeferIdleNotchPresentation = true

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.shouldDeferIdleNotchPresentation = false
            guard self.latestSnapshot == nil else { return }
            self.presentIdleCollapsedNotchIfNeeded()
        }

        startupIdleFallbackTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + startupIdleFallbackDelay, execute: task)
    }

    private func cancelStartupIdleNotchDeferral() {
        startupIdleFallbackTask?.cancel()
        startupIdleFallbackTask = nil
        shouldDeferIdleNotchPresentation = false
    }
}
