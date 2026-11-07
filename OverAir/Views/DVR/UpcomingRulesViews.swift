import SwiftUI

struct UpcomingView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(GuideStore.self) private var guide

    private struct DayGroup: Identifiable {
        var id: Date { day }
        var day: Date
        var items: [UpcomingEpisode]
    }

    private var grouped: [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: dvr.upcoming) { (ep: UpcomingEpisode) in cal.startOfDay(for: ep.start) }
        return dict.keys.sorted().map { (day: Date) in
            DayGroup(day: day, items: (dict[day] ?? []).sorted { (a: UpcomingEpisode, b: UpcomingEpisode) in a.start < b.start })
        }
    }

    var body: some View {
        List {
            if dvr.upcoming.isEmpty {
                EmptyStateView(symbol: "calendar", title: "Nothing Scheduled", message: "Recordings you schedule will appear here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(grouped) { group in
                Section(Fmt.day.string(from: group.day)) {
                    ForEach(group.items) { ep in
                        HStack(spacing: 12) {
                            Artwork(url: ep.imageURL, fallbackSymbol: "calendar", cornerRadius: 8).frame(width: 84, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if let t = ep.episodeTitle { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Text("\(Fmt.range(ep.start, ep.end)) · \(ep.channelNumber ?? "") \(ep.channelName ?? "")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ep.start <= Date() { RecordDot() }
                        }
                    }
                }
            }
            if conflicts > 0 {
                Section {
                    Label("\(conflicts) time slot(s) need more tuners than you have (\(tuners.totalTuners)). Lower-priority rules may be skipped.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .refreshable { await dvr.refresh(tuners: tuners) }
    }

    /// Counts moments where scheduled recordings exceed the available tuners.
    private var conflicts: Int {
        let tunerCount = max(tuners.totalTuners, 1)
        var count = 0
        for ep in dvr.upcoming {
            let overlapping = dvr.upcoming.filter { $0.start < ep.end && $0.end > ep.start }.count
            if overlapping > tunerCount { count += 1 }
        }
        return count
    }
}

struct RulesView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @State private var editing: RecordingRule?

    var body: some View {
        List {
            if dvr.rules.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: "No Recording Rules", message: "Tap + to find a show and record every episode.")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(dvr.rules) { rule in
                        Button { editing = rule } label: { RuleRow(rule: rule) }
                            .foregroundStyle(.primary)
                    }
                    .onMove { from, to in Task { await dvr.move(from: from, to: to, tuners: tuners) } }
                    .onDelete { idx in
                        let toDelete = idx.map { dvr.rules[$0] }
                        Task { for r in toDelete { await dvr.delete(r, tuners: tuners) } }
                    }
                } header: {
                    Text("Priority order")
                } footer: {
                    Text("When tuners are busy, rules higher in the list win. Drag to reorder.")
                }
            }
        }
        .toolbar { if !dvr.rules.isEmpty { EditButton() } }
        .refreshable { await dvr.refresh(tuners: tuners) }
        .sheet(item: $editing) { rule in RuleEditor(rule: rule) }
    }
}

struct RuleRow: View {
    var rule: RecordingRule
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: rule.imageURL, fallbackSymbol: "record.circle", cornerRadius: 8).frame(width: 72, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var description: String {
        var parts: [String] = []
        if let dt = rule.dateTimeOnly { parts.append("Once · \(Fmt.smartDay(dt))") } else { parts.append(rule.recentOnly ? "New episodes" : "All episodes") }
        if let ch = rule.channelOnly, !ch.isEmpty { parts.append("Ch \(ch)") }
        parts.append("+\(rule.startPadding / 60)m/+\(rule.endPadding / 60)m")
        return parts.joined(separator: " · ")
    }
}

struct RuleEditor: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(\.dismiss) private var dismiss
    var rule: RecordingRule

    @State private var startPad = 0
    @State private var endPad = 0
    @State private var recentOnly = false
    @State private var channel = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Artwork(url: rule.imageURL, cornerRadius: 8).frame(width: 90, height: 50)
                        VStack(alignment: .leading) {
                            Text(rule.title).font(.headline)
                            if let s = rule.synopsis { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                }
                if !rule.isOneTime {
                    Section("Episodes") {
                        Toggle("New Episodes Only", isOn: $recentOnly)
                        Picker("Channel", selection: $channel) {
                            Text("Any Channel").tag("")
                            ForEach(tuners.visibleChannels) { Text("\($0.number) \($0.name)").tag($0.number) }
                        }
                    }
                }
                Section("Padding") {
                    Stepper("Start early: \(startPad / 60) min", value: $startPad, in: 0...1800, step: 60)
                    Stepper("End late: \(endPad / 60) min", value: $endPad, in: 0...3600, step: 60)
                }
                Section {
                    Button("Delete Rule", role: .destructive) {
                        Task { await dvr.delete(rule, tuners: tuners); dismiss() }
                    }
                }
            }
            .navigationTitle("Recording Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await dvr.update(rule, startPadding: startPad, endPadding: endPad, recentOnly: recentOnly, channelOnly: channel.isEmpty ? nil : channel, tuners: tuners)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                startPad = rule.startPadding
                endPad = rule.endPadding
                recentOnly = rule.recentOnly
                channel = rule.channelOnly ?? ""
            }
        }
    }
}

