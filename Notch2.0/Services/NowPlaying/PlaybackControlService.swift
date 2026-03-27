import Foundation
import AppKit
import IOKit.hidsystem

final class PlaybackControlService {
    private enum MediaKey: Int32 {
        case playPause = 16
        case next = 17
        case previous = 18
    }

    private enum PlaybackAction {
        case playPause
        case next
        case previous
    }

    func prepareAutomationPromptIfNeeded() {
        // No-op: controls are sent as system media keys.
    }

    @discardableResult
    func togglePlayback(preferredSourceBundleID: String?) -> Bool {
        perform(.playPause, preferredSourceBundleID: preferredSourceBundleID)
    }

    @discardableResult
    func nextTrack(preferredSourceBundleID: String?) -> Bool {
        perform(.next, preferredSourceBundleID: preferredSourceBundleID)
    }

    @discardableResult
    func previousTrack(preferredSourceBundleID: String?) -> Bool {
        perform(.previous, preferredSourceBundleID: preferredSourceBundleID)
    }

    @discardableResult
    func seek(to progress: Float, preferredSourceBundleID: String?, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0 else { return false }
        let clampedProgress = min(max(progress, 0), 1)
        let targetSeconds = TimeInterval(clampedProgress) * duration

        if let preferredSourceBundleID, performDirectSeek(to: targetSeconds, bundleID: preferredSourceBundleID) {
            return true
        }

        if preferredSourceBundleID == nil {
            let spotifyRunning = isRunning(bundleID: "com.spotify.client")
            let musicRunning = isRunning(bundleID: "com.apple.Music")

            if spotifyRunning != musicRunning {
                let fallbackBundleID = spotifyRunning ? "com.spotify.client" : "com.apple.Music"
                if performDirectSeek(to: targetSeconds, bundleID: fallbackBundleID) {
                    return true
                }
            }
        }

        return false
    }

    private func perform(_ action: PlaybackAction, preferredSourceBundleID: String?) -> Bool {
        if let preferredSourceBundleID, performDirectAction(action, bundleID: preferredSourceBundleID) {
            return true
        }

        if preferredSourceBundleID == nil {
            let spotifyRunning = isRunning(bundleID: "com.spotify.client")
            let musicRunning = isRunning(bundleID: "com.apple.Music")

            if spotifyRunning != musicRunning {
                let fallbackBundleID = spotifyRunning ? "com.spotify.client" : "com.apple.Music"
                if performDirectAction(action, bundleID: fallbackBundleID) {
                    return true
                }
            }
        }

        switch action {
        case .playPause:
            return post(mediaKey: .playPause)
        case .next:
            return post(mediaKey: .next)
        case .previous:
            return post(mediaKey: .previous)
        }
    }

    private func performDirectAction(_ action: PlaybackAction, bundleID: String) -> Bool {
        switch bundleID {
        case "com.spotify.client":
            guard isRunning(bundleID: bundleID) else { return false }
            switch action {
            case .playPause:
                return runAppleScript(#"tell application id "com.spotify.client" to playpause"#)
            case .next:
                return runAppleScript(#"tell application id "com.spotify.client" to next track"#)
            case .previous:
                return runAppleScript(#"tell application id "com.spotify.client" to previous track"#)
            }
        case "com.apple.Music":
            guard isRunning(bundleID: bundleID) else { return false }
            switch action {
            case .playPause:
                return runAppleScript(#"tell application id "com.apple.Music" to if player state is playing then pause else play"#)
            case .next:
                return runAppleScript(#"tell application id "com.apple.Music" to next track"#)
            case .previous:
                return runAppleScript(#"tell application id "com.apple.Music" to previous track"#)
            }
        case "org.videolan.vlc":
            guard isRunning(bundleID: bundleID) else { return false }
            switch action {
            case .playPause:
                return runAppleScript(#"tell application id "org.videolan.vlc" to if playing then pause else play"#)
            case .next:
                return runAppleScript(#"tell application id "org.videolan.vlc" to next"#)
            case .previous:
                return runAppleScript(#"tell application id "org.videolan.vlc" to previous"#)
            }
        case "com.apple.QuickTimePlayerX":
            guard isRunning(bundleID: bundleID) else { return false }
            switch action {
            case .playPause:
                return runAppleScript(
                    #"""
                    tell application id "com.apple.QuickTimePlayerX"
                        if not (exists document 1) then return
                        tell document 1
                            if playing then
                                pause
                            else
                                play
                            end if
                        end tell
                    end tell
                    """#
                )
            case .next, .previous:
                return false
            }
        default:
            return false
        }
    }

    private func performDirectSeek(to seconds: TimeInterval, bundleID: String) -> Bool {
        guard seconds.isFinite else { return false }
        let clampedSeconds = max(0, seconds)
        let secondsLiteral = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            clampedSeconds
        )

        switch bundleID {
        case "com.spotify.client":
            guard isRunning(bundleID: bundleID) else { return false }
            return runAppleScript(#"tell application id "com.spotify.client" to set player position to \#(secondsLiteral)"#)
        case "com.apple.Music":
            guard isRunning(bundleID: bundleID) else { return false }
            return runAppleScript(#"tell application id "com.apple.Music" to set player position to \#(secondsLiteral)"#)
        case "org.videolan.vlc":
            guard isRunning(bundleID: bundleID) else { return false }
            return runAppleScript(#"tell application id "org.videolan.vlc" to set current time to \#(secondsLiteral)"#)
        case "com.apple.QuickTimePlayerX":
            guard isRunning(bundleID: bundleID) else { return false }
            return runAppleScript(
                #"""
                tell application id "com.apple.QuickTimePlayerX"
                    if not (exists document 1) then return
                    tell document 1 to set current time to \#(secondsLiteral)
                end tell
                """#
            )
        default:
            return false
        }
    }

    private func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    private func post(mediaKey: MediaKey) -> Bool {
        let keyCode = mediaKey.rawValue
        let downData1 = Int((keyCode << 16) | (0xA << 8))
        let upData1 = Int((keyCode << 16) | (0xB << 8))

        guard
            let keyDown = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: downData1,
                data2: -1
            ),
            let keyUp = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xB00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: upData1,
                data2: -1
            ),
            let downCGEvent = keyDown.cgEvent,
            let upCGEvent = keyUp.cgEvent
        else {
            return false
        }

        downCGEvent.post(tap: .cghidEventTap)
        upCGEvent.post(tap: .cghidEventTap)
        return true
    }
}
