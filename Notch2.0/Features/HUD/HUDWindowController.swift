import AppKit
import SwiftUI

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDWindowController {
    private var hostingView: NSHostingView<HUDView>?
    private var currentPayload: HUDPayload?
    private var currentStyle: HUDStyle = .notch
    private var currentLayout: HUDLayout?

    private var isNowPlayingCollapsed = false
    private var shouldRunEntryBounce = false
    private var collapseTask: DispatchWorkItem?
    private var lastNowPlayingSignature: String?
    private let autoCollapseDelay: TimeInterval = 3
    private let autoCollapseHoverRetryDelay: TimeInterval = 0.35

    private let nowPlayingCanvasSize = NSSize(width: 376, height: 98)
    private let nowPlayingInteractiveCardSize = NSSize(width: 324, height: 76)
    private let collapsedHandleInteractiveSize = NSSize(width: 110, height: 18)
    private var mouseInterceptionTimer: Timer?

    private let panel: HUDPanel = {
        let panel = HUDPanel(
            contentRect: .init(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.alphaValue = 0
        return panel
    }()

    private var isVisible = false

    func show(payload: HUDPayload, style: HUDStyle, startCollapsed: Bool = false) {
        let previousPayload = currentPayload
        let previousLayout = currentLayout

        currentPayload = payload
        currentStyle = style
        currentLayout = payload.layout

        let targetSize: NSSize
        switch payload.layout {
        case .compact:
            targetSize = style == .notch ? NSSize(width: 420, height: 124) : NSSize(width: 340, height: 112)
            resetNowPlayingRuntime()
        case .nowPlaying:
            targetSize = nowPlayingCanvasSize
            handleNowPlayingLifecycle(
                payload: payload,
                previousPayload: previousPayload,
                previousLayout: previousLayout,
                startCollapsed: startCollapsed
            )
        }

        panel.setContentSize(targetSize)
        panel.hasShadow = false

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = frameOnTopCenter(on: screen, size: targetSize, layout: payload.layout)
        panel.setFrame(frame, display: true)

        updateRootView()
        refreshMouseInterceptionPolicy()
        shouldRunEntryBounce = false

        if !isVisible {
            if payload.layout == .nowPlaying {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            panel.animator().alphaValue = 1
            isVisible = true
        } else {
            if payload.layout == .nowPlaying, panel.isKeyWindow == false {
                panel.makeKey()
            }
            panel.alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }

        cancelCollapseTask()
        stopMouseInterceptionTimer()
        panel.ignoresMouseEvents = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel.orderOut(nil)
                self?.resetNowPlayingRuntime()
                self?.isVisible = false
            }
        }
    }

    private func handleNowPlayingLifecycle(
        payload: HUDPayload,
        previousPayload: HUDPayload?,
        previousLayout: HUDLayout?,
        startCollapsed: Bool
    ) {
        if startCollapsed {
            isNowPlayingCollapsed = true
            shouldRunEntryBounce = false
            cancelCollapseTask()
            lastNowPlayingSignature = nowPlayingSignature(for: payload)
            return
        }

        let signature = nowPlayingSignature(for: payload)
        let isFirstNowPlaying = previousLayout != .nowPlaying
        let didTrackChange = signature != lastNowPlayingSignature
        let becamePlaying = (previousPayload?.isPlaying ?? false) == false && (payload.isPlaying ?? false)

        if isFirstNowPlaying || didTrackChange || becamePlaying {
            isNowPlayingCollapsed = false
            shouldRunEntryBounce = true
            scheduleAutoCollapse()
        }

        lastNowPlayingSignature = signature
    }

    private func nowPlayingSignature(for payload: HUDPayload) -> String {
        [
            payload.title,
            payload.subtitle ?? "",
            payload.isPlaying == true ? "1" : "0"
        ].joined(separator: "|")
    }

    private func updateRootView() {
        guard let payload = currentPayload else { return }

        let rootView = HUDView(
            payload: payload,
            style: currentStyle,
            isNowPlayingCollapsed: payload.layout == .nowPlaying && isNowPlayingCollapsed,
            shouldRunEntryBounce: shouldRunEntryBounce,
            onCollapsedHandleHover: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reopenFromCollapsedIfNeeded()
                }
            },
            onNowPlayingDoubleClick: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.collapseFromDoubleClickIfNeeded()
                }
            }
        )

        if let hostingView {
            hostingView.rootView = rootView
            return
        }

        let newHostingView = NSHostingView(rootView: rootView)
        newHostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        newHostingView.autoresizingMask = [.width, .height]
        newHostingView.wantsLayer = true
        newHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        newHostingView.layer?.masksToBounds = false
        panel.contentView = newHostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.masksToBounds = false
        hostingView = newHostingView
    }

    private func reopenFromCollapsedIfNeeded() {
        guard currentLayout == .nowPlaying else { return }
        guard isNowPlayingCollapsed else { return }
        guard currentPayload?.canExpandFromCollapsed != false else { return }

        isNowPlayingCollapsed = false
        shouldRunEntryBounce = true
        updateRootView()
        shouldRunEntryBounce = false
        refreshMouseInterceptionPolicy()
        scheduleAutoCollapse()
    }

    private func collapseFromDoubleClickIfNeeded() {
        guard currentLayout == .nowPlaying else { return }
        guard isNowPlayingCollapsed == false else { return }

        isNowPlayingCollapsed = true
        shouldRunEntryBounce = false
        updateRootView()
        refreshMouseInterceptionPolicy()
        cancelCollapseTask()
    }

    private func scheduleAutoCollapse() {
        scheduleAutoCollapse(after: autoCollapseDelay)
    }

    private func scheduleAutoCollapse(after delay: TimeInterval) {
        cancelCollapseTask()

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentLayout == .nowPlaying else { return }
            guard self.isNowPlayingCollapsed == false else { return }

            if self.isMouseOverExpandedNowPlayingArea() {
                self.scheduleAutoCollapse(after: self.autoCollapseHoverRetryDelay)
                return
            }

            self.isNowPlayingCollapsed = true
            self.updateRootView()
            self.refreshMouseInterceptionPolicy()
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func cancelCollapseTask() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func resetNowPlayingRuntime() {
        isNowPlayingCollapsed = false
        shouldRunEntryBounce = false
        lastNowPlayingSignature = nil
        cancelCollapseTask()
    }

    private func refreshMouseInterceptionPolicy() {
        guard currentLayout == .nowPlaying else {
            stopMouseInterceptionTimer()
            panel.ignoresMouseEvents = true
            return
        }

        if isNowPlayingCollapsed, currentPayload?.canExpandFromCollapsed == false {
            stopMouseInterceptionTimer()
            panel.ignoresMouseEvents = true
            return
        }

        startMouseInterceptionTimerIfNeeded()
        updateMouseInterception()
    }

    private func startMouseInterceptionTimerIfNeeded() {
        guard mouseInterceptionTimer == nil else { return }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMouseInterception()
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseInterceptionTimer = timer
    }

    private func stopMouseInterceptionTimer() {
        mouseInterceptionTimer?.invalidate()
        mouseInterceptionTimer = nil
    }

    private func updateMouseInterception() {
        guard currentLayout == .nowPlaying else {
            panel.ignoresMouseEvents = true
            return
        }

        if isNowPlayingCollapsed, currentPayload?.canExpandFromCollapsed == false {
            panel.ignoresMouseEvents = true
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        panel.ignoresMouseEvents = interactiveFrameForNowPlaying().contains(mouseLocation) == false
    }

    private func interactiveFrameForNowPlaying() -> NSRect {
        if isNowPlayingCollapsed {
            return NSRect(
                x: panel.frame.midX - (collapsedHandleInteractiveSize.width / 2),
                y: panel.frame.maxY - collapsedHandleInteractiveSize.height - 2,
                width: collapsedHandleInteractiveSize.width,
                height: collapsedHandleInteractiveSize.height
            )
        }

        return NSRect(
            x: panel.frame.midX - (nowPlayingInteractiveCardSize.width / 2),
            y: panel.frame.maxY - nowPlayingInteractiveCardSize.height - 4,
            width: nowPlayingInteractiveCardSize.width,
            height: nowPlayingInteractiveCardSize.height
        )
    }

    private func isMouseOverExpandedNowPlayingArea() -> Bool {
        guard currentLayout == .nowPlaying else { return false }
        guard isNowPlayingCollapsed == false else { return false }

        let expandedFrame = NSRect(
            x: panel.frame.midX - (nowPlayingInteractiveCardSize.width / 2),
            y: panel.frame.maxY - nowPlayingInteractiveCardSize.height - 4,
            width: nowPlayingInteractiveCardSize.width,
            height: nowPlayingInteractiveCardSize.height
        )
        return expandedFrame.contains(NSEvent.mouseLocation)
    }

    private func frameOnTopCenter(on screen: NSScreen, size: NSSize, layout: HUDLayout) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = screen.frame.maxY - visibleFrame.maxY
        let x = visibleFrame.midX - size.width / 2

        let y: CGFloat
        switch layout {
        case .compact:
            y = visibleFrame.maxY - size.height - 4
        case .nowPlaying:
            y = visibleFrame.maxY - size.height + menuBarHeight + 6
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
