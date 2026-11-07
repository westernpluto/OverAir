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
    var rate: Float = 1 { didSet { applyRate() } }
    var aspect: AspectMode = .fit { didSet { applyAspect() } }

    /// The view libVLC renders into. Re-parented into whichever SwiftUI surface shows video.
    let videoView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        return v
    }()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wantsCaptions = false
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored var containerSize: CGSize = .zero { didSet { if oldValue != containerSize { applyAspect() } } }

    #if canImport(VLCKitSPM)
    private let player = VLCMediaPlayer()
    @ObservationIgnored private var renderer: VLCRendererDiscoverer?
    #endif

    init() {
        #if canImport(VLCKitSPM)
        player.drawable = videoView
        #endif
    }

    var isLive: Bool { duration <= 0 }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

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
        stopTimer()
        state = .opening
        currentTime = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        wantsCaptions = options.captions
        pendingStart = options.startAt
        openedAt = Date()
        isMuted = options.muted
        #if canImport(VLCKitSPM)
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(options.cachingMs)")
        media.addOption(":live-caching=\(options.cachingMs)")
        media.addOption(":file-caching=\(max(options.cachingMs / 2, 300))")
        media.addOption(":clock-jitter=0")
        media.addOption(":http-reconnect")
        if !options.hardwareDecoding { media.addOption(":codec=avcodec") }
        player.media = media
        player.setDeinterlaceFilter(options.deinterlace ? "yadif2x" : nil)
        player.play()
        applyAspect()
        applyMute()
        #else
        state = .failed("Video playback requires VLCKit. Open the project in Xcode so Swift Package Manager can fetch it.")
        #endif
        startTimer()
    }

    func togglePause() {
        #if canImport(VLCKitSPM)
        if player.isPlaying { player.pause() } else { player.play() }
        #endif
    }

    func pause() {
        #if canImport(VLCKitSPM)
        if player.isPlaying { player.pause() }
        #endif
    }

    func resume() {
        #if canImport(VLCKitSPM)
        if !player.isPlaying { player.play() }
        #endif
    }

    func stop() {
        stopTimer()
        #if canImport(VLCKitSPM)
        player.stop()
        player.media = nil
        #endif
        state = .idle
        currentTime = 0
        duration = 0
    }

    func seek(to seconds: Double) {
        #if canImport(VLCKitSPM)
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration - 1)
        player.position = Float(clamped / duration)
        currentTime = clamped
        #endif
    }

    func skip(by seconds: Int) {
        #if canImport(VLCKitSPM)
        if seconds >= 0 { player.jumpForward(Int32(seconds)) } else { player.jumpBackward(Int32(-seconds)) }
        currentTime = max(0, currentTime + Double(seconds))
        #endif
    }

    func selectAudio(_ track: MediaTrack) {
        #if canImport(VLCKitSPM)
        player.currentAudioTrackIndex = track.id
        selectedAudio = track.id
        #endif
    }

    func selectSubtitle(_ track: MediaTrack?) {
        #if canImport(VLCKitSPM)
        let id = track?.id ?? -1
        player.currentVideoSubTitleIndex = id
        selectedSubtitle = id
        wantsCaptions = track != nil
        #endif
    }

    var captionsOn: Bool { selectedSubtitle >= 0 }

    func toggleCaptions() {
        if captionsOn { selectSubtitle(nil) } else if let first = subtitleTracks.first { selectSubtitle(first) } else { wantsCaptions = true }
    }

    func snapshot() -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: videoView.bounds)
        return renderer.image { _ in videoView.drawHierarchy(in: videoView.bounds, afterScreenUpdates: false) }
    }

    // MARK: Casting (Chromecast via libVLC renderer)

    func startCastDiscovery() {
        #if canImport(VLCKitSPM)
        guard renderer == nil else { return }
        let names = VLCRendererDiscoverer.list()?.map(\.name) ?? []
        let name = names.first(where: { $0.contains("microdns") }) ?? names.first
        guard let name, let d = VLCRendererDiscoverer(name: name) else { return }
        _ = d.start()
        renderer = d
        #endif
    }

    func stopCastDiscovery() {
        #if canImport(VLCKitSPM)
        renderer?.stop()
        renderer = nil
        #endif
    }

    func cast(to target: CastTarget?) {
        #if canImport(VLCKitSPM)
        guard let target else {
            _ = player.setRendererItem(nil)
            activeCast = nil
            return
        }
        if let item = renderer?.renderers.first(where: { $0.name == target.name && $0.type == target.type }) {
            _ = player.setRendererItem(item)
            activeCast = target
        }
        #endif
    }

    // MARK: Internals

    private func applyMute() {
        #if canImport(VLCKitSPM)
        player.audio?.isMuted = isMuted
        #endif
    }

    private func applyRate() {
        #if canImport(VLCKitSPM)
        player.rate = rate
        #endif
    }

    private func applyAspect() {
        #if canImport(VLCKitSPM)
        let size = containerSize
        func setCrop(_ s: String?) {
            if let s { let p = strdup(s); player.videoCropGeometry = p; free(p) } else { player.videoCropGeometry = nil }
        }
        func setAspect(_ s: String?) {
            if let s { let p = strdup(s); player.videoAspectRatio = p; free(p) } else { player.videoAspectRatio = nil }
        }
        guard size.width > 0, size.height > 0 else { return }
        let ratio = "\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
        switch aspect {
        case .fit:
            setCrop(nil); setAspect(nil)
        case .fill:
            setAspect(nil); setCrop(ratio)
        case .stretch:
            setCrop(nil); setAspect(ratio)
        }
        #endif
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        #if canImport(VLCKitSPM)
        switch player.state {
        case .opening: state = .opening
        case .buffering: if state != .playing && state != .paused { state = player.isPlaying ? .playing : .buffering }
        case .playing, .esAdded: state = player.isPlaying ? .playing : .buffering
        case .paused: state = .paused
        case .ended: state = .ended
        case .error: state = .failed("The stream couldn't be played. The tuner may be busy, or the signal too weak.")
        case .stopped:
            if state == .opening && Date().timeIntervalSince(openedAt) > 15 {
                state = .failed("Timed out connecting to the tuner.")
            } else if state.isActive && state != .opening {
                state = .ended
            }
        @unknown default: break
        }
        if player.isPlaying && state != .playing { state = .playing }

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
        #endif
    }
}
