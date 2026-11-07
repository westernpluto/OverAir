import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

/// Turns audio PES payloads into sample buffers for AVSampleBufferAudioRenderer.
/// Dolby Digital (AC-3), the audio on every ATSC 1.0 channel, is decoded here by `AC3Decoder` and
/// handed over as PCM. Other formats go to the system decoder as compressed packets; if the
/// renderer can't take one, `pcmFallback` decodes it with AudioConverter instead.
final class AudioPackager {
    let kind: TSDemuxer.Kind
    private var format: CMAudioFormatDescription?
    private var formatKey = ""
    private var converter: PCMConverter?
    private var ac3: AC3Decoder?
    private var ac4: AC4Decoder?
    private var pcmFormat: CMAudioFormatDescription?
    private var pcmRate: Double = 0
    var pcmFallback = false
    /// Broadcaster dynamic range control for Dolby Digital: 0 = off, 1 = full.
    var dynamicRange: Float = 1 { didSet { ac3?.dynamicRange = dynamicRange } }
    private(set) var sampleRate = 0
    private(set) var channels = 0
    private(set) var layoutName: String?
    private(set) var decodesInApp = false
    /// Display name of the in-app decoder's format.
    var codecName: String { kind == .ac4 ? "Dolby AC-4" : (kind == .ac3 ? "Dolby Digital" : kind.name) }

    private let assembler: AudioFrameAssembler

    init(kind: TSDemuxer.Kind) {
        self.kind = kind
        assembler = AudioFrameAssembler(kind: kind)
        if kind == .ac3 {
            ac3 = AC3Decoder()
            decodesInApp = true
        }
        if kind == .ac4 {
            ac4 = AC4Decoder()
            decodesInApp = true
        }
    }

    func reset() {
        converter = nil
        assembler.reset()
        ac3?.reset()
        ac4?.reset()
    }

    func makeSampleBuffers(_ payload: [UInt8], pts: Int64?) -> [CMSampleBuffer] {
        let frames = assembler.push(payload, pts: pts)
        guard let first = frames.first else { return [] }

        if let ac3 {
            return frames.compactMap { (tf) -> CMSampleBuffer? in
                guard let pcm = tf.bytes.withUnsafeBytes({ ac3.decode($0) }) else { return nil }
                if let f = ac3.format {
                    sampleRate = f.sampleRate
                    channels = f.channelCount
                    layoutName = f.layoutName
                }
                return makePCMBuffer(pcm, rate: Double(ac3.format?.sampleRate ?? 48000), pts: tf.pts)
            }
        }

        if let ac4 {
            return frames.compactMap { (tf) -> CMSampleBuffer? in
                do {
                    guard let f = try tf.bytes.withUnsafeBytes({ try ac4.decodeFrame($0) }) else { return nil }
                    if let fmt = ac4.format {
                        sampleRate = fmt.sampleRate
                        channels = fmt.channelCount
                        layoutName = fmt.layoutName
                    }
                    lastAC4 = (f.samples, f.sampleRate)
                    let pcm = StereoDownmix.mix(f.channels, samples: f.samples)
                    return makePCMBuffer(pcm, rate: f.sampleRate, pts: tf.pts)
                } catch {
                    // Keep the timeline continuous: a damaged frame plays as silence.
                    guard let last = lastAC4 else { return nil }
                    return makePCMBuffer([Float](repeating: 0, count: last.samples * 2), rate: last.rate, pts: tf.pts)
                }
            }
        }

        let formatID: AudioFormatID
        switch kind {
        case .eac3: formatID = kAudioFormatEnhancedAC3
        case .aacADTS: formatID = kAudioFormatMPEG4AAC
        case .mpegAudio: formatID = kAudioFormatMPEGLayer2
        default: return []
        }
        let cookie = assembler.config
        sampleRate = first.frame.sampleRate
        channels = first.frame.channels
        layoutName = nil

        if pcmFallback {
            if converter == nil {
                converter = PCMConverter(formatID: formatID, sampleRate: first.frame.sampleRate, channels: first.frame.channels,
                                         framesPerPacket: first.frame.samplesPerFrame, cookie: cookie)
            }
            guard let converter else { return [] }
            return frames.compactMap { (tf) -> CMSampleBuffer? in converter.decode(tf.bytes, pts: tf.pts) }
        }

        let key = "\(formatID)-\(first.frame.sampleRate)-\(first.frame.channels)-\(first.frame.samplesPerFrame)"
        if key != formatKey || format == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(first.frame.sampleRate), mFormatID: formatID,
                mFormatFlags: formatID == kAudioFormatMPEG4AAC ? AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue) : 0,
                mBytesPerPacket: 0, mFramesPerPacket: UInt32(first.frame.samplesPerFrame), mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(first.frame.channels), mBitsPerChannel: 0, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            if let cookie {
                cookie.withUnsafeBytes { c in
                    _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                       magicCookieSize: c.count, magicCookie: c.baseAddress,
                                                       extensions: nil, formatDescriptionOut: &fmt)
                }
            } else {
                CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                               magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
            }
            format = fmt
            formatKey = key
        }
        guard let format else { return [] }

        // One buffer per frame keeps every buffer's timestamp exact.
        return frames.compactMap { (tf) -> CMSampleBuffer? in
            let bytes = tf.bytes
            var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
            guard let block = Self.blockBuffer(bytes) else { return nil }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                 sampleCount: 1,
                                                                 presentationTimeStamp: CMTime(value: tf.pts, timescale: 90000),
                                                                 packetDescriptions: &desc, sampleBufferOut: &sb)
            return sb
        }
    }

    private var lastAC4: (samples: Int, rate: Double)?

    private func makePCMBuffer(_ samples: [Float], rate: Double, pts: Int64) -> CMSampleBuffer? {
        if pcmFormat == nil || pcmRate != rate {
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                           layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
            pcmFormat = fmt
            pcmRate = rate
        }
        guard let pcmFormat else { return nil }
        let block: CMBlockBuffer? = samples.withUnsafeBytes { Self.blockBuffer($0) }
        guard let block else { return nil }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: pcmFormat,
                                                             sampleCount: samples.count / 2,
                                                             presentationTimeStamp: CMTime(value: pts, timescale: 90000),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    private static func blockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
        bytes.withUnsafeBytes { blockBuffer($0) }
    }

    private static func blockBuffer(_ raw: UnsafeRawBufferPointer) -> CMBlockBuffer? {
        guard raw.count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: raw.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: raw.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        return block
    }
}

