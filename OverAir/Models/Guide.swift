import Foundation

struct GuideChannel: Codable, Identifiable, Hashable, Sendable {
    var id: String { number }
    var number: String
    var name: String
    var affiliate: String?
    var logoURL: URL?
    var programs: [GuideProgram]
}

struct GuideProgram: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(channelNumber)-\(Int(start.timeIntervalSince1970))" }
    var channelNumber: String
    var start: Date
    var end: Date
    var title: String
    var episodeNumber: String?
    var episodeTitle: String?
    var synopsis: String?
    var imageURL: URL?
    var posterURL: URL?
    var originalAirdate: Date?
    var seriesID: String?
    var programID: String?
    var filters: [String]
    var isFirstAiring: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func isAiring(at date: Date = Date()) -> Bool { start <= date && date < end }

    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    var category: ProgramCategory {
        let f = Set(filters.map { $0.lowercased() })
        if f.contains("movies") || f.contains("movie") { return .movie }
        if f.contains("sports") { return .sports }
        if f.contains("news") { return .news }
        if f.contains("kids") { return .kids }
        return .show
    }

    var isNew: Bool {
        if isFirstAiring { return true }
        guard let originalAirdate else { return false }
        return abs(originalAirdate.timeIntervalSince(start)) < 60 * 60 * 36
    }

    var subtitleLine: String? {
        let parts = [episodeNumber, episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ProgramCategory: String, CaseIterable, Identifiable, Sendable {
    case all, movie, sports, news, kids, show
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .movie: return "Movies"
        case .sports: return "Sports"
        case .news: return "News"
        case .kids: return "Kids"
        case .show: return "Shows"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .movie: return "film"
        case .sports: return "sportscourt"
        case .news: return "newspaper"
        case .kids: return "teddybear"
        case .show: return "tv"
        }
    }
}

// MARK: - Cloud guide decoding

struct CloudGuideChannel: Decodable, Sendable {
    var guideNumber: String
    var guideName: String
    var affiliate: String?
    var imageURL: URL?
    var guide: [CloudGuideProgram]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        guideNumber = c.str("GuideNumber") ?? "?"
        guideName = c.str("GuideName") ?? ""
        affiliate = c.str("Affiliate")
        imageURL = c.url("ImageURL")
        guide = (try? c.decodeIfPresent([CloudGuideProgram].self, forKey: JSONKey("Guide"))) ?? []
    }
}

struct CloudGuideProgram: Decodable, Sendable {
    var start: Date
    var end: Date
    var title: String
    var episodeNumber: String?
    var episodeTitle: String?
    var synopsis: String?
    var imageURL: URL?
    var posterURL: URL?
    var originalAirdate: Date?
    var seriesID: String?
    var programID: String?
    var filters: [String]
    var first: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        start = c.date("StartTime") ?? Date.distantPast
        end = c.date("EndTime") ?? Date.distantPast
        title = c.str("Title") ?? "Unknown"
        episodeNumber = c.str("EpisodeNumber")
        episodeTitle = c.str("EpisodeTitle")
        synopsis = c.str("Synopsis")
        imageURL = c.url("ImageURL")
        posterURL = c.url("PosterURL")
        originalAirdate = c.date("OriginalAirdate")
        seriesID = c.str("SeriesID")
        programID = c.str("ProgramID")
        filters = c.strings("Filter")
        first = c.bool("First") ?? false
    }

    func program(channel: String) -> GuideProgram {
        GuideProgram(channelNumber: channel, start: start, end: end, title: title,
                     episodeNumber: episodeNumber, episodeTitle: episodeTitle, synopsis: synopsis,
                     imageURL: imageURL, posterURL: posterURL, originalAirdate: originalAirdate,
                     seriesID: seriesID, programID: programID, filters: filters, isFirstAiring: first)
    }
}
