import Foundation

struct Channel: Codable, Identifiable, Hashable, Sendable {
    var id: String { number }
    var number: String
    var name: String
    var videoCodec: String?
    var audioCodec: String?
    var isHD: Bool
    var isDRM: Bool
    var isFavoriteOnDevice: Bool
    var streamURL: URL?
    /// The device the channel was found on.
    var deviceID: String?

    /// Sort key so "2.1" < "2.10" < "10.1".
    var sortKey: [Int] {
        number.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }

    var isATSC3: Bool {
        let v = videoCodec?.uppercased() ?? ""
        let a = audioCodec?.uppercased() ?? ""
        return v == "HEVC" || a == "AC4"
    }

    var codecBadge: String? {
        if isATSC3 { return "ATSC 3.0" }
        return nil
    }
}

struct LineupEntry: Decodable, Sendable {
    var guideNumber: String
    var guideName: String
    var videoCodec: String?
    var audioCodec: String?
    var hd: Bool
    var drm: Bool
    var favorite: Bool
    var url: URL?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        guideNumber = c.str("GuideNumber") ?? "?"
        guideName = c.str("GuideName") ?? ""
        videoCodec = c.str("VideoCodec")
        audioCodec = c.str("AudioCodec")
        hd = c.bool("HD") ?? false
        drm = c.bool("DRM") ?? false
        favorite = c.bool("Favorite") ?? false
        url = c.url("URL")
    }
}
