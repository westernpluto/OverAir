import Foundation
import Observation

enum ConnectionState: Equatable {
    case unknown, connecting, local, remote, offline

    var title: String {
        switch self {
        case .unknown: return "Not connected"
        case .connecting: return "Connecting…"
        case .local: return "Home network"
        case .remote: return "Remote"
        case .offline: return "Offline"
        }
    }

    var symbol: String {
        switch self {
        case .unknown, .offline: return "wifi.slash"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .local: return "house.fill"
        case .remote: return "globe"
        }
    }
}

/// Owns devices, the channel lineup and live tuner status.
@MainActor
@Observable
final class TunerStore {
    let settings: AppSettings

    private(set) var devices: [HDHRDevice] = []
    private(set) var channels: [Channel] = []
    private(set) var tunerStatus: [TunerStatus] = []
    private(set) var lineupStatus: LineupStatus?
    var connection: ConnectionState = .unknown
    var isDiscovering = false
    var discoveryPhase = ""
    var discoveryProgress: Double = 0
    var lastError: String?

    init(settings: AppSettings) {
        self.settings = settings
        devices = Persistence.load([HDHRDevice].self, from: "devices") ?? []
        channels = Persistence.load([Channel].self, from: "channels") ?? []
    }

    // MARK: Derived

    var tuners: [HDHRDevice] { devices.filter(\.isTuner) }
    var storageDevices: [HDHRDevice] { devices.filter(\.hasStorage) }

    var selectedTuner: HDHRDevice? {
        if let id = settings.selectedTunerID, let d = tuners.first(where: { $0.id == id }) { return d }
        return tuners.first
    }

    var hasDevice: Bool { !tuners.isEmpty }

    /// Combined DeviceAuth for every tuner, as the SiliconDust API expects.
    var deviceAuth: String? {
        let joined = tuners.compactMap(\.deviceAuth).joined()
        return joined.isEmpty ? nil : joined
    }

    var totalTuners: Int { tuners.reduce(0) { $0 + $1.tunerCount } }
    var tunersInUse: Int { tunerStatus.filter(\.inUse).count }

    func channel(_ number: String) -> Channel? { channels.first { $0.number == number } }

    /// Channels after applying hide / DRM / favourites-first preferences.
    var visibleChannels: [Channel] {
        var list = channels.filter { !settings.isHidden($0.number) }
        if settings.hideDRMChannels { list = list.filter { !$0.isDRM } }
        if settings.favoritesFirst {
            let favs = list.filter { settings.isFavorite($0.number) }
            let rest = list.filter { !settings.isFavorite($0.number) }
            return favs + rest
        }
        return list
    }

    var favoriteChannels: [Channel] { channels.filter { settings.isFavorite($0.number) } }

    func adjacentChannel(to number: String, offset: Int) -> Channel? {
        let list = channels.filter { !settings.isHidden($0.number) && !(settings.hideDRMChannels && $0.isDRM) }
        guard !list.isEmpty else { return nil }
        let idx = list.firstIndex { $0.number == number } ?? 0
        let next = (idx + offset + list.count) % list.count
        return list[next]
    }

    // MARK: Connection

