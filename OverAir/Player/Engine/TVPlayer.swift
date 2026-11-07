import Foundation
import AVFoundation
import AVKit
import CoreMedia
import UIKit
import Observation

/// Hosts the AVSampleBufferDisplayLayer that frames are rendered into.
final class SampleBufferVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct StreamInfo: Equatable {
    var videoCodec: String?
    var width = 0
    var height = 0
    var frameRate: Double = 0
    var interlaced = false
    var deinterlacing = false
    var audioCodec: String?
    var audioChannels = 0
    var sampleRate = 0
    var mbps: Double = 0
    var lateFrames = 0

    var resolutionLabel: String {
        guard height > 0 else { return "—" }
        let p = interlaced ? "i" : "p"
        switch height {
        case 1070...1090: return "1080\(p)"
        case 710...730: return "720\(p)"
        case 2100...2200: return "4K"
        default: return "\(height)\(p)"
        }
    }

    var channelLabel: String {
        switch audioChannels {
        case 0: return "—"
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        default: return "\(audioChannels) ch"
        }
    }
}

struct AudioTrack: Identifiable, Hashable {
    var id: Int
    var language: String?
    var codec: String
    var isDescription: Bool
    var supported: Bool

    var title: String {
        var name = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }?.capitalized ?? "Audio \(id)"
        if isDescription { name += " (Described)" }
        return name
    }
}

/// OverAir's native broadcast player: no third-party code.
/// Transport stream → demux → MPEG-2 (software, multi-core) or H.264/HEVC (hardware) → Metal
/// deinterlacing → AVSampleBufferDisplayLayer, with Dolby/AAC audio through AVSampleBufferAudioRenderer.
/// Live TV is buffered to disk so it can be paused and rewound.
@MainActor
@Observable
final class TVPlayer {
    enum State: Equatable {
        case idle, opening, buffering, playing, paused, ended
        case failed(String)

        var isActive: Bool { [.opening, .buffering, .playing, .paused].contains(self) }
        var isLoading: Bool { self == .opening || self == .buffering }
    }

    private(set) var state: State = .idle {
        didSet {
            #if DEBUG
            if oldValue != state { print("[TVPlayer] state \(state)") }
            #endif
        }
    }
    private(set) var isLive = true
    /// Recordings: seconds from the start. Live: seconds from the oldest buffered moment.
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Live only: how far behind the live broadcast we are.
    private(set) var behindLive: Double = 0
    /// Live only: how much can be rewound.
    private(set) var timeshiftAvailable: Double = 0
    private(set) var audioTracks: [AudioTrack] = []
    private(set) var selectedAudio: Int?
    private(set) var captionRows: [CEA608Decoder.Row] = []
    private(set) var hasCaptions = false
    private(set) var info = StreamInfo()
    private(set) var isPictureInPictureActive = false
    private(set) var isPictureInPicturePossible = false

    var captionsEnabled = false {
        didSet {
            worker?.setCaptions(captionsEnabled)
            if !captionsEnabled { captionRows = []; pendingCaptions.removeAll() }
        }
    }
    var isMuted = false { didSet { audioRenderer.isMuted = isMuted } }
    var rate: Float = 1 { didSet { if state == .playing { synchronizer.rate = rate } } }
    var aspect: AspectMode = .fit { didSet { applyGravity() } }
    /// Multiview tiles: skip B-frames, no deinterlacing, no audio unless selected.
    var lowPower = false { didSet { worker?.setLowPower(lowPower) } }
    var audioEnabled = true { didSet { worker?.setAudioEnabled(audioEnabled); if !audioEnabled { audioRenderer.flush() } } }
    /// Convert interlaced broadcasts to smooth 60 fps.
    var deinterlace = true { didSet { worker?.setDeinterlace(deinterlace) } }

    let videoView = SampleBufferVideoView()

    @ObservationIgnored private let audioRenderer = AVSampleBufferAudioRenderer()
    @ObservationIgnored private let synchronizer = AVSampleBufferRenderSynchronizer()
    @ObservationIgnored private var worker: PipelineWorker?
    @ObservationIgnored private var store: StreamStore?
    @ObservationIgnored private var feeder: NetworkFeeder?
    @ObservationIgnored private var indexer: StreamIndexer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var firstPTS: Int64?       // first PTS of a recording (position 0)
    @ObservationIgnored private var lastFramePTS: Int64 = 0
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var totalBytes: Int64?
    @ObservationIgnored private var pendingCaptions: [(pts: Int64, rows: [CEA608Decoder.Row])] = []
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var pipDelegate: PiPDelegate?
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var timeshiftCapacity: Int64 = 1_500_000_000

