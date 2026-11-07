import SwiftUI

struct LiveTVView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(DVRStore.self) private var dvr

    @State private var query = ""
    @State private var category: ProgramCategory = .all
    @State private var showKeypad = false
    @State private var detailProgram: GuideProgram?
    @State private var listMode: ListMode = .all

    enum ListMode: String, CaseIterable, Identifiable {
        case all, favorites, recent
        var id: String { rawValue }
        var title: String { self == .all ? "All" : self == .favorites ? "Favorites" : "Recent" }
    }

    var body: some View {
        NowTicker(interval: 30) { now in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                    if !query.isEmpty {
                        searchResults(now: now)
                    } else {
                        if tuners.connection == .offline || tuners.connection == .connecting || tuners.lastError != nil {
                            statusBanner.padding(.horizontal)
                        }
                        heroCarousel(now: now)
                        if !recentChannels.isEmpty { recentRow(now: now) }
                        onNowSection(now: now)
                        channelList(now: now)
                    }
                }
                .padding(.vertical)
            }
            .refreshable {
                await tuners.connect()
                await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true)
            }
        }
        .navigationTitle("Live TV")
        .searchable(text: $query, prompt: "Channels, shows, movies, teams")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ConnectionBadge(state: tuners.connection) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { playback.openMultiview(with: Array(tuners.favoriteChannels.prefix(4))) } label: {
                    Image(systemName: "rectangle.split.2x2")
                }
                .accessibilityLabel("Multiview")
                Button { showKeypad = true } label: { Image(systemName: "number.square") }
                    .accessibilityLabel("Enter channel number")
            }
        }
        .sheet(isPresented: $showKeypad) {
            KeypadSheet { number in _ = playback.tune(number: number) }
                .presentationDetents([.medium])
        }
        .sheet(item: $detailProgram) { p in
            NavigationStack { ProgramDetailView(program: p) }
                .presentationDetents([.medium, .large])
        }
        .overlay {
            if tuners.channels.isEmpty && !tuners.isDiscovering && tuners.connection != .connecting {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right.slash", title: "No Channels",
                               message: "Run a channel scan on your HDHomeRun, or check that it's connected.",
                               actionTitle: "Reconnect") { Task { await tuners.connect() } }
            }
        }
    }

    private var recentChannels: [Channel] {
        settings.recentChannels.compactMap { tuners.channel($0) }
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 12) {
            if tuners.connection == .connecting { ProgressView() } else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            VStack(alignment: .leading, spacing: 2) {
                Text(tuners.connection == .connecting ? "Connecting to your HDHomeRun…" : "Connection problem").font(.subheadline.weight(.semibold))
                if let e = tuners.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if tuners.connection != .connecting {
                Button("Retry") { Task { await tuners.connect() } }.buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    // MARK: Hero

    @ViewBuilder
    private func heroCarousel(now: Date) -> some View {
        let picks = heroPicks(now: now)
        if !picks.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(picks) { p in
                        HeroCard(program: p, channel: tuners.channel(p.channelNumber), logo: guide.logo(p.channelNumber), now: now)
                            .containerRelativeFrame(.horizontal, count: hCount, spacing: 14)
                            .onTapGesture { if let ch = tuners.channel(p.channelNumber) { playback.play(ch) } }
                            .contextMenu { programMenu(p) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @Environment(\.horizontalSizeClass) private var hSize
    private var hCount: Int { hSize == .regular ? 2 : 1 }

    private func heroPicks(now: Date) -> [GuideProgram] {
        let airing = guide.onNow().filter { $0.imageURL != nil && tuners.channel($0.channelNumber) != nil }
        let favs = airing.filter { settings.isFavorite($0.channelNumber) }
        let rest = airing.filter { !settings.isFavorite($0.channelNumber) }
            .sorted { a, b in
                let score: (GuideProgram) -> Int = { p in
                    (p.category == .sports ? 3 : 0) + (p.category == .movie ? 2 : 0) + (p.isNew ? 2 : 0)
                }
                return score(a) > score(b)
            }
        return Array((favs + rest).prefix(8))
    }

    private func recentRow(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Jump Back In").padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentChannels) { ch in
                        Button { playback.play(ch) } label: {
                            VStack(spacing: 6) {
                                ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 64)
                                Text(ch.number).font(.caption.weight(.semibold).monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: On Now by category

    @ViewBuilder
    private func onNowSection(now: Date) -> some View {
        if guide.hasData {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "On Now").padding(.horizontal)
                CategoryChips(selection: $category)
                if category != .all {
                    let items = guide.onNow(category: category).filter { tuners.channel($0.channelNumber) != nil }
                    if items.isEmpty {
                        Text("Nothing in \(category.title) right now.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(items) { p in
                                    PosterTile(program: p, logo: guide.logo(p.channelNumber), now: now)
                                        .onTapGesture { if let ch = tuners.channel(p.channelNumber) { playback.play(ch) } }
                                        .contextMenu { programMenu(p) }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
        }
    }

    // MARK: Channel list

    private func channelList(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Channels", subtitle: "\(tuners.visibleChannels.count) channels · \(tuners.totalTuners) tuners")
                Picker("", selection: $listMode) {
                    ForEach(ListMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(listedChannels) { ch in
                    ChannelRow(channel: ch, now: now)
                        .contentShape(Rectangle())
                        .onTapGesture { playback.play(ch) }
                        .contextMenu { channelMenu(ch) }
                    Divider().padding(.leading, 76)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
        }
    }

    private var listedChannels: [Channel] {
        switch listMode {
        case .all: return tuners.visibleChannels
        case .favorites: return tuners.favoriteChannels
        case .recent: return recentChannels
        }
    }

    // MARK: Search

    @ViewBuilder
    private func searchResults(now: Date) -> some View {
        let q = query.lowercased()
        let chans = tuners.visibleChannels.filter { $0.number.hasPrefix(q) || $0.name.lowercased().contains(q) }
        let progs = guide.search(query)
        if !chans.isEmpty {
            SectionHeader(title: "Channels").padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(chans) { ch in
                    ChannelRow(channel: ch, now: now).contentShape(Rectangle()).onTapGesture { playback.play(ch) }
                    Divider().padding(.leading, 76)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
        }
        if !progs.isEmpty {
            SectionHeader(title: "In the Guide", subtitle: "\(progs.count) airings").padding(.horizontal)
            LazyVStack(spacing: 8) {
                ForEach(progs.prefix(60)) { p in
                    ProgramRow(program: p, logo: guide.logo(p.channelNumber), scheduled: dvr.isScheduled(p), now: now)
                        .onTapGesture { detailProgram = p }
                }
            }
            .padding(.horizontal)
        }
        if chans.isEmpty && progs.isEmpty {
            ContentUnavailableView.search(text: query).padding(.top, 40)
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func channelMenu(_ ch: Channel) -> some View {
        Button { playback.play(ch) } label: { Label("Watch", systemImage: "play.fill") }
        Button { playback.play(ch, fullScreen: false) } label: { Label("Play in Mini Player", systemImage: "pip") }
        Button { settings.toggleFavorite(ch.number) } label: {
            Label(settings.isFavorite(ch.number) ? "Remove Favorite" : "Add to Favorites", systemImage: settings.isFavorite(ch.number) ? "star.slash" : "star")
        }
        if let p = guide.nowPlaying(ch.number) {
            Button { detailProgram = p } label: { Label("Program Info", systemImage: "info.circle") }
        }
        Button(role: .destructive) { settings.toggleHidden(ch.number) } label: { Label("Hide Channel", systemImage: "eye.slash") }
    }

    @ViewBuilder
    private func programMenu(_ p: GuideProgram) -> some View {
        if let ch = tuners.channel(p.channelNumber) {
            Button { playback.play(ch) } label: { Label("Watch Now", systemImage: "play.fill") }
        }
        Button { detailProgram = p } label: { Label("Details & Recording", systemImage: "info.circle") }
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
            ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.number).font(.subheadline.weight(.bold).monospacedDigit())
                    Text(channel.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if settings.isFavorite(channel.number) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    if let badge = channel.codecBadge { Pill(text: badge, color: .purple.opacity(0.6)) }
                    if channel.isDRM { Pill(text: "DRM", color: .gray.opacity(0.5), symbol: "lock.fill") }
                    if recorder.isRecording(channel: channel.number) { RecordDot() }
                }
                Text(current?.title ?? "No guide data").font(.callout.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(current == nil ? .secondary : .primary)
                if let current {
                    HStack(spacing: 8) {
                        ProgressLine(value: current.progress(at: now), tint: Theme.live, height: 3).frame(maxWidth: 120)
                        Text(Fmt.remaining(until: current.end)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let next {
                    Text("Next: \(Fmt.time.string(from: next.start)) \(next.title)")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if playback.currentChannel == channel {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct HeroCard: View {
    var program: GuideProgram
    var channel: Channel?
    var logo: URL?
    var now: Date

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: program.imageURL, cornerRadius: 22)
            Theme.heroGradient.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LiveBadge()
                    if program.isNew { Pill(text: "NEW", color: .accentColor) }
                    Pill(text: program.category.title.uppercased(), color: Theme.color(for: program.category).opacity(0.8))
                }
                Text(program.title).font(.title2.weight(.bold)).lineLimit(2)
                if let sub = program.subtitleLine { Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1) }
                HStack(spacing: 8) {
                    ChannelLogo(url: logo, number: program.channelNumber, name: channel?.name ?? "", size: 26)
                    Text("\(program.channelNumber) \(channel?.name ?? "")").font(.caption.weight(.semibold))
                    Spacer()
                    Text(Fmt.remaining(until: program.end)).font(.caption)
                }
                ProgressLine(value: program.progress(at: now), tint: Theme.live, height: 3)
            }
            .padding(16)
            .foregroundStyle(.white)
        }
        .frame(height: 230)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
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
