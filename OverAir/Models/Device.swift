import Foundation

/// A HDHomeRun tuner and/or storage engine (the FLEX 4K is both when storage is attached).
struct HDHRDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String { deviceID ?? storageID ?? baseURL.absoluteString }

    var deviceID: String?
    var storageID: String?
    var friendlyName: String
    var modelNumber: String?
    var firmwareName: String?
    var firmwareVersion: String?
    var deviceAuth: String?
    var baseURL: URL
    var lineupURL: URL?
    var tunerCount: Int
    var storageURL: URL?
    var totalSpace: Int64?
    var freeSpace: Int64?
    var upgradeAvailable: String?
    var conditionalAccess: Bool

    /// When the user reaches the device through a remote host (VPN, Tailscale, port forward),
    /// this overrides the LAN host the device reports so all URLs are rewritten.
    var hostOverride: String?
    var lastSeen: Date = Date()

    var isTuner: Bool { tunerCount > 0 }
    var hasStorage: Bool { storageURL != nil }
    var isRemote: Bool { hostOverride != nil }

    var displayModel: String {
        switch modelNumber?.uppercased() {
        case "HDFX-4K": return "HDHomeRun FLEX 4K"
        case "HDFX-2": return "HDHomeRun FLEX DUO"
        case "HDFX-4": return "HDHomeRun FLEX QUATRO"
        case "HDVR-4K": return "HDHomeRun SCRIBE 4K"
        case "HDVR-2US", "HDVR-4US": return "HDHomeRun SCRIBE"
        case "HDHR5-4K": return "HDHomeRun CONNECT 4K"
        case let m?: return m
        case nil: return hasStorage && !isTuner ? "HDHomeRun DVR" : "HDHomeRun"
        }
    }

    var supportsATSC3: Bool {
        let m = modelNumber?.uppercased() ?? ""
        return m.contains("4K")
    }

    /// Rewrites a URL reported by the device so it is reachable via the host override.
    func reachable(_ url: URL) -> URL {
        guard let hostOverride, let reportedHost = baseURL.host, url.host == reportedHost || isPrivate(url.host) else { return url }
        return url.replacingHost(hostOverride)
    }

    var effectiveBaseURL: URL { reachable(baseURL) }

    private func isPrivate(_ host: String?) -> Bool {
        guard let host else { return false }
        return host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") || host.hasPrefix("169.254.")
    }
}

/// Raw response from `http://<device>/discover.json`.
struct DiscoverResponse: Decodable, Sendable {
    var friendlyName: String?
    var modelNumber: String?
    var firmwareName: String?
    var firmwareVersion: String?
    var deviceID: String?
    var deviceAuth: String?
    var baseURL: URL?
    var lineupURL: URL?
    var tunerCount: Int?
    var storageID: String?
    var storageURL: URL?
    var totalSpace: Int64?
    var freeSpace: Int64?
    var upgradeAvailable: String?
    var conditionalAccess: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        friendlyName = c.str("FriendlyName")
        modelNumber = c.str("ModelNumber")
        firmwareName = c.str("FirmwareName")
        firmwareVersion = c.str("FirmwareVersion")
        deviceID = c.str("DeviceID")
        deviceAuth = c.str("DeviceAuth")
        baseURL = c.url("BaseURL")
        lineupURL = c.url("LineupURL")
        tunerCount = c.int("TunerCount")
        storageID = c.str("StorageID")
        storageURL = c.url("StorageURL")
        totalSpace = c.int64("TotalSpace")
        freeSpace = c.int64("FreeSpace")
        upgradeAvailable = c.str("UpgradeAvailable")
        conditionalAccess = c.bool("ConditionalAccess")
    }

    func makeDevice(fallbackBase: URL, hostOverride: String?) -> HDHRDevice? {
        let base = baseURL ?? fallbackBase
        guard deviceID != nil || storageID != nil else { return nil }
        return HDHRDevice(
            deviceID: deviceID,
            storageID: storageID,
            friendlyName: friendlyName ?? "HDHomeRun",
            modelNumber: modelNumber,
            firmwareName: firmwareName,
            firmwareVersion: firmwareVersion,
            deviceAuth: deviceAuth,
            baseURL: base,
            lineupURL: lineupURL,
            tunerCount: tunerCount ?? 0,
            storageURL: storageURL,
            totalSpace: totalSpace,
            freeSpace: freeSpace,
            upgradeAvailable: upgradeAvailable,
            conditionalAccess: conditionalAccess ?? false,
            hostOverride: hostOverride
        )
    }
}

/// Entry returned by the SiliconDust cloud discover service.
struct CloudDiscoverEntry: Decodable, Sendable {
    var deviceID: String?
    var storageID: String?
    var localIP: String?
    var baseURL: URL?
    var discoverURL: URL?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        deviceID = c.str("DeviceID")
        storageID = c.str("StorageID")
        localIP = c.str("LocalIP")
        baseURL = c.url("BaseURL")
        discoverURL = c.url("DiscoverURL")
    }
}

/// Response of `/status.json` — one entry per tuner.
struct TunerStatus: Decodable, Identifiable, Hashable, Sendable {
    var id: String { resource }
    var resource: String
    var channelNumber: String?
    var channelName: String?
    var frequency: Int?
    var signalStrength: Int?
    var signalQuality: Int?
    var symbolQuality: Int?
    var networkRate: Int?
    var targetIP: String?

    var inUse: Bool { channelNumber != nil || frequency != nil || targetIP != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        resource = c.str("Resource") ?? "tuner"
        channelNumber = c.str("VctNumber")
        channelName = c.str("VctName")
        frequency = c.int("Frequency")
        signalStrength = c.int("SignalStrengthPercent")
        signalQuality = c.int("SignalQualityPercent")
        symbolQuality = c.int("SymbolQualityPercent")
        networkRate = c.int("NetworkRate")
        targetIP = c.str("TargetIP")
    }

    var displayName: String {
        resource.replacingOccurrences(of: "tuner", with: "Tuner ")
    }
}

/// Response of `/lineup_status.json`.
struct LineupStatus: Decodable, Sendable {
    var scanInProgress: Bool
    var scanPossible: Bool
    var progress: Int
    var found: Int
    var source: String?
    var sourceList: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        scanInProgress = c.bool("ScanInProgress") ?? false
        scanPossible = c.bool("ScanPossible") ?? false
        progress = c.int("Progress") ?? 0
        found = c.int("Found") ?? 0
        source = c.str("Source")
        sourceList = c.strings("SourceList")
    }
}
