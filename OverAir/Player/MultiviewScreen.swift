import SwiftUI
import AVFoundation

/// Watch up to four channels at once — one per FLEX 4K tuner.
/// Tiles use the whole screen: the controls float on top and hide after a few seconds. Tiles show
/// the whole 16:9 picture unless Fill Screen is on, and stay clear of the fold.
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

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var layoutStyle: MultiviewLayoutStyle { MultiviewLayoutStyle(rawValue: settings.multiviewLayout) ?? .auto }

    var body: some View {
        GeometryReader { proxy in
            let division = Fold.division(in: proxy)
            let content = CGRect(origin: .zero, size: proxy.size)
            let frames = TileLayout.frames(count: channels.count, in: content, avoiding: division, style: layoutStyle,
                                           focus: audioIndex, fill: settings.multiviewFill)
            ZStack(alignment: .top) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, frame in
                    if i < channels.count {
                        tile(i)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                if chromeVisible {
                    topBar
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !settings.multiviewHintSeen {
                    hint
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy(duration: 0.35), value: audioIndex)
            .animation(.snappy(duration: 0.35), value: settings.multiviewLayout)
            .animation(.snappy(duration: 0.35), value: settings.multiviewFill)
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { setup(); showChrome() }
        .onDisappear { players.forEach { $0.stop() }; hideTask?.cancel() }
        .onChange(of: settings.multiviewFill) { _, fill in
            for p in players { p.aspect = fill ? .fill : .fit }
        }
        .sheet(item: Binding(get: { pickingSlot.map { SlotID(id: $0) } }, set: { pickingSlot = $0?.id })) { slot in
            ChannelPickerSheet(title: channels[safe: slot.id].flatMap { $0 } == nil ? "Add a Channel" : "Change Channel") { ch in
                assign(ch, to: slot.id)
            }
        }
    }

    /// Shows the controls, then hides them so the tiles get the whole screen.
    private func showChrome() {
        chromeVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            chromeVisible = false
            if !settings.multiviewHintSeen { settings.multiviewHintSeen = true }
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
            Menu {
                Picker("Layout", selection: Binding(get: { layoutStyle }, set: { settings.multiviewLayout = $0.rawValue; showChrome() })) {
                    ForEach(MultiviewLayoutStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbol).tag(style)
                    }
                }
                Toggle(isOn: Binding(get: { settings.multiviewFill }, set: { settings.multiviewFill = $0; showChrome() })) {
                    Label("Fill Screen (Crop Edges)", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } label: {
                Label("Layout", systemImage: layoutStyle.symbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glass(in: Capsule())
            }
            if channels.count < maxSlots {
                Button { addSlot() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glass(in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private var hint: some View {
        Text("Tap a channel to hear it · Double-tap for full screen · Hold for options")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glass(in: Capsule())
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
                if i < players.count, case let .failed(problem) = players[i].state {
                    VStack(spacing: 6) {
                        Image(systemName: problem.symbol).font(.title2)
                        Text(problem.shortTitle).font(.subheadline.weight(.semibold))
                        if problem.isRetryable {
                            Button("Try Again") { start(i) }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.55))
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
        .onTapGesture { selectAudio(i); showChrome() }
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
        if ch.isDRM { p.fail(.copyProtected); return }
        p.timeshiftCapacity = 64_000_000 // tiles only need a small buffer
        p.allowsPictureInPicture = false
        p.aspect = settings.multiviewFill ? .fill : .fit
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

enum MultiviewLayoutStyle: String, CaseIterable, Identifiable {
    case auto, grid, focus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .grid: return "Equal Tiles"
        case .focus: return "Spotlight"
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "sparkles.rectangle.stack"
        case .grid: return "square.grid.2x2"
        case .focus: return "rectangle.inset.topleft.filled"
        }
    }
}

/// Arranges multiview tiles. Tiles show the whole 16:9 picture unless `fill` is on, stay clear of
/// the fold when the device is partially folded, and use as much of the screen as possible:
/// equal tiles, or a large "spotlight" tile for the channel being heard with the rest beside it.
enum TileLayout {
    static let aspect: CGFloat = 16.0 / 9.0

    static func frames(count: Int, in rect: CGRect, avoiding division: CGRect?, style: MultiviewLayoutStyle = .auto,
                       focus: Int = 0, fill: Bool = false, spacing: CGFloat = 4) -> [CGRect] {
        guard count > 0, rect.width > 0, rect.height > 0 else { return [] }
        if let d = division, count > 1 {
            let firstCount = (count + 1) / 2
            let secondCount = count - firstCount
            let halves: (CGRect, CGRect)
            if d.height > d.width { // vertical fold: left | right
                halves = (CGRect(x: rect.minX, y: rect.minY, width: max(d.minX - rect.minX, 0), height: rect.height),
                          CGRect(x: d.maxX, y: rect.minY, width: max(rect.maxX - d.maxX, 0), height: rect.height))
            } else { // horizontal fold: top / bottom
                halves = (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(d.minY - rect.minY, 0)),
                          CGRect(x: rect.minX, y: d.maxY, width: rect.width, height: max(rect.maxY - d.maxY, 0)))
            }
            let layout = fill ? fillRows : grid
            return layout(firstCount, halves.0, spacing) + layout(secondCount, halves.1, spacing)
        }
        if fill { return fillRows(count, in: rect, spacing: spacing) }
        let equal = grid(count, in: rect, spacing: spacing)
        guard count > 1, style != .grid else { return equal }
        let spotlight = spotlightLayout(count, focus: min(max(focus, 0), count - 1), in: rect, spacing: spacing)
        if style == .focus { return spotlight }
        // Automatic: the spotlight arrangement only when it uses clearly more of the screen.
        return area(spotlight) > area(equal) * 1.08 ? spotlight : equal
    }

    static func area(_ frames: [CGRect]) -> CGFloat { frames.reduce(0) { $0 + $1.width * $1.height } }

    /// Equal 16:9 tiles in rows, as large as fits, centred.
    static func grid(_ count: Int, in rect: CGRect, spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
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
            frames.append(CGRect(x: rect.midX - rowW / 2 + CGFloat(col) * (w + spacing),
                                 y: rect.midY - totalH / 2 + CGFloat(row) * (h + spacing), width: w, height: h))
        }
        return frames
    }

    /// Rows of cells that cover the whole rect (pictures are cropped to fit), choosing the row
    /// split whose cells are closest to 16:9.
    static func fillRows(_ count: Int, in rect: CGRect, spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        var best: (rows: [Int], score: Double)?
        for r in 1...count {
            var rows = [Int](repeating: count / r, count: r)
            for i in 0..<(count % r) { rows[i] += 1 }
            let h = (rect.height - spacing * CGFloat(r - 1)) / CGFloat(r)
            var score = 0.0
            for k in rows {
                let w = (rect.width - spacing * CGFloat(k - 1)) / CGFloat(k)
                score += Double(k) * abs(log(Double(w / h / aspect)))
            }
            if best == nil || score < best!.score { best = (rows, score) }
        }
        guard let rows = best?.rows else { return [] }
        let h = (rect.height - spacing * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        var frames: [CGRect] = []
        for (r, k) in rows.enumerated() {
            let w = (rect.width - spacing * CGFloat(k - 1)) / CGFloat(k)
            for c in 0..<k {
                frames.append(CGRect(x: rect.minX + CGFloat(c) * (w + spacing),
                                     y: rect.minY + CGFloat(r) * (h + spacing), width: w, height: h))
            }
        }
        return frames
    }

    /// One large tile (the channel being heard) with the others in a row beneath it or a column
    /// beside it, whichever is larger.
    static func spotlightLayout(_ count: Int, focus: Int, in rect: CGRect, spacing: CGFloat) -> [CGRect] {
        let others = count - 1
        guard others > 0 else { return grid(count, in: rect, spacing: spacing) }
        let n = CGFloat(others)

        // Row of small tiles under the big one.
        var below: [CGRect] = []
        do {
            var hs = min((rect.width - spacing * (n - 1)) / n / aspect, rect.height * 0.4)
            var bh = rect.height - spacing - hs
            var bw = min(rect.width, bh * aspect)
            bh = bw / aspect
            // Grow the small row into any height the big tile can't use.
            hs = min(rect.height - spacing - bh, (rect.width - spacing * (n - 1)) / n / aspect)
            let ws = hs * aspect
            let totalH = bh + spacing + hs
            let top = rect.midY - totalH / 2
            bw = bh * aspect
            let big = CGRect(x: rect.midX - bw / 2, y: top, width: bw, height: bh)
            let rowW = ws * n + spacing * (n - 1)
            var smalls: [CGRect] = []
            for i in 0..<others {
                smalls.append(CGRect(x: rect.midX - rowW / 2 + CGFloat(i) * (ws + spacing), y: top + bh + spacing, width: ws, height: hs))
            }
            below = place(big: big, smalls: smalls, focus: focus, count: count)
        }

        // Column of small tiles beside the big one.
        var beside: [CGRect] = []
        do {
            var ws = min((rect.height - spacing * (n - 1)) / n * aspect, rect.width * 0.4)
            var bw = rect.width - spacing - ws
            var bh = min(rect.height, bw / aspect)
            bw = bh * aspect
            ws = min(rect.width - spacing - bw, (rect.height - spacing * (n - 1)) / n * aspect)
            let hs = ws / aspect
            let totalW = bw + spacing + ws
            let left = rect.midX - totalW / 2
            bh = bw / aspect
            let big = CGRect(x: left, y: rect.midY - bh / 2, width: bw, height: bh)
            let colH = hs * n + spacing * (n - 1)
            var smalls: [CGRect] = []
            for i in 0..<others {
                smalls.append(CGRect(x: left + bw + spacing, y: rect.midY - colH / 2 + CGFloat(i) * (hs + spacing), width: ws, height: hs))
            }
            beside = place(big: big, smalls: smalls, focus: focus, count: count)
        }
        return area(below) >= area(beside) ? below : beside
    }

    private static func place(big: CGRect, smalls: [CGRect], focus: Int, count: Int) -> [CGRect] {
        var frames: [CGRect] = []
        var s = 0
        for i in 0..<count {
            if i == focus { frames.append(big) } else { frames.append(smalls[s]); s += 1 }
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
