import Foundation
import Observation

enum AppTab: String, CaseIterable, Identifiable, Codable {
    case live, guide, dvr, settings, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live TV"
        case .guide: return "Guide"
        case .dvr: return "Recordings"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }
    var symbol: String {
        switch self {
        case .live: return "play.tv"
        case .guide: return "calendar"
        case .dvr: return "record.circle"
        case .settings: return "gearshape"
        case .search: return "magnifyingglass"
        }
    }
}

enum AspectMode: String, CaseIterable, Identifiable, Codable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }
    var symbol: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }
}

enum RecordingTarget: String, CaseIterable, Identifiable, Codable {
    case device, phone, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .device: return "HDHomeRun Storage"
        case .phone: return "This iPhone"
        case .ask: return "Ask Every Time"
        }
    }
}

enum RemoteMethod: String, CaseIterable, Identifiable, Codable {
    case none, tailscale, routerVPN, portForward
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Not Set Up"
        case .tailscale: return "Tailscale"
        case .routerVPN: return "Router VPN"
        case .portForward: return "Port Forwarding"
        }
    }
}

enum NetworkProfile: String, CaseIterable, Identifiable, Codable {
    case automatic, local, remote
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .local: return "Home Network"
        case .remote: return "Remote"
        }
    }
}

/// User preferences, persisted to UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var guideHours: Int { didSet { defaults.set(guideHours, forKey: "guideHours") } }
    var startPaddingSeconds: Int { didSet { defaults.set(startPaddingSeconds, forKey: "startPadding") } }
    var endPaddingSeconds: Int { didSet { defaults.set(endPaddingSeconds, forKey: "endPadding") } }
    var liveCachingMs: Int { didSet { defaults.set(liveCachingMs, forKey: "liveCaching") } }
    var remoteCachingMs: Int { didSet { defaults.set(remoteCachingMs, forKey: "remoteCaching") } }
    var deinterlace: Bool { didSet { defaults.set(deinterlace, forKey: "deinterlace") } }
    var hardwareDecoding: Bool { didSet { defaults.set(hardwareDecoding, forKey: "hwDecode") } }
    var autoplayLastChannel: Bool { didSet { defaults.set(autoplayLastChannel, forKey: "autoplayLast") } }
    var showSignalOverlay: Bool { didSet { defaults.set(showSignalOverlay, forKey: "signalOverlay") } }
    var closedCaptionsByDefault: Bool { didSet { defaults.set(closedCaptionsByDefault, forKey: "ccDefault") } }
    var backgroundAudio: Bool { didSet { defaults.set(backgroundAudio, forKey: "bgAudio") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var hideDRMChannels: Bool { didSet { defaults.set(hideDRMChannels, forKey: "hideDRM") } }
    var favoritesFirst: Bool { didSet { defaults.set(favoritesFirst, forKey: "favFirst") } }
    var aspectMode: AspectMode { didSet { defaults.set(aspectMode.rawValue, forKey: "aspect") } }
    var recordingTarget: RecordingTarget { didSet { defaults.set(recordingTarget.rawValue, forKey: "recTarget") } }
    var networkProfile: NetworkProfile { didSet { defaults.set(networkProfile.rawValue, forKey: "netProfile") } }
    var remoteHosts: [String] { didSet { defaults.set(remoteHosts, forKey: "remoteHosts") } }
    var lastChannel: String? { didSet { defaults.set(lastChannel, forKey: "lastChannel") } }
    var favorites: [String] { didSet { defaults.set(favorites, forKey: "favorites") } }
    var hiddenChannels: [String] { didSet { defaults.set(hiddenChannels, forKey: "hidden") } }
    var recentChannels: [String] { didSet { defaults.set(recentChannels, forKey: "recents") } }
    var selectedTunerID: String? { didSet { defaults.set(selectedTunerID, forKey: "selectedTuner") } }
    var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboarded") } }
    var skipForwardSeconds: Int { didSet { defaults.set(skipForwardSeconds, forKey: "skipFwd") } }
    var skipBackSeconds: Int { didSet { defaults.set(skipBackSeconds, forKey: "skipBack") } }
    var guideRowHeight: Double { didSet { defaults.set(guideRowHeight, forKey: "guideRow") } }
    var reminderMinutes: Int { didSet { defaults.set(reminderMinutes, forKey: "reminderMin") } }
    var remoteMethod: RemoteMethod { didSet { defaults.set(remoteMethod.rawValue, forKey: "remoteMethod") } }
    /// Your home's public IP, refreshed automatically whenever the app is used at home.
    var homePublicIP: String? { didSet { defaults.set(homePublicIP, forKey: "homePublicIP") } }
    var homePublicIPUpdated: Date? { didSet { defaults.set(homePublicIPUpdated, forKey: "homePublicIPUpdated") } }
    var playerTipsSeen: Bool { didSet { defaults.set(playerTipsSeen, forKey: "playerTips") } }
    /// Minutes of live TV kept on disk for pause / rewind.
    var rewindMinutes: Int { didSet { defaults.set(rewindMinutes, forKey: "rewindMinutes") } }
    /// Roughly 80 MB per minute covers a full-bitrate HD channel.
    var rewindBufferBytes: Int64 { Int64(max(rewindMinutes, 5)) * 80_000_000 }
    var guideTipsSeen: Bool { didSet { defaults.set(guideTipsSeen, forKey: "guideTips") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func int(_ k: String, _ d: Int) -> Int { defaults.object(forKey: k) as? Int ?? d }
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        guideHours = int("guideHours", 24)
        startPaddingSeconds = int("startPadding", 30)
        endPaddingSeconds = int("endPadding", 120)
        liveCachingMs = int("liveCaching", 1200)
        remoteCachingMs = int("remoteCaching", 3500)
        deinterlace = bool("deinterlace", true)
        hardwareDecoding = bool("hwDecode", true)
        autoplayLastChannel = bool("autoplayLast", false)
        showSignalOverlay = bool("signalOverlay", false)
        closedCaptionsByDefault = bool("ccDefault", false)
        backgroundAudio = bool("bgAudio", true)
        haptics = bool("haptics", true)
        hideDRMChannels = bool("hideDRM", true)
        favoritesFirst = bool("favFirst", true)
        aspectMode = AspectMode(rawValue: defaults.string(forKey: "aspect") ?? "") ?? .fit
        recordingTarget = RecordingTarget(rawValue: defaults.string(forKey: "recTarget") ?? "") ?? .ask
        networkProfile = NetworkProfile(rawValue: defaults.string(forKey: "netProfile") ?? "") ?? .automatic
        remoteHosts = defaults.stringArray(forKey: "remoteHosts") ?? []
        lastChannel = defaults.string(forKey: "lastChannel")
        favorites = defaults.stringArray(forKey: "favorites") ?? []
        hiddenChannels = defaults.stringArray(forKey: "hidden") ?? []
        recentChannels = defaults.stringArray(forKey: "recents") ?? []
        selectedTunerID = defaults.string(forKey: "selectedTuner")
        onboardingComplete = bool("onboarded", false)
        skipForwardSeconds = int("skipFwd", 30)
        skipBackSeconds = int("skipBack", 10)
        guideRowHeight = defaults.object(forKey: "guideRow") as? Double ?? 72
        reminderMinutes = int("reminderMin", 2)
        remoteMethod = RemoteMethod(rawValue: defaults.string(forKey: "remoteMethod") ?? "") ?? .none
        homePublicIP = defaults.string(forKey: "homePublicIP")
        homePublicIPUpdated = defaults.object(forKey: "homePublicIPUpdated") as? Date
        playerTipsSeen = bool("playerTips", false)
        rewindMinutes = int("rewindMinutes", 30)
        guideTipsSeen = bool("guideTips", false)
    }

    func isFavorite(_ number: String) -> Bool { favorites.contains(number) }

    func toggleFavorite(_ number: String) {
        if let i = favorites.firstIndex(of: number) { favorites.remove(at: i) } else { favorites.append(number) }
    }

    func isHidden(_ number: String) -> Bool { hiddenChannels.contains(number) }

    func toggleHidden(_ number: String) {
        if let i = hiddenChannels.firstIndex(of: number) { hiddenChannels.remove(at: i) } else { hiddenChannels.append(number) }
    }

    func noteWatched(_ number: String) {
        lastChannel = number
        var r = recentChannels.filter { $0 != number }
        r.insert(number, at: 0)
        recentChannels = Array(r.prefix(8))
    }
}
