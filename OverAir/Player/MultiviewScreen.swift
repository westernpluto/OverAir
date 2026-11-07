import SwiftUI
import AVFoundation

/// Watch up to four channels at once — one per FLEX 4K tuner.
/// Every tile shows the whole 16:9 picture (never cropped); tiles stay clear of the fold.
struct MultiviewScreen: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings

    @State private var players: [TVPlayer] = []
    @State private var channels: [Channel?] = []
    @State private var audioIndex = 0
    @State private var pickingSlot: Int?

    private var maxSlots: Int { playback.maxMultiviewTiles }

    var body: some View {
        GeometryReader { proxy in
            let division = Fold.division(in: proxy)
            let top: CGFloat = 56, bottom: CGFloat = 34
            let content = CGRect(x: 0, y: top, width: proxy.size.width, height: max(proxy.size.height - top - bottom, 100))
            let frames = TileLayout.frames(count: channels.count, in: content, avoiding: division)
            ZStack(alignment: .topLeading) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, frame in
                    if i < channels.count {
                        tile(i)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                topBar.frame(width: proxy.size.width, height: top)
                hint
                    .frame(width: proxy.size.width, height: bottom)
                    .offset(y: proxy.size.height - bottom)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear(perform: setup)
        .onDisappear { players.forEach { $0.stop() } }
        .sheet(item: Binding(get: { pickingSlot.map { SlotID(id: $0) } }, set: { pickingSlot = $0?.id })) { slot in
            ChannelPickerSheet(title: channels[safe: slot.id].flatMap { $0 } == nil ? "Add a Channel" : "Change Channel") { ch in
                assign(ch, to: slot.id)
            }
        }
    }

    private struct SlotID: Identifiable { let id: Int }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: {
                Label("Done", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glass(in: Capsule())
            }
            Spacer()
            Text("Multiview").font(.headline)
            Spacer()
            if channels.count < maxSlots {
                Button { addSlot() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glass(in: Capsule())
                }
            } else {
                Text("\(maxSlots) of \(maxSlots)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private var hint: some View {
        Text("Tap to hear · Double-tap for full screen · Hold for options")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    @ViewBuilder
    private func tile(_ i: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.07)
            if i < players.count, channels[i] != nil {
                TVVideoView(player: players[i])
            }
            if let ch = channels[i] {
                HStack(spacing: 6) {
                    Image(systemName: audioIndex == i ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .foregroundStyle(audioIndex == i ? Color.accentColor : .white.opacity(0.6))
                    Text("\(ch.number) \(guide.nowPlaying(ch.number)?.title ?? ch.name)")
                        .font(.caption.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(8)
                .foregroundStyle(.white)
                if i < players.count, players[i].state.isLoading || players[i].state == .idle {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Button { pickingSlot = i } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.largeTitle)
                        Text("Choose a Channel").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(audioIndex == i && channels[i] != nil ? Color.accentColor : Color.white.opacity(0.08), lineWidth: audioIndex == i ? 2.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { fullScreen(i) }
        .onTapGesture { selectAudio(i) }
        .contextMenu {
            if channels[i] != nil {
                Button { selectAudio(i) } label: { Label("Listen to This One", systemImage: "speaker.wave.2") }
                Button { fullScreen(i) } label: { Label("Watch Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            Button { pickingSlot = i } label: { Label("Change Channel", systemImage: "arrow.left.arrow.right") }
            if channels.count > 1 {
                Button(role: .destructive) { removeSlot(i) } label: { Label("Remove Screen", systemImage: "rectangle.badge.minus") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Listen") { selectAudio(i) }
    }

    // MARK: Logic

    private func setup() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        var initial: [Channel?] = playback.multiviewChannels.map { Optional($0) }
        if initial.isEmpty { initial = Array(tuners.favoriteChannels.prefix(2)).map { Optional($0) } }
        if initial.count < 2 { initial += Array(repeating: nil, count: 2 - initial.count) }
        channels = Array(initial.prefix(maxSlots))
        players = channels.map { _ in TVPlayer() }
        for i in channels.indices { start(i) }
        selectAudio(0)
    }

    private func start(_ i: Int) {
        guard let ch = channels[i], let url = tuners.streamURL(for: ch) else { return }
        let p = players[i]
        p.timeshiftCapacity = 64_000_000 // tiles only need a small buffer
        p.allowsPictureInPicture = false
        p.aspect = .fit
        p.lowPower = i != audioIndex
        p.audioEnabled = i == audioIndex
        var opts = TVPlayer.Options()
        opts.muted = i != audioIndex
        p.playLive(url: url, options: opts)
    }

    private func selectAudio(_ i: Int) {
        guard channels[safe: i] != nil, channels[i] != nil else { return }
        audioIndex = i
        for (idx, p) in players.enumerated() {
            let focused = idx == i
            p.lowPower = !focused
            p.audioEnabled = focused
            p.isMuted = !focused
        }
    }

    private func assign(_ ch: Channel, to i: Int) {
        guard i < channels.count else { return }
        channels[i] = ch
        start(i)
        if channels.compactMap({ $0 }).count == 1 { selectAudio(i) } else { selectAudio(audioIndex) }
    }

    private func addSlot() {
        channels.append(nil)
        players.append(TVPlayer())
        pickingSlot = channels.count - 1
    }

    private func removeSlot(_ i: Int) {
        guard channels.count > 1, i < channels.count else { return }
        players[i].stop()
        players.remove(at: i)
        channels.remove(at: i)
        if audioIndex >= channels.count { audioIndex = 0 }
        selectAudio(audioIndex)
    }

    private func fullScreen(_ i: Int) {
        guard let ch = channels[safe: i] ?? nil else { return }
        close()
        playback.play(ch)
    }

    private func close() {
        players.forEach { $0.stop() }
        playback.isMultiviewPresented = false
    }
}

/// Computes 16:9 tile frames that fill the space as much as possible without cropping,
/// keeping tiles on either side of the fold when the device is partially folded.
enum TileLayout {
    static func frames(count: Int, in rect: CGRect, avoiding division: CGRect?, spacing: CGFloat = 6) -> [CGRect] {
        guard count > 0, rect.width > 0, rect.height > 0 else { return [] }
        if let d = division, count > 1 {
            let firstCount = (count + 1) / 2
            let secondCount = count - firstCount
            if d.height > d.width { // vertical fold: left | right
                let left = CGRect(x: rect.minX, y: rect.minY, width: max(d.minX - rect.minX, 0), height: rect.height)
                let right = CGRect(x: d.maxX, y: rect.minY, width: max(rect.maxX - d.maxX, 0), height: rect.height)
                return grid(firstCount, in: left, spacing: spacing) + grid(secondCount, in: right, spacing: spacing)
            } else { // horizontal fold: top / bottom
                let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(d.minY - rect.minY, 0))
                let bottom = CGRect(x: rect.minX, y: d.maxY, width: rect.width, height: max(rect.maxY - d.maxY, 0))
                return grid(firstCount, in: top, spacing: spacing) + grid(secondCount, in: bottom, spacing: spacing)
            }
        }
        return grid(count, in: rect, spacing: spacing)
    }

    static func grid(_ count: Int, in rect: CGRect, spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let aspect: CGFloat = 16.0 / 9.0
        var best: (cols: Int, rows: Int, w: CGFloat) = (1, count, 0)
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let maxW = (rect.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let maxH = (rect.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let w = min(maxW, maxH * aspect)
            if w > best.w { best = (cols, rows, w) }
        }
        let w = best.w, h = w / aspect
        let totalH = h * CGFloat(best.rows) + spacing * CGFloat(best.rows - 1)
        var frames: [CGRect] = []
        for i in 0..<count {
            let row = i / best.cols
            let itemsInRow = min(best.cols, count - row * best.cols)
            let rowW = w * CGFloat(itemsInRow) + spacing * CGFloat(itemsInRow - 1)
            let col = i % best.cols
            let x = rect.midX - rowW / 2 + CGFloat(col) * (w + spacing)
            let y = rect.midY - totalH / 2 + CGFloat(row) * (h + spacing)
            frames.append(CGRect(x: x, y: y, width: w, height: h))
        }
        return frames
    }
}

struct ChannelPickerSheet: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var title: String = "Choose a Channel"
    var onPick: (Channel) -> Void

    var body: some View {
        NavigationStack {
            List(filtered) { ch in
                Button {
                    onPick(ch)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 38)
                        VStack(alignment: .leading) {
                            Text("\(ch.number)  \(ch.name)").font(.subheadline.weight(.semibold))
                            Text(guide.nowPlaying(ch.number)?.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $query, prompt: "Channel or show")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var filtered: [Channel] {
        guard !query.isEmpty else { return tuners.visibleChannels }
        let q = query.lowercased()
        return tuners.visibleChannels.filter {
            $0.number.hasPrefix(q) || $0.name.lowercased().contains(q) || (guide.nowPlaying($0.number)?.title.lowercased().contains(q) ?? false)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