    init() {
        synchronizer.addRenderer(videoView.displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        audioRenderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        audioRenderer.audioTimePitchAlgorithm = .spectral
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var isAtLiveEdge: Bool { behindLive < 4 }
    var captionsOn: Bool { captionsEnabled }

    // MARK: Playback

    struct Options {
        var startAt: Double?
        var captions = false
        var muted = false
        var duration: Double?
        var bufferingMs = 0
    }

    func playLive(url: URL, options: Options = Options()) {
        start(url: url, live: true, local: false, options: options)
    }

    func playRecording(url: URL, options: Options = Options()) {
        start(url: url, live: false, local: url.isFileURL, options: options)
    }

    private func start(url: URL, live: Bool, local: Bool, options: Options) {
        stop()
        generation += 1
        let gen = generation
        isLive = live
        sourceURL = url
        state = .opening
        openedAt = Date()
        position = 0
        duration = options.duration ?? 0
        behindLive = 0
        timeshiftAvailable = 0
        audioTracks = []
        selectedAudio = nil
        hasCaptions = false
        captionRows = []
        info = StreamInfo()
        firstPTS = nil
        captionsEnabled = options.captions
        isMuted = options.muted
        rate = 1
        audioRenderer.isMuted = isMuted

        let source: ByteSource
        if local {
            guard let file = FileByteSource(url: url) else { state = .failed("Couldn't open the recording file."); return }
            source = file
            totalBytes = file.length
        } else {
            guard let s = try? StreamStore(capacity: live ? timeshiftCapacity : 600_000_000) else {
                state = .failed("Not enough storage to buffer video."); return
            }
            store = s
            let f = NetworkFeeder(store: s)
            if live {
                let idx = StreamIndexer(store: s)
                indexer = idx
                f.onIndexBytes = { data, offset in idx.consume(data, at: offset) }
            }
            feeder = f
            source = s
        }

        let w = PipelineWorker(source: source, videoRenderer: videoView.displayLayer.sampleBufferRenderer,
                               audioRenderer: audioRenderer, synchronizer: synchronizer)
        w.setCaptions(captionsEnabled)
        w.setLowPower(lowPower)
        w.setAudioEnabled(audioEnabled)
        w.setDeinterlace(deinterlace)
        w.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, generation: gen) } }
        }
        worker = w

        if live {
            feeder?.start(url: url)
            w.start(at: 0)
        } else if local {
            w.start(at: startOffset(for: options.startAt))
            probeFirstPTS(url: url, generation: gen)
        } else {
            // Find the recording's first timestamp and size, then start (possibly mid-file for resume).
            Task { [weak self] in
                let probe = await Self.probe(url: url)
                guard let self, self.generation == gen else { return }
                self.firstPTS = probe.firstPTS
                self.totalBytes = probe.length
                let offset = self.startOffset(for: options.startAt)
                self.feeder?.start(url: url, from: offset)
                self.worker?.start(at: offset)
            }
        }
        setupPictureInPicture()
        startTimer()
    }

    private func startOffset(for seconds: Double?) -> Int64 {
        guard let seconds, seconds > 0, duration > 0, let total = totalBytes, total > 0 else { return 0 }
        let fraction = min(max(seconds / duration, 0), 0.98)
        return (Int64(Double(total) * fraction) / 188) * 188
    }

    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        worker?.cancel()
        worker = nil
        feeder?.stop()
        feeder = nil
        store = nil
        indexer = nil
        synchronizer.rate = 0
        videoView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()
        pendingCaptions.removeAll()
        captionRows = []
        state = .idle
    }

    func togglePause() { state == .paused ? resume() : pause() }

    func pause() {
        guard state == .playing || state == .buffering else { return }
        synchronizer.rate = 0
        state = .paused
        worker?.setPaused(true)
    }

    func resume() {
        guard state == .paused else { return }
        worker?.setPaused(false)
        synchronizer.rate = rate
        state = .playing
    }

    /// Jump relative to the current position (instant replay / skip ahead).
    func skip(by seconds: Double) {
        seek(toTime: currentClock + seconds)
    }

    /// Recordings: seek to seconds from the start.
    func seek(to seconds: Double) {
        if isLive {
            guard let range = store?.ptsRange else { return }
            seek(toTime: Double(range.oldest) / 90000 + seconds)
        } else if let first = firstPTS {
            seek(toTime: Double(first) / 90000 + seconds)
        } else if let url = sourceURL, duration > 0 {
            restartRecording(url: url, at: seconds)
        }
    }

    func goLive() {
        guard isLive, let range = store?.ptsRange else { return }
        seek(toTime: Double(range.newest) / 90000 - 1.0)
    }

    private var currentClock: Double { CMTimeGetSeconds(synchronizer.currentTime()) }

    private func seek(toTime target: Double) {
        guard let worker else { return }
        if isLive {
            guard let store, let range = store.ptsRange else { return }
            let clamped = min(max(target, Double(range.oldest) / 90000), Double(range.newest) / 90000 - 0.5)
            let pts = Int64(clamped * 90000)
            guard let offset = store.offset(forPTS: pts - 90000) else { return }
            synchronizer.rate = 0
            state = .buffering
            pendingCaptions.removeAll(); captionRows = []
            worker.seek(to: offset, dropBefore: pts)
        } else if let first = firstPTS, let url = sourceURL {
            let seconds = target - Double(first) / 90000
            if duration > 0 { restartRecording(url: url, at: min(max(seconds, 0), duration - 1)) }
        }
    }

    private func restartRecording(url: URL, at seconds: Double) {
        guard let worker else { return }
        let offset = startOffset(for: seconds)
        synchronizer.rate = 0
        state = .buffering
        pendingCaptions.removeAll(); captionRows = []
        if url.isFileURL {
            worker.seek(to: offset, dropBefore: nil)
        } else {
            feeder?.start(url: url, from: offset)
            worker.seek(to: offset, dropBefore: nil)
        }
    }

    func selectAudio(_ track: AudioTrack) {
        selectedAudio = track.id
        audioRenderer.flush()
        worker?.selectAudio(pid: track.id)
    }

    func toggleCaptions() { captionsEnabled.toggle() }

    // MARK: Events

    private func handle(_ event: PipelineWorker.Event, generation gen: Int) {
        guard gen == generation else { return }
        #if DEBUG
        switch event {
        case .frame, .info, .captions: break
        default: print("[TVPlayer] \(event)")
        }
        #endif
        switch event {
        case let .program(program):
            audioTracks = program.audio.map {
                AudioTrack(id: $0.pid, language: $0.language, codec: $0.kind.name, isDescription: $0.isAudioDescription,
                           supported: $0.kind != .ac4 && $0.kind != .aacLATM)
            }
            if selectedAudio == nil || !audioTracks.contains(where: { $0.id == selectedAudio }) {
                let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier(.alpha3) }
                let usable = audioTracks.filter { $0.supported && !$0.isDescription }
                let pick = usable.first { t in preferred.contains { $0 == t.language } } ?? usable.first ?? audioTracks.first
                selectedAudio = pick?.id
                worker?.selectAudio(pid: pick?.id)
            }
            info.videoCodec = program.video?.kind.name
            if let audio = audioTracks.first(where: { $0.id == selectedAudio }) { info.audioCodec = audio.codec }
            if let audio = audioTracks.first(where: { $0.id == selectedAudio }), !audio.supported {
                info.audioCodec = "\(audio.codec) (not supported)"
            }
        case let .firstFrame(pts):
            lastFramePTS = pts
            synchronizer.setRate(state == .paused ? 0 : rate, time: CMTime(value: pts, timescale: 90000))
            if state != .paused { state = .playing }
            if firstPTS == nil && !isLive { firstPTS = pts }
        case let .frame(pts):
            lastFramePTS = pts
        case let .info(newInfo):
            var merged = newInfo
            merged.mbps = (feeder?.bytesPerSecond ?? 0) * 8 / 1_000_000
            info = merged
        case let .captions(rows, pts):
            hasCaptions = true
            if captionsEnabled { pendingCaptions.append((pts, rows)) }
        case .captionsAvailable:
            hasCaptions = true
        case .ended:
            if !isLive { state = .ended; synchronizer.rate = 0 }
        case let .failed(message):
            state = .failed(message)
            synchronizer.rate = 0
        case .audioFailed:
            info.audioCodec = (info.audioCodec ?? "Audio") + " (decoded in software)"
        }
    }

    // MARK: Clock & UI updates

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = synchronizer.currentTime()
        let nowPTS = Int64(CMTimeGetSeconds(now) * 90000)
        // Captions due now.
        if !pendingCaptions.isEmpty {
            var latest: [CEA608Decoder.Row]?
            pendingCaptions.removeAll { item in
                if item.pts <= nowPTS + 3000 { latest = item.rows; return true }
                return false
            }
            if let latest { captionRows = latest }
        }
        if isLive, let range = store?.ptsRange {
            timeshiftAvailable = Double(range.newest - range.oldest) / 90000
            if state == .playing || state == .paused {
                behindLive = max(0, Double(range.newest - nowPTS) / 90000 - 0.8)
                position = max(0, Double(nowPTS - range.oldest) / 90000)
            }
            duration = timeshiftAvailable
        } else if let first = firstPTS, state == .playing || state == .paused {
            position = max(0, Double(nowPTS - first) / 90000)
        }
        // Stalls: no data at all.
        if state == .opening && Date().timeIntervalSince(openedAt) > 15 {
            state = .failed("The tuner didn't send any video. It may be busy, or the signal is too weak.")
        }
        if state == .playing, synchronizer.rate > 0, lastFramePTS > 0, nowPTS - lastFramePTS > 90000 * 4 {
            state = .buffering
        } else if state == .buffering, lastFramePTS > nowPTS {
            state = .playing
        }
    }

    // MARK: Presentation

    private func applyGravity() {
        switch aspect {
        case .fit: videoView.displayLayer.videoGravity = .resizeAspect
        case .fill: videoView.displayLayer.videoGravity = .resizeAspectFill
        case .stretch: videoView.displayLayer.videoGravity = .resize
        }
    }

    // MARK: Picture in Picture

    private func setupPictureInPicture() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let delegate = PiPDelegate(player: self)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: videoView.displayLayer, playbackDelegate: delegate)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = delegate
        pip = controller
        pipDelegate = delegate
        isPictureInPicturePossible = true
    }

    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    fileprivate func pipStateChanged(_ active: Bool) { isPictureInPictureActive = active }

    fileprivate var pipTimeRange: CMTimeRange {
        if isLive { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        let start = CMTime(value: firstPTS ?? 0, timescale: 90000)
        return CMTimeRange(start: start, duration: CMTime(seconds: max(duration, 1), preferredTimescale: 90000))
    }
}

