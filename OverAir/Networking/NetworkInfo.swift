import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Looks at the phone's network interfaces to tell whether we're on the tuner's home network,
/// connected through Tailscale, or through another VPN.
enum NetworkInfo {
    struct Interface: Hashable {
        var name: String
        var ipv4: String
    }

    static func interfaces() -> [Interface] {
        #if canImport(Darwin)
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let iface = p.pointee
            if let sa = iface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (iface.ifa_flags & UInt32(IFF_UP)) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        result.append(Interface(name: String(cString: iface.ifa_name), ipv4: ip))
                    }
                }
            }
            ptr = iface.ifa_next
        }
        return result
        #else
        return []
        #endif
    }

    private static func octets(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 ? parts : nil
    }

    /// Tailscale hands out addresses in 100.64.0.0/10 on a utun interface.
    static var tailscaleAddress: String? {
        interfaces().first { i in
            guard i.name.hasPrefix("utun"), let o = octets(i.ipv4) else { return false }
            return o[0] == 100 && (64...127).contains(o[1])
        }?.ipv4
    }

    static var isTailscaleActive: Bool { tailscaleAddress != nil }

    /// Any VPN tunnel (Tailscale, WireGuard, IKEv2…) with an IPv4 address.
    static var isVPNActive: Bool {
        interfaces().contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp") }
    }

    /// The phone's Wi-Fi / Ethernet address.
    static var lanAddress: String? {
        let list = interfaces()
        return list.first(where: { $0.name == "en0" })?.ipv4 ?? list.first(where: { $0.name.hasPrefix("en") })?.ipv4
    }

    /// True when the phone is on the same /24 as the device (i.e. at home on Wi-Fi).
    static func isOnLAN(of device: HDHRDevice?) -> Bool {
        if let host = device?.baseURL.host, host == "127.0.0.1" || host == "localhost" { return true }
        guard let host = device?.baseURL.host, let deviceIP = octets(host), let mine = lanAddress.flatMap(octets) else { return false }
        return Array(deviceIP.prefix(3)) == Array(mine.prefix(3))
    }

    /// "192.168.1.0/24" for the device's home network — what a Tailscale subnet router should advertise.
    static func homeSubnet(of device: HDHRDevice?) -> String? {
        guard let host = device?.baseURL.host, let o = octets(host) else { return nil }
        return "\(o[0]).\(o[1]).\(o[2]).0/24"
    }

    static func isPrivateIP(_ host: String) -> Bool {
        guard let o = octets(host) else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    /// Your home's public IPv4 address (only meaningful while on the home network).
    static func fetchPublicIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        guard let data = try? await HTTP.data(url, timeout: 5) else { return nil }
        let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return octets(ip) != nil ? ip : nil
    }
}
