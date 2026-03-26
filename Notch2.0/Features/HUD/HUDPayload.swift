import Foundation
import AppKit

enum HUDStyle: String, CaseIterable, Identifiable {
    case notch
    case bubble

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notch: return "Notch"
        case .bubble: return "Bubble"
        }
    }
}

enum HUDLayout {
    case compact
    case nowPlaying
}

struct HUDPayload: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let symbol: String
    let progress: Float?
    let artwork: NSImage?
    let isPlaying: Bool?
    let layout: HUDLayout
    let canExpandFromCollapsed: Bool
    let onPrevious: (() -> Void)?
    let onPlayPause: (() -> Void)?
    let onNext: (() -> Void)?

    init(
        title: String,
        subtitle: String?,
        symbol: String,
        progress: Float?,
        artwork: NSImage? = nil,
        isPlaying: Bool? = nil,
        layout: HUDLayout = .compact,
        canExpandFromCollapsed: Bool = true,
        onPrevious: (() -> Void)? = nil,
        onPlayPause: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.progress = progress
        self.artwork = artwork
        self.isPlaying = isPlaying
        self.layout = layout
        self.canExpandFromCollapsed = canExpandFromCollapsed
        self.onPrevious = onPrevious
        self.onPlayPause = onPlayPause
        self.onNext = onNext
    }
}
