import Foundation
import AppKit

actor ArtworkResolver {
    private struct SpotifyCurrentTrackInfo {
        let trackID: String
        let title: String
        let artist: String
        let artworkURLString: String
    }

    private struct SpotifyOEmbedResponse: Decodable {
        let thumbnail_url: String?
    }

    private struct ITunesSearchResponse: Decodable {
        struct Track: Decodable {
            let artworkUrl100: String?
            let trackName: String?
            let artistName: String?
        }

        let results: [Track]
    }

    private var cache: [String: Data] = [:]
    private var failedUntilByKey: [String: Date] = [:]
    private let retryCooldown: TimeInterval = 90
    // Disabled by default to avoid repeated AppleScript-related system errors on some Macs.
    private let spotifyScriptFallbackEnabled = UserDefaults.standard.bool(forKey: "EnableSpotifyAppleScriptArtwork")
    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac"
    ]

    func fetchArtworkData(for snapshot: NowPlayingSnapshot) async -> Data? {
        let source = snapshot.sourceApp ?? ""

        if let artworkURLString = snapshot.artworkURLString,
           artworkURLString.isEmpty == false,
           let artwork = await fetchArtworkData(fromDirectURLString: artworkURLString, cachePrefix: "snapshot-url") {
            return artwork
        }

        if source == "com.spotify.client" {
            if let artwork = await fetchStrictSpotifyArtwork(for: snapshot) {
                return artwork
            }
            // Keep a metadata fallback when Spotify endpoints fail.
            if shouldSkipITunesFallback(source: source, snapshot: snapshot) {
                return nil
            }
            return await fetchArtworkData(title: snapshot.title, artist: snapshot.artist)
        }

        // If source is unknown but Spotify is running and current track matches metadata,
        // force Spotify artwork instead of approximate iTunes matching.
        if spotifyScriptFallbackEnabled,
           let artwork = await fetchSpotifyArtworkIfSnapshotMatchesCurrentTrack(snapshot) {
            return artwork
        }

        // Avoid wrong covers for browser/video contexts or low-confidence metadata.
        if shouldSkipITunesFallback(source: source, snapshot: snapshot) {
            return nil
        }

        return await fetchArtworkData(title: snapshot.title, artist: snapshot.artist)
    }

    private func fetchStrictSpotifyArtwork(for snapshot: NowPlayingSnapshot) async -> Data? {
        if let rawTrackID = snapshot.trackIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           rawTrackID.isEmpty == false,
           let trackID = spotifyTrackID(from: rawTrackID),
           isCoolingDown("spotify|\(trackID.lowercased())") == false,
           let artwork = await fetchSpotifyArtworkData(trackID: trackID) {
            return artwork
        }

        if let artworkURLString = snapshot.artworkURLString,
           artworkURLString.isEmpty == false,
           let artwork = await fetchArtworkData(fromDirectURLString: artworkURLString, cachePrefix: "spotify-url") {
            return artwork
        }

        if spotifyScriptFallbackEnabled {
            if let artwork = await fetchSpotifyArtworkDataFromCurrentTrackScript() {
                return artwork
            }

            if let artwork = await fetchSpotifyArtworkIfSnapshotMatchesCurrentTrack(snapshot) {
                return artwork
            }
        }

        return nil
    }

    private func fetchSpotifyArtworkIfSnapshotMatchesCurrentTrack(_ snapshot: NowPlayingSnapshot) async -> Data? {
        guard let info = await readSpotifyCurrentTrackInfo() else { return nil }

        let snapshotTitle = normalized(snapshot.title)
        let snapshotArtist = normalized(snapshot.artist)
        let spotifyTitle = normalized(info.title)
        let spotifyArtist = normalized(info.artist)

        guard snapshotTitle.isEmpty == false, spotifyTitle.isEmpty == false else { return nil }
        guard snapshotTitle == spotifyTitle else { return nil }

        if snapshotArtist.isEmpty == false, spotifyArtist.isEmpty == false, snapshotArtist != spotifyArtist {
            return nil
        }

        if info.trackID.isEmpty == false,
           let trackID = spotifyTrackID(from: info.trackID),
           let artwork = await fetchSpotifyArtworkData(trackID: trackID) {
            return artwork
        }

        if info.artworkURLString.isEmpty == false,
           let artwork = await fetchArtworkData(fromDirectURLString: info.artworkURLString, cachePrefix: "spotify-url") {
            return artwork
        }

        return nil
    }

    private func shouldSkipITunesFallback(source: String, snapshot: NowPlayingSnapshot) -> Bool {
        let trimmedArtist = snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return true
        }

        if browserBundleIDs.contains(source) {
            return true
        }

        let lowerTitle = trimmedTitle.lowercased()
        if lowerTitle.contains("youtube")
            || lowerTitle.contains("netflix")
            || lowerTitle.contains("prime video")
            || lowerTitle.contains("twitch")
            || lowerTitle.contains("vimeo") {
            return true
        }

        // iTunes matching without artist causes many wrong hits.
        if trimmedArtist.isEmpty {
            return true
        }

        return false
    }

    private func fetchArtworkData(fromDirectURLString urlString: String, cachePrefix: String) async -> Data? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let url = URL(string: trimmed) else {
            return nil
        }

        let cacheKey = "\(cachePrefix)|\(url.absoluteString)"
        if isCoolingDown(cacheKey) {
            return nil
        }
        if let cached = cache[cacheKey] {
            return cached
        }

        do {
            let (artworkData, _) = try await URLSession.shared.data(from: url)
            guard artworkData.isEmpty == false else {
                markFailed(cacheKey)
                return nil
            }
            cache[cacheKey] = artworkData
            return artworkData
        } catch {
            markFailed(cacheKey)
            return nil
        }
    }

    func fetchArtworkData(title: String, artist: String) async -> Data? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.isEmpty { return nil }

        let key = "\(normalizedTitle.lowercased())|\(artist.lowercased())"
        if isCoolingDown(key) {
            return nil
        }
        if let cached = cache[key] {
            return cached
        }

        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        let term = [normalizedTitle, artist].filter { $0.isEmpty == false }.joined(separator: " ")
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "20")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            guard let bestTrack = bestMatch(in: response.results, title: normalizedTitle, artist: artist),
                  let rawArtworkURL = bestTrack.artworkUrl100,
                  rawArtworkURL.isEmpty == false else {
                markFailed(key)
                return nil
            }

            let hiResURLString = rawArtworkURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artworkURL = URL(string: hiResURLString) else { return nil }

            let (artworkData, _) = try await URLSession.shared.data(from: artworkURL)
            guard artworkData.isEmpty == false else { return nil }

            cache[key] = artworkData
            return artworkData
        } catch {
            markFailed(key)
            return nil
        }
    }

    private func bestMatch(in tracks: [ITunesSearchResponse.Track], title: String, artist: String) -> ITunesSearchResponse.Track? {
        let normalizedTitle = normalized(title)
        let normalizedArtist = normalized(artist)

        var bestTrack: ITunesSearchResponse.Track?
        var bestScore = -1.0

        for track in tracks {
            let candidateTitle = normalized(track.trackName ?? "")
            let candidateArtist = normalized(track.artistName ?? "")

            var score = 0.0

            if candidateTitle == normalizedTitle {
                score += 5
            } else if candidateTitle.contains(normalizedTitle) || normalizedTitle.contains(candidateTitle) {
                score += 2.5
            }

            if normalizedArtist.isEmpty == false {
                if candidateArtist == normalizedArtist {
                    score += 5
                } else if candidateArtist.contains(normalizedArtist) || normalizedArtist.contains(candidateArtist) {
                    score += 2.5
                }
            } else if candidateArtist.isEmpty == false {
                score += 0.5
            }

            if score > bestScore {
                bestScore = score
                bestTrack = track
            }
        }

        guard bestScore >= 4 else { return nil }
        return bestTrack
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchSpotifyArtworkData(trackID: String) async -> Data? {
        let resolvedTrackID = spotifyTrackID(from: trackID) ?? trackID
        let normalized = resolvedTrackID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return nil }

        let cacheKey = "spotify|\(normalized)"
        if isCoolingDown(cacheKey) {
            return nil
        }
        if let cached = cache[cacheKey] {
            return cached
        }

        guard var oembedComponents = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        oembedComponents.queryItems = [
            URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(normalized)")
        ]

        guard let oembedURL = oembedComponents.url else { return nil }

        do {
            let (oembedData, _) = try await URLSession.shared.data(from: oembedURL)
            let response = try JSONDecoder().decode(SpotifyOEmbedResponse.self, from: oembedData)

            guard let thumbnailURLString = response.thumbnail_url,
                  thumbnailURLString.isEmpty == false,
                  let thumbnailURL = URL(string: thumbnailURLString) else {
                markFailed(cacheKey)
                return nil
            }

            let (artworkData, _) = try await URLSession.shared.data(from: thumbnailURL)
            guard artworkData.isEmpty == false else { return nil }

            cache[cacheKey] = artworkData
            return artworkData
        } catch {
            markFailed(cacheKey)
            return nil
        }
    }

    private func fetchSpotifyArtworkDataFromCurrentTrackScript() async -> Data? {
        guard let info = await readSpotifyCurrentTrackInfo() else {
            return nil
        }

        if info.trackID.isEmpty == false,
           let trackID = spotifyTrackID(from: info.trackID),
           let artworkData = await fetchSpotifyArtworkData(trackID: trackID) {
            return artworkData
        }

        guard info.artworkURLString.isEmpty == false else { return nil }
        return await fetchArtworkData(fromDirectURLString: info.artworkURLString, cachePrefix: "spotify-url")
    }

    @MainActor
    private func isSpotifyRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty == false
    }

    @MainActor
    private func appleScriptString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }

    @MainActor
    private func readSpotifyCurrentTrackInfo() -> SpotifyCurrentTrackInfo? {
        guard isSpotifyRunning() else { return nil }

        let response = appleScriptString(
            """
            tell application id "com.spotify.client"
                if player state is stopped then return ""
                set trackID to id of current track
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackArtworkURL to artwork url of current track
                return trackID & "|||" & trackName & "|||" & trackArtist & "|||" & trackArtworkURL
            end tell
            """
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard response.isEmpty == false else { return nil }
        let parts = response.components(separatedBy: "|||")
        guard parts.count >= 4 else { return nil }

        return SpotifyCurrentTrackInfo(
            trackID: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
            title: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
            artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            artworkURLString: parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func spotifyTrackID(from rawIdentifier: String) -> String? {
        let raw = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func isCoolingDown(_ key: String) -> Bool {
        guard let retryAt = failedUntilByKey[key] else { return false }
        if retryAt <= Date() {
            failedUntilByKey.removeValue(forKey: key)
            return false
        }
        return true
    }

    private func markFailed(_ key: String) {
        failedUntilByKey[key] = Date().addingTimeInterval(retryCooldown)
    }
}
