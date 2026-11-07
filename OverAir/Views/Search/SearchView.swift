import SwiftUI

/// One place to find anything: channels, what's on TV, shows to record, and your recordings.
struct SearchView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback

    @State private var query = ""
    @State private var cloudResults: [SeriesSearchResult] = []
    @State private var searching = false
    @State private var selected: GuideProgram?
    @State private var added: Set<String> = []
    @State private var message: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            if trimmed.count < 2 {
                browseSections
            } else {
                resultSections
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Shows, movies, teams, channels")
        .task(id: trimmed) { await searchCloud() }
        .sheet(item: $selected) { p in
            NavigationStack { ProgramDetailView(program: p) }
                .presentationDetents([.medium, .large])
                .detailSheetPlacement()
        }
        .navigationDestination(for: Genre.self) { g in CategoryListingView(genre: g) }
        .navigationDestination(for: Channel.self) { ch in ChannelDetailView(channel: ch) }
    }

    // MARK: Browse (empty query)

    private var browseGenres: [(genre: Genre, count: Int)] {
        var counts: [Genre: Int] = [:]
        let now = Date()
        for ch in guide.channels {
            for p in ch.programs where p.end > now { for g in p.genres { counts[g, default: 0] += 1 } }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.genre.name < $1.genre.name }
    }

    @ViewBuilder
    private var browseSections: some View {
        Section {
            if browseGenres.isEmpty {
                Text(guide.isLoading ? "Loading listings…" : "Genres appear once the guide has loaded.")
                    .foregroundStyle(.secondary)
            }
            ForEach(browseGenres, id: \.genre) { item in
                NavigationLink(value: item.genre) {
                    Label {
                        HStack {
                            Text(item.genre.name)
                            Spacer()
                            Text("\(item.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: item.genre.symbol).foregroundStyle(item.genre.color)
                    }
                }
            }
        } header: {
            Text("Browse by Genre")
        } footer: {
            Text("Search for a show, movie, team or channel to watch it, get a reminder, or record every future episode.")
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultSections: some View {
        let q = trimmed.lowercased()
        let channels = tuners.visibleChannels.filter { $0.number.hasPrefix(q) || $0.name.lowercased().contains(q) }
        let airings = groupedAirings(guide.search(trimmed))
        let recordings = dvr.allEpisodes.filter { $0.title.lowercased().contains(q) || ($0.episodeTitle?.lowercased().contains(q) ?? false) }

        if let message { Section { Text(message).font(.footnote) } }

        if !channels.isEmpty {
            Section("Channels") {
                ForEach(channels) { ch in
                    NavigationLink(value: ch) {
                        HStack(spacing: 12) {
                            ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 36)
                            VStack(alignment: .leading) {
                                Text("\(ch.number) \(ch.name)").font(.subheadline.weight(.semibold))
                                Text(guide.nowPlaying(ch.number)?.title ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }

        if !airings.isEmpty {
            Section("On TV") {
                ForEach(airings, id: \.first.id) { group in
                    Button { selected = group.first } label: {
                        HStack(spacing: 12) {
                            Artwork(url: group.first.imageURL, fallbackSymbol: group.first.primaryGenre?.symbol ?? "tv", cornerRadius: 8)
                                .frame(width: 84, height: 47)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(group.first.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if group.first.isAiring() { LiveBadge() }
                                }
                                Text("\(group.first.isAiring() ? "On now" : Fmt.smartDay(group.first.start)) · \(group.first.channelNumber) \(tuners.channel(group.first.channelNumber)?.name ?? "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if group.count > 1 {
                                    Text("+\(group.count - 1) more airing\(group.count > 2 ? "s" : "")").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Section {
            if searching && cloudResults.isEmpty {
                HStack { ProgressView(); Text("Searching listings…").foregroundStyle(.secondary) }
            }
            ForEach(cloudResults) { r in cloudRow(r) }
        } header: {
            Text("Record a Show")
        } footer: {
            if !cloudResults.isEmpty {
                Text(tuners.storageDevices.isEmpty
                     ? "Recording needs storage on your HDHomeRun (a USB drive on the FLEX 4K)."
                     : "Recording a show catches every future episode, even beyond the guide.")
            }
        }

        if !recordings.isEmpty {
            Section("Your Recordings") {
                ForEach(recordings.prefix(20)) { ep in
                    Button { playback.play(ep) } label: { EpisodeRow(episode: ep) }
                        .foregroundStyle(.primary)
                }
            }
        }

        if channels.isEmpty && airings.isEmpty && cloudResults.isEmpty && recordings.isEmpty && !searching {
            ContentUnavailableView.search(text: trimmed)
        }
    }

    private struct AiringGroup { var first: GuideProgram; var count: Int }

    private func groupedAirings(_ list: [GuideProgram]) -> [AiringGroup] {
        var order: [String] = []
        var map: [String: AiringGroup] = [:]
        for p in list {
            let key = p.seriesID ?? p.title
            if var g = map[key] { g.count += 1; map[key] = g } else { map[key] = AiringGroup(first: p, count: 1); order.append(key) }
        }
        return order.prefix(30).compactMap { map[$0] }
    }

    private func cloudRow(_ r: SeriesSearchResult) -> some View {
        HStack(spacing: 12) {
            Artwork(url: r.imageURL, fallbackSymbol: "tv", cornerRadius: 8).frame(width: 84, height: 47)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let s = r.synopsis { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if added.contains(r.seriesID) || dvr.hasSeriesRule(r.seriesID) {
                Label("Recording", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                    .font(.title2).foregroundStyle(.green)
                    .accessibilityLabel("Recording every episode")
            } else if !tuners.storageDevices.isEmpty {
                Menu {
                    Button { add(r, newOnly: false) } label: { Label("Record Every Episode", systemImage: "square.stack.3d.down.right") }
                    Button { add(r, newOnly: true) } label: { Label("Record New Episodes Only", systemImage: "sparkles") }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.record.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.record)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func searchCloud() async {
        let q = trimmed
        guard q.count >= 2, let auth = tuners.deviceAuth else { cloudResults = []; return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        if let results = try? await CloudAPI.search(q, deviceAuth: auth), !Task.isCancelled {
            cloudResults = Array(results.prefix(25))
        }
    }

    private func add(_ r: SeriesSearchResult, newOnly: Bool) {
        Task {
            do {
                try await dvr.addSeriesRule(r, newOnly: newOnly, channel: nil, settings: settings, tuners: tuners)
                added.insert(r.seriesID)
                Haptics.success()
                message = "“\(r.title)” will record \(newOnly ? "new episodes" : "every episode")."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// Everything coming up in one genre across all channels.
struct CategoryListingView: View {
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(TunerStore.self) private var tuners
    var genre: Genre
    @State private var selected: GuideProgram?

    private var programs: [GuideProgram] {
        let now = Date()
        let visible = Set(tuners.visibleChannels.map(\.number))
        return guide.channels.flatMap(\.programs)
            .filter { $0.end > now && visible.contains($0.channelNumber) && $0.genres.contains(genre) }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        List {
            ForEach(programs.prefix(150)) { p in
                Button { selected = p } label: {
                    ProgramRow(program: p, logo: guide.logo(p.channelNumber), scheduled: dvr.isScheduled(p), now: Date())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { if programs.isEmpty { ContentUnavailableView("Nothing Coming Up", systemImage: genre.symbol) } }
        .navigationTitle(genre.name)
        .sheet(item: $selected) { p in
            NavigationStack { ProgramDetailView(program: p) }
                .presentationDetents([.medium, .large])
                .detailSheetPlacement()
        }
    }
}
