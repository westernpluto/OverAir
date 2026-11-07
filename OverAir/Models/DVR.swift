import Foundation

struct RecordingRule: Decodable, Identifiable, Hashable, Sendable {
    var id: String { ruleID }
    var ruleID: String
    var seriesID: String?
    var title: String
    var synopsis: String?
    var imageURL: URL?
    var channelOnly: String?
    var recentOnly: Bool
    var teamOnly: String?
    var startPadding: Int
    var endPadding: Int
    var priority: Int
    var dateTimeOnly: Date?
    var afterOriginalAirdateOnly: Date?

    var isOneTime: Bool { dateTimeOnly != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        ruleID = c.str("RecordingRuleID") ?? UUID().uuidString
        seriesID = c.str("SeriesID")
        title = c.str("Title") ?? "Untitled"
        synopsis = c.str("Synopsis")
        imageURL = c.url("ImageURL")
        channelOnly = c.str("ChannelOnly")
        recentOnly = c.bool("RecentOnly") ?? false
        teamOnly = c.str("TeamOnly")
        startPadding = c.int("StartPadding") ?? 30
        endPadding = c.int("EndPadding") ?? 30
        priority = c.int("Priority") ?? 0
        dateTimeOnly = c.date("DateTimeOnly")
        afterOriginalAirdateOnly = c.date("AfterOriginalAirdateOnly")
    }
}

struct SeriesSearchResult: Decodable, Identifiable, Hashable, Sendable {
    var id: String { seriesID }
    var seriesID: String
    var title: String
    var synopsis: String?
    var imageURL: URL?
    var channelNumbers: [String]
    var category: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        seriesID = c.str("SeriesID") ?? UUID().uuidString
        title = c.str("Title") ?? "Untitled"
        synopsis = c.str("Synopsis")
        imageURL = c.url("ImageURL")
        if let list = try? c.decodeIfPresent([SearchChannel].self, forKey: JSONKey("ChannelList")) {
            channelNumbers = list.compactMap(\.number)
        } else {
            channelNumbers = c.str("ChannelNumber").map { [$0] } ?? []
        }
        category = c.str("Category")
    }

    private struct SearchChannel: Decodable {
        var number: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: JSONKey.self)
            number = c.str("ChannelNumber") ?? c.str("GuideNumber")
        }
    }
}

struct UpcomingEpisode: Decodable, Identifiable, Hashable, Sendable {
    var id: String { "\(programID ?? title)-\(Int(start.timeIntervalSince1970))-\(channelNumber ?? "")" }
    var programID: String?
    var seriesID: String?
    var title: String
    var episodeNumber: String?
    var episodeTitle: String?
    var synopsis: String?
    var imageURL: URL?
    var start: Date
    var end: Date
    var channelNumber: String?
    var channelName: String?
    var channelImageURL: URL?
    var isScheduled: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        programID = c.str("ProgramID")
        seriesID = c.str("SeriesID")
        title = c.str("Title") ?? "Untitled"
        episodeNumber = c.str("EpisodeNumber")
        episodeTitle = c.str("EpisodeTitle")
        synopsis = c.str("Synopsis")
        imageURL = c.url("ImageURL")
        start = c.date("StartTime") ?? .distantPast
        end = c.date("EndTime") ?? .distantPast
        channelNumber = c.str("ChannelNumber")
        channelName = c.str("ChannelName")
        channelImageURL = c.url("ChannelImageURL")
        isScheduled = (c.int("RecordingRule") ?? 0) != 0
    }
}

/// A series folder in the record engine's `recorded_files.json`.
struct RecordedSeries: Decodable, Identifiable, Hashable, Sendable {
    var id: String { seriesID }
    var seriesID: String
    var title: String
    var category: String?
    var imageURL: URL?
    var posterURL: URL?
    var startTime: Date?
    var episodesURL: URL?
    var storageDeviceID: String = ""

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        seriesID = c.str("SeriesID") ?? UUID().uuidString
        title = c.str("Title") ?? "Untitled"
        category = c.str("Category")
        imageURL = c.url("ImageURL")
        posterURL = c.url("PosterURL")
        startTime = c.date("StartTime")
        episodesURL = c.url("EpisodesURL")
    }
}

struct RecordedEpisode: Decodable, Identifiable, Hashable, Sendable {
    var id: String { programID.map { "\($0)-\(Int(recordStart?.timeIntervalSince1970 ?? 0))" } ?? (playURL?.absoluteString ?? title) }
    var programID: String?
    var seriesID: String?
    var title: String
    var episodeNumber: String?
    var episodeTitle: String?
    var synopsis: String?
    var category: String?
    var imageURL: URL?
    var channelNumber: String?
    var channelName: String?
    var channelImageURL: URL?
    var originalAirdate: Date?
    var start: Date?
    var end: Date?
    var recordStart: Date?
    var recordEnd: Date?
    var resume: Int
    var playURL: URL?
    var cmdURL: URL?
    var filename: String?
    var recordSuccess: Bool

    static let watchedMarker = 4_294_967_295

    var isWatched: Bool { resume == Self.watchedMarker }
    var resumeSeconds: Int? { (resume > 0 && !isWatched) ? resume : nil }

    var duration: TimeInterval {
        if let s = recordStart, let e = recordEnd { return e.timeIntervalSince(s) }
        if let s = start, let e = end { return e.timeIntervalSince(s) }
        return 0
    }

    var isRecordingNow: Bool {
        guard let rs = recordStart else { return false }
        let now = Date()
        if let re = recordEnd { return rs <= now && now < re.addingTimeInterval(-5) && (end ?? re) > now }
        return rs <= now
    }

    var subtitleLine: String? {
        let parts = [episodeNumber, episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        programID = c.str("ProgramID")
        seriesID = c.str("SeriesID")
        title = c.str("Title") ?? "Untitled"
        episodeNumber = c.str("EpisodeNumber")
        episodeTitle = c.str("EpisodeTitle")
        synopsis = c.str("Synopsis")
        category = c.str("Category")
        imageURL = c.url("ImageURL")
        channelNumber = c.str("ChannelNumber")
        channelName = c.str("ChannelName")
        channelImageURL = c.url("ChannelImageURL")
        originalAirdate = c.date("OriginalAirdate")
        start = c.date("StartTime")
        end = c.date("EndTime")
        recordStart = c.date("RecordStartTime")
        recordEnd = c.date("RecordEndTime")
        resume = c.int("Resume") ?? 0
        playURL = c.url("PlayURL")
        cmdURL = c.url("CmdURL")
        filename = c.str("Filename")
        recordSuccess = c.bool("RecordSuccess") ?? true
    }
}

/// A recording captured directly onto this iPhone.
struct LocalRecording: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String?
    var channelNumber: String
    var channelName: String
    var imageURL: URL?
    var started: Date
    var ended: Date?
    var fileName: String
    var bytes: Int64
    var resumeSeconds: Double?

    var fileURL: URL { LocalRecording.directory.appendingPathComponent(fileName) }

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
