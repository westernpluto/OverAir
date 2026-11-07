import Foundation
import Observation

/// HDHomeRun DVR: recording rules (cloud), recorded content (record engine / device storage)
/// and upcoming scheduled recordings.
@MainActor
@Observable
final class DVRStore {
    private(set) var rules: [RecordingRule] = []
    private(set) var series: [RecordedSeries] = []
    private(set) var episodes: [String: [RecordedEpisode]] = [:]
    private(set) var upcoming: [UpcomingEpisode] = []
    private(set) var isLoading = false
    var lastError: String?

    /// Fast lookup of (channel, start) pairs that are scheduled to record.
    private(set) var scheduledKeys: Set<String> = []

    var allEpisodes: [RecordedEpisode] {
        episodes.values.flatMap { $0 }.sorted { ($0.recordStart ?? .distantPast) > ($1.recordStart ?? .distantPast) }
    }

    var recordingNow: [RecordedEpisode] { allEpisodes.filter(\.isRecordingNow) }

    var continueWatching: [RecordedEpisode] {
        allEpisodes.filter { $0.resumeSeconds != nil }.prefix(12).map { $0 }
    }

    var recentlyAdded: [RecordedEpisode] { Array(allEpisodes.filter { !$0.isWatched }.prefix(20)) }

    static func key(channel: String?, start: Date) -> String { "\(channel ?? "")@\(Int(start.timeIntervalSince1970))" }

    func isScheduled(_ program: GuideProgram) -> Bool {
        if scheduledKeys.contains(DVRStore.key(channel: program.channelNumber, start: program.start)) { return true }
        return false
    }

    func hasSeriesRule(_ seriesID: String?) -> Bool {
        guard let seriesID else { return false }
        return rules.contains { $0.seriesID == seriesID && !$0.isOneTime }
    }

    func rule(for program: GuideProgram) -> RecordingRule? {
        rules.first { r in
            guard r.seriesID == program.seriesID else { return false }
            if let dt = r.dateTimeOnly { return abs(dt.timeIntervalSince(program.start)) < 60 }
            return true
        }
    }

    // MARK: Refresh

    func refresh(tuners: TunerStore) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        lastError = nil

