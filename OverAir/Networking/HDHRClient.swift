import Foundation

/// Talks directly to a HDHomeRun tuner / record engine over its local HTTP API.
enum HDHRClient {
    static func discover(at base: URL, hostOverride: String? = nil, timeout: TimeInterval = 4, probe: Bool = false) async throws -> HDHRDevice {
        let url = base.appendingPathComponent("discover.json")
        let response: DiscoverResponse = try await HTTP.get(url, timeout: timeout, session: probe ? HTTP.probeSession : HTTP.session)
        guard let device = response.makeDevice(fallbackBase: base, hostOverride: hostOverride) else {
            throw HTTPError.decoding("Not a HDHomeRun device")
        }
        return device
    }

    static func lineup(for device: HDHRDevice) async throws -> [Channel] {
        let url = device.reachable(device.lineupURL ?? device.baseURL.appendingPathComponent("lineup.json"))
        let entries: [LineupEntry] = try await HTTP.get(url)
        return entries.map { e in
            Channel(number: e.guideNumber, name: e.guideName, videoCodec: e.videoCodec, audioCodec: e.audioCodec,
                    isHD: e.hd, isDRM: e.drm, isFavoriteOnDevice: e.favorite,
                    streamURL: e.url.map(device.reachable), deviceID: device.deviceID)
        }
        .sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
    }

    static func tunerStatus(for device: HDHRDevice) async throws -> [TunerStatus] {
        try await HTTP.get(device.effectiveBaseURL.appendingPathComponent("status.json"), timeout: 4)
    }

    static func lineupStatus(for device: HDHRDevice) async throws -> LineupStatus {
        try await HTTP.get(device.effectiveBaseURL.appendingPathComponent("lineup_status.json"), timeout: 4)
    }

    static func startScan(on device: HDHRDevice, source: String = "Antenna") async throws {
        let url = device.effectiveBaseURL.appendingPathComponent("lineup.post").appendingQuery(["scan": "start", "source": source])
        try await HTTP.post(url)
    }

    static func abortScan(on device: HDHRDevice) async throws {
        let url = device.effectiveBaseURL.appendingPathComponent("lineup.post").appendingQuery(["scan": "abort"])
        try await HTTP.post(url)
    }

    /// Builds a live stream URL. The FLEX 4K streams the native MPEG-TS on port 5004.
    static func streamURL(for channel: Channel, on device: HDHRDevice?, preferTuner: Int? = nil) -> URL? {
        if let preferTuner, let device {
            var base = device.effectiveBaseURL.replacingHost(device.effectiveBaseURL.host ?? "", port: 5004)
            base = base.appendingPathComponent("tuner\(preferTuner)").appendingPathComponent("v\(channel.number)")
            return base
        }
        if let url = channel.streamURL { return url }
        guard let device, let host = device.effectiveBaseURL.host else { return nil }
        return URL(string: "http://\(host):5004/auto/v\(channel.number)")
    }

    // MARK: - Record engine

    static func recordedSeries(storage: HDHRDevice) async throws -> [RecordedSeries] {
        guard let storageURL = storage.storageURL else { return [] }
        var series: [RecordedSeries] = try await HTTP.get(storage.reachable(storageURL))
        for i in series.indices {
            series[i].storageDeviceID = storage.id
            if let u = series[i].episodesURL { series[i].episodesURL = storage.reachable(u) }
        }
        return series
    }

    static func episodes(for series: RecordedSeries, storage: HDHRDevice) async throws -> [RecordedEpisode] {
        let url: URL
        if let e = series.episodesURL {
            url = storage.reachable(e)
        } else if let s = storage.storageURL {
            url = storage.reachable(s).appendingQuery(["SeriesID": series.seriesID])
        } else {
            return []
        }
        var eps: [RecordedEpisode] = try await HTTP.get(url)
        for i in eps.indices {
            if let p = eps[i].playURL { eps[i].playURL = storage.reachable(p) }
            if let c = eps[i].cmdURL { eps[i].cmdURL = storage.reachable(c) }
        }
        return eps.sorted { ($0.recordStart ?? .distantPast) > ($1.recordStart ?? .distantPast) }
    }

    static func deleteRecording(_ episode: RecordedEpisode, allowRerecord: Bool) async throws {
        guard let cmd = episode.cmdURL else { return }
        try await HTTP.post(cmd.appendingQuery(["cmd": "delete", "rerecord": allowRerecord ? "1" : "0"]))
    }

    static func setResume(_ episode: RecordedEpisode, seconds: Int) async throws {
        guard let cmd = episode.cmdURL else { return }
        try await HTTP.post(cmd.appendingQuery(["cmd": "set", "Resume": String(seconds)]))
    }

    /// Asks the record engine to re-sync rules from the cloud after changes.
    static func syncRecordEngine(_ storage: HDHRDevice) async {
        let url = storage.effectiveBaseURL.appendingPathComponent("recording_events.post").appendingQuery(["sync": ""])
        _ = try? await HTTP.post(url)
    }
}
