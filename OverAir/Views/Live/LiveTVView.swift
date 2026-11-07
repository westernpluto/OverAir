import SwiftUI

enum LiveFilter: String, CaseIterable, Identifiable {
    case all, favorites, movies, sports, news, kids
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Channels"
        case .favorites: return "Favorites"
        case .movies: return "Movies"
        case .sports: return "Sports"
        case .news: return "News"
        case .kids: return "Kids"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .movies: return "film"
        case .sports: return "sportscourt"
        case .news: return "newspaper"
        case .kids: return "teddybear"
        }
    }

    var category: ProgramCategory? {
        switch self {
        case .movies: return .movie
        case .sports: return .sports
        case .news: return .news
        case .kids: return .kids
        default: return nil
        }
    }
}

struct LiveTVView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings

    @State private var filter: LiveFilter = .all
    @State private var showKeypad = false
    @State private var detailProgram: GuideProgram?
    @State private var channelPage: Channel?

    var body: some View {
        GeometryReader { proxy in
            NowTicker(interval: 30) { now in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if tuners.connection == .offline || (tuners.connection == .connecting && tuners.channels.isEmpty) {
                            ConnectionCard()
                        }
                        quickActions
                        if filter == .all && !tuners.favoriteChannels.isEmpty {
                            favoritesRow(now: now)
                        }
                        filterChips
                        channelSection(now: now, width: proxy.size.width)
                    }
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await tuners.connect()
                    await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true)
                }
            }
        }
        .navigationTitle("Live TV")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionBadge(state: tuners.connection)
            }
        }
        .sheet(isPresented: $showKeypad) {
            KeypadSheet { number in playback.tune(number: number) }
                .presentationDetents([.medium])
        }
        .sheet(item: $detailProgram) { p in
            NavigationStack { ProgramDetailView(program: p) }
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(item: $channelPage) { ch in ChannelDetailView(channel: ch) }
        .overlay {
            if tuners.channels.isEmpty && !tuners.isDiscovering && tuners.connection != .connecting {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right.slash", title: "No Channels Yet",
                               message: "Scan for channels on your HDHomeRun in Settings → Channels, or check that it's connected.",
                               actionTitle: "Try Again") { Task { await tuners.connect() } }
            }
        }
    }

    // MARK: Quick actions (labelled, so it's obvious what each does)

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let last = settings.lastChannel.flatMap({ tuners.channel($0) }), playback.currentChannel != last {
                    QuickAction(title: "Resume \(last.number)", symbol: "play.fill", prominent: true) { playback.play(last) }
                }
                QuickAction(title: "Channel Number", symbol: "number") { showKeypad = true }
                QuickAction(title: "Multiview", symbol: "rectangle.split.2x2") {
                    playback.openMultiview(with: Array(tuners.favoriteChannels.prefix(2)))
                }
            }
            .padding(.horizontal)
        }
    }

    private func favoritesRow(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Favorites").padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(tuners.favoriteChannels) { ch in
                        ChannelCard(channel: ch, now: now)
                            .frame(width: 220)
                            .onTapGesture { playback.play(ch) }
                            .contextMenu { channelMenu(ch) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LiveFilter.allCases) { f in
                    Button {
                        withAnimation(.snappy) { filter = f }
                    } label: {
                        Label(f.title, systemImage: f.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(filter == f ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.card), in: Capsule())
                            .foregroundStyle(filter == f ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }

    private func filtered(now: Date) -> [Channel] {
        switch filter {
        case .all: return tuners.visibleChannels
        case .favorites: return tuners.favoriteChannels
        default:
            guard let cat = filter.category else { return tuners.visibleChannels }
            return tuners.visibleChannels.filter { guide.nowPlaying($0.number, at: now)?.category == cat }
        }
    }

    @ViewBuilder
    private func channelSection(now: Date, width: CGFloat) -> some View {
        let list = filtered(now: now)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: filter == .all ? "All Channels" : "\(filter.title) On Now",
                          subtitle: "\(list.count) channel\(list.count == 1 ? "" : "s") · tap to watch")
                .padding(.horizontal)

            if list.isEmpty {
                Text(filter == .favorites ? "Tap ☆ on any channel (or press and hold it) to add favorites." : "Nothing on in \(filter.title) right now.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else if width >= 700 {
                // Wide layouts (iPhone Duo open, iPad): an even-column grid that divides cleanly at the fold.
                let cols = Fold.evenColumns(for: width - 32, minimumItemWidth: 300)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 14) {
                    ForEach(list) { ch in
                        ChannelCard(channel: ch, now: now)
                            .onTapGesture { playback.play(ch) }
                            .contextMenu { channelMenu(ch) }
                    }
                }
                .padding(.horizontal)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(list) { ch in
                        ChannelRow(channel: ch, now: now)
                            .contentShape(Rectangle())
                            .onTapGesture { playback.play(ch) }
                            .contextMenu { channelMenu(ch) }
                        if ch.id != list.last?.id { Divider().padding(.leading, 78) }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func channelMenu(_ ch: Channel) -> some View {
        Button { playback.play(ch) } label: { Label("Watch Now", systemImage: "play.fill") }
        Button { playback.play(ch, expand: false) } label: { Label("Play While Browsing", systemImage: "rectangle.bottomhalf.inset.filled") }
        Button { channelPage = ch } label: { Label("Schedule & Shows to Record", systemImage: "calendar") }
        if let p = guide.nowPlaying(ch.number) {
            Button { detailProgram = p } label: { Label("About “\(p.title)”", systemImage: "info.circle") }
        }
        Divider()
        Button { settings.toggleFavorite(ch.number) } label: {
            Label(settings.isFavorite(ch.number) ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: settings.isFavorite(ch.number) ? "star.slash" : "star")
        }
        Button(role: .destructive) { settings.toggleHidden(ch.number) } label: { Label("Hide Channel", systemImage: "eye.slash") }
    }
}

struct QuickAction: View {
    var title: String
    var symbol: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.card), in: Capsule())
                .foregroundStyle(prominent ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// Shown when the tuner isn't reachable, with a clear next step.
struct ConnectionCard: View {
    @Environment(TunerStore.self) private var tuners
    @State private var showRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if tuners.connection == .connecting {
                    ProgressView()
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tuners.connection == .connecting ? "Connecting to your HDHomeRun…" : "Can't reach your HDHomeRun")
                        .font(.headline)
                    if tuners.connection != .connecting {
                        Text(NetworkInfo.isOnLAN(of: tuners.selectedTuner)
                             ? "Make sure it's powered on and connected to your router."
                             : "Looks like you're away from home. Set up remote viewing once and it will connect automatically.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if tuners.connection != .connecting {
                HStack {
                    Button { Task { await tuners.connect() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                    Button { showRemote = true } label: { Label("Set Up Away-From-Home", systemImage: "globe") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .cardStyle()
        .padding(.horizontal)
        .sheet(isPresented: $showRemote) { NavigationStack { RemoteAccessView() } }
    }
}

struct ChannelRow: View {
    @Environment(GuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LocalRecorder.self) private var recorder
    var channel: Channel
    var now: Date

    var body: some View {
        let current = guide.nowPlaying(channel.number, at: now)
        let next = guide.upNext(channel.number, at: now)
        HStack(spacing: 12) {
            ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.number).font(.caption.weight(.bold).monospacedDigit())
                    Text(channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let badge = channel.codecBadge { Pill(text: badge, color: .purple.opacity(0.6)) }
                    if recorder.isRecording(channel: channel.number) { RecordDot() }
                }
                Text(current?.title ?? channel.name).font(.body.weight(.semibold)).lineLimit(1)
                if let current {
                    HStack(spacing: 8) {
                        ProgressLine(value: current.progress(at: now), tint: Theme.live, height: 3).frame(maxWidth: 110)
                        Text(Fmt.remaining(until: current.end)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let next {
                    Text("Next \(Fmt.time.string(from: next.start)) · \(next.title)")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if playback.currentChannel == channel {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Playing")
            }
            Button { settings.toggleFavorite(channel.number) } label: {
                Image(systemName: settings.isFavorite(channel.number) ? "star.fill" : "star")
                    .foregroundStyle(settings.isFavorite(channel.number) ? .yellow : .secondary)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.isFavorite(channel.number) ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
    }
}

/// Artwork-forward card used for favorites and wide layouts.
struct ChannelCard: View {
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    var channel: Channel
    var now: Date

    var body: some View {
        let p = guide.nowPlaying(channel.number, at: now)
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Artwork(url: p?.imageURL, fallbackSymbol: p?.category.symbol ?? "tv", cornerRadius: 14)
                    .aspectRatio(16 / 9, contentMode: .fit)
                ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: 34)
                    .padding(8)
                if playback.currentChannel == channel {
                    Pill(text: "PLAYING", color: .accentColor, symbol: "waveform")
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p?.title ?? channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(channel.number) \(channel.name)\(p.map { " · " + Fmt.remaining(until: $0.end) } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p { ProgressLine(value: p.progress(at: now), tint: Theme.live, height: 3) }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to watch")
    }
}

struct PosterTile: View {
    var program: GuideProgram
    var logo: URL?
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Artwork(url: program.imageURL, fallbackSymbol: program.category.symbol)
                    .frame(width: 200, height: 112)
                ChannelLogo(url: logo, number: program.channelNumber, name: "", size: 28).padding(6)
            }
            Text(program.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(program.subtitleLine ?? Fmt.range(program.start, program.end)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ProgressLine(value: program.progress(at: now), tint: Theme.live, height: 2)
        }
        .frame(width: 200)
    }
}

struct ProgramRow: View {
    var program: GuideProgram
    var logo: URL?
    var scheduled: Bool
    var now: Date

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: program.imageURL, fallbackSymbol: program.category.symbol, cornerRadius: 10)
                .frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(program.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if scheduled { RecordDot() }
                    if program.isNew { Pill(text: "NEW", color: .accentColor) }
                }
                if let sub = program.subtitleLine { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 6) {
                    if program.isAiring(at: now) { LiveBadge() }
                    Text("\(Fmt.smartDay(program.start)) · \(program.channelNumber)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            ChannelLogo(url: logo, number: program.channelNumber, name: "", size: 32)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}
