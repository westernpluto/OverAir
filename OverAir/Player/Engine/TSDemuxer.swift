import Foundation

/// MPEG transport stream demuxer for broadcast (ATSC 1.0 / 3.0 as delivered by HDHomeRun).
final class TSDemuxer {
    enum Kind: Equatable {
        case mpeg2Video, h264, hevc
        case ac3, eac3, ac4, aacADTS, aacLATM, mpegAudio
        case unknown(UInt8)

        var isVideo: Bool { self == .mpeg2Video || self == .h264 || self == .hevc }
        var isAudio: Bool {
            switch self {
            case .ac3, .eac3, .ac4, .aacADTS, .aacLATM, .mpegAudio: return true
            default: return false
            }
        }

        var name: String {
            switch self {
            case .mpeg2Video: return "MPEG-2"
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            case .ac3: return "Dolby Digital"
            case .eac3: return "Dolby Digital Plus"
            case .ac4: return "Dolby AC-4"
            case .aacADTS, .aacLATM: return "AAC"
            case .mpegAudio: return "MPEG Audio"
            case let .unknown(t): return String(format: "Type 0x%02X", t)
            }
        }
    }

    struct Stream: Equatable {
        var pid: Int
        var kind: Kind
        var language: String?
        /// ATSC/DVB audio service: visually impaired / description tracks are flagged so they aren't the default.
        var isAudioDescription: Bool
    }

    struct Program: Equatable {
        var programNumber: Int
        var pcrPID: Int
        var streams: [Stream]

        var video: Stream? { streams.first { $0.kind.isVideo } }
        var audio: [Stream] { streams.filter { $0.kind.isAudio } }
    }

    struct PES {
        var pid: Int
        var kind: Kind
        var pts: Int64?
        var dts: Int64?
        var randomAccess: Bool
        var payload: [UInt8]
    }

    var onProgram: ((Program) -> Void)?
    var onPES: ((PES) -> Void)?

    private(set) var program: Program?
    private(set) var packetsSeen = 0
    private(set) var continuityErrors = 0

    private var remainder: [UInt8] = []
    private var pmtPID: Int?
    private var sections: [Int: [UInt8]] = [:]
    private var kinds: [Int: Kind] = [:]

    private final class Assembly {
        var data: [UInt8] = []
        var expected = 0
        var randomAccess = false
        var lastCC = -1
    }
    private var assemblies: [Int: Assembly] = [:]

    func reset() {
        remainder.removeAll()
        sections.removeAll()
        assemblies.removeAll()
        // Keep the program map: channel content is unchanged on a seek.
    }

    func resetAll() {
        reset()
        pmtPID = nil
        program = nil
        kinds.removeAll()
    }

