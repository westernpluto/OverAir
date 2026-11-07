import SwiftUI

/// Persistent mini player shown above the tab bar while something is playing.
struct MiniPlayer: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(GuideStore.self) private var guide

    var body: some View {
        if let item = playback.item, !playback.isFullScreen {
            HStack(spacing: 12) {
                VideoSurface(player: playback.player)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(item)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if case let .live(ch) = item, let p = guide.nowPlaying(ch.number) {
                        ProgressLine(value: p.progress(), tint: Theme.live, height: 2).padding(.top, 2)
                    } else if !item.isLive {
                        ProgressLine(value: playback.player.progress, height: 2).padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
                Button { playback.player.togglePause() } label: {
                    Image(systemName: playback.player.state == .paused ? "play.fill" : "pause.fill")
                        .font(.title3).frame(width: 36, height: 36)
                }
                Button { withAnimation(.snappy) { playback.stop() } } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 32, height: 36)
                }
            }
            .foregroundStyle(.primary)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.cardStroke, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { playback.isFullScreen = true }
            .gesture(DragGesture().onEnded { v in
                if v.translation.height < -30 { playback.isFullScreen = true }
                else if abs(v.translation.width) > 80, item.isLive {
                    if v.translation.width < 0 { playback.channelUp() } else { playback.channelDown() }
                }
            })
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func title(_ item: PlaybackItem) -> String {
        if case let .live(ch) = item { return guide.nowPlaying(ch.number)?.title ?? ch.name }
        return item.title
    }

    private func subtitle(_ item: PlaybackItem) -> String {
        switch item {
        case let .live(ch): return "\(ch.number) \(ch.name) · Live"
        case let .recording(ep): return ep.subtitleLine ?? ep.channelName ?? "Recording"
        case let .local(rec): return "On iPhone · \(rec.channelName)"
        }
    }
}