        async let r: Void = refreshRules(auth: tuners.deviceAuth)
        async let rec: Void = refreshRecordings(storage: tuners.storageDevices)
        _ = await (r, rec)
        await refreshUpcoming(auth: tuners.deviceAuth)
    }

    func refreshRules(auth: String?) async {
        guard let auth else { return }
        do { rules = try await CloudAPI.recordingRules(deviceAuth: auth) } catch { lastError = error.localizedDescription }
    }

    func refreshRecordings(storage: [HDHRDevice]) async {
        var allSeries: [RecordedSeries] = []
        var allEpisodes: [String: [RecordedEpisode]] = [:]
        for s in storage {
            do {
                let list = try await HDHRClient.recordedSeries(storage: s)
                allSeries.append(contentsOf: list)
                await withTaskGroup(of: (String, [RecordedEpisode]).self) { group in
                    for item in list {
                        group.addTask { (item.seriesID, (try? await HDHRClient.episodes(for: item, storage: s)) ?? []) }
                    }
                    for await (id, eps) in group { allEpisodes[id, default: []].append(contentsOf: eps) }
                }
            } catch {
                lastError = "Couldn't load recordings from \(s.friendlyName): \(error.localizedDescription)"
            }
        }
        series = allSeries.sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
        episodes = allEpisodes
    }

    func refreshUpcoming(auth: String?) async {
        guard let auth else { return }
        let ids = Array(Set(rules.compactMap(\.seriesID))).prefix(60)
        var all: [UpcomingEpisode] = []
        await withTaskGroup(of: [UpcomingEpisode].self) { group in
            for id in ids { group.addTask { (try? await CloudAPI.episodes(seriesID: id, deviceAuth: auth)) ?? [] } }
            for await list in group { all.append(contentsOf: list) }
        }
        let now = Date()
        upcoming = all.filter { $0.isScheduled && $0.end > now }.sorted { $0.start < $1.start }
        scheduledKeys = Set(upcoming.map { DVRStore.key(channel: $0.channelNumber, start: $0.start) })
    }

    func loadEpisodes(for s: RecordedSeries, tuners: TunerStore) async {
        guard let storage = tuners.storageDevices.first(where: { $0.id == s.storageDeviceID }) ?? tuners.storageDevices.first else { return }
        if let eps = try? await HDHRClient.episodes(for: s, storage: storage) { episodes[s.seriesID] = eps }
    }

    // MARK: Actions

    enum RecordMode { case once, series, newOnly }

    func record(_ program: GuideProgram, mode: RecordMode, settings: AppSettings, tuners: TunerStore) async throws {
        guard let auth = tuners.deviceAuth else { throw HTTPError.unreachable("No DeviceAuth — connect to your tuner first.") }
        guard let seriesID = program.seriesID else { throw HTTPError.unreachable("This program can't be scheduled (no series information).") }
        guard !tuners.storageDevices.isEmpty else {
            throw HTTPError.unreachable("No HDHomeRun storage found. Attach a USB drive to your FLEX 4K or run HDHomeRun DVR on a NAS/PC.")
        }
        var opts = CloudAPI.RuleOptions()
        opts.startPadding = settings.startPaddingSeconds
        opts.endPadding = settings.endPaddingSeconds
        switch mode {
        case .once:
            opts.dateTimeOnly = program.start
            opts.channelOnly = program.channelNumber
        case .series:
            break
        case .newOnly:
            opts.recentOnly = true
        }
        try await CloudAPI.addRule(seriesID: seriesID, options: opts, deviceAuth: auth)
        await syncAll(tuners: tuners)
        // Optimistically mark scheduled while the cloud updates.
        scheduledKeys.insert(DVRStore.key(channel: program.channelNumber, start: program.start))
    }

    func addSeriesRule(_ result: SeriesSearchResult, newOnly: Bool, channel: String?, settings: AppSettings, tuners: TunerStore) async throws {
        guard let auth = tuners.deviceAuth else { return }
        var opts = CloudAPI.RuleOptions()
        opts.recentOnly = newOnly
        opts.channelOnly = channel
        opts.startPadding = settings.startPaddingSeconds
        opts.endPadding = settings.endPaddingSeconds
        try await CloudAPI.addRule(seriesID: result.seriesID, options: opts, deviceAuth: auth)
        await syncAll(tuners: tuners)
    }

    func cancel(_ program: GuideProgram, tuners: TunerStore) async throws {
        guard let auth = tuners.deviceAuth, let rule = rule(for: program) else { return }
        try await CloudAPI.deleteRule(rule, deviceAuth: auth)
        scheduledKeys.remove(DVRStore.key(channel: program.channelNumber, start: program.start))
        await syncAll(tuners: tuners)
    }

    func delete(_ rule: RecordingRule, tuners: TunerStore) async {
        guard let auth = tuners.deviceAuth else { return }
        do {
            try await CloudAPI.deleteRule(rule, deviceAuth: auth)
            rules.removeAll { $0.id == rule.id }
            await syncAll(tuners: tuners)
        } catch { lastError = error.localizedDescription }
    }

    func update(_ rule: RecordingRule, startPadding: Int, endPadding: Int, recentOnly: Bool, channelOnly: String?, tuners: TunerStore) async {
        guard let auth = tuners.deviceAuth else { return }
        do {
            try await CloudAPI.changeRule(rule, startPadding: startPadding, endPadding: endPadding, recentOnly: recentOnly, channelOnly: channelOnly, deviceAuth: auth)
            await syncAll(tuners: tuners)
        } catch { lastError = error.localizedDescription }
    }

    func move(from source: IndexSet, to destination: Int, tuners: TunerStore) async {
        guard let auth = tuners.deviceAuth, let from = source.first else { return }
        var list = rules
        let item = list.remove(at: from)
        let insertAt = destination > from ? destination - 1 : destination
        list.insert(item, at: insertAt)
        rules = list
        let after: RecordingRule? = insertAt == 0 ? nil : list[insertAt - 1]
        do {
            try await CloudAPI.moveRule(item, after: after, deviceAuth: auth)
            await syncAll(tuners: tuners)
        } catch { lastError = error.localizedDescription }
    }

    func delete(_ episode: RecordedEpisode, rerecord: Bool, tuners: TunerStore) async {
        do {
            try await HDHRClient.deleteRecording(episode, allowRerecord: rerecord)
            for (k, v) in episodes { episodes[k] = v.filter { $0.id != episode.id } }
            series.removeAll { (episodes[$0.seriesID] ?? []).isEmpty }
        } catch { lastError = error.localizedDescription }
    }

    func setWatched(_ episode: RecordedEpisode, watched: Bool) async {
        let value = watched ? RecordedEpisode.watchedMarker : 0
        await saveResume(episode, seconds: value)
    }

    func saveResume(_ episode: RecordedEpisode, seconds: Int) async {
        try? await HDHRClient.setResume(episode, seconds: seconds)
        for (k, v) in episodes {
            if let i = v.firstIndex(where: { $0.id == episode.id }) {
                var copy = v
                copy[i].resume = seconds
                episodes[k] = copy
            }
        }
    }

    private func syncAll(tuners: TunerStore) async {
        for s in tuners.storageDevices { await HDHRClient.syncRecordEngine(s) }
        await refreshRules(auth: tuners.deviceAuth)
        await refreshUpcoming(auth: tuners.deviceAuth)
    }

    // MARK: Storage

    func storageSummary(_ tuners: TunerStore) -> (used: Int64, total: Int64)? {
        let devs = tuners.storageDevices.filter { ($0.totalSpace ?? 0) > 0 }
        guard !devs.isEmpty else { return nil }
        let total = devs.reduce(Int64(0)) { $0 + ($1.totalSpace ?? 0) }
        let free = devs.reduce(Int64(0)) { $0 + ($1.freeSpace ?? 0) }
        return (total - free, total)
    }
}