    func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var count = bytes.count
        var ptr = base
        if !remainder.isEmpty {
            let need = 188 - remainder.count
            if count < need { remainder.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count)); return }
            remainder.append(contentsOf: UnsafeBufferPointer(start: ptr, count: need))
            ptr += need; count -= need
            if remainder[0] == 0x47 {
                remainder.withUnsafeBufferPointer { handlePacket($0.baseAddress!) }
            }
            remainder.removeAll(keepingCapacity: true)
        }
        var i = 0
        while i + 188 <= count {
            if ptr[i] != 0x47 {
                // Resync: find the next sync byte that repeats 188 bytes later.
                var j = i + 1
                while j < count && !(ptr[j] == 0x47 && (j + 188 >= count || ptr[j + 188] == 0x47)) { j += 1 }
                i = j
                continue
            }
            handlePacket(ptr + i)
            i += 188
        }
        if i < count { remainder.append(contentsOf: UnsafeBufferPointer(start: ptr + i, count: count - i)) }
    }

    func feed(_ data: [UInt8]) { data.withUnsafeBytes { feed($0) } }

    /// Delivers any PES still being assembled (end of file).
    func flush() {
        for (pid, a) in assemblies where !a.data.isEmpty { deliver(pid: pid, a) }
    }

    // MARK: Packets

    /// Elementary-stream packets with transport_scrambling_control set (encrypted content).
    private(set) var scrambledPackets = 0

    private func handlePacket(_ p: UnsafePointer<UInt8>) {
        packetsSeen += 1
        let pusi = p[1] & 0x40 != 0
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let afc = (p[3] >> 4) & 0x3
        let cc = Int(p[3] & 0x0F)
        if pid == 0x1FFF { return }
        var offset = 4
        var randomAccess = false
        if afc & 0x2 != 0 {
            let afLen = Int(p[4])
            if afLen > 0 { randomAccess = p[5] & 0x40 != 0 }
            offset += 1 + afLen
        }
        guard afc & 0x1 != 0, offset < 188 else { return }
        let payload = UnsafeBufferPointer(start: p + offset, count: 188 - offset)

        if pid == 0 || pid == pmtPID {
            handleSection(pid: pid, pusi: pusi, payload: payload)
            return
        }
        guard let kind = kinds[pid] else { return }
        if p[3] & 0xC0 != 0 { scrambledPackets += 1; return }

        let a: Assembly
        if let existing = assemblies[pid] { a = existing } else { a = Assembly(); assemblies[pid] = a }
        if a.lastCC >= 0 && cc != (a.lastCC + 1) & 0xF && cc != a.lastCC {
            continuityErrors += 1
            if !pusi { a.data.removeAll(keepingCapacity: true); a.lastCC = cc; return }
        }
        a.lastCC = cc
        _ = kind

        if pusi {
            if !a.data.isEmpty { deliver(pid: pid, a) }
            a.data.removeAll(keepingCapacity: true)
            a.data.append(contentsOf: payload)
            a.randomAccess = randomAccess
            if a.data.count >= 6 {
                let len = (Int(a.data[4]) << 8) | Int(a.data[5])
                a.expected = len > 0 ? len + 6 : 0
            }
        } else {
            guard !a.data.isEmpty else { return }
            a.data.append(contentsOf: payload)
        }
        if a.expected > 0 && a.data.count >= a.expected {
            deliver(pid: pid, a)
            a.data.removeAll(keepingCapacity: true)
        }
    }

    private func deliver(pid: Int, _ a: Assembly) {
        defer { a.expected = 0 }
        let d = a.data
        guard d.count > 9, d[0] == 0, d[1] == 0, d[2] == 1, let kind = kinds[pid] else { return }
        let flags = d[7]
        let headerLen = Int(d[8])
        var pts: Int64?, dts: Int64?
        if flags & 0x80 != 0, d.count >= 14 { pts = Self.timestamp(d, 9) }
        if flags & 0x40 != 0, d.count >= 19 { dts = Self.timestamp(d, 14) }
        let start = 9 + headerLen
        guard start < d.count else { return }
        let end = a.expected > 0 ? min(a.expected, d.count) : d.count
        guard start < end else { return }
        onPES?(PES(pid: pid, kind: kind, pts: pts, dts: dts, randomAccess: a.randomAccess, payload: Array(d[start..<end])))
    }

    static func timestamp(_ d: [UInt8], _ i: Int) -> Int64 {
        let a = Int64(d[i] >> 1) & 0x07
        let b = (Int64(d[i + 1]) << 7) | (Int64(d[i + 2]) >> 1)
        let c = (Int64(d[i + 3]) << 7) | (Int64(d[i + 4]) >> 1)
        return (a << 30) | (b << 15) | c
    }

    // MARK: PSI

    private func handleSection(pid: Int, pusi: Bool, payload: UnsafeBufferPointer<UInt8>) {
        var buf = sections[pid] ?? []
        var data = Array(payload)
        if pusi {
            guard let pointer = data.first else { return }
            let start = 1 + Int(pointer)
            if !buf.isEmpty && start > 1 { buf.append(contentsOf: data[1..<min(start, data.count)]) ; processSection(pid: pid, buf) }
            buf = []
            data = start < data.count ? Array(data[start...]) : []
        } else if buf.isEmpty {
            return
        }
        buf.append(contentsOf: data)
        if buf.count >= 3 {
            let len = ((Int(buf[1]) & 0x0F) << 8) | Int(buf[2])
            if buf.count >= len + 3 {
                processSection(pid: pid, Array(buf[0..<(len + 3)]))
                buf = []
            }
        }
        sections[pid] = buf
    }

    private func processSection(pid: Int, _ s: [UInt8]) {
        guard s.count >= 8 else { return }
        let tableID = s[0]
        let len = ((Int(s[1]) & 0x0F) << 8) | Int(s[2])
        let end = min(3 + len - 4, s.count) // exclude CRC
        if pid == 0 && tableID == 0x00 {
            var i = 8
            while i + 4 <= end {
                let number = (Int(s[i]) << 8) | Int(s[i + 1])
                let mapPID = (Int(s[i + 2] & 0x1F) << 8) | Int(s[i + 3])
                if number != 0 { if pmtPID != mapPID { pmtPID = mapPID }; break }
                i += 4
            }
        } else if tableID == 0x02 {
            parsePMT(s, end: end)
        }
    }

    private func parsePMT(_ s: [UInt8], end: Int) {
        guard s.count >= 12 else { return }
        let programNumber = (Int(s[3]) << 8) | Int(s[4])
        let pcrPID = (Int(s[8] & 0x1F) << 8) | Int(s[9])
        let infoLen = ((Int(s[10]) & 0x0F) << 8) | Int(s[11])
        var i = 12 + infoLen
        var streams: [Stream] = []
        while i + 5 <= end {
            let type = s[i]
            let epid = (Int(s[i + 1] & 0x1F) << 8) | Int(s[i + 2])
            let esLen = ((Int(s[i + 3]) & 0x0F) << 8) | Int(s[i + 4])
            let descStart = i + 5
            let descEnd = min(descStart + esLen, end)
            var language: String?
            var description = false
            var kind: Kind
            switch type {
            case 0x01, 0x02: kind = .mpeg2Video
            case 0x1B: kind = .h264
            case 0x24: kind = .hevc
            case 0x81: kind = .ac3
            case 0x87: kind = .eac3
            case 0x0F: kind = .aacADTS
            case 0x11: kind = .aacLATM
            case 0x03, 0x04: kind = .mpegAudio
            default: kind = .unknown(type)
            }
            var d = descStart
            while d + 2 <= descEnd {
                let tag = s[d], dlen = Int(s[d + 1])
                let body = d + 2
                guard body + dlen <= descEnd else { break }
                switch tag {
                case 0x0A where dlen >= 4:
                    language = String(bytes: s[body..<(body + 3)], encoding: .ascii)
                    if s[body + 3] == 0x03 { description = true } // visual impaired commentary
                case 0x05 where dlen >= 4:
                    let id = String(bytes: s[body..<(body + 4)], encoding: .ascii) ?? ""
                    if id == "AC-3" && !kind.isAudio { kind = .ac3 }
                    if id == "EAC3" && !kind.isAudio { kind = .eac3 }
                    if id == "AC-4" { kind = .ac4 }
                    if id == "HEVC" { kind = .hevc }
                case 0x6A: if case .unknown = kind { kind = .ac3 }
                case 0x7A, 0xCC: if case .unknown = kind { kind = .eac3 }
                case 0x7F where dlen >= 1 && s[body] == 0x15: kind = .ac4 // DVB AC-4 extension descriptor
                case 0x81 where dlen >= 3:
                    // ATSC AC-3 audio descriptor: bsmod 2 = visually impaired, 3 = hearing impaired...
                    let bsmod = (s[body + 1] >> 5) & 0x7
                    if bsmod == 2 { description = true }
                    if dlen >= 6 && language == nil {
                        // Language code at a variable offset; best-effort.
                    }
                default: break
                }
                d = body + dlen
            }
            streams.append(Stream(pid: epid, kind: kind, language: language, isAudioDescription: description))
            i = descEnd
        }
        let newProgram = Program(programNumber: programNumber, pcrPID: pcrPID, streams: streams)
        if newProgram != program {
            program = newProgram
            kinds = [:]
            for st in streams where st.kind.isVideo || st.kind.isAudio { kinds[st.pid] = st.kind }
            onProgram?(newProgram)
        }
    }
}

