import SwiftUI

/// Compact now-playing bar shown in the tab view's bottom accessory while something plays.
struct MiniPlayer: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(GuideStore.self) private var guide

    var body: some View {
        if let item = playback.item {
            HStack(spacing: 10) {
                artwork(item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(item)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    playback.player.togglePause()
                } label: {
                    Label(playback.player.state == .paused ? "Play" : "Pause",
                          systemImage: playback.player.state == .paused ? "play.fill" : "pause.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                Button {
                    withAnimation(.snappy) { playback.stop() }
                } label: {
                    Label("Stop", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 36)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { playback.isExpanded = true }
            .accessibilityAction(named: "Open Player") { playback.isExpanded = true }
        }
    }

    @ViewBuilder
    private func artwork(_ item: PlaybackItem) -> some View {
        switch item {
        case let .live(ch):
            ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 34)
        case let .recording(ep):
            Artwork(url: ep.imageURL, fallbackSymbol: "play.rectangle", cornerRadius: 6).frame(width: 52, height: 30)
        case let .local(rec):
            Artwork(url: rec.imageURL, fallbackSymbol: "iphone", cornerRadius: 6).frame(width: 52, height: 30)
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
