import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HTTPError: LocalizedError {
    case badStatus(Int, URL)
    case decoding(String)
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code, url): return "Request to \(url.host ?? "device") failed (HTTP \(code))."
        case let .decoding(msg): return "Unexpected response: \(msg)"
        case let .unreachable(msg): return msg
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    /// Short-timeout session used for subnet probing.
    static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    static let userAgent = "OverAir/1.0 (iOS)"

    static func data(_ url: URL, timeout: TimeInterval? = nil, session: URLSession = HTTP.session) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.badStatus(http.statusCode, url)
        }
        return data
    }

    static func get<T: Decodable>(_ url: URL, as type: T.Type = T.self, timeout: TimeInterval? = nil, session: URLSession = HTTP.session) async throws -> T {
        let data = try await data(url, timeout: timeout, session: session)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(String(describing: error))
        }
    }

    @discardableResult
    static func post(_ url: URL, form: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !form.isEmpty {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncode(form).data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.badStatus(http.statusCode, url)
        }
        return data
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted(by: { $0.key < $1.key }).map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