// MARK: - Audio frame parsing

/// Splits audio PES payloads into codec frames and works out their format.
enum AudioFrameParser {
    struct Frame {
        var range: Range<Int>
        var sampleRate: Int
        var channels: Int
        var samplesPerFrame: Int
    }

    static let ac3SampleRates = [48000, 44100, 32000]
    static let ac3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    static let ac3ChannelCounts = [2, 1, 2, 3, 3, 4, 4, 5]

    /// AC-3 and E-AC-3 frames (sync word 0x0B77). `consumed` is where scanning stopped: the start
    /// of a frame that continues in the next PES packet, or the last few unscanned bytes.
    static func dolbyFrames(_ d: [UInt8]) -> (frames: [Frame], consumed: Int) {
        var out: [Frame] = []
        var i = 0
        while i + 7 < d.count {
            guard d[i] == 0x0B && d[i + 1] == 0x77 else { i += 1; continue }
            let bsid = d[i + 5] >> 3
            if bsid <= 10 {
                let fscod = Int(d[i + 4] >> 6)
                let frmsizecod = Int(d[i + 4] & 0x3F)
                guard fscod < 3, frmsizecod < 38 else { i += 1; continue }
                let kbps = ac3Bitrates[frmsizecod / 2]
                let size: Int
                switch fscod {
                case 0: size = kbps * 2 * 2 // 48 kHz: words = kbps*2
                case 1: size = (kbps * 320 / 147 + (frmsizecod & 1)) * 2
                default: size = kbps * 3 * 2
                }
                let acmod = Int(d[i + 6] >> 5)
                // lfeon follows optional mix-level fields whose presence depends on acmod.
                var bit = 3
                if acmod & 1 != 0 && acmod != 1 { bit += 2 }
                if acmod & 4 != 0 { bit += 2 }
                if acmod == 2 { bit += 2 }
                let word = (Int(d[i + 6]) << 8) | Int(d[i + 7])
                let lfe = (word >> (15 - bit)) & 1
                let ch = ac3ChannelCounts[acmod] + lfe
                guard size > 0, i + size <= d.count else { break }
                // A sync word inside audio data looks like a frame start: accept it only if the CRC
                // holds or another frame follows straight after; otherwise keep scanning.
                let followed = i + size + 1 < d.count ? (d[i + size] == 0x0B && d[i + size + 1] == 0x77) : nil
                if followed != true {
                    let valid = d.withUnsafeBytes { AC3Decoder.crcIsValid(UnsafeRawBufferPointer(rebasing: $0[i..<(i + size)]), size: size) }
                    if !valid {
                        if followed == nil { break }     // wait for more data before deciding
                        i += 1
                        continue
                    }
                }
                out.append(Frame(range: i..<(i + size), sampleRate: ac3SampleRates[fscod], channels: ch, samplesPerFrame: 1536))
                i += size
            } else {
                // E-AC-3
                let frmsiz = (Int(d[i + 2] & 0x07) << 8) | Int(d[i + 3])
                let size = (frmsiz + 1) * 2
                let fscod = Int(d[i + 4] >> 6)
                var rate = 48000
                var blocks = 6
                if fscod == 3 {
                    let fscod2 = Int((d[i + 4] >> 4) & 0x3)
                    rate = [24000, 22050, 16000, 48000][fscod2]
                } else {
                    rate = ac3SampleRates[min(fscod, 2)]
                    blocks = [1, 2, 3, 6][Int((d[i + 4] >> 4) & 0x3)]
                }
                let acmod = Int((d[i + 4] >> 1) & 0x7)
                let lfe = Int(d[i + 4] & 0x1)
                guard size > 0, i + size <= d.count else { break }
                out.append(Frame(range: i..<(i + size), sampleRate: rate, channels: ac3ChannelCounts[acmod] + lfe, samplesPerFrame: 256 * blocks))
                i += size
            }
        }
        return (out, i)
    }

