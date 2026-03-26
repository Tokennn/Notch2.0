import SwiftUI

struct HUDView: View {
    let payload: HUDPayload
    let style: HUDStyle
    let isNowPlayingCollapsed: Bool
    let shouldRunEntryBounce: Bool
    let onCollapsedHandleHover: (() -> Void)?
    let onNowPlayingDoubleClick: (() -> Void)?

    @State private var collapseProgress: CGFloat = 0
    @State private var entryScale: CGFloat = 1
    @State private var entryOffsetY: CGFloat = 0
    @State private var tapScale: CGFloat = 1
    @State private var tapOffsetY: CGFloat = 0

    private let nowPlayingCardSize = CGSize(width: 300, height: 62)
    private let nowPlayingCanvasSize = CGSize(width: 376, height: 98)
    private let collapsedHandleSize = CGSize(width: 86, height: 8)
    private let notchTopCornerRadius: CGFloat = 19
    private let notchTopCornerConcavity: CGFloat = 24
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
                    x: max(0.72, (1 - (collapseProgress * 0.28)) * entryScale * tapScale),
                    y: max(0.12, (1 - (collapseProgress * 0.86)) * entryScale * tapScale),
                    anchor: .top
                )
                .offset(y: entryOffsetY + tapOffsetY - (collapseProgress * 18))
                .opacity(Double(1 - collapseProgress))
                .allowsHitTesting(collapseProgress < 0.82)

            collapsedHandle
                .opacity(Double(collapseProgress))
                .scaleEffect(
                    x: 0.9 + (collapseProgress * 0.1),
                    y: 0.62 + (collapseProgress * 0.38),
                    anchor: .top
                )
                .offset(y: (1 - collapseProgress) * -8)
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
            entryScale = 1
            entryOffsetY = 0
            if isNowPlayingCollapsed == false, shouldRunEntryBounce {
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
            guard isNowPlayingCollapsed == false else { return }
            runEntryBounce()
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

                if let subtitle = payload.subtitle, subtitle.isEmpty == false {
                    Text(subtitle)
                        .font(.system(size: 9.2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                GeometryReader { proxy in
                    let progress = CGFloat(min(max(payload.progress ?? 0, 0), 1))
                    let width = max(6, proxy.size.width * progress)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.24))
                        Capsule()
                            .fill(.white.opacity(0.96))
                            .frame(width: width)
                    }
                }
                .frame(height: 4)
            }

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
            NotchCardShape(topInsetRadius: 20, bottomCornerRadius: 16, topCornerConcavity: 26)
                .fill(.black)
                .overlay(
                    NotchCardShape(topInsetRadius: 20, bottomCornerRadius: 16, topCornerConcavity: 26)
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
    }

    private func runEntryBounce() {
        entryScale = 0.96
        entryOffsetY = -4

        withAnimation(.spring(response: 0.24, dampingFraction: 0.58)) {
            entryScale = 1.02
            entryOffsetY = 2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                entryScale = 1
                entryOffsetY = 0
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
}

private struct NotchCardShape: Shape {
    let topInsetRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let topCornerConcavity: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topInsetRadius, min(rect.width, rect.height) * 0.45))
        let bottom = max(0, min(bottomCornerRadius, min(rect.width, rect.height) * 0.45))
        let concavity = max(0, min(topCornerConcavity, top * 2.0))
        let bend = top * 0.92

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))

        // Top edge + smooth outward top-right concavity (no visible hard angle)
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control1: CGPoint(x: rect.maxX - top + bend + (concavity * 0.94), y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + top - bend)
        )

        // Right edge + rounded bottom-right
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )

        // Bottom edge + rounded bottom-left
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )

        // Left edge + smooth outward top-left concavity (no visible hard angle)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + top - bend),
            control2: CGPoint(x: rect.minX + top - bend - (concavity * 0.94), y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
