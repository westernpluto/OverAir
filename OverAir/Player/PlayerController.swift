import Foundation
import Observation
import UIKit
#if canImport(VLCKitSPM)
import VLCKitSPM
#else
#error("VLCKit is missing. In Xcode choose File > Packages > Resolve Package Versions so the vlckit-spm package is downloaded.")
#endif

struct MediaTrack: Identifiable, Hashable {
    var id: Int32
    var name: String
}

struct CastTarget: Identifiable, Hashable {
    var id: String { name + type }
    var name: String
    var type: String
}

/// Wraps libVLC so the app can play the raw MPEG-TS that HDHomeRun tuners emit
/// (MPEG-2, H.264, HEVC video; AC-3, E-AC-3, AAC, MP2 audio; EIA-608/708 captions).
///
/// Every stream gets its own `VLCMediaPlayer` and render view. When the channel changes the
/// previous player is stopped on a background queue: libVLC's `stop` blocks until the network
/// input thread exits, which used to freeze the UI (and keep the old tuner busy) on channel changes.
@MainActor
@Observable
final class PlayerController {
    enum State: Equatable {
        case idle, opening, buffering, playing, paused, ended
        case failed(String)

        var isActive: Bool {
            switch self {
            case .opening, .buffering, .playing, .paused: return true
            default: return false
            }
        }

        var isLoading: Bool { self == .opening || self == .buffering }
    }

    private(set) var state: State = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isSeekable = false
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudio: Int32 = -1
    private(set) var selectedSubtitle: Int32 = -1
    private(set) var videoSize: CGSize = .zero
    private(set) var castTargets: [CastTarget] = []
    private(set) var activeCast: CastTarget?
    var isMuted = false { didSet { applyMute() } }
    var rate: Float = 1 { didSet { player?.rate = rate } }
    var aspect: AspectMode = .fit { didSet { applyAspect() } }

    /// The stable view SwiftUI hosts. Each stream renders into its own child view inside it.
    let videoView: UIView = VideoHostView()

    @ObservationIgnored private var player: VLCMediaPlayer?
    @ObservationIgnored private var renderView: UIView?
    @ObservationIgnored private var renderer: VLCRendererDiscoverer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wantsCaptions = false
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var sawPlaying = false
    @ObservationIgnored var containerSize: CGSize = .zero { didSet { if oldValue != containerSize { applyAspect() } } }

    private static let teardownQueue = DispatchQueue(label: "app.overair.vlc-teardown", qos: .userInitiated)

    var isLive: Bool { duration <= 0 }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var captionsOn: Bool { selectedSubtitle >= 0 || (wantsCaptions && subtitleTracks.isEmpty && state.isActive) }

    // MARK: Playback

    struct Options {
        var cachingMs: Int = 1200
        var deinterlace = true
        var hardwareDecoding = true
        var captions = false
        var startAt: Double?
        var muted = false
    }

    func play(url: URL, options: Options) {
        retireCurrentPlayer()
        state = .opening
        currentTime = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        selectedAudio = -1
        selectedSubtitle = -1
        wantsCaptions = options.captions
        pendingStart = options.startAt
        openedAt = Date()
        sawPlaying = false
        rate = 1

        let render = VideoHostView(frame: videoView.bounds)
        render.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        render.backgroundColor = .clear
        videoView.addSubview(render)

        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(options.cachingMs)")
        media.addOption(":live-caching=\(options.cachingMs)")
        media.addOption(":file-caching=\(max(options.cachingMs / 2, 300))")
        media.addOption(":clock-jitter=0")
        if !options.hardwareDecoding { media.addOption(":codec=avcodec") }

        let p = VLCMediaPlayer()
        p.drawable = render
        p.media = media
        p.setDeinterlaceFilter(options.deinterlace ? "yadif2x" : nil)
        player = p
        renderView = render
        isMuted = options.muted
        p.play()
        applyAspect()
        applyMute()
        startTimer()
    }

    func togglePause() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func pause() { if player?.isPlaying == true { player?.pause() } }

    func resume() { if player?.isPlaying == false { player?.play() } }

    func stop() {
        stopTimer()
        retireCurrentPlayer()
        state = .idle
        currentTime = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
    }