/// Bridges the PiP sample-buffer playback delegate (called off the main actor) to TVPlayer.
private final class PiPDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    weak var player: TVPlayer?
    init(player: TVPlayer) { self.player = player }

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { if playing { player?.resume() } else { player?.pause() } }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated { player?.pipTimeRange ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { player?.state == .paused }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { player?.skip(by: CMTimeGetSeconds(skipInterval)) }
        completionHandler()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { player?.pipStateChanged(true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { player?.pipStateChanged(false) }
    }
}

extension TVPlayer {
    /// Reads the start of a recording to learn its first PTS and total size.
    nonisolated static func probe(url: URL) async -> (firstPTS: Int64?, length: Int64?) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await HTTP.session.data(for: request) else { return (nil, nil) }
        var length: Int64?
        if let http = response as? HTTPURLResponse {
            if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last {
                length = Int64(total)
            } else if http.expectedContentLength > 0 {
                length = http.expectedContentLength
            }
        }
        return (firstVideoPTS(in: [UInt8](data)), length)
    }

    nonisolated static func firstVideoPTS(in bytes: [UInt8]) -> Int64? {
        let dmx = TSDemuxer()
        var found: Int64?
        dmx.onPES = { pes in if found == nil, pes.kind.isVideo, let p = pes.pts { found = p } }
        dmx.feed(bytes)
        dmx.flush()
        return found
    }

    private func probeFirstPTS(url: URL, generation gen: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 1 << 20) else { return }
        try? handle.close()
        if generation == gen { firstPTS = Self.firstVideoPTS(in: [UInt8](data)) }
    }
}

// MARK: - Byte sources

protocol ByteSource: AnyObject {
    func read(at offset: Int64, max: Int, timeout: TimeInterval) -> [UInt8]?
    var failure: Error? { get }
}

extension StreamStore: ByteSource {}

final class FileByteSource: ByteSource {
    private let handle: FileHandle
    let length: Int64
    var failure: Error? { nil }

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = h
        length = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    deinit { try? handle.close() }

    func read(at offset: Int64, max: Int, timeout: TimeInterval) -> [UInt8]? {
        guard offset < length else { return [] }
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.read(upToCount: max) else { return [] }
        return [UInt8](data)
    }
}
