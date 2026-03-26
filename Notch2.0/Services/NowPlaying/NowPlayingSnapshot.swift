import Foundation

struct NowPlayingSnapshot: Sendable {
    let title: String
    let artist: String
    let sourceApp: String?
    let trackIdentifier: String?
    let artworkURLString: String?
    let isPlaying: Bool
    let elapsedTime: TimeInterval?
    let duration: TimeInterval?
    let artworkData: Data?

    var progress: Float? {
        guard let elapsedTime, let duration, duration > 0 else { return nil }
        return Float(min(max(elapsedTime / duration, 0), 1))
    }
}
