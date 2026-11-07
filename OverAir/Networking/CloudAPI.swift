import Foundation

/// SiliconDust cloud services: discovery, guide data and DVR rule management.
enum CloudAPI {
    static let apiBase = URL(string: "https://api.hdhomerun.com/api")!
    static let discoverURL = URL(string: "https://ipv4-api.hdhomerun.com/discover")!

    static func discover() async throws -> [CloudDiscoverEntry] {
        try await HTTP.get(discoverURL, timeout: 5)
    }

    /// Fetches guide data in 4-hour windows until `hours` are covered.
    static func guide(deviceAuth: String, from start: Date, hours: Int) async throws -> [CloudGuideChannel] {
        var merged: [String: CloudGuideChannel] = [:]
        var order: [String] = []
        var cursor = start
        let end = start.addingTimeInterval(TimeInterval(hours) * 3600)
        var iterations = 0
        while cursor < end && iterations < max(12, hours / 2 + 4) {
            iterations += 1
            let url = apiBase.appendingPathComponent("guide").appendingQuery([
                "DeviceAuth": deviceAuth,
                "Start": String(Int(cursor.timeIntervalSince1970))
            ])
            let chunk: [CloudGuideChannel] = try await HTTP.get(url, timeout: 20)
            if chunk.isEmpty { break }
            var latestEnd = cursor
            for ch in chunk {
                if var existing = merged[ch.guideNumber] {
                    let known = Set(existing.guide.map { $0.start })
                    existing.guide.append(contentsOf: ch.guide.filter { !known.contains($0.start) })
                    merged[ch.guideNumber] = existing
                } else {
                    merged[ch.guideNumber] = ch
                    order.append(ch.guideNumber)
                }
                if let last = ch.guide.map(\.end).max(), last > latestEnd { latestEnd = last }
            }
            if latestEnd <= cursor { break }
            cursor = latestEnd
        }
        return order.compactMap { merged[$0] }
    }

    static func search(_ text: String, deviceAuth: String) async throws -> [SeriesSearchResult] {
        let url = apiBase.appendingPathComponent("search").appendingQuery(["DeviceAuth": deviceAuth, "Search": text])
        return try await HTTP.get(url)
    }

    static func episodes(seriesID: String, deviceAuth: String) async throws -> [UpcomingEpisode] {
        let url = apiBase.appendingPathComponent("episodes").appendingQuery(["DeviceAuth": deviceAuth, "SeriesID": seriesID])
        return try await HTTP.get(url)
    }

    static func recordingRules(deviceAuth: String) async throws -> [RecordingRule] {
        let url = apiBase.appendingPathComponent("recording_rules").appendingQuery(["DeviceAuth": deviceAuth])
        let rules: [RecordingRule] = try await HTTP.get(url)
        return rules.sorted { $0.priority > $1.priority }
    }

    struct RuleOptions: Sendable {
        var recentOnly = false
        var channelOnly: String?
        var startPadding = 30
        var endPadding = 30
        var dateTimeOnly: Date?
        var afterOriginalAirdateOnly: Date?
    }

    static func addRule(seriesID: String, options: RuleOptions, deviceAuth: String) async throws {
        var form: [String: String] = [
            "DeviceAuth": deviceAuth,
            "Cmd": "add",
            "SeriesID": seriesID,
            "StartPadding": String(options.startPadding),
            "EndPadding": String(options.endPadding)
        ]
        if options.recentOnly { form["RecentOnly"] = "1" }
        if let ch = options.channelOnly { form["ChannelOnly"] = ch }
        if let dt = options.dateTimeOnly { form["DateTimeOnly"] = String(Int(dt.timeIntervalSince1970)) }
        if let a = options.afterOriginalAirdateOnly { form["AfterOriginalAirdateOnly"] = String(Int(a.timeIntervalSince1970)) }
        try await HTTP.post(apiBase.appendingPathComponent("recording_rules"), form: form)
    }

    static func deleteRule(_ rule: RecordingRule, deviceAuth: String) async throws {
        try await HTTP.post(apiBase.appendingPathComponent("recording_rules"), form: [
            "DeviceAuth": deviceAuth, "Cmd": "delete", "RecordingRuleID": rule.ruleID
        ])
    }

    static func changeRule(_ rule: RecordingRule, startPadding: Int, endPadding: Int, recentOnly: Bool, channelOnly: String?, deviceAuth: String) async throws {
        var form: [String: String] = [
            "DeviceAuth": deviceAuth, "Cmd": "change", "RecordingRuleID": rule.ruleID,
            "StartPadding": String(startPadding), "EndPadding": String(endPadding),
            "RecentOnly": recentOnly ? "1" : "0"
        ]
        form["ChannelOnly"] = channelOnly ?? ""
        try await HTTP.post(apiBase.appendingPathComponent("recording_rules"), form: form)
    }

    /// Moves `rule` to sit directly after `after` in priority order (nil = top).
    static func moveRule(_ rule: RecordingRule, after: RecordingRule?, deviceAuth: String) async throws {
        try await HTTP.post(apiBase.appendingPathComponent("recording_rules"), form: [
            "DeviceAuth": deviceAuth, "Cmd": "change", "RecordingRuleID": rule.ruleID,
            "AfterRecordingRuleID": after?.ruleID ?? "0"
        ])
    }
}