    static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// AAC ADTS frames. Returns frames whose range excludes the ADTS header, plus the AudioSpecificConfig.
    static func adtsFrames(_ d: [UInt8]) -> (frames: [Frame], config: [UInt8]?, consumed: Int) {
        var out: [Frame] = []
        var config: [UInt8]?
        var i = 0
        while i + 7 <= d.count {
            guard d[i] == 0xFF && d[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let protectionAbsent = d[i + 1] & 0x01
            let profile = Int(d[i + 2] >> 6) + 1
            let srIndex = Int((d[i + 2] >> 2) & 0x0F)
            let channelConfig = Int(((d[i + 2] & 0x01) << 2) | (d[i + 3] >> 6))
            let length = (Int(d[i + 3] & 0x03) << 11) | (Int(d[i + 4]) << 3) | Int(d[i + 5] >> 5)
            let header = protectionAbsent == 1 ? 7 : 9
            guard srIndex < aacRates.count, length > header, i + length <= d.count else { break }
            if config == nil {
                config = [UInt8((profile << 3) | (srIndex >> 1)), UInt8(((srIndex & 1) << 7) | (channelConfig << 3))]
            }
            out.append(Frame(range: (i + header)..<(i + length), sampleRate: aacRates[srIndex], channels: max(channelConfig, 1), samplesPerFrame: 1024))
            i += length
        }
        return (out, config, i)
    }

    /// AC-4 sync frames (0xAC40, or 0xAC41 with a CRC). `samplesPerFrame` is the frame duration
    /// in 90 kHz ticks and `sampleRate` is 90000, so frame timing works out in PTS units.
    static func ac4Frames(_ d: [UInt8]) -> (frames: [Frame], consumed: Int) {
        var out: [Frame] = []
        var i = 0
        while i + 8 <= d.count {
            guard d[i] == 0xAC && (d[i + 1] == 0x40 || d[i + 1] == 0x41) else { i += 1; continue }
            var size = Int(d[i + 2]) << 8 | Int(d[i + 3])
            var header = 4
            if size == 0xFFFF {
                guard i + 7 <= d.count else { break }
                size = Int(d[i + 4]) << 16 | Int(d[i + 5]) << 8 | Int(d[i + 6])
                header = 7
            }
            let total = header + size + (d[i + 1] == 0x41 ? 2 : 0)
            guard size > 0, i + total <= d.count else { break }
            // A sync word inside frame data: only accept it if another frame (or the end) follows.
            if i + total + 1 < d.count && !(d[i + total] == 0xAC && (d[i + total + 1] & 0xFE) == 0x40) {
                i += 1
                continue
            }
            out.append(Frame(range: i..<(i + total), sampleRate: 90000, channels: 2,
                             samplesPerFrame: ac4FrameTicks(d, at: i + header)))
            i += total
        }
        return (out, i)
    }

    /// Duration of an AC-4 frame in 90 kHz ticks, from its table of contents.
    static func ac4FrameTicks(_ d: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= d.count else { return 3003 }
        var bits = 0, pos = 0
        func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = offset + (pos >> 3)
                let bit = byte < d.count ? Int(d[byte] >> (7 - UInt8(pos & 7))) & 1 : 0
                v = (v << 1) | bit
                pos += 1
            }
            return v
        }
        let version = read(2)
        if version == 3 { return 3003 }
        _ = read(10)                                     // sequence_counter
        if read(1) == 1 { if read(3) > 0 { _ = read(2) } } // wait_frames
        bits = read(1)                                   // fs_index
        let rateIndex = read(4)
        let base = AC4Tables.frame_len_base_48khz[rateIndex]
        guard base > 0 else { return 3003 }
        let r = AC4Decoder.resamplingRatios[rateIndex]
        let rate = bits == 1 ? 48000.0 : 44100.0
        return Int((Double(base) * Double(r.0) / Double(r.1) / rate * 90000).rounded())
    }

    /// MPEG-1 Layer II audio frames.
    static func mpegAudioFrames(_ d: [UInt8]) -> (frames: [Frame], consumed: Int) {
        let bitratesL2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
        let rates = [44100, 48000, 32000, 0]
        var out: [Frame] = []
        var i = 0
        while i + 4 <= d.count {
            guard d[i] == 0xFF && d[i + 1] & 0xE0 == 0xE0 else { i += 1; continue }
            let br = bitratesL2[Int(d[i + 2] >> 4)]
            let sr = rates[Int((d[i + 2] >> 2) & 0x3)]
            let pad = Int((d[i + 2] >> 1) & 0x1)
            guard br > 0, sr > 0 else { i += 1; continue }
            let size = 144 * br * 1000 / sr + pad
            guard i + size <= d.count else { break }
            let ch = (d[i + 3] >> 6) == 3 ? 1 : 2
            out.append(Frame(range: i..<(i + size), sampleRate: sr, channels: ch, samplesPerFrame: 1152))
            i += size
        }
        return (out, i)
    }
}

