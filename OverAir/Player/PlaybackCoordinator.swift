import Foundation
import Observation
import AVFoundation
import MediaPlayer
import UIKit

enum PlaybackItem: Equatable {
    case live(Channel)
    case recording(RecordedEpisode)
    case local(LocalRecording)

    var isLive: Bool { if case .live = self { return true }; return false }

    var channel: Channel? { if case let .live(c) = self { return c }; return nil }

    var title: String {
        switch self {
        case let .live(c): return c.name
        case let .recording(e): return e.title
        case let .local(r): return r.title
        }
    }
}

/// Central place that starts/stops playback so the same player survives tab switches
/// (full screen ⇄ mini player), integrates with Control Center and the sleep timer.
@MainActor
@Observable
final class PlaybackCoordinator {
    let player = PlayerController()
    private(set) var item: PlaybackItem?
    var isFullScreen = false
    var isMultiviewPresented = false
    var multiviewChannels: [Channel] = []
    private(set) var sleepTimerEnd: Date?
    var lastError: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tuners: TunerStore
    @ObservationIgnored private let guide: GuideStore
    @ObservationIgnored private let dvr: DVRStore
    @ObservationIgnored private let recorder: LocalRecorder
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var previousChannel: Channel?
    @ObservationIgnored private var remoteCommandsConfigured = false

    init(settings: AppSettings, tuners: TunerStore, guide: GuideStore, dvr: DVRStore, recorder: LocalRecorder) {
        self.settings = settings
        self.tuners = tuners
        self.guide = guide
        self.dvr = dvr
        self.recorder = recorder
        player.aspect = settings.aspectMode
    }

    var isPlaying: Bool { item != nil }

    var currentChannel: Channel? { item?.channel }

    // MARK: Start

    func play(_ channel: Channel, fullScreen: Bool = true) {
        guard let url = tuners.streamURL(for: channel) else {
            lastError = "No stream address for channel \(channel.number)."
            return
        }
        if let current = item?.channel, current != channel { previousChannel = current }
        saveResumeIfNeeded()
        item = .live(channel)
        settings.noteWatched(channel.number)
        player.play(url: url, options: options(captions: settings.closedCaptionsByDefault))
        activateAudioSession()
        updateNowPlaying()
        if fullScreen { isFullScreen = true }
        Haptics.tap(settings)
    }

    func play(_ episode: RecordedEpisode, fromStart: Bool = false) {
        guard let url = episode.playURL else { lastError = "This recording has no play address."; return }
        saveResumeIfNeeded()
        item = .recording(episode)
        var opts = options(captions: settings.closedCaptionsByDefault)
        opts.startAt = fromStart ? nil : episode.resumeSeconds.map(Double.init)
        player.play(url: url, options: opts)
        activateAudioSession()
        updateNowPlaying()
        isFullScreen = true
    }

    func play(_ local: LocalRecording, fromStart: Bool = false) {
        saveResumeIfNeeded()
        item = .local(local)
        var opts = options(captions: settings.closedCaptionsByDefault)
        opts.cachingMs = 300
        opts.startAt = fromStart ? nil : local.resumeSeconds
        player.play(url: local.fileURL, options: opts)
        activateAudioSession()
        updateNowPlaying()
        isFullScreen = true
    }

    private func options(captions: Bool) -> PlayerController.Options {
        var o = PlayerController.Options()
        o.cachingMs = tuners.connection == .remote ? settings.remoteCachingMs : settings.liveCachingMs
        o.deinterlace = settings.deinterlace
        o.hardwareDecoding = settings.hardwareDecoding
        o.captions = captions
        return o
    }

    // MARK: Control

    func channelUp() { step(1) }
    func channelDown() { step(-1) }

    private func step(_ offset: Int) {
        guard let current = item?.channel, let next = tuners.adjacentChannel(to: current.number, offset: offset) else { return }
        play(next, fullScreen: isFullScreen)
    }

    func lastChannel() {
        guard let prev = previousChannel else { return }
        play(prev, fullScreen: isFullScreen)
    }

    var hasPreviousChannel: Bool { previousChannel != nil }

    func tune(number: String) -> Bool {
        let normalized = number.replacingOccurrences(of: "-", with: ".")
        if let ch = tuners.channels.first(where: { $0.number == normalized }) ?? tuners.channels.first(where: { $0.number.hasPrefix(normalized + ".") }) {
            play(ch, fullScreen: isFullScreen)
            return true
        }
        return false
    }

    func stop() {
        saveResumeIfNeeded()
        player.stop()
        item = nil
        isFullScreen = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setAspect(_ mode: AspectMode) {
        player.aspect = mode
        settings.aspectMode = mode
    }

    func cycleAspect() {
        let all = AspectMode.allCases
        let idx = all.firstIndex(of: player.aspect) ?? 0
        setAspect(all[(idx + 1) % all.count])
    }

    private func saveResumeIfNeeded() {
        guard let item, player.duration > 0 else { return }
        let t = player.currentTime
        let nearEnd = player.duration - t < 60
        switch item {
        case let .recording(ep):
            Task { [dvr] in
                if nearEnd { await dvr.setWatched(ep, watched: true) } else { await dvr.saveResume(ep, seconds: Int(t)) }
            }
        case let .local(rec):
            recorder.saveResume(rec, seconds: nearEnd ? 0 : t)
        case .live:
            break
        }
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        cancelSleepTimer()
        guard let minutes else { return }
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEnd = end
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
    }

    // MARK: Multiview

    func openMultiview(with channels: [Channel]) {
        var list = channels
        if let c = item?.channel, !list.contains(c) { list.insert(c, at: 0) }
        multiviewChannels = Array(list.prefix(max(1, min(4, tuners.totalTuners == 0 ? 4 : tuners.totalTuners))))
        if item != nil { stop() }
        isMultiviewPresented = true
    }

    // MARK: System integration

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setActive(true)
        configureRemoteCommands()
    }

    func updateNowPlaying() {
        guard let item else { return }
        var info: [String: Any] = [:]
        switch item {
        case let .live(ch):
            let now = guide.nowPlaying(ch.number)
            info[MPMediaItemPropertyTitle] = now?.title ?? ch.name
            info[MPMediaItemPropertyArtist] = "\(ch.number) \(ch.name)"
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        case let .recording(ep):
            info[MPMediaItemPropertyTitle] = ep.title
            info[MPMediaItemPropertyArtist] = ep.subtitleLine ?? ep.channelName ?? ""
            info[MPMediaItemPropertyPlaybackDuration] = ep.duration
        case let .local(rec):
            info[MPMediaItemPropertyTitle] = rec.title
            info[MPMediaItemPropertyArtist] = rec.channelName
        }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackCoordinator) -> Void) {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
                return .success
            }
        }
        handle(center.playCommand) { $0.player.resume() }
        handle(center.pauseCommand) { $0.player.pause() }
        handle(center.togglePlayPauseCommand) { $0.player.togglePause() }
        handle(center.nextTrackCommand) { $0.channelUp() }
        handle(center.previousTrackCommand) { $0.channelDown() }
        center.skipForwardCommand.preferredIntervals = [30]
        handle(center.skipForwardCommand) { $0.player.skip(by: 30) }
        center.skipBackwardCommand.preferredIntervals = [10]
        handle(center.skipBackwardCommand) { $0.player.skip(by: -10) }
    }
}
