import SwiftUI

/// Live TV: favorites, a genre filter built from what's actually on, and the channel list.
struct LiveTVView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var hSize

    enum Filter: Hashable {
        case all, favorites
        case genre(Genre)
    }

    @State private var filter: Filter = .all
    @State private var showKeypad = false
    @State private var detailProgram: GuideProgram?
    @State private var channelPage: Channel?
    @State private var contentWidth: CGFloat = 390

    var body: some View {
        NowTicker(interval: 30) { now in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if tuners.connection == .offline || (tuners.connection == .connecting && tuners.channels.isEmpty) {
                        ConnectionCard().padding(.horizontal)
                    }
                    if filter == .all && !tuners.favoriteChannels.isEmpty {
                        favoritesRow(now: now)
                    }
                    ChipBar(items: filters(now: now), selection: $filter, title: title(for:), symbol: symbol(for:))
                    channelList(now: now)
                }
                .padding(.vertical, 8)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .refreshable {
                await tuners.connect()
                await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true)
            }
        }
        .navigationTitle("Live TV")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showKeypad = true } label: { Label("Channel Number", systemImage: "number") }
                Button { playback.openMultiview(with: Array(tuners.favoriteChannels.prefix(2))) } label: {
                    Label("Multiview", systemImage: "rectangle.split.2x2")
                }
            }
        }
        .sheet(isPresented: $showKeypad) {
            KeypadSheet { number in playback.tune(number: number) }.presentationDetents([.medium])
        }
        .sheet(item: $detailProgram) { p in
            NavigationStack { ProgramDetailView(program: p) }.presentationDetents([.medium, .large]).detailSheetPlacement()
        }
        .navigationDestination(item: $channelPage) { ch in ChannelDetailView(channel: ch) }
        .overlay {
            if tuners.channels.isEmpty && !tuners.isDiscovering && tuners.connection != .connecting {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right.slash", title: "No Channels Yet",
                               message: "Scan for channels in Settings → Channels, or check that your HDHomeRun is connected.",
                               actionTitle: "Try Again") { Task { await tuners.connect() } }
            }
        }
    }

    // MARK: Filters

    private func filters(now: Date) -> [Filter] {
        var counts: [Genre: Int] = [:]
        for ch in tuners.visibleChannels {
            for g in guide.nowPlaying(ch.number, at: now)?.genres ?? [] { counts[g, default: 0] += 1 }
        }
        let genres = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.name < $1.key.name }.map(\.key)
        var list: [Filter] = [.all]
        if !tuners.favoriteChannels.isEmpty { list.append(.favorites) }
        list += genres.map { .genre($0) }
        if case let .genre(g) = filter, !genres.contains(g) { list.append(filter) }
        return list
    }

    private func title(for f: Filter) -> String {
        switch f {
        case .all: return "All"
        case .favorites: return "Favorites"
        case let .genre(g): return g.name
        }
    }

    private func symbol(for f: Filter) -> String? {
        switch f {
        case .all: return nil
        case .favorites: return "star.fill"
        case let .genre(g): return g.symbol
        }
    }

    private func channels(now: Date) -> [Channel] {
        switch filter {
        case .all:
            // Favorites already have their own row above, so list channels in number order.
            return tuners.visibleChannels.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
        case .favorites: return tuners.favoriteChannels
        case let .genre(g): return tuners.visibleChannels.filter { guide.nowPlaying($0.number, at: now)?.genres.contains(g) ?? false }
        }
    }

    // MARK: Sections

    private func favoritesRow(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Favorites").padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(tuners.favoriteChannels) { ch in
                        ChannelCard(channel: ch, now: now)
                            .containerRelativeFrame(.horizontal, count: hSize == .regular ? 4 : 5, span: hSize == .regular ? 1 : 3, spacing: 12)
                            .onTapGesture { playback.play(ch) }
                            .contextMenu { channelMenu(ch) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private func channelList(now: Date) -> some View {
        let list = channels(now: now)
        if list.isEmpty {
            Text(filter == .favorites ? "Add favorites with the ☆ on any channel." : "Nothing in \(title(for: filter)) right now.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal)
        } else if hSize == .regular {
            // Wide (iPhone Duo open, iPad): cards in an even number of columns so nothing straddles the fold.
            let cols = Fold.evenColumns(for: contentWidth - 32, minimumItemWidth: 260)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols), spacing: 18) {
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
                    if ch.id != list.last?.id { Divider().padding(.leading, 76) }
                }
            }
        }
    }

    @ViewBuilder
    private func channelMenu(_ ch: Channel) -> some View {
        Button { playback.play(ch) } label: { Label("Watch", systemImage: "play.fill") }
        Button { channelPage = ch } label: { Label("Schedule & Shows", systemImage: "calendar") }
        if let p = guide.nowPlaying(ch.number) {
            Button { detailProgram = p } label: { Label("About “\(p.title)”", systemImage: "info.circle") }
        }
        Button { settings.toggleFavorite(ch.number) } label: {
            Label(settings.isFavorite(ch.number) ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: settings.isFavorite(ch.number) ? "star.slash" : "star")
        }
        Button(role: .destructive) { settings.toggleHidden(ch.number) } label: { Label("Hide Channel", systemImage: "eye.slash") }
    }
}

