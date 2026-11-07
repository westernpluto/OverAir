import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// The real-time playback loop: reads transport-stream bytes, demuxes, decodes and enqueues
/// samples on a dedicated high-priority thread, paced against the render synchronizer's clock.
final class PipelineWorker: @unchecked Sendable {
    enum Event {
        case program(TSDemuxer.Program)
        /// The first picture is ready; the clock is held on it until audio has caught up.
        case firstFrame(Int64)
        /// Enough audio is buffered: start the clock at this time.
        case startClock(Int64)
        /// Audio keeps arriving after its play time; move the clock back to this time.
        case audioLate(Int64)
        case progress(video: Int64, audio: Int64)
        case info(StreamInfo)
        case captions([CEA608Decoder.Row], Int64)
        case captionsAvailable
        case ended
        case failed(String)
        case audioFailed
    }

    var onEvent: ((Event) -> Void)?

    private let source: ByteSource
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer

    // Control state shared with the main thread.
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    private var seekRequest: (offset: Int64, dropBefore: Int64?)?
    private var wantCaptions = false
    private var lowPower = false
    private var audioEnabled = true
    private var deinterlaceOn = true
    private var dynamicRange: Float = 1
    private var audioPID: Int?
    private var audioPIDChanged = false

    // Worker-thread state.
    private let demuxer = TSDemuxer()
    private var program: TSDemuxer.Program?
    private var mpeg2: MPEG2VideoDecoder?
    private var compressed: CompressedVideoPackager?
    private var audio: AudioPackager?
    private let pixels = PixelBufferFactory()
    private var deinterlacer: MetalDeinterlacer?
    private var triedDeinterlacer = false
    private var previousFrame: CVPixelBuffer?
    private let cc = CEA608Decoder()
    private var captionPTS: Int64 = 0
    private var captionsSeen = false
    private var readOffset: Int64 = 0
    private var dropBefore: Int64?
    private var clockStarted = false
    private var lastVideoPTS: Int64 = 0
    private var ptsWrap: Int64 = 0
    private var lastRawPTS: Int64?
    private var info = StreamInfo()
    private var infoSent = Date.distantPast
    private var adaptiveSkipB = false
    private var reportedAudioFailure = false
    private var audioEndPTS: Int64 = 0           // end time of the last audio buffer handed to the renderer
    private var clockReleased = false
    private var firstVideoPTS: Int64 = 0
    private var firstFrameWall = Date()
    private var lateAudioRun = 0
    private var lastLateReport = Date.distantPast

    init(source: ByteSource, videoRenderer: AVSampleBufferVideoRenderer, audioRenderer: AVSampleBufferAudioRenderer,
         synchronizer: AVSampleBufferRenderSynchronizer) {
        self.source = source
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        self.synchronizer = synchronizer
    }

    // MARK: Control (any thread)

