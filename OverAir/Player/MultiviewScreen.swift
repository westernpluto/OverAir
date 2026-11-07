import SwiftUI

/// Watch up to four channels at once — one per tuner on the FLEX 4K.
struct MultiviewScreen: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings

    @State private var players: [PlayerController] = []
    @State private var channels: [Channel?] = []
    @State private var audioIndex = 0
    @State private var pickingSlot: Int?
    @State private var showChrome = true

    private var maxSlots: Int { max(1, min(4, tuners.totalTuners == 0 ? 4 : tuners.totalTuners)) }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let cols = channels.count <= 1 ? 1 : (landscape || channels.count > 2 ? 2 : 1)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols), spacing: 2) {
                    ForEach(channels.indices, id: \.self) { i in
                        tile(i, height: tileHeight(geo.size, cols: cols))
                    }
                }
                .frame(maxHeight: .infinity)

                if showChrome {
                    HStack {
                        CircleButton(symbol: "xmark") { close() }
                        Spacer()
                        Text("Multiview").font(.headline)
                        Spacer()
                        Menu {
                            if channels.count < maxSlots {
                                Button { addSlot() } label: { Label("Add Screen", systemImage: "plus.rectangle") }
                            }
                            if channels.count > 1 {
                                Button(role: .destructive) { removeSlot(channels.count - 1) } label: { Label("Remove Screen", systemImage: "minus.rectangle") }
                            }
                            Button {
                                if let ch = channels[safe: audioIndex] ?? nil {
                                    close()
                                    playback.play(ch)
                                }
                            } label: { Label("Full Screen Selected", systemImage: "arrow.up.left.and.arrow.down.right") }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, landscape ? 44 : 16)
                    .padding(.top, landscape ? 14 : 56)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear(perform: setup)
        .onDisappear { players.forEach { $0.stop() } }
        .sheet(item: Binding(get: { pickingSlot.map(SlotID.init) }, set: { pickingSlot = $0?.id })) { slot in
            ChannelPickerSheet { ch in assign(ch, to: slot.id) }
        }
    }

    private struct SlotID: Identifiable { let id: Int }

    private func tileHeight(_ size: CGSize, cols: Int) -> CGFloat {
        let rows = Int(ceil(Double(channels.count) / Double(cols)))
        return size.height / CGFloat(max(rows, 1)) - 2
    }

    @ViewBuilder
    private func tile(_ i: Int, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            if i < players.count {
                VideoSurface(player: players[i])
            }
            if let ch = channels[i] {
                HStack(spacing: 6) {
                    if audioIndex == i { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor) }
                    Text("\(ch.number) \(guide.nowPlaying(ch.number)?.title ?? ch.name)")
                        .font(.caption.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
                .foregroundStyle(.white)
            } else {
                Button { pickingSlot = i } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.largeTitle)
                        Text("Choose Channel").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.06))
        .overlay(Rectangle().stroke(audioIndex == i ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            selectAudio(i)
            withAnimation { showChrome.toggle() }
        }
        .onLongPressGesture { pickingSlot = i }
        .contextMenu {
            Button { pickingSlot = i } label: { Label("Change Channel", systemImage: "arrow.left.arrow.right") }
            Button { selectAudio(i) } label: { Label("Listen to This", systemImage: "speaker.wave.2") }
            if channels.count > 1 {
                Button(role: .destructive) { removeSlot(i) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private func setup() {
        var initial: [Channel?] = playback.multiviewChannels.map { Optional($0) }
        if initial.isEmpty {
            initial = Array(tuners.favoriteChannels.prefix(2)).map { Optional($0) }
        }
        if initial.count < 2 { initial += Array(repeating: nil, count: 2 - initial.count) }
        channels = Array(initial.prefix(maxSlots))
        players = channels.map { _ in PlayerController() }
        for i in channels.indices { start(i) }
        selectAudio(0)
    }

    private func start(_ i: Int) {
        guard let ch = channels[i], let url = tuners.streamURL(for: ch) else { return }
        var opts = PlayerController.Options()
        opts.cachingMs = tuners.connection == .remote ? settings.remoteCachingMs : settings.liveCachingMs
        opts.deinterlace = settings.deinterlace
        opts.muted = i != audioIndex
        players[i].aspect = .fill
        players[i].play(url: url, options: opts)
    }

    private func selectAudio(_ i: Int) {
        audioIndex = i
        for (idx, p) in players.enumerated() { p.isMuted = idx != i }
    }

    private func assign(_ ch: Channel, to i: Int) {
        guard i < channels.count else { return }
        channels[i] = ch
        players[i].stop()
        start(i)
    }

    private func addSlot() {
        channels.append(nil)
        players.append(PlayerController())
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

    private func close() {
        players.forEach { $0.stop() }
        playback.isMultiviewPresented = false
    }
}

struct ChannelPickerSheet: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
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
            .navigationTitle("Choose Channel")
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
