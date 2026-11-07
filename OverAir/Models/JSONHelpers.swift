import Foundation

/// A dynamic coding key so models can decode SiliconDust's loosely-typed JSON
/// (numbers sometimes arrive as strings and vice versa).
struct JSONKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer where Key == JSONKey {
    func str(_ key: String) -> String? {
        let k = JSONKey(key)
        if let v = try? decodeIfPresent(String.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return String(v) }
        return nil
    }

    func int(_ key: String) -> Int? {
        let k = JSONKey(key)
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        if let v = try? decodeIfPresent(String.self, forKey: k) { return Int(v) ?? Double(v).map { Int($0) } }
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v ? 1 : 0 }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        let k = JSONKey(key)
        if let v = try? decodeIfPresent(Int64.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return Int64(v) }
        if let v = try? decodeIfPresent(String.self, forKey: k) { return Int64(v) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        let k = JSONKey(key)
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v != 0 }
        if let v = try? decodeIfPresent(String.self, forKey: k) {
            return ["1", "true", "yes"].contains(v.lowercased())
        }
        return nil
    }

    func url(_ key: String) -> URL? {
        guard let s = str(key), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    func date(_ key: String) -> Date? {
        guard let t = int64(key), t > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t))
    }

    func strings(_ key: String) -> [String] {
        (try? decodeIfPresent([String].self, forKey: JSONKey(key))) ?? []
    }
}

extension URL {
    /// Returns a copy of the URL with its host (and optionally port) replaced.
    func replacingHost(_ host: String, port: Int? = nil) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        comps.host = host
        if let port { comps.port = port }
        return comps.url ?? self
    }

    func appendingQuery(_ items: [String: String]) -> URL {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var q = comps.queryItems ?? []
        for (k, v) in items.sorted(by: { $0.key < $1.key }) { q.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = q
        return comps.url ?? self
    }
}
