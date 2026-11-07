import Foundation

/// Tiny JSON-on-disk cache used for devices, lineups and guide data so the app
/// opens instantly (and works offline / remotely with the last known state).
enum Persistence {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OverAir", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        let url = directory.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).json"))
    }
}