/// Shown when the tuner isn't reachable, with a clear next step.
struct ConnectionCard: View {
    @Environment(TunerStore.self) private var tuners
    @State private var showRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if tuners.connection == .connecting {
                    ProgressView()
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.yellow)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tuners.connection == .connecting ? "Connecting…" : "Can't reach your HDHomeRun").font(.headline)
                    if tuners.connection != .connecting {
                        Text(NetworkInfo.isOnLAN(of: tuners.selectedTuner)
                             ? "Make sure it's powered on and connected to your router."
                             : "You're away from home. Set up away-from-home viewing once and it will connect automatically.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if tuners.connection != .connecting {
                HStack {
                    Button("Try Again") { Task { await tuners.connect() } }.buttonStyle(.bordered)
                    Button("Watch Away From Home") { showRemote = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .cardStyle()
        .sheet(isPresented: $showRemote) { NavigationStack { RemoteAccessView() } }
    }
}

/// A compact channel row: logo, what's on, time left, and a favorite toggle.
struct ChannelRow: View {
    @Environment(GuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LocalRecorder.self) private var recorder
    @ScaledMetric private var logoSize: CGFloat = 48
    var channel: Channel
    var now: Date

    var body: some View {
        let current = guide.nowPlaying(channel.number, at: now)
        HStack(spacing: 12) {
            ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: logoSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(current?.title ?? channel.name).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(channel.number) \(channel.name)").monospacedDigit()
                    if let current { Text("· \(Fmt.remaining(until: current.end))") }
                    if recorder.isRecording(channel: channel.number) { RecordDot() }
                }
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let current {
                    ProgressLine(value: current.progress(at: now), tint: Theme.live, height: 2).frame(maxWidth: 140)
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
                    .frame(minWidth: 40, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.isFavorite(channel.number) ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }
}

/// Artwork-forward card used for favorites and wide layouts.
struct ChannelCard: View {
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    @ScaledMetric private var logoSize: CGFloat = 32
    var channel: Channel
    var now: Date

    var body: some View {
        let p = guide.nowPlaying(channel.number, at: now)
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: p?.imageURL, fallbackSymbol: p?.primaryGenre?.symbol ?? "tv", cornerRadius: 14)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: logoSize)
                        .padding(8)
                }
                .overlay(alignment: .bottom) {
                    if let p { ProgressLine(value: p.progress(at: now), tint: Theme.live, height: 3).padding(8) }
                }
                .overlay(alignment: .topTrailing) {
                    if playback.currentChannel == channel {
                        Image(systemName: "waveform").padding(8).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(p?.title ?? channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(channel.number) \(channel.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Watch")
    }
}

struct ProgramRow: View {
    var program: GuideProgram
    var logo: URL?
    var scheduled: Bool
    var now: Date
    @ScaledMetric private var artWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: program.imageURL, fallbackSymbol: program.primaryGenre?.symbol ?? "tv", cornerRadius: 10)
                .frame(width: artWidth, height: artWidth * 9 / 16)
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
            if let logo { ChannelLogo(url: logo, number: program.channelNumber, name: "", size: 30) }
        }
        .contentShape(Rectangle())
    }
}
