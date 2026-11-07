import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds HDHomeRun devices using every available method in parallel:
/// 1. SiliconDust cloud discover (returns devices behind the same public IP)
/// 2. Native HDHomeRun UDP broadcast protocol (port 65001)
/// 3. A fast HTTP sweep of the local /24 subnet for `/discover.json`
/// 4. Previously known addresses and user-entered remote hosts
enum Discovery {
    struct Progress: Sendable {
        var phase: String
        var fraction: Double
    }

    static func discoverAll(knownHosts: [String], remoteHosts: [String], subnetScan: Bool = true,
                            progress: (@Sendable (Progress) -> Void)? = nil) async -> [HDHRDevice] {
        var found: [String: HDHRDevice] = [:]
        var candidateHosts = Set<String>(knownHosts)

        progress?(Progress(phase: "Asking SiliconDust cloud…", fraction: 0.05))
        async let cloud = cloudCandidates()
        async let udp = udpCandidates()
        let cloudHosts = await cloud
        let udpHosts = await udp
        candidateHosts.formUnion(cloudHosts)
        candidateHosts.formUnion(udpHosts)

        progress?(Progress(phase: "Contacting devices…", fraction: 0.25))
        for device in await probe(hosts: Array(candidateHosts), hostOverride: nil) {
            found[device.id] = device
        }

        // Remote hosts keep their override so URLs get rewritten.
        for host in remoteHosts {
            guard let base = baseURL(for: host) else { continue }
            if let device = try? await HDHRClient.discover(at: base, hostOverride: base.host, timeout: 6) {
                if found[device.id] == nil { found[device.id] = device }
            }
        }

        let haveTuner = found.values.contains { $0.isTuner }
        if subnetScan && !haveTuner {
            progress?(Progress(phase: "Scanning your network…", fraction: 0.4))
            let hosts = subnetHosts()
            let total = max(hosts.count, 1)
            var done = 0
            await withTaskGroup(of: HDHRDevice?.self) { group in
                var iterator = hosts.makeIterator()
                let width = 48
                for _ in 0..<width {
                    guard let h = iterator.next() else { break }
                    group.addTask { await probeOne(host: h) }
                }
                while let result = await group.next() {
                    done += 1
                    if done % 16 == 0 {
                        progress?(Progress(phase: "Scanning your network…", fraction: 0.4 + 0.55 * Double(done) / Double(total)))
                    }
                    if let d = result, found[d.id] == nil { found[d.id] = d }
                    if let h = iterator.next() { group.addTask { await probeOne(host: h) } }
                }
            }
        }

        // Record engines also listen on 59090 when running on a NAS / PC.
        progress?(Progress(phase: "Done", fraction: 1))
        return found.values.sorted { ($0.isTuner ? 0 : 1, $0.friendlyName) < ($1.isTuner ? 0 : 1, $1.friendlyName) }
    }

    static func baseURL(for host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return URL(string: trimmed) }
        return URL(string: "http://\(trimmed)")
    }

    private static func probe(hosts: [String], hostOverride: String?) async -> [HDHRDevice] {
        await withTaskGroup(of: HDHRDevice?.self) { group in
            for h in hosts {
                group.addTask {
                    guard let base = baseURL(for: h) else { return nil }
                    return try? await HDHRClient.discover(at: base, hostOverride: hostOverride, timeout: 4)
                }
            }
            var out: [HDHRDevice] = []
            for await d in group { if let d { out.append(d) } }
            return out
        }
    }

    private static func probeOne(host: String) async -> HDHRDevice? {
        guard let base = URL(string: "http://\(host)") else { return nil }
        return try? await HDHRClient.discover(at: base, timeout: 1.5, probe: true)
    }

    private static func cloudCandidates() async -> [String] {
        guard let entries = try? await CloudAPI.discover() else { return [] }
        return entries.compactMap { e in
            if let b = e.baseURL, let host = b.host {
                if let port = b.port { return "\(host):\(port)" }
                return host
            }
            return e.localIP
        }
    }

    // MARK: - Native UDP discovery

    private static func udpCandidates() async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: UDPDiscovery.run(timeout: 1.5))
            }
        }
    }

    // MARK: - Subnet

    /// All host addresses in the /24 containing the phone's Wi-Fi/Ethernet IPv4 address.
    static func subnetHosts() -> [String] {
        guard let ip = localIPv4() else { return [] }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts[0...2].joined(separator: ".")
        return (1...254).map { "\(prefix).\($0)" }.filter { $0 != ip }
    }

    static func localIPv4() -> String? {
        #if canImport(Darwin)
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let iface = p.pointee
            if let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") { candidates.append((name, ip)) }
                }
            }
            ptr = iface.ifa_next
        }
        address = candidates.first(where: { $0.0 == "en0" })?.1
            ?? candidates.first(where: { $0.0.hasPrefix("en") })?.1
            ?? candidates.first(where: { !$0.0.hasPrefix("utun") && !$0.0.hasPrefix("pdp_ip") })?.1
        return address
        #else
        return nil
        #endif
    }
}

/// Implementation of the HDHomeRun discovery protocol (libhdhomerun compatible).
enum UDPDiscovery {
    static let port: UInt16 = 65001
    static let typeDiscoverRequest: UInt16 = 0x0002
    static let typeDiscoverReply: UInt16 = 0x0003
    static let tagDeviceType: UInt8 = 0x01
    static let tagDeviceID: UInt8 = 0x02
    static let tagBaseURL: UInt8 = 0x2A

    static func buildRequest() -> [UInt8] {
        var payload: [UInt8] = []
        payload += [tagDeviceType, 4, 0xFF, 0xFF, 0xFF, 0xFF]
        payload += [tagDeviceID, 4, 0xFF, 0xFF, 0xFF, 0xFF]
        var packet: [UInt8] = []
        packet += [UInt8(typeDiscoverRequest >> 8), UInt8(typeDiscoverRequest & 0xFF)]
        packet += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        packet += payload
        let crc = crc32(packet)
        packet += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 24) & 0xFF)]
        return packet
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Parses a discover reply; returns the base URL host[:port] or the sender IP.
    static func parseReply(_ bytes: [UInt8], sender: String) -> String? {
        guard bytes.count >= 8 else { return nil }
        let type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard type == typeDiscoverReply else { return nil }
        let length = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        guard bytes.count >= 4 + length else { return sender }
        var i = 4
        let end = 4 + length
        while i + 2 <= end {
            let tag = bytes[i]
            var len = Int(bytes[i + 1])
            i += 2
            if len & 0x80 != 0 {
                guard i < end else { break }
                len = (len & 0x7F) | (Int(bytes[i]) << 7)
                i += 1
            }
            guard i + len <= end else { break }
            if tag == tagBaseURL, let s = String(bytes: bytes[i..<(i + len)], encoding: .utf8),
               let url = URL(string: s), let host = url.host {
                return url.port.map { "\(host):\($0)" } ?? host
            }
            i += len
        }
        return sender
    }

    static func run(timeout: TimeInterval) -> [String] {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST

        let packet = buildRequest()
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        // Sending broadcasts requires the multicast entitlement; fall back silently.
        guard sent > 0 else { return [] }

        var results = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)
            let ready = poll(&pfd, 1, remaining)
            if ready <= 0 { break }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &fromLen)
                    }
                }
            }
            guard n > 0 else { continue }
            let sender = String(cString: inet_ntoa(from.sin_addr))
            if let host = parseReply(Array(buffer[0..<n]), sender: sender) { results.insert(host) }
        }
        return Array(results)
        #else
        return []
        #endif
    }
}
