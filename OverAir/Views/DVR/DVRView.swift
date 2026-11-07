import SwiftUI

struct DVRView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(LocalRecorder.self) private var recorder

    enum DVRSection: String, CaseIterable, Identifiable {
        case library, upcoming, rules, iphone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: return "Library"
            case .upcoming: return "Upcoming"
            case .rules: return "Rules"
            case .iphone: return "On iPhone"
            }
        }
    }

    @State private var section: DVRSection = .library
    @State private var showSearch = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(DVRSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch section {
            case .library: LibraryView()
            case .upcoming: UpcomingView()
            case .rules: RulesView()
            case .iphone: LocalRecordingsView()
            }
        }
        .navigationTitle("DVR")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Find shows to record")
            }
        }
        .sheet(isPresented: $showSearch) { SeriesSearchView() }
        .task { if dvr.rules.isEmpty && dvr.series.isEmpty { await dvr.refresh(tuners: tuners) } }
    }
}

// MARK: - Library

struct LibraryView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var filter = "All"

    private var categories: [String] {
        ["All"] + Array(Set(dvr.series.compactMap { $0.category?.capitalized })).sorted()
    }

    private var filteredSeries: [RecordedSeries] {
        filter == "All" ? dvr.series : dvr.series.filter { $0.category?.capitalized == filter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let summary = dvr.storageSummary(tuners) { storageCard(summary).padding(.horizontal) }

                if tuners.storageDevices.isEmpty {
                    noStorage
                } else if dvr.series.isEmpty && !dvr.isLoading {
                    EmptyStateView(symbol: "tray", title: "No Recordings Yet", message: "Schedule something from the Guide, or tap + to find a show.")
                        .padding(.top, 40)
                }

                if !dvr.recordingNow.isEmpty {
                    shelf("Recording Now", episodes: dvr.recordingNow)
                }
                if !dvr.continueWatching.isEmpty {
                    shelf("Continue Watching", episodes: dvr.continueWatching)
                }
                if !dvr.recentlyAdded.isEmpty {
                    shelf("Recently Recorded", episodes: Array(dvr.recentlyAdded.prefix(12)))
                }

                if !dvr.series.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "All Shows", subtitle: "\(dvr.series.count) shows · \(dvr.allEpisodes.count) recordings").padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(categories, id: \.self) { c in
                                    Button(c) { filter = c }
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(filter == c ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.card), in: Capsule())
                                        .foregroundStyle(filter == c ? .white : .primary)
                                }
                            }
                            .padding(.horizontal)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: hSize == .regular ? 200 : 150), spacing: 14)], spacing: 18) {
                            ForEach(filteredSeries) { s in
                                NavigationLink { SeriesEpisodesView(series: s) } label: { SeriesTile(series: s, count: dvr.episodes[s.seriesID]?.count ?? 0) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable { await dvr.refresh(tuners: tuners) }
        .overlay { if dvr.isLoading && dvr.series.isEmpty { ProgressView() } }
    }

    private var noStorage: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Add Storage to Record").font(.headline)
            Text("Your FLEX 4K records to a USB drive plugged directly into it. Once attached and formatted from the HDHomeRun app or web UI, recordings appear here. HDHomeRun DVR on a NAS/PC works too. You can still record to this iPhone from any live channel.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .cardStyle()
        .padding(.horizontal)
    }

    private func storageCard(_ s: (used: Int64, total: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("HDHomeRun Storage", systemImage: "externaldrive.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Fmt.bytes(s.total - s.used)) free").font(.caption).foregroundStyle(.secondary)
            }
            ProgressLine(value: Double(s.used) / Double(max(s.total, 1)), tint: Double(s.used) / Double(max(s.total, 1)) > 0.9 ? .red : .accentColor, height: 8)
            Text("\(Fmt.bytes(s.used)) of \(Fmt.bytes(s.total)) used").font(.caption2).foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func shelf(_ title: String, episodes: [RecordedEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(episodes) { ep in
                        EpisodeCard(episode: ep)
                            .onTapGesture { playback.play(ep) }
                            .contextMenu { EpisodeMenu(episode: ep) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct SeriesTile: View {
    var series: RecordedSeries
    var count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: series.posterURL ?? series.imageURL, fallbackSymbol: "film.stack")
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let cat = series.category { Text(cat.capitalized).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct EpisodeCard: View {
    var episode: RecordedEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Artwork(url: episode.imageURL, fallbackSymbol: "play.rectangle")
                    .frame(width: 220, height: 124)
                if episode.isRecordingNow {
                    Pill(text: "REC", color: Theme.record, symbol: "record.circle").padding(8)
                }
                if let r = episode.resumeSeconds, episode.duration > 0 {
                    ProgressLine(value: Double(r) / episode.duration, height: 3).padding(8)
                }
            }
            Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(episode.subtitleLine ?? (episode.recordStart.map(Fmt.smartDay) ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 220)
    }
}

struct EpisodeMenu: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(PlaybackCoordinator.self) private var playback
    var episode: RecordedEpisode

    var body: some View {
        Button { playback.play(episode) } label: { Label(episode.resumeSeconds != nil ? "Resume" : "Play", systemImage: "play.fill") }
        if episode.resumeSeconds != nil {
            Button { playback.play(episode, fromStart: true) } label: { Label("Play from Beginning", systemImage: "backward.end.fill") }
        }
        Button { Task { await dvr.setWatched(episode, watched: !episode.isWatched) } } label: {
            Label(episode.isWatched ? "Mark Unwatched" : "Mark Watched", systemImage: episode.isWatched ? "eye.slash" : "eye")
        }
        Button(role: .destructive) { Task { await dvr.delete(episode, rerecord: false, tuners: tuners) } } label: { Label("Delete", systemImage: "trash") }
        Button(role: .destructive) { Task { await dvr.delete(episode, rerecord: true, tuners: tuners) } } label: { Label("Delete & Allow Re-record", systemImage: "arrow.clockwise.circle") }
    }
}

struct SeriesEpisodesView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(PlaybackCoordinator.self) private var playback
    var series: RecordedSeries
    @State private var confirmDelete: RecordedEpisode?
    @State private var hideWatched = false

    private var episodes: [RecordedEpisode] {
        let all = dvr.episodes[series.seriesID] ?? []
        return hideWatched ? all.filter { !$0.isWatched } : all
    }

    var body: some View {
        List {
            Section {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: series.imageURL, fallbackSymbol: "film.stack", cornerRadius: 16).frame(height: 190)
                    Theme.heroGradient.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading) {
                        Text(series.title).font(.title.weight(.bold))
                        Text("\(episodes.count) episodes").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                    .foregroundStyle(.white)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(episodes) { ep in
                    Button { playback.play(ep) } label: { EpisodeRow(episode: ep) }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { confirmDelete = ep } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { Task { await dvr.setWatched(ep, watched: !ep.isWatched) } } label: {
                                Label(ep.isWatched ? "Unwatched" : "Watched", systemImage: ep.isWatched ? "eye.slash" : "eye")
                            }
                            .tint(.blue)
                        }
                        .contextMenu { EpisodeMenu(episode: ep) }
                }
            }
        }
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Hide Watched", isOn: $hideWatched)
                    if let first = episodes.first(where: { !$0.isWatched }) ?? episodes.last {
                        Button { playback.play(first) } label: { Label("Play Next Unwatched", systemImage: "play.fill") }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .refreshable { await dvr.loadEpisodes(for: series, tuners: tuners) }
        .confirmationDialog("Delete this recording?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { ep in
            Button("Delete", role: .destructive) { Task { await dvr.delete(ep, rerecord: false, tuners: tuners) } }
            Button("Delete & Allow Re-record", role: .destructive) { Task { await dvr.delete(ep, rerecord: true, tuners: tuners) } }
        }
    }
}

struct EpisodeRow: View {
    var episode: RecordedEpisode

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                Artwork(url: episode.imageURL, fallbackSymbol: "play.rectangle", cornerRadius: 10).frame(width: 120, height: 68)
                if let r = episode.resumeSeconds, episode.duration > 0 {
                    ProgressLine(value: Double(r) / episode.duration, height: 3).padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !episode.isWatched && episode.resumeSeconds == nil { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                    Text(episode.episodeTitle ?? episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let ep = episode.episodeNumber { Text(ep).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    if episode.isRecordingNow { Pill(text: "REC", color: Theme.record) }
                    Text([episode.recordStart.map(Fmt.smartDay), episode.channelNumber, Fmt.duration(episode.duration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let s = episode.synopsis { Text(s).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            }
        }
        .padding(.vertical, 4)
    }
}