    func start(at offset: Int64) {
        readOffset = offset
        let thread = Thread { [self] in self.run() }
        thread.name = "OverAir.Pipeline"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func setPaused(_ p: Bool) { lock.lock(); paused = p; lock.unlock() }
    func setCaptions(_ on: Bool) { lock.lock(); wantCaptions = on; lock.unlock() }
    func setLowPower(_ on: Bool) { lock.lock(); lowPower = on; lock.unlock() }
    func setAudioEnabled(_ on: Bool) { lock.lock(); audioEnabled = on; lock.unlock() }
    func setDeinterlace(_ on: Bool) { lock.lock(); deinterlaceOn = on; lock.unlock() }
    func setDynamicRange(_ v: Float) { lock.lock(); dynamicRange = v; lock.unlock() }
    func selectAudio(pid: Int?) { lock.lock(); audioPID = pid; audioPIDChanged = true; lock.unlock() }

    func seek(to offset: Int64, dropBefore: Int64?) {
        lock.lock(); seekRequest = (offset, dropBefore); lock.unlock()
    }

    private func emit(_ e: Event) { onEvent?(e) }

    // MARK: Loop

    private func run() {
        demuxer.onProgram = { [unowned self] p in self.programChanged(p) }
        demuxer.onPES = { [unowned self] pes in self.handlePES(pes) }

        while true {
            lock.lock()
            let isCancelled = cancelled
            let seek = seekRequest
            seekRequest = nil
            let isPaused = paused
            let pidChanged = audioPIDChanged
            audioPIDChanged = false
            lock.unlock()
            if isCancelled { break }
            if let seek { performSeek(seek) }
            if pidChanged { audio = nil; audioEndPTS = 0; lateAudioRun = 0 }

            if clockStarted {
                let wantsAudio = expectsAudio()
                if !clockReleased,
                   !wantsAudio || audioEndPTS >= firstVideoPTS + 27_000 || Date().timeIntervalSince(firstFrameWall) > 2.5 {
                    clockReleased = true
                    emit(.startClock(firstVideoPTS))
                }
                // Until the clock starts it is parked on the first picture.
                let now = clockReleased ? Int64(CMTimeGetSeconds(synchronizer.currentTime()) * 90000) : firstVideoPTS
                let videoLead = lastVideoPTS - now
                // Broadcasts send video well ahead of the matching audio, so keep reading until
                // both are buffered (with a cap on how far video may run ahead).
                let audioLead = wantsAudio ? audioEndPTS - now : Int64.max
                let enough = isPaused ? (videoLead > 45_000 && audioLead > 27_000) : (videoLead > 72_000 && audioLead > 36_000)
                if enough || videoLead > 180_000 {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                // Behind real time (slow device / multiview): temporarily skip B-pictures.
                if clockReleased {
                    if videoLead < -9_000 { adaptiveSkipB = true } else if videoLead > 30_000 { adaptiveSkipB = false }
                }
            }

            guard let chunk = source.read(at: readOffset, max: 188 * 256, timeout: 0.1) else { continue }
            if chunk.isEmpty {
                if let error = source.failure {
                    emit(.failed(error.localizedDescription))
                } else {
                    demuxer.flush()
                    mpeg2?.flush()
                    emit(.ended)
                }
                // Idle until a seek or cancel.
                while true {
                    lock.lock(); let done = cancelled || seekRequest != nil; lock.unlock()
                    if done { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continue
            }
            readOffset += Int64(chunk.count)
            chunk.withUnsafeBytes { demuxer.feed($0) }
            if Date().timeIntervalSince(infoSent) > 0.5 {
                infoSent = Date()
                emit(.info(info))
                if clockStarted { emit(.progress(video: lastVideoPTS, audio: audioEndPTS)) }
            }
        }
    }

    private func performSeek(_ seek: (offset: Int64, dropBefore: Int64?)) {
        videoRenderer.flush()
        audioRenderer.flush()
        demuxer.reset()
        mpeg2?.reset()
        audio?.reset()
        cc.reset()
        previousFrame = nil
        readOffset = seek.offset
        dropBefore = seek.dropBefore
        clockStarted = false
        clockReleased = false
        lastVideoPTS = 0
        audioEndPTS = 0
        lateAudioRun = 0
    }

    private func programChanged(_ p: TSDemuxer.Program) {
        program = p
        mpeg2 = nil
        compressed = nil
        audio = nil
        switch p.video?.kind {
        case .mpeg2Video?:
            let d = MPEG2VideoDecoder()
            d.onPicture = { [unowned self] pic in self.handlePicture(pic) }
            mpeg2 = d
        case .h264?:
            compressed = makePackager(hevc: false)
        case .hevc?:
            compressed = makePackager(hevc: true)
        default:
            break
        }
        info.videoCodec = p.video?.kind.name
        emit(.program(p))
    }

    private func makePackager(hevc: Bool) -> CompressedVideoPackager {
        let pk = CompressedVideoPackager(hevc: hevc)
        pk.onCaptions = { [unowned self] data, pts in self.handleCaptions(data, pts: pts.map(self.unwrapPTS)) }
        return pk
    }

    private func unwrapPTS(_ raw: Int64) -> Int64 {
        if let last = lastRawPTS {
            if raw < last - (1 << 32) { ptsWrap += 1 << 33 } else if raw > last + (1 << 32) { ptsWrap -= 1 << 33 }
        }
        lastRawPTS = raw
        return raw + ptsWrap
    }

    /// Whether a playable audio track is selected, so the clock should wait for it.
    private func expectsAudio() -> Bool {
        lock.lock(); let pid = audioPID, on = audioEnabled; lock.unlock()
        guard on, let pid, let track = program?.audio.first(where: { $0.pid == pid }) else { return false }
        switch track.kind {
        case .ac3, .eac3, .ac4, .aacADTS, .mpegAudio: return true
        default: return false
        }
    }

    // MARK: PES

    private func handlePES(_ pes: TSDemuxer.PES) {
        lock.lock()
        let pid = audioPID
        let audioOn = audioEnabled
        let low = lowPower
        lock.unlock()

        if pes.kind.isVideo && pes.pid == program?.video?.pid {
            let pts = pes.pts.map(unwrapPTS)
            let dts = pes.dts.map(unwrapPTS)
            if let mpeg2 {
                mpeg2.skipBPictures = low || adaptiveSkipB
                mpeg2.decode(pes.payload, pts: pts)
            } else if let compressed, let sb = compressed.makeSampleBuffer(pes.payload, pts: pts, dts: dts) {
                if let d = dropBefore, let pts, pts < d { Self.markDoNotDisplay(sb) }
                info.width = compressed.width
                info.height = compressed.height
                enqueueVideo(sb, pts: pts ?? lastVideoPTS)
            }
        } else if pes.kind.isAudio && pes.pid == pid && audioOn {
            let pts = pes.pts.map(unwrapPTS)
            if let d = dropBefore, let pts, pts < d { audio?.reset(); return }
            if audio == nil { audio = AudioPackager(kind: pes.kind) }
            guard let audio else { return }
            lock.lock(); let drc = dynamicRange; lock.unlock()
            if audio.dynamicRange != drc { audio.dynamicRange = drc }
            let now = clockReleased ? Int64(CMTimeGetSeconds(synchronizer.currentTime()) * 90000) : Int64.min
            for sb in audio.makeSampleBuffers(pes.payload, pts: pts) {
                audioRenderer.enqueue(sb)
                let start = CMSampleBufferGetPresentationTimeStamp(sb).value
                let duration = CMSampleBufferGetDuration(sb)
                let end = start + (duration.isValid ? CMTimeConvertScale(duration, timescale: 90000, method: .default).value : 2880)
                audioEndPTS = max(audioEndPTS, end)
                // Audio that is already late is dropped by the renderer: notice a run of it.
                if end < now { lateAudioRun += 1 } else { lateAudioRun = 0 }
                if lateAudioRun >= 12, Date().timeIntervalSince(lastLateReport) > 5 {
                    lastLateReport = Date()
                    lateAudioRun = 0
                    emit(.audioLate(start))
                }
            }
            info.audioCodec = audio.codecName
            info.audioChannels = audio.channels
            info.audioLayout = audio.layoutName
            info.audioDecodedInApp = audio.decodesInApp
            info.sampleRate = audio.sampleRate
            if audioRenderer.status == .failed && !audio.pcmFallback {
                audio.pcmFallback = true
                audioRenderer.flush()
                if !reportedAudioFailure { reportedAudioFailure = true; emit(.audioFailed) }
            }
        }
    }

    private static func markDoNotDisplay(_ sb: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    // MARK: Video

    private func handlePicture(_ pic: MPEG2Picture) {
        guard let pts = pic.pts else { return }
        if let d = dropBefore, pts < d - 1_500 { return }
        lock.lock()
        let low = lowPower || !deinterlaceOn
        lock.unlock()

        info.width = pic.width
        info.height = pic.height
        info.frameRate = pic.frameRate
        info.interlaced = !pic.progressive

        if !pic.captionData.isEmpty { handleCaptions(pic.captionData, pts: pts) }

        guard let buffer = pixels.makeBuffer(from: pic) else { return }
        let duration = Int64(90000 / max(pic.frameRate, 1))
        if !pic.progressive && !low {
            if !triedDeinterlacer { triedDeinterlacer = true; deinterlacer = MetalDeinterlacer() }
            let w = pic.width & ~1, h = pic.height & ~1
            if let di = deinterlacer,
               let pair = di.deinterlace(current: buffer, previous: previousFrame, topFieldFirst: pic.topFieldFirst,
                                         makeOutput: { [pixels] in pixels.makeBuffer(width: w, height: h) }) {
                info.deinterlacing = true
                enqueuePixels(pair.0, pts: pts, duration: duration / 2)
                enqueuePixels(pair.1, pts: pts + duration / 2, duration: duration / 2)
                previousFrame = buffer
                return
            }
        }
        info.deinterlacing = false
        enqueuePixels(buffer, pts: pts, duration: duration)
        previousFrame = buffer
    }

    private func enqueuePixels(_ buffer: CVPixelBuffer, pts: Int64, duration: Int64) {
        guard let sb = PixelBufferFactory.sampleBuffer(buffer, pts: CMTime(value: pts, timescale: 90000),
                                                        duration: CMTime(value: duration, timescale: 90000)) else { return }
        enqueueVideo(sb, pts: pts)
    }

    private func enqueueVideo(_ sb: CMSampleBuffer, pts: Int64) {
        if videoRenderer.status == .failed {
            videoRenderer.flush()
        }
        videoRenderer.enqueue(sb)
        if let d = dropBefore, pts < d { return }
        lastVideoPTS = max(lastVideoPTS, pts)
        if !clockStarted {
            clockStarted = true
            dropBefore = nil
            firstVideoPTS = pts
            firstFrameWall = Date()
            emit(.firstFrame(pts))
        }
    }

    // MARK: Captions

    private func handleCaptions(_ data: [UInt8], pts: Int64?) {
        if !captionsSeen { captionsSeen = true; emit(.captionsAvailable) }
        lock.lock(); let on = wantCaptions; lock.unlock()
        guard on else { return }
        if cc.onChange == nil {
            cc.onChange = { [unowned self] rows in self.emit(.captions(rows, self.captionPTS)) }
        }
        captionPTS = pts ?? lastVideoPTS
        cc.feed(data)
    }
}
