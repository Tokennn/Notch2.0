import SwiftUI

struct HUDView: View {
    let payload: HUDPayload
    let style: HUDStyle
    let isNowPlayingCollapsed: Bool
    let shouldRunEntryBounce: Bool
    let onCollapsedHandleHover: (() -> Void)?
    let onNowPlayingDoubleClick: (() -> Void)?

    @ObservedObject private var audioSpectrum = AudioSpectrumService.shared

    @State private var collapseProgress: CGFloat = 0
    @State private var entryScaleX: CGFloat = 1
    @State private var entryScaleY: CGFloat = 1
    @State private var entryOffsetY: CGFloat = 0
    @State private var collapsedEntryScaleX: CGFloat = 1
    @State private var collapsedEntryScaleY: CGFloat = 1
    @State private var collapsedEntryOffsetY: CGFloat = 0
    @State private var tapScale: CGFloat = 1
    @State private var tapOffsetY: CGFloat = 0
    @State private var timelineDragProgress: CGFloat?
    @State private var isTimelineHovered = false
    @State private var isTimelineDragging = false
    @State private var artworkSpinAngle: Double = 0
    @State private var isArtworkSpinning = false

    private let nowPlayingCardSize = CGSize(width: 300, height: 62)
    private let nowPlayingCanvasSize = CGSize(width: 376, height: 98)
    private let collapsedHandleSize = CGSize(width: 86, height: 8)
    private let notchTopCornerRadius: CGFloat = 14
    private let notchTopCornerConcavity: CGFloat = 52
    private let notchBottomCornerRadius: CGFloat = 22

    var body: some View {
        Group {
            switch payload.layout {
            case .compact:
                compactView
            case .nowPlaying:
                nowPlayingView
            }
        }
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: payload.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let subtitle = payload.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }

            if let progress = payload.progress {
                ProgressView(value: Double(progress))
                    .tint(.white)
                    .scaleEffect(x: 1, y: 1.2, anchor: .center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(.black.opacity(style == .notch ? 0.82 : 0.72))
                .overlay(.ultraThinMaterial.opacity(style == .notch ? 0.25 : 0.2))
        )
        .overlay(compactBorder)
        .clipShape(
            NotchCardShape(
                topInsetRadius: style == .notch ? notchTopCornerRadius : 18,
                bottomCornerRadius: style == .notch ? notchBottomCornerRadius : 18,
                topCornerConcavity: style == .notch ? notchTopCornerConcavity : 0
            )
        )
    }

    private var compactBorder: some View {
        NotchCardShape(
            topInsetRadius: style == .notch ? notchTopCornerRadius : 18,
            bottomCornerRadius: style == .notch ? notchBottomCornerRadius : 18,
            topCornerConcavity: style == .notch ? notchTopCornerConcavity : 0
        )
        .stroke(.white.opacity(0.12), lineWidth: 1)
    }

