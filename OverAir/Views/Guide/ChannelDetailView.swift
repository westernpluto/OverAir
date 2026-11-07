import SwiftUI

/// Everything about one channel: watch it, what's on, the shows it regularly airs (with one-tap
/// "record this show on this channel"), and its full schedule.
struct ChannelDetailView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback

    var channel: Channel

    @State private var selected: GuideProgram?
    @State private var message: String?
    @State private var working: Set<String> = []

    struct ShowSummary: Identifiable {
        var id: String
        var title: String
        var seriesID: String?
        var imageURL: URL?
        var genre: Genre?
        var airings: [GuideProgram]
        var next: GuideProgram { airings[0] }
    }

    private var upcoming: [GuideProgram] {
        let now = Date()
        return guide.programs(for: channel.number).filter { $0.end > now }
    }

    private var shows: [ShowSummary] {
        let groups = Dictionary(grouping: upcoming) { (p: GuideProgram) in p.seriesID ?? p.title }
        return groups.map { key, list in
            let sorted = list.sorted { $0.start < $1.start }
            return ShowSummary(id: key, title: sorted[0].title, seriesID: sorted[0].seriesID,
                               imageURL: sorted.first(where: { $0.imageURL != nil })?.imageURL,
                               genre: sorted[0].primaryGenre, airings: sorted)
        }
        .sorted { a, b in a.airings.count != b.airings.count ? a.airings.count > b.airings.count : a.next.start < b.next.start }
    }

    struct DaySchedule: Identifiable {
        var id: Date { day }
        var day: Date
        var programs: [GuideProgram]
    }

    private var days: [DaySchedule] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: upcoming) { (p: GuideProgram) in cal.startOfDay(for: p.start) }
        return groups.keys.sorted().map { (d: Date) in DaySchedule(day: d, programs: groups[d] ?? []) }
    }

    var body: some View {
        List {
            Section { header }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

            if let message {
                Section { Label(message, systemImage: "info.circle").font(.footnote) }
            }

            if let now = guide.nowPlaying(channel.number) {
                Section("On Now") {
                    Button { selected = now } label: {
                        ProgramRow(program: now, logo: nil, scheduled: dvr.isScheduled(now), now: Date())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }

            if !shows.isEmpty {
                Section {
                    ForEach(shows) { show in showRow(show) }
                } header: {
                    Text("Shows on \(channel.name)")
                } footer: {
                    Text(tuners.storageDevices.isEmpty
                         ? "To record, plug a USB drive into your HDHomeRun (or run HDHomeRun DVR on a NAS/PC)."
                         : "Record a show to catch every future episode automatically — even ones beyond the guide shown here.")
                }
            }

            ForEach(days) { day in
                Section(Fmt.day.string(from: day.day)) {
                    ForEach(day.programs) { p in
                        Button { selected = p } label: { scheduleRow(p) }
                            .buttonStyle(.plain)
                    }
                }
            }

            if upcoming.isEmpty {
                Section {
                    Text(guide.hasData ? "No guide data for this channel." : "Guide data hasn't loaded yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("\(channel.number) \(channel.name)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { p in
            NavigationStack { ProgramDetailView(program: p) }
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).font(.title2.weight(.bold))
                    Text([channel.number, guide.affiliate(channel.number), channel.isHD ? "HD" : nil, channel.codecBadge]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { playback.play(channel) } label: {
                    Label("Watch Now", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                Button { settings.toggleFavorite(channel.number) } label: {
                    Label(settings.isFavorite(channel.number) ? "Favorite" : "Add Favorite",
                          systemImage: settings.isFavorite(channel.number) ? "star.fill" : "star")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .tint(settings.isFavorite(channel.number) ? .yellow : .accentColor)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 4)
    }

    private func showRow(_ show: ShowSummary) -> some View {
        HStack(spacing: 12) {
            Artwork(url: show.imageURL, fallbackSymbol: show.genre?.symbol ?? "tv", cornerRadius: 8)
                .frame(width: 88, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(show.airings.count == 1 ? "Next: \(Fmt.smartDay(show.next.start))"
                     : "\(show.airings.count) airings · next \(Fmt.smartDay(show.next.start))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            recordControl(show)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = show.next }
    }

    @ViewBuilder
    private func recordControl(_ show: ShowSummary) -> some View {
        if dvr.hasSeriesRule(show.seriesID) {
            Label("Recording", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if let sid = show.seriesID, !tuners.storageDevices.isEmpty {
            Menu {
                Button { record(show, seriesID: sid, newOnly: true, onChannel: true) } label: {
                    Label("New Episodes on \(channel.name)", systemImage: "sparkles")
                }
                Button { record(show, seriesID: sid, newOnly: false, onChannel: true) } label: {
                    Label("All Episodes on \(channel.name)", systemImage: "square.stack.3d.down.right")
                }
                Button { record(show, seriesID: sid, newOnly: false, onChannel: false) } label: {
                    Label("All Episodes, Any Channel", systemImage: "antenna.radiowaves.left.and.right")
                }
                Divider()
                Button { recordOnce(show.next) } label: {
                    Label("Just \(Fmt.smartDay(show.next.start))", systemImage: "record.circle")
                }
            } label: {
                if working.contains(show.id) {
                    ProgressView()
                } else {
                    Label("Record", systemImage: "record.circle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.record.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.record)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func scheduleRow(_ p: GuideProgram) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Fmt.time.string(from: p.start))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(p.isAiring() ? Theme.live : .secondary)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if dvr.isScheduled(p) { RecordDot() }
                    if p.isNew { Pill(text: "NEW", color: .accentColor) }
                }
                if let sub = p.subtitleLine { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let g = p.primaryGenre {
                Circle().fill(g.color).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .contentShape(Rectangle())
    }

    private func record(_ show: ShowSummary, seriesID: String, newOnly: Bool, onChannel: Bool) {
        working.insert(show.id)
        Task {
            defer { working.remove(show.id) }
            do {
                try await dvr.recordSeries(seriesID: seriesID, newOnly: newOnly, channel: onChannel ? channel.number : nil,
                                           settings: settings, tuners: tuners)
                Haptics.success()
                message = "“\(show.title)” will record \(newOnly ? "new episodes" : "every episode")\(onChannel ? " on \(channel.name)" : "")."
            } catch {
                Haptics.error()
                message = error.localizedDescription
            }
        }
    }

    private func recordOnce(_ p: GuideProgram) {
        Task {
            do {
                try await dvr.record(p, mode: .once, settings: settings, tuners: tuners)
                Haptics.success()
                message = "Recording “\(p.title)” \(Fmt.smartDay(p.start))."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
