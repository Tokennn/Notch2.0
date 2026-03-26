import Foundation

@MainActor
final class HUDCoordinator {
    private let windowController = HUDWindowController()
    private var hideTask: Task<Void, Never>?
    private var stickyVisible = false

    func present(
        _ payload: HUDPayload,
        style: HUDStyle,
        autoHideAfter: TimeInterval? = 1.3,
        startCollapsed: Bool = false
    ) {
        windowController.show(payload: payload, style: style, startCollapsed: startCollapsed)

        hideTask?.cancel()
        guard let autoHideAfter else {
            stickyVisible = true
            return
        }

        stickyVisible = false
        hideTask = Task { [weak self] in
            let nanoseconds = UInt64(autoHideAfter * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            self?.windowController.hide()
        }
    }

    func dismissSticky() {
        guard stickyVisible else { return }
        hideTask?.cancel()
        windowController.hide()
        stickyVisible = false
    }
}