    private var nowPlayingView: some View {
        ZStack(alignment: .top) {
            nowPlayingCard
                .scaleEffect(
                    x: max(0.72, (1 - (collapseProgress * 0.28)) * entryScaleX * tapScale),
                    y: max(0.12, (1 - (collapseProgress * 0.86)) * entryScaleY * tapScale),
                    anchor: .top
                )
                .offset(y: entryOffsetY + tapOffsetY - (collapseProgress * 18))
                .opacity(Double(1 - collapseProgress))
                .allowsHitTesting(collapseProgress < 0.82)

            collapsedHandle
                .opacity(Double(collapseProgress))
                .scaleEffect(
                    x: (0.9 + (collapseProgress * 0.1)) * collapsedEntryScaleX,
                    y: (0.62 + (collapseProgress * 0.38)) * collapsedEntryScaleY,
                    anchor: .top
                )
                .offset(y: ((1 - collapseProgress) * -8) + collapsedEntryOffsetY)
                .allowsHitTesting(collapseProgress > 0.92)
                .onHover { hovering in
                    guard hovering else { return }
                    onCollapsedHandleHover?()
                }
        }
        .frame(width: nowPlayingCanvasSize.width, height: nowPlayingCanvasSize.height, alignment: .top)
        .background(Color.clear)
        .onAppear {
            collapseProgress = isNowPlayingCollapsed ? 1 : 0
            entryScaleX = 1
            entryScaleY = 1
            entryOffsetY = 0
            collapsedEntryScaleX = 1
            collapsedEntryScaleY = 1
            collapsedEntryOffsetY = 0
            artworkSpinAngle = 0
            isArtworkSpinning = false

            if shouldRunEntryBounce == false {
                return
            }

            if isNowPlayingCollapsed {
                runCollapsedEntryBounce()
            } else {
                runEntryBounce()
            }
        }
        .onChange(of: isNowPlayingCollapsed) { _, collapsed in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.10)) {
                collapseProgress = collapsed ? 1 : 0
            }
        }
        .onChange(of: shouldRunEntryBounce) { _, value in
            guard value else { return }
            if isNowPlayingCollapsed {
                runCollapsedEntryBounce()
            } else {
                runEntryBounce()
            }
        }
    }

    private var collapsedHandle: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.black.opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .frame(width: collapsedHandleSize.width, height: collapsedHandleSize.height)
            .padding(.top, 1)
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 10) {
            artworkView

            VStack(alignment: .leading, spacing: 3) {
                Text(payload.title)
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)

                if let subtitle = payload.subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.system(size: 9.2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                NowPlayingMiniSpectrumView(
                    isPlaying: payload.isPlaying ?? false,
                    seedText: payload.title + "|" + (payload.subtitle ?? ""),
                    progress: payload.progress,
                    liveBands: audioSpectrum.bands,
                    hasLiveAudio: audioSpectrum.hasLiveAudio
                )
                .padding(.top, 1)

                timelineView
            }
            .layoutPriority(1)

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                Button(action: { payload.onPrevious?() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: { payload.onPlayPause?() }) {
                    Image(systemName: (payload.isPlaying ?? false) ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: { payload.onNext?() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: nowPlayingCardSize.width, height: nowPlayingCardSize.height)
        .background(
            NotchCardShape(topInsetRadius: 14, bottomCornerRadius: 16, topCornerConcavity: 52)
                .fill(.black)
                .overlay(
                    NotchCardShape(topInsetRadius: 14, bottomCornerRadius: 16, topCornerConcavity: 52)
                        .stroke(.white.opacity(0.11), lineWidth: 1)
                )
        )
        .simultaneousGesture(
            TapGesture().onEnded { _ in
                runTapBounce()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { _ in
                onNowPlayingDoubleClick?()
            }
        )
    }

    private var timelineView: some View {
        GeometryReader { proxy in
            let progress = effectiveTimelineProgress
            let width = max(6, proxy.size.width * progress)
            let isTimelineInteractive = isTimelineHovered || isTimelineDragging
            let trackCornerRadius: CGFloat = isTimelineInteractive ? 2.6 : 2.0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackCornerRadius, style: .continuous)
                    .fill(Color(white: 0.36).opacity(0.78))
                RoundedRectangle(cornerRadius: trackCornerRadius, style: .continuous)
                    .fill(Color(white: 0.82))
                    .frame(width: width)
                Circle()
                    .fill(Color(white: 0.92))
                    .frame(width: isTimelineInteractive ? 8 : 0, height: isTimelineInteractive ? 8 : 0)
                    .offset(x: max(0, width - (isTimelineInteractive ? 4 : 0)))
                    .opacity(isTimelineInteractive ? 1 : 0)
            }
            .frame(height: isTimelineInteractive ? 6 : 4)
            .shadow(color: .black.opacity(isTimelineInteractive ? 0.26 : 0), radius: isTimelineInteractive ? 4 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.22, dampingFraction: 0.80), value: isTimelineInteractive)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard payload.onSeek != nil else { return }
                        isTimelineDragging = true
                        isTimelineHovered = true
                        let progress = normalizedTimelineProgress(
                            x: value.location.x,
                            width: proxy.size.width
                        )
                        timelineDragProgress = progress
                    }
                    .onEnded { value in
                        defer {
                            timelineDragProgress = nil
                            isTimelineDragging = false
                        }
                        guard let onSeek = payload.onSeek else { return }
                        let progress = normalizedTimelineProgress(
                            x: value.location.x,
                            width: proxy.size.width
                        )
                        onSeek(Float(progress))
                    }
            )
            .onHover { hovering in
                isTimelineHovered = hovering
            }
        }
        .frame(height: 12)
    }

    private var effectiveTimelineProgress: CGFloat {
        if let timelineDragProgress {
            return min(max(timelineDragProgress, 0), 1)
        }

        return CGFloat(min(max(payload.progress ?? 0, 0), 1))
    }

    private func normalizedTimelineProgress(x: CGFloat, width: CGFloat) -> CGFloat {
        let safeWidth = max(width, 1)
        return min(max(x / safeWidth, 0), 1)
    }

    private var artworkView: some View {
        Group {
            if let artwork = payload.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [.pink.opacity(0.85), .orange.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Image(systemName: payload.symbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    )
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .rotation3DEffect(
            .degrees(artworkSpinAngle),
            axis: (x: 0.18, y: 1, z: 0),
            anchor: .center,
            perspective: 0.75
        )
        .scaleEffect(isArtworkSpinning ? 1.06 : 1)
        .shadow(
            color: .black.opacity(isArtworkSpinning ? 0.36 : 0.20),
            radius: isArtworkSpinning ? 10 : 4,
            x: 0,
            y: isArtworkSpinning ? 6 : 2
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isArtworkSpinning)
        .onTapGesture {
            runArtworkSpin()
        }
    }

    private func runEntryBounce() {
        entryScaleX = 0.90
        entryScaleY = 1.16
        entryOffsetY = -14

        withAnimation(.spring(response: 0.34, dampingFraction: 0.54, blendDuration: 0.12)) {
            entryScaleX = 1.05
            entryScaleY = 0.94
            entryOffsetY = 6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.68, blendDuration: 0.08)) {
                entryScaleX = 0.985
                entryScaleY = 1.03
                entryOffsetY = -1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.06)) {
                entryScaleX = 1
                entryScaleY = 1
                entryOffsetY = 0
            }
        }
    }

    private func runCollapsedEntryBounce() {
        collapsedEntryScaleX = 0.86
        collapsedEntryScaleY = 1.20
        collapsedEntryOffsetY = -11

        withAnimation(.spring(response: 0.30, dampingFraction: 0.56, blendDuration: 0.12)) {
            collapsedEntryScaleX = 1.04
            collapsedEntryScaleY = 0.95
            collapsedEntryOffsetY = 2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.67, blendDuration: 0.08)) {
                collapsedEntryScaleX = 0.99
                collapsedEntryScaleY = 1.02
                collapsedEntryOffsetY = -1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.06)) {
                collapsedEntryScaleX = 1
                collapsedEntryScaleY = 1
                collapsedEntryOffsetY = 0
            }
        }
    }

    private func runTapBounce() {
        withAnimation(.spring(response: 0.14, dampingFraction: 0.7)) {
            tapScale = 0.985
            tapOffsetY = 1.5
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                tapScale = 1.012
                tapOffsetY = -1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                tapScale = 1
                tapOffsetY = 0
            }
        }
    }

    private func runArtworkSpin() {
        guard isArtworkSpinning == false else { return }
        isArtworkSpinning = true
        artworkSpinAngle = 0

        let spinDuration = 0.68
        withAnimation(.timingCurve(0.22, 0.82, 0.22, 1, duration: spinDuration)) {
            artworkSpinAngle = 360
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + spinDuration) {
            artworkSpinAngle = 0
            isArtworkSpinning = false
        }
    }
}

