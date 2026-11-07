import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

/// Turns audio PES payloads into sample buffers for AVSampleBufferAudioRenderer.
/// Compressed Dolby/AAC/MP2 packets are handed to the system decoder; if the renderer can't
/// take a format, `pcmFallback` switches to decoding with AudioConverter.
final class AudioPackager {
    let kind: TSDemuxer.Kind
    private var format: CMAudioFormatDescription?
    private var formatKey = ""
    private var converter: PCMConverter?
    var pcmFallback = false
    private(set) var sampleRate = 0
    private(set) var channels = 0

    init(kind: TSDemuxer.Kind) { self.kind = kind }

    func reset() {
        converter = nil
    }

    func makeSampleBuffers(_ payload: [UInt8], pts: Int64?) -> [CMSampleBuffer] {
        guard let pts else { return [] }
        let frames: [AudioFrameParser.Frame]
        var cookie: [UInt8]?
        var formatID: AudioFormatID
        switch kind {
        case .ac3: frames = AudioFrameParser.dolbyFrames(payload); formatID = kAudioFormatAC3
        case .eac3: frames = AudioFrameParser.dolbyFrames(payload); formatID = kAudioFormatEnhancedAC3
        case .aacADTS:
            let r = AudioFrameParser.adtsFrames(payload)
            frames = r.frames; cookie = r.config; formatID = kAudioFormatMPEG4AAC
        case .mpegAudio: frames = AudioFrameParser.mpegAudioFrames(payload); formatID = kAudioFormatMPEGLayer2
        default: return []
        }
        guard let first = frames.first else { return [] }
        sampleRate = first.sampleRate
        channels = first.channels

        if pcmFallback {
            if converter == nil {
                converter = PCMConverter(formatID: formatID, sampleRate: first.sampleRate, channels: first.channels,
                                         framesPerPacket: first.samplesPerFrame, cookie: cookie)
            }
            guard let converter else { return [] }
            var out: [CMSampleBuffer] = []
            var t = pts
            for f in frames {
                if let sb = converter.decode(Array(payload[f.range]), pts: t) { out.append(sb) }
                t += Int64(f.samplesPerFrame) * 90000 / Int64(f.sampleRate)
            }
            return out
        }

        let key = "\(formatID)-\(first.sampleRate)-\(first.channels)-\(first.samplesPerFrame)"
        if key != formatKey || format == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(first.sampleRate), mFormatID: formatID,
                mFormatFlags: formatID == kAudioFormatMPEG4AAC ? AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue) : 0,
                mBytesPerPacket: 0, mFramesPerPacket: UInt32(first.samplesPerFrame), mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(first.channels), mBitsPerChannel: 0, mReserved: 0)
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

        var data: [UInt8] = []
        var descs: [AudioStreamPacketDescription] = []
        for f in frames {
            descs.append(AudioStreamPacketDescription(mStartOffset: Int64(data.count), mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.range.count)))
            data.append(contentsOf: payload[f.range])
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return [] }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: descs.count,
                                                             presentationTimeStamp: CMTime(value: pts, timescale: 90000),
                                                             packetDescriptions: &descs, sampleBufferOut: &sb)
        return sb.map { [$0] } ?? []
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