struct SeriesSearchView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(DVRStore.self) private var dvr
    @Environment(GuideStore.self) private var guide
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SeriesSearchResult] = []
    @State private var searching = false
    @State private var added: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                ForEach(results) { r in
                    HStack(spacing: 12) {
                        Artwork(url: r.imageURL, fallbackSymbol: "tv", cornerRadius: 8).frame(width: 90, height: 50)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.subheadline.weight(.semibold))
                            if let s = r.synopsis { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            if !r.channelNumbers.isEmpty {
                                Text("Channels: \(r.channelNumbers.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if added.contains(r.seriesID) || dvr.hasSeriesRule(r.seriesID) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                        } else {
                            Menu {
                                Button("All Episodes") { add(r, newOnly: false) }
                                Button("New Episodes Only") { add(r, newOnly: true) }
                            } label: {
                                Image(systemName: "record.circle").font(.title2).foregroundStyle(Theme.record)
                            }
                        }
                    }
                }
            }
            .overlay {
                if searching { ProgressView() }
                else if results.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
                else if results.isEmpty { ContentUnavailableView("Find Shows", systemImage: "magnifyingglass", description: Text("Search for shows, movies and teams to record.")) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Shows, movies, teams")
            .onSubmit(of: .search) { Task { await search() } }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await search()
            }
            .navigationTitle("Record a Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let auth = tuners.deviceAuth else { results = []; return }
        searching = true
        defer { searching = false }
        do {
            results = try await CloudAPI.search(q, deviceAuth: auth)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ r: SeriesSearchResult, newOnly: Bool) {
        Task {
            do {
                try await dvr.addSeriesRule(r, newOnly: newOnly, channel: nil, settings: settings, tuners: tuners)
                added.insert(r.seriesID)
                Haptics.success()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct LocalRecordingsView: View {
    @Environment(LocalRecorder.self) private var recorder
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        List {
            if !recorder.active.isEmpty {
                Section("Recording Now") {
                    ForEach(Array(recorder.active.values), id: \.id) { a in
                        HStack {
                            RecordDot()
                            VStack(alignment: .leading) {
                                Text(a.recording.title).font(.subheadline.weight(.semibold))
                                Text("\(a.recording.channelNumber) · \(Fmt.bytes(a.bytes))\(a.stopAt.map { " · until \(Fmt.time.string(from: $0))" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop") { recorder.stop(a.id) }.buttonStyle(.bordered).tint(.red)
                        }
                    }
                }
            }
            Section {
                if recorder.recordings.isEmpty {
                    Text("Use Record → This iPhone on any live channel to save shows for offline viewing. Files also appear in the Files app under OverAir.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(recorder.recordings) { rec in
                    Button { playback.play(rec) } label: {
                        HStack(spacing: 12) {
                            Artwork(url: rec.imageURL, fallbackSymbol: "iphone", cornerRadius: 8).frame(width: 84, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(Fmt.smartDay(rec.started)) · \(rec.channelNumber) · \(Fmt.bytes(rec.bytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) { recorder.delete(rec) } label: { Label("Delete", systemImage: "trash") }
                        ShareLink(item: rec.fileURL) { Label("Share", systemImage: "square.and.arrow.up") }.tint(.blue)
                    }
                }
            } header: {
                if !recorder.recordings.isEmpty { Text("Saved on iPhone") }
            }
            if let e = recorder.lastError {
                Section { Text(e).font(.footnote).foregroundStyle(.orange) }
            }
        }
    }
}
