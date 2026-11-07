import Foundation
import Observation

@MainActor
@Observable
final class GuideStore {
    private(set) var channels: [GuideChannel] = []
    private(set) var byNumber: [String: GuideChannel] = [:]
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    var lastError: String?

    init() {
        if let cached = Persistence.load(CachedGuide.self, from: "guide") {
            set(cached.channels)
            lastUpdated = cached.updated
            prune()
        }
    }

    private struct CachedGuide: Codable {
        var updated: Date
        var channels: [GuideChannel]
    }

    var hasData: Bool { !channels.isEmpty }

    /// Start of the visible guide window (the current half hour).
    static func windowStart(for date: Date = Date()) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(t / 1800) * 1800)
    }

    var guideEnd: Date {
        channels.compactMap { $0.programs.last?.end }.max() ?? Date().addingTimeInterval(3 * 3600)
    }

    func load(deviceAuth: String?, hours: Int, force: Bool = false) async {
        guard let deviceAuth, !isLoading else { return }
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < 30 * 60, hasData { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let start = GuideStore.windowStart().addingTimeInterval(-1800)
            let raw = try await CloudAPI.guide(deviceAuth: deviceAuth, from: start, hours: hours)
            let mapped = raw.map { ch in
                GuideChannel(number: ch.guideNumber, name: ch.guideName, affiliate: ch.affiliate, logoURL: ch.imageURL,
                             programs: ch.guide.map { $0.program(channel: ch.guideNumber) }.sorted { $0.start < $1.start })
            }
            set(mapped)
            lastUpdated = Date()
            lastError = nil
            Persistence.save(CachedGuide(updated: Date(), channels: mapped), as: "guide")
        } catch {
            lastError = "Guide unavailable: \(error.localizedDescription)"
        }
    }

    private func set(_ list: [GuideChannel]) {
        channels = list
        var map: [String: GuideChannel] = [:]
        for c in list { map[c.number] = c }
        byNumber = map
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        set(channels.map { ch in
            var c = ch
            c.programs = ch.programs.filter { $0.end > cutoff }
            return c
        })
    }

    func programs(for number: String) -> [GuideProgram] { byNumber[number]?.programs ?? [] }

    func nowPlaying(_ number: String, at date: Date = Date()) -> GuideProgram? {
        programs(for: number).first { $0.isAiring(at: date) }
    }

    func upNext(_ number: String, at date: Date = Date()) -> GuideProgram? {
        programs(for: number).first { $0.start >= date }
    }

    func logo(_ number: String) -> URL? { byNumber[number]?.logoURL }

    func affiliate(_ number: String) -> String? { byNumber[number]?.affiliate }

    /// Free-text search over everything in the guide.
    func search(_ text: String) -> [GuideProgram] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        let now = Date()
        return channels.flatMap(\.programs)
            .filter { $0.end > now }
            .filter { p in
                p.title.lowercased().contains(q)
                    || (p.episodeTitle?.lowercased().contains(q) ?? false)
                    || (p.synopsis?.lowercased().contains(q) ?? false)
            }
            .sorted { $0.start < $1.start }
    }

    /// What's on right now, optionally filtered by category — powers the "On Now" shelf.
    func onNow(category: ProgramCategory = .all) -> [GuideProgram] {
        let now = Date()
        return channels.compactMap { ch in ch.programs.first { $0.isAiring(at: now) } }
            .filter { category == .all || $0.category == category }
    }

    func airings(seriesID: String) -> [GuideProgram] {
        let now = Date()
        return channels.flatMap(\.programs).filter { $0.seriesID == seriesID && $0.end > now }.sorted { $0.start < $1.start }
    }
}