    /// Re-establishes contact with known devices, using the right path for the
    /// current network (home vs. remote) and falling back to full discovery.
    func connect() async {
        connection = .connecting
        lastError = nil
        let profile = settings.networkProfile

        if profile != .remote, !devices.isEmpty {
            var refreshed: [HDHRDevice] = []
            await withTaskGroup(of: HDHRDevice?.self) { group in
                for d in devices where d.hostOverride == nil {
                    group.addTask { try? await HDHRClient.discover(at: d.baseURL, timeout: 2.5) }
                }
                for await d in group { if let d { refreshed.append(d) } }
            }
            if refreshed.contains(where: \.isTuner) {
                apply(devices: refreshed, state: .local)
                await loadLineup()
                return
            }
        }

        if profile != .local, !settings.remoteHosts.isEmpty {
            var remote: [HDHRDevice] = []
            for host in settings.remoteHosts {
                guard let base = Discovery.baseURL(for: host) else { continue }
                if let d = try? await HDHRClient.discover(at: base, hostOverride: base.host, timeout: 6) {
                    remote.append(d)
                }
            }
            if remote.contains(where: \.isTuner) {
                apply(devices: remote, state: .remote)
                await loadLineup()
                return
            }
        }

        if profile == .remote {
            connection = .offline
            lastError = "Couldn't reach your HDHomeRun through any remote address. Check your VPN / Tailscale connection or port forwarding."
            return
        }
        await discover()
    }

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        connection = .connecting
        discoveryProgress = 0
        discoveryPhase = "Looking for HDHomeRun devices…"
        let known = devices.filter { $0.hostOverride == nil }.compactMap { d -> String? in
            guard let host = d.baseURL.host else { return nil }
            return d.baseURL.port.map { "\(host):\($0)" } ?? host
        }
        let remote = settings.networkProfile == .local ? [] : settings.remoteHosts
        let found = await Discovery.discoverAll(knownHosts: known, remoteHosts: remote) { p in
            Task { @MainActor [weak self] in
                self?.discoveryPhase = p.phase
                self?.discoveryProgress = p.fraction
            }
        }
        isDiscovering = false
        if found.isEmpty {
            connection = .offline
            lastError = "No HDHomeRun found. Make sure your iPhone is on the same Wi-Fi as the tuner, or add a remote address."
            return
        }
        let anyLocal = found.contains { $0.hostOverride == nil && $0.isTuner }
        apply(devices: found, state: anyLocal ? .local : .remote)
        await loadLineup()
    }

    private func apply(devices new: [HDHRDevice], state: ConnectionState) {
        var merged: [String: HDHRDevice] = [:]
        for d in new { merged[d.id] = d }
        // A FLEX 4K with storage shows up twice (tuner + record engine) with identical base URLs; keep the richer entry.
        devices = merged.values.sorted { ($0.isTuner ? 0 : 1, $0.friendlyName) < ($1.isTuner ? 0 : 1, $1.friendlyName) }
        connection = state
        if settings.selectedTunerID == nil || !devices.contains(where: { $0.id == settings.selectedTunerID }) {
            settings.selectedTunerID = devices.first(where: \.isTuner)?.id
        }
        Persistence.save(devices, as: "devices")
    }

    func addManualDevice(host: String, remote: Bool) async throws -> HDHRDevice {
        guard let base = Discovery.baseURL(for: host) else { throw HTTPError.unreachable("That address doesn't look right.") }
        let device = try await HDHRClient.discover(at: base, hostOverride: remote ? base.host : nil, timeout: 8)
        if remote, !settings.remoteHosts.contains(host) { settings.remoteHosts.append(host) }
        var list = devices.filter { $0.id != device.id }
        list.append(device)
        apply(devices: list, state: remote ? .remote : .local)
        await loadLineup()
        return device
    }

    func forget(_ device: HDHRDevice) {
        devices.removeAll { $0.id == device.id }
        Persistence.save(devices, as: "devices")
        if settings.selectedTunerID == device.id { settings.selectedTunerID = tuners.first?.id }
    }

    func select(_ device: HDHRDevice) async {
        settings.selectedTunerID = device.id
        await loadLineup()
    }

    // MARK: Lineup & status

    func loadLineup() async {
        guard let tuner = selectedTuner else { return }
        do {
            let list = try await HDHRClient.lineup(for: tuner)
            channels = list
            Persistence.save(list, as: "channels")
        } catch {
            lastError = error.localizedDescription
            if channels.isEmpty { connection = .offline }
        }
    }

    func refreshStatus() async {
        var all: [TunerStatus] = []
        for t in tuners {
            if let s = try? await HDHRClient.tunerStatus(for: t) { all.append(contentsOf: s) }
        }
        tunerStatus = all
    }

    /// Signal for the tuner currently streaming `channel` to this phone, if any.
    func status(forChannel number: String) -> TunerStatus? {
        tunerStatus.first { $0.channelNumber == number }
    }

    func refreshScanStatus() async {
        guard let tuner = selectedTuner else { return }
        lineupStatus = try? await HDHRClient.lineupStatus(for: tuner)
    }

    func startChannelScan(source: String) async {
        guard let tuner = selectedTuner else { return }
        do {
            try await HDHRClient.startScan(on: tuner, source: source)
            await refreshScanStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func abortChannelScan() async {
        guard let tuner = selectedTuner else { return }
        try? await HDHRClient.abortScan(on: tuner)
        await refreshScanStatus()
    }

    func streamURL(for channel: Channel) -> URL? {
        let device = tuners.first { $0.deviceID == channel.deviceID } ?? selectedTuner
        return HDHRClient.streamURL(for: channel, on: device)
    }
}