/// Joins audio PES payloads into whole frames. Frames may straddle PES packets; each frame is
/// timed from the PTS of the packet it starts in, or from the end of the frame before it.
final class AudioFrameAssembler {
    struct TimedFrame {
        var bytes: [UInt8]
        var pts: Int64
        var frame: AudioFrameParser.Frame
    }

    let kind: TSDemuxer.Kind
    private(set) var config: [UInt8]?     // AAC AudioSpecificConfig
    private var pending: [UInt8] = []
    private var nextPTS: Int64?

    init(kind: TSDemuxer.Kind) { self.kind = kind }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        nextPTS = nil
    }

    func push(_ payload: [UInt8], pts: Int64?) -> [TimedFrame] {
        let anchor = pending.count
        pending.append(contentsOf: payload)
        var pesPTS = pts
        let frames: [AudioFrameParser.Frame]
        let consumed: Int
        switch kind {
        case .ac3, .eac3:
            (frames, consumed) = AudioFrameParser.dolbyFrames(pending)
        case .aacADTS:
            let r = AudioFrameParser.adtsFrames(pending)
            frames = r.frames; consumed = r.consumed
            if let c = r.config { config = c }
        case .mpegAudio:
            (frames, consumed) = AudioFrameParser.mpegAudioFrames(pending)
        case .ac4:
            (frames, consumed) = AudioFrameParser.ac4Frames(pending)
        default:
            pending.removeAll()
            return []
        }
        var out: [TimedFrame] = []
        for f in frames {
            // ADTS frame ranges exclude the header; the frame starts where its header does.
            let start = kind == .aacADTS ? max(0, f.range.lowerBound - 7) : f.range.lowerBound
            let t: Int64
            if let p = pesPTS, start >= anchor {
                t = p
                pesPTS = nil
            } else if let n = nextPTS {
                t = n
            } else {
                continue                                  // no timing yet: wait for a PTS
            }
            out.append(TimedFrame(bytes: Array(pending[f.range]), pts: t, frame: f))
            nextPTS = t + Int64(f.samplesPerFrame) * 90000 / Int64(max(f.sampleRate, 1))
        }
        if consumed > 0 { pending.removeFirst(min(consumed, pending.count)) }
        if pending.count > 65536 { reset() }
        return out
    }
}
