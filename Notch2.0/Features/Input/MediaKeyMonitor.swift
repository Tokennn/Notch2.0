import AppKit

final class MediaKeyMonitor {
    enum MediaKey: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case keyboardBrightnessUp = 5
        case keyboardBrightnessDown = 6
        case playPause = 16
        case nextTrack = 17
        case previousTrack = 18
    }

    private let handler: (MediaKey) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(handler: @escaping (MediaKey) -> Void) {
        self.handler = handler
    }

    func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.process(event: event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.process(event: event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func process(event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }

        let data = event.data1
        let keyCode = Int((data & 0xFFFF0000) >> 16)
        let keyFlags = Int(data & 0x0000FFFF)
        let keyIsDown = ((keyFlags & 0xFF00) >> 8) == 0xA

        guard keyIsDown else { return }
        guard let key = MediaKey(rawValue: keyCode) else { return }

        handler(key)
    }
}
