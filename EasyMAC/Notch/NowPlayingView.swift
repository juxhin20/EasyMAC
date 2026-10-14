import AppKit
import SwiftUI

/// Droppy-style now playing: art on the left wing, live bars on the right; hovering opens a small
/// card under the notch with title, artist and controls.
struct NowPlayingNotchView: View {
    let player: NowPlaying
    let expanded: Bool
    let notchWidth: CGFloat
    let height: CGFloat

    static let wing: CGFloat = 44
    static let expandedWing: CGFloat = 130
    static let expandedExtra: CGFloat = 86

    private var wing: CGFloat { expanded ? Self.expandedWing : Self.wing }
    private var tint: Color { player.appBundleID == "com.spotify.client" ? Color(red: 0.12, green: 0.84, blue: 0.38) : Color(red: 0.98, green: 0.28, blue: 0.45) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    artwork(size: height * 0.62, radius: 5)
                    Spacer(minLength: 0)
                }
                .padding(.leading, height * 0.4)
                .frame(width: wing)
                Color.clear.frame(width: notchWidth)
                HStack {
                    Spacer(minLength: 0)
                    EqualizerBars(playing: player.isPlaying, tint: tint)
                        .frame(width: height * 0.6, height: height * 0.42)
                }
                .padding(.trailing, height * 0.4)
                .frame(width: wing)
            }
            .frame(height: height)

            if expanded {
                HStack(spacing: 12) {
                    artwork(size: 58, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(player.artist)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        HStack(spacing: 22) {
                            control("backward.fill", NowPlaying.previous)
                            control(player.isPlaying ? "pause.fill" : "play.fill", NowPlaying.playPause, size: 17)
                            control("forward.fill", NowPlaying.next)
                        }
                        .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: Self.expandedExtra)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(.white)
        .frame(width: notchWidth + wing * 2)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 22 : height * 0.42,
                                           bottomTrailingRadius: expanded ? 22 : height * 0.42, style: .continuous).fill(.black))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func artwork(size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let art = player.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func control(_ symbol: String, _ action: @escaping () -> Void, size: CGFloat = 13) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Five bouncing bars while playing, a calm low row when paused.
struct EqualizerBars: View {
    let playing: Bool
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                HStack(alignment: .center, spacing: proxy.size.width * 0.1) {
                    ForEach(0..<5, id: \.self) { i in
                        let phase = t * (2.2 + Double(i) * 0.7) + Double(i) * 1.3
                        let level = playing ? 0.3 + 0.7 * abs(sin(phase)) : 0.25
                        Capsule()
                            .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                            .frame(height: proxy.size.height * level)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