private struct NowPlayingMiniSpectrumView: View {
    let isPlaying: Bool
    let progress: Float?
    let liveBands: [Float]
    let hasLiveAudio: Bool
    private let seedValue: Double

    private let barCount = 10
    private let barWidth: CGFloat = 1.6
    private let barSpacing: CGFloat = 1.35
    private let visualizerWidth: CGFloat = 29
    private let minBarHeight: CGFloat = 2
    private let maxBarHeight: CGFloat = 11

    init(
        isPlaying: Bool,
        seedText: String,
        progress: Float?,
        liveBands: [Float],
        hasLiveAudio: Bool
    ) {
        self.isPlaying = isPlaying
        self.progress = progress
        self.liveBands = liveBands
        self.hasLiveAudio = hasLiveAudio
        self.seedValue = Self.seed(from: seedText)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
            let shouldUseLiveBands = isPlaying && hasLiveAudio && ((liveBands.max() ?? 0) > 0.001)
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(barColor(for: index))
                        .frame(
                            width: barWidth,
                            height: barHeight(
                                for: index,
                                time: context.date.timeIntervalSinceReferenceDate,
                                shouldUseLiveBands: shouldUseLiveBands
                            )
                        )
                }
            }
            .frame(width: visualizerWidth, height: maxBarHeight, alignment: .leading)
            .opacity(isPlaying ? 1 : 0.58)
            .accessibilityHidden(true)
        }
    }

    private func barHeight(
        for index: Int,
        time: TimeInterval,
        shouldUseLiveBands: Bool
    ) -> CGFloat {
        let barSpan = maxBarHeight - minBarHeight
        if shouldUseLiveBands, index < liveBands.count {
            let liveValue = CGFloat(min(max(liveBands[index], 0), 1))
            return minBarHeight + (liveValue * barSpan)
        }

        let x = Double(index) / Double(max(barCount - 1, 1))
        let level = Double(min(max(progress ?? 0.65, 0), 1))

        guard isPlaying else {
            let idleLow = abs(sin((seedValue * 1.4) + (Double(index) * 0.62)))
            let idleHigh = abs(sin((seedValue * 2.2) + (Double(index) * 1.15)))
            let idleMix = min(1, (idleLow * 0.62) + (pow(idleHigh, 1.3) * 0.38))
            return minBarHeight + (CGFloat(idleMix) * barSpan * 0.32)
        }

        let t = time + seedValue
        let bassWave = abs(sin((t * 2.15) + (x * 2.8)))
        let midWave = abs(sin((t * 5.7) + (x * 9.1) + (seedValue * 0.33)))
        let highWave = pow(abs(sin((t * 11.9) + (x * 18.6) + (seedValue * 0.71))), 1.4)

        let bassWeight = max(0, 1 - (x * 1.55))
        let trebleWeight = max(0, (x - 0.34) / 0.66)
        let midWeight = max(0.12, 1 - abs((x - 0.5) * 1.88))

        let energy =
            (0.44 * bassWave * bassWeight) +
            (0.30 * midWave * midWeight) +
            (0.48 * highWave * trebleWeight)

        let loudness = 0.60 + (level * 0.4)
        let normalized = min(max((0.14 + energy) * loudness, 0), 1)
        return minBarHeight + (CGFloat(normalized) * barSpan)
    }

    private func barColor(for index: Int) -> Color {
        let x = Double(index) / Double(max(barCount - 1, 1))
        let hue = 0.35 + (x * 0.09)
        return Color(hue: hue, saturation: 0.58, brightness: 0.98)
    }

    private static func seed(from text: String) -> Double {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }

        return Double(hash % 10_000) / 1_000
    }
}

private struct NotchCardShape: Shape {
    let topInsetRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let topCornerConcavity: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topInsetRadius, min(rect.width, rect.height) * 0.45))
        let bottom = max(0, min(bottomCornerRadius, min(rect.width, rect.height) * 0.45))
        let concavity = max(0, min(topCornerConcavity, top * 3.0))
        let bend = top * 1.28

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control1: CGPoint(x: rect.maxX - top + bend + (concavity * 1.55), y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + top - bend)
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + top - bend),
            control2: CGPoint(x: rect.minX + top - bend - (concavity * 1.55), y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