    func seek(to seconds: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration - 1)
        player.position = Float(clamped / duration)
        currentTime = clamped
    }

    func skip(by seconds: Int) {
        guard let player else { return }
        if seconds >= 0 { player.jumpForward(Int32(seconds)) } else { player.jumpBackward(Int32(-seconds)) }
        currentTime = max(0, currentTime + Double(seconds))
    }

    func selectAudio(_ track: MediaTrack) {
        player?.currentAudioTrackIndex = track.id
        selectedAudio = track.id
    }

    func selectSubtitle(_ track: MediaTrack?) {
        let id = track?.id ?? -1
        player?.currentVideoSubTitleIndex = id
        selectedSubtitle = id
        wantsCaptions = track != nil
    }

    func toggleCaptions() {
        if captionsOn {
            selectSubtitle(nil)
        } else if let first = subtitleTracks.first {
            selectSubtitle(first)
        } else {
            wantsCaptions = true // applied as soon as the caption track appears
        }
    }

    /// Stops the current player without blocking the main thread.
    private func retireCurrentPlayer() {
        guard let old = player else { return }
        let oldView = renderView
        player = nil
        renderView = nil
        old.audio?.isMuted = true
        Self.teardownQueue.async {
            old.stop()
            DispatchQueue.main.async {
                old.drawable = nil
                oldView?.removeFromSuperview()
            }
        }
    }

    // MARK: Casting (Chromecast via libVLC renderer)

    func startCastDiscovery() {
        guard renderer == nil else { return }
        let names = VLCRendererDiscoverer.list()?.map(\.name) ?? []
        let name = names.first(where: { $0.contains("microdns") }) ?? names.first
        guard let name, let d = VLCRendererDiscoverer(name: name) else { return }
        _ = d.start()
        renderer = d
    }

    func stopCastDiscovery() {
        renderer?.stop()
        renderer = nil
    }

    func cast(to target: CastTarget?) {
        guard let player else { return }
        guard let target else {
            _ = player.setRendererItem(nil)
            activeCast = nil
            return
        }
        if let item = renderer?.renderers.first(where: { $0.name == target.name && $0.type == target.type }) {
            _ = player.setRendererItem(item)
            activeCast = target
        }
    }

    // MARK: Internals

    private func applyMute() {
        player?.audio?.isMuted = isMuted
    }

    private func applyAspect() {
        guard let player else { return }
        func setCrop(_ s: String?) {
            if let s { let p = strdup(s); player.videoCropGeometry = p; free(p) } else { player.videoCropGeometry = nil }
        }
        func setAspect(_ s: String?) {
            if let s { let p = strdup(s); player.videoAspectRatio = p; free(p) } else { player.videoAspectRatio = nil }
        }
        let size = containerSize
        guard size.width > 0, size.height > 0 else { return }
        let ratio = "\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
        switch aspect {
        case .fit: setCrop(nil); setAspect(nil)
        case .fill: setAspect(nil); setCrop(ratio)
        case .stretch: setCrop(nil); setAspect(ratio)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let player else { return }
        let elapsed = Date().timeIntervalSince(openedAt)
        switch player.state {
        case .opening:
            state = .opening
        case .buffering, .playing, .esAdded:
            state = player.isPlaying ? .playing : (state == .paused ? .paused : .buffering)
        case .paused:
            state = .paused
        case .ended:
            state = .ended
        case .error:
            state = .failed("This channel couldn't be played. All tuners may be in use, or the signal is too weak.")
        case .stopped:
            if !sawPlaying && elapsed > 12 {
                state = .failed("The tuner didn't respond. Check that your HDHomeRun is online and a tuner is free.")
            } else if sawPlaying {
                state = .ended
            }
        @unknown default:
            break
        }
        if player.isPlaying {
            state = .playing
            sawPlaying = true
        } else if !sawPlaying && state.isLoading && elapsed > 20 {
            state = .failed("Still waiting for video. The signal may be too weak, or all tuners are busy.")
        }

        currentTime = Double(player.time.intValue) / 1000
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        duration = length > 0 ? length : 0
        isSeekable = player.isSeekable
        videoSize = player.videoSize

        let audioNames = player.audioTrackNames.compactMap { $0 as? String }
        let audioIdx = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let newAudio = zip(audioIdx, audioNames).filter { $0.0 >= 0 }.map { MediaTrack(id: $0.0, name: $0.1) }
        if newAudio != audioTracks { audioTracks = newAudio }
        selectedAudio = player.currentAudioTrackIndex

        let subNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let subIdx = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let newSubs = zip(subIdx, subNames).filter { $0.0 >= 0 }.map { MediaTrack(id: $0.0, name: $0.1) }
        if newSubs != subtitleTracks { subtitleTracks = newSubs }
        selectedSubtitle = player.currentVideoSubTitleIndex
        if wantsCaptions && selectedSubtitle < 0, let first = subtitleTracks.first {
            player.currentVideoSubTitleIndex = first.id
        }

        if let start = pendingStart, duration > 0, player.isPlaying {
            pendingStart = nil
            seek(to: start)
        }

        if let d = renderer {
            let targets = d.renderers.map { CastTarget(name: $0.name, type: $0.type) }
            if targets != castTargets { castTargets = targets }
        }
    }
}

/// A view that keeps every subview (libVLC's render surface) sized to its bounds,
/// through rotation, fold/unfold and window resizes.
final class VideoHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        autoresizesSubviews = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews where sub.frame != bounds { sub.frame = bounds }
    }
}