/// Stereo (Lo/Ro) downmix of decoded speaker channels (A/52 7.8.2 coefficients), normalised for
/// headroom, lifted back for multichannel programmes and caught by a soft limiter.
enum StereoDownmix {
    /// `channels`: L, R, C, LFE, Ls, Rs (nil where absent). Returns interleaved stereo.
    static func mix(_ channels: [[Float]?], samples n: Int) -> [Float] {
        let l = channels[0], r = channels[1], c = channels[2], ls = channels[4], rs = channels[5]
        var out = [Float](repeating: 0, count: n * 2)
        guard let l else { return out }
        if r == nil && c == nil {
            for i in 0..<n { out[2 * i] = l[i]; out[2 * i + 1] = l[i] }   // mono
            return out
        }
        let clev: Float = c != nil ? 0.7071 : 0
        let slev: Float = (ls != nil || rs != nil) ? 0.7071 : 0
        let norm = 1 / (1 + clev + slev)
        let makeup: Float = (c != nil || ls != nil) ? 1.6 : 1
        let g = norm * makeup
        let rr = r ?? l
        for i in 0..<n {
            var lo = l[i], ro = rr[i]
            if let c { lo += clev * c[i]; ro += clev * c[i] }
            if let ls { lo += slev * ls[i] }
            if let rs { ro += slev * rs[i] }
            out[2 * i] = softLimit(lo * g)
            out[2 * i + 1] = softLimit(ro * g)
        }
        return out
    }

    @inline(__always) static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.85 else { return x }
        let limited = 0.85 + 0.15 * Float(tanh(Double((a - 0.85) / 0.15)))
        return x < 0 ? -limited : limited
    }
}

/// Decodes one compressed audio packet at a time to interleaved Float32 PCM.
final class PCMConverter {
    private var converter: AudioConverterRef?
    private let outFormat: CMAudioFormatDescription
    private let channels: Int
    private let sampleRate: Int
    private let framesPerPacket: Int

    private final class InputBox {
        let bytes: UnsafeMutableRawPointer
        let count: Int
        let desc: UnsafeMutablePointer<AudioStreamPacketDescription>
        var consumed = false

        init(_ packet: [UInt8]) {
            let n = packet.count
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(n, 1), alignment: 16)
            packet.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: n) }
            let d = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            d.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(n)))
            count = n
            bytes = buffer
            desc = d
        }

        deinit { bytes.deallocate(); desc.deallocate() }
    }

    init?(formatID: AudioFormatID, sampleRate: Int, channels: Int, framesPerPacket: Int, cookie: [UInt8]?) {
        var input = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: formatID,
                                                mFormatFlags: formatID == kAudioFormatMPEG4AAC ? AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue) : 0,
                                                mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
                                                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let outCh = min(channels, 2)
        var output = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(4 * outCh), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * outCh),
                                                 mChannelsPerFrame: UInt32(outCh), mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &conv) == noErr, let conv else { return nil }
        if let cookie {
            _ = cookie.withUnsafeBytes { AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!) }
        }
        if channels > 2 {
            // Let the decoder downmix to stereo.
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            AudioConverterSetProperty(conv, kAudioConverterOutputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &layout)
        }
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &output, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        converter = conv
        outFormat = fmt
        self.channels = outCh
        self.sampleRate = sampleRate
        self.framesPerPacket = framesPerPacket
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    func decode(_ packet: [UInt8], pts: Int64) -> CMSampleBuffer? {
        guard let converter else { return nil }
        guard !packet.isEmpty else { return nil }
        let box = InputBox(packet)
        let frames = framesPerPacket
        let bytes = frames * channels * 4
        let out = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        defer { out.deallocate() }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes), mData: out))
        var produced = UInt32(frames)
        let status = withExtendedLifetime(box) {
            AudioConverterFillComplexBuffer(converter, { _, ioCount, ioData, outDesc, user in
                let box = Unmanaged<InputBox>.fromOpaque(user!).takeUnretainedValue()
                if box.consumed { ioCount.pointee = 0; return 1 }
                box.consumed = true
                ioCount.pointee = 1
                ioData.pointee.mBuffers.mData = box.bytes
                ioData.pointee.mBuffers.mDataByteSize = UInt32(box.count)
                ioData.pointee.mBuffers.mNumberChannels = 0
                if let outDesc { outDesc.pointee = box.desc }
                return noErr
            }, Unmanaged.passUnretained(box).toOpaque(), &produced, &list, nil)
        }
        guard status == noErr || status == 1, produced > 0 else { return nil }
        let size = Int(produced) * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: size,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        CMBlockBufferReplaceDataBytes(with: out, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: outFormat,
                                                             sampleCount: Int(produced),
                                                             presentationTimeStamp: CMTime(value: pts, timescale: 90000),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}
