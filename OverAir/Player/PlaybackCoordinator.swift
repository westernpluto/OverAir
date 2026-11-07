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

/// Central place that starts/stops playback. The player view stays mounted for as long as
/// something is playing; "minimising" only hides it.
@MainActor
@Observable
final class PlaybackCoordinator {
    let player = TVPlayer()
    private(set) var item: PlaybackItem?
    /// Full-screen player visible (vs. minimised to the mini player).
    var isExpanded = false
    var isMultiviewPresented = false
    var multiviewChannels: [Channel] = []
    private(set) var sleepTimerEnd: Date?
    /// Briefly shown "2.1 CBS" banner after a channel change.
    private(set) var channelBanner: Channel?
    var lastError: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tuners: TunerStore
    @ObservationIgnored private let guide: GuideStore
    @ObservationIgnored private let dvr: DVRStore
    @ObservationIgnored private let recorder: LocalRecorder
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var tuneTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastTune = Date.distantPast
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
    var hasPreviousChannel: Bool { previousChannel != nil && previousChannel != currentChannel }

    func nextChannel(offset: Int) -> Channel? {
        guard let current = currentChannel else { return nil }
        return tuners.adjacentChannel(to: current.number, offset: offset)
    }

    // MARK: Start

    /// Tunes a live channel. Rapid presses (channel surfing) are coalesced so only the
    /// channel you land on actually takes a tuner.
    func play(_ channel: Channel, expand: Bool = true) {
        guard let url = tuners.streamURL(for: channel) else {
            lastError = "No stream address for channel \(channel.number)."
            return
        }
        if let current = currentChannel, current != channel { previousChannel = current }
        saveResumeIfNeeded()
        let wasSurfing = item?.isLive == true && Date().timeIntervalSince(lastTune) < 1.2
        lastTune = Date()
        item = .live(channel)
        settings.noteWatched(channel.number)
        showBanner(channel)
        if expand { isExpanded = true }
        Haptics.tap(settings)

        tuneTask?.cancel()
        var options = TVPlayer.Options()
        options.captions = settings.closedCaptionsByDefault || player.captionsEnabled
        if wasSurfing { player.stop() } // release the old tuner right away
        tuneTask = Task { [weak self] in
            if wasSurfing { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled, let self else { return }
            self.activateAudioSession()
            self.player.timeshiftCapacity = self.settings.rewindBufferBytes
            self.player.deinterlace = self.settings.deinterlace
            self.player.playLive(url: url, options: options)
            self.updateNowPlaying()
        }
    }

    func play(_ episode: RecordedEpisode, fromStart: Bool = false) {
        guard let url = episode.playURL else { lastError = "This recording has no play address."; return }
        saveResumeIfNeeded()
        tuneTask?.cancel()
        item = .recording(episode)
        var opts = TVPlayer.Options()
        opts.captions = settings.closedCaptionsByDefault
        opts.duration = episode.duration
        opts.startAt = fromStart ? nil : episode.resumeSeconds.map(Double.init)
        activateAudioSession()
        player.playRecording(url: url, options: opts)
        updateNowPlaying()
        isExpanded = true
    }

    func play(_ local: LocalRecording, fromStart: Bool = false) {
        saveResumeIfNeeded()
        tuneTask?.cancel()
        item = .local(local)
        var opts = TVPlayer.Options()
        opts.captions = settings.closedCaptionsByDefault
        opts.duration = local.ended.map { $0.timeIntervalSince(local.started) }
        opts.startAt = fromStart ? nil : local.resumeSeconds
        activateAudioSession()
        player.playRecording(url: local.fileURL, options: opts)
        updateNowPlaying()
        isExpanded = true
    }

    func retry() {
        switch item {
        case let .live(ch)?: lastTune = .distantPast; play(ch, expand: isExpanded)
        case let .recording(ep)?: play(ep)
        case let .local(rec)?: play(rec)
        case nil: break
        }
    }

    // MARK: Control

    func channelUp() { step(1) }
    func channelDown() { step(-1) }

    private func step(_ offset: Int) {
        guard let next = nextChannel(offset: offset) else { return }
        play(next, expand: isExpanded)
    }

    func lastChannel() {
        guard let prev = previousChannel else { return }
        play(prev, expand: isExpanded)
    }

    @discardableResult
    func tune(number: String) -> Bool {
        let normalized = number.replacingOccurrences(of: "-", with: ".")
        if let ch = tuners.channels.first(where: { $0.number == normalized })
            ?? tuners.channels.first(where: { $0.number.hasPrefix(normalized + ".") }) {
            play(ch, expand: true)
            return true
        }
        return false
    }

    func stop() {
        tuneTask?.cancel()
        saveResumeIfNeeded()
        player.stop()
        item = nil
        isExpanded = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setAspect(_ mode: AspectMode) {
        player.aspect = mode
        settings.aspectMode = mode
    }

    private func showBanner(_ channel: Channel) {
        channelBanner = channel
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.channelBanner = nil
        }
    }

    private func saveResumeIfNeeded() {
        guard let item, !player.isLive, player.duration > 0 else { return }
        let t = player.position
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
        sleepTimerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
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
        if let c = currentChannel, !list.contains(c) { list.insert(c, at: 0) }
        multiviewChannels = Array(list.prefix(maxMultiviewTiles))
        if item != nil { stop() }
        isMultiviewPresented = true
    }

    var maxMultiviewTiles: Int { max(2, min(4, tuners.totalTuners == 0 ? 4 : tuners.totalTuners)) }

    // MARK: System integration

    private func activateAudioSession() {
        player.reduceLoudSounds = settings.reduceLoudSounds
        player.deinterlace = settings.deinterlace
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
