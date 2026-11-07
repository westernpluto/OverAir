import Foundation

/// Dolby Digital (AC-3) decoder, written from ATSC A/52. Every ATSC 1.0 channel and HDHomeRun
/// recording carries AC-3, so the player decodes it itself and hands the system plain PCM, which
/// plays on every device and route. Output is a stereo (Lo/Ro) downmix.
final class AC3Decoder {
    struct Format: Equatable {
        var sampleRate: Int
        var acmod: Int
        var lfe: Bool
        var bitrate: Int

        var channelCount: Int { AC3Decoder.fullBandwidthChannels[acmod] + (lfe ? 1 : 0) }
        /// "2.0", "5.1", …
        var layoutName: String {
            let fbw = AC3Decoder.fullBandwidthChannels[acmod]
            return acmod == 0 ? "1+1" : "\(fbw).\(lfe ? 1 : 0)"
        }
    }

    static let samplesPerFrame = 1536

    /// How much of the broadcaster's dynamic range control to apply: 0 = none, 1 = all of it.
    var dynamicRange: Float = 1
    private(set) var format: Format?

    // MARK: Constants (A/52 tables)

    static let fullBandwidthChannels = [2, 1, 2, 3, 3, 4, 4, 5]
    static let sampleRates = [48000, 44100, 32000]
    static let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]

    /// Frame size in bytes (Table 5.18).
    static func frameSize(fscod: Int, frmsizecod: Int) -> Int {
        let kbps = bitrates[frmsizecod >> 1]
        switch fscod {
        case 0: return kbps * 4
        case 1: return (kbps * 320 / 147 + (frmsizecod & 1)) * 2
        default: return kbps * 6
        }
    }

    private static let lfeIndex = 5
    private static let cplIndex = 6

    private static let slowDecay = [0x0f, 0x11, 0x13, 0x15]
    private static let fastDecay = [0x3f, 0x53, 0x67, 0x7b]
    private static let slowGain = [0x540, 0x4d8, 0x478, 0x410]
    private static let dbPerBit = [0x000, 0x700, 0x900, 0xb00]
    private static let floorTable = [0x2f0, 0x2b0, 0x270, 0x230, 0x1f0, 0x170, 0x0f0, -2048] // 0xf800 as a signed 16-bit value
    private static let fastGain = [0x080, 0x100, 0x180, 0x200, 0x280, 0x300, 0x380, 0x400]

    private static let bandStart: [Int] = Array(0...28) + [31, 34, 37, 40, 43, 46, 49, 55, 61, 67, 73, 79, 85, 97, 109, 121, 133, 157, 181, 205, 229]
    private static let bandSize: [Int] = Array(repeating: 1, count: 28) + Array(repeating: 3, count: 7)
        + Array(repeating: 6, count: 6) + Array(repeating: 12, count: 4) + Array(repeating: 24, count: 5)
    private static let maskTable: [Int] = {
        var t = [Int](repeating: 0, count: 256)
        for band in 0..<50 {
            for bin in bandStart[band]..<(bandStart[band] + bandSize[band]) { t[bin] = band }
        }
        return t
    }()

    private static let logAdd: [Int] = [
        0x40, 0x3f, 0x3e, 0x3d, 0x3c, 0x3b, 0x3a, 0x39, 0x38, 0x37, 0x36, 0x35, 0x34, 0x34, 0x33, 0x32, 0x31, 0x30, 0x2f, 0x2f,
        0x2e, 0x2d, 0x2c, 0x2c, 0x2b, 0x2a, 0x29, 0x29, 0x28, 0x27, 0x26, 0x26, 0x25, 0x24, 0x24, 0x23, 0x23, 0x22, 0x21, 0x21,
        0x20, 0x20, 0x1f, 0x1e, 0x1e, 0x1d, 0x1d, 0x1c, 0x1c, 0x1b, 0x1b, 0x1a, 0x1a, 0x19, 0x19, 0x18, 0x18, 0x17, 0x17, 0x16,
        0x16, 0x15, 0x15, 0x15, 0x14, 0x14, 0x13, 0x13, 0x13, 0x12, 0x12, 0x12, 0x11, 0x11, 0x11, 0x10, 0x10, 0x10, 0x0f, 0x0f,
        0x0f, 0x0e, 0x0e, 0x0e, 0x0d, 0x0d, 0x0d, 0x0d, 0x0c, 0x0c, 0x0c, 0x0c, 0x0b, 0x0b, 0x0b, 0x0b, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x09, 0x09, 0x09, 0x09, 0x09, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    ] + Array(repeating: 0, count: 46)

    private static let hearingThreshold: [[Int]] = [
        [0x04d0, 0x04d0, 0x0440, 0x0400, 0x03e0, 0x03c0, 0x03b0, 0x03b0, 0x03a0, 0x03a0, 0x03a0, 0x03a0, 0x03a0, 0x0390, 0x0390,
         0x0390, 0x0380, 0x0380, 0x0370, 0x0370, 0x0360, 0x0360, 0x0350, 0x0350, 0x0340, 0x0340, 0x0330, 0x0320, 0x0310, 0x0300,
         0x02f0, 0x02f0, 0x02f0, 0x02f0, 0x0300, 0x0310, 0x0340, 0x0390, 0x03e0, 0x0420, 0x0460, 0x0490, 0x04a0, 0x0460, 0x0440,
         0x0440, 0x0520, 0x0800, 0x0840, 0x0840],
        [0x04f0, 0x04f0, 0x0460, 0x0410, 0x03e0, 0x03d0, 0x03c0, 0x03b0, 0x03b0, 0x03a0, 0x03a0, 0x03a0, 0x03a0, 0x03a0, 0x0390,
         0x0390, 0x0390, 0x0380, 0x0380, 0x0380, 0x0370, 0x0370, 0x0360, 0x0360, 0x0350, 0x0350, 0x0340, 0x0340, 0x0320, 0x0310,
         0x0300, 0x02f0, 0x02f0, 0x02f0, 0x02f0, 0x0300, 0x0320, 0x0350, 0x0390, 0x03e0, 0x0420, 0x0450, 0x04a0, 0x0490, 0x0460,
         0x0440, 0x0480, 0x0630, 0x0840, 0x0840],
        [0x0580, 0x0580, 0x04b0, 0x0450, 0x0420, 0x03f0, 0x03e0, 0x03d0, 0x03c0, 0x03b0, 0x03b0, 0x03b0, 0x03a0, 0x03a0, 0x03a0,
         0x03a0, 0x03a0, 0x03a0, 0x03a0, 0x03a0, 0x0390, 0x0390, 0x0390, 0x0390, 0x0380, 0x0380, 0x0380, 0x0370, 0x0360, 0x0350,
         0x0340, 0x0330, 0x0320, 0x0310, 0x0300, 0x02f0, 0x02f0, 0x02f0, 0x0300, 0x0310, 0x0330, 0x0350, 0x03c0, 0x0410, 0x0470,
         0x04a0, 0x0460, 0x0440, 0x0450, 0x04e0],
    ]

    private static let bapTable: [Int] = [
        0, 1, 1, 1, 1, 1, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8, 9, 9, 9, 9, 10,
        10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    ]
    /// Mantissa bits for asymmetric quantisation, by bap (6...15).
    private static let asymmetricBits = [0, 0, 0, 0, 0, 0, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16]

    private static func symmetricLevels(_ levels: Int) -> [Float] {
        (0..<levels).map { Float(2 * $0 - (levels - 1)) / Float(levels) }
    }
    private static let q3 = symmetricLevels(3)
    private static let q5 = symmetricLevels(5)
    private static let q7 = symmetricLevels(7)
    private static let q11 = symmetricLevels(11)
    private static let q15 = symmetricLevels(15)

    private static let rematrixBands = [13, 25, 37, 61, 253]
    private static let centerMix: [Float] = [0.7071, 0.5946, 0.5, 0.5946]
    private static let surroundMix: [Float] = [0.7071, 0.5, 0, 0.5]

    /// Exponent scale factors 2^-e for e in 0...24 (and beyond, to stay in range on bad input).
    private static let pow2Neg: [Float] = (0..<64).map { Float(pow(2.0, -Double($0))) }

    // MARK: Transform tables

    private static let window: [Float] = {
        // Kaiser-Bessel-derived window, alpha = 5 (Table 7.33).
        let n = 256
        let alpha2 = 4 * pow(5.0 * Double.pi / Double(n), 2)
        var cumulative = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            let x = Double(i * (n - i)) * alpha2
            var bessel = 1.0
            for j in stride(from: 50, to: 0, by: -1) { bessel = bessel * x / Double(4 * j * j) + 1 }
            sum += bessel
            cumulative[i] = sum
        }
        sum += 1
        return cumulative.map { Float(sqrt($0 / sum)) }
    }()
    private static let cos1: [Float] = (0..<128).map { Float(-cos(2 * Double.pi * Double(8 * $0 + 1) / 4096)) }
    private static let sin1: [Float] = (0..<128).map { Float(-sin(2 * Double.pi * Double(8 * $0 + 1) / 4096)) }
    private static let cos2: [Float] = (0..<64).map { Float(-cos(2 * Double.pi * Double(8 * $0 + 1) / 2048)) }
    private static let sin2: [Float] = (0..<64).map { Float(-sin(2 * Double.pi * Double(8 * $0 + 1) / 2048)) }
    private static let fft128 = ComplexFFT(size: 128)
    private static let fft64 = ComplexFFT(size: 64)

    // MARK: Decoder state

    private var padded = [UInt8](repeating: 0, count: 4096)
    private var acmod = 0
    private var nfchans = 0
    private var lfeon = false
    private var fscod = 0
    private var cmixlev = 0
    private var surmixlev = 0

    private var blksw = [Bool](repeating: false, count: 5)
    private var dithflag = [Bool](repeating: false, count: 5)
    private var dynrng: [Float] = [1, 1]

    private var cplinu = false
    private var chincpl = [Bool](repeating: false, count: 5)
    private var phsflginu = false
    private var cplbegf = 0
    private var cplendf = 0
    private var ncplsubnd = 0
    private var cplbndstrc = [Bool](repeating: false, count: 18)
    private var cplco = [[Float]](repeating: [Float](repeating: 0, count: 18), count: 5)
    private var phsflg = [Bool](repeating: false, count: 18)
    private var cplstrtmant = 0
    private var cplendmant = 0

    private var rematflg = [Bool](repeating: false, count: 4)
    private var nrematbd = 0

    private var expstr = [Int](repeating: 0, count: 7)
    private var chbwcod = [Int](repeating: 0, count: 5)
    private var endmant = [Int](repeating: 0, count: 7)
    private var exps = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 7)

    private var sdcycod = 0, fdcycod = 0, sgaincod = 0, dbpbcod = 0, floorcod = 0
    private var csnroffst = 0
    private var fsnroffst = [Int](repeating: 0, count: 7)
    private var fgaincod = [Int](repeating: 0, count: 7)
    private var cplfleak = 0, cplsleak = 0

    private var dbaActive = [Bool](repeating: false, count: 7)
    private var dbaSegments = [[(offset: Int, length: Int, ba: Int)]](repeating: [], count: 7)

    private var bap = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 7)
    private var coefficients = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 7)
    private var cplZero = [Bool](repeating: false, count: 256)   // coupling bins with no bits (dithered per channel)

    /// The last frame's decoded channels in coded order (L, C, R, Ls, Rs, then LFE), before downmixing.
    private(set) var channelPCM = [[Float]](repeating: [Float](repeating: 0, count: 1536), count: 6)
    private var delay = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 6)
    private var blockPCM = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 6)
    private var transformScratch = [Float](repeating: 0, count: 512)
    private var re = [Float](repeating: 0, count: 128)
    private var im = [Float](repeating: 0, count: 128)
    private var re2 = [Float](repeating: 0, count: 64)
    private var im2 = [Float](repeating: 0, count: 64)

    private var group1: [Float] = [], group2: [Float] = [], group4: [Float] = []
    private var ditherState: UInt32 = 0x1234_5678

    // Scratch for bit allocation.
    private var psd = [Int](repeating: 0, count: 256)
    private var bandPSD = [Int](repeating: 0, count: 50)
    private var excite = [Int](repeating: 0, count: 50)
    private var mask = [Int](repeating: 0, count: 50)

    /// Keep per-channel output in `channelPCM` (for tests and diagnostics).
    var keepsChannels = false
    private var currentBlock = 0

    init() {}

    func reset() {
        for ch in 0..<6 { for i in 0..<256 { delay[ch][i] = 0 } }
        format = nil
    }

    // MARK: Frame

    /// Decodes one syncframe to interleaved stereo Float32 (1536 frames). Returns nil if the
    /// bytes aren't a valid AC-3 frame; returns silence for a frame that fails its CRC.
    func decode(_ frame: UnsafeRawBufferPointer) -> [Float]? {
        guard frame.count >= 8, frame[0] == 0x0B, frame[1] == 0x77 else { return nil }
        let fs = Int(frame[4] >> 6), sizeCode = Int(frame[4] & 0x3F)
        guard fs < 3, sizeCode < 38 else { return nil }
        let size = Self.frameSize(fscod: fs, frmsizecod: sizeCode)
        guard frame.count >= size, Int(frame[5] >> 3) <= 8 else { return nil }

        guard Self.crcIsValid(frame, size: size) else {
            // Damaged by reception errors: play silence rather than noise, and restart the overlap.
            for ch in 0..<6 { for i in 0..<256 { delay[ch][i] = 0 } }
            return [Float](repeating: 0, count: Self.samplesPerFrame * 2)
        }

        for i in 0..<size { padded[i] = frame[i] }
        for i in size..<(size + 8) { padded[i] = 0 }

        return padded.withUnsafeBufferPointer { buffer -> [Float]? in
            var br = BitReader(data: buffer.baseAddress!, byteCount: size, bitPos: 40)
            fscod = fs
            guard parseBSI(&br) else { return nil }
            let newFormat = Format(sampleRate: Self.sampleRates[fs], acmod: acmod, lfe: lfeon,
                                   bitrate: Self.bitrates[sizeCode >> 1] * 1000)
            if format != newFormat {
                if format != nil { for ch in 0..<6 { for i in 0..<256 { delay[ch][i] = 0 } } }
                format = newFormat
            }
            for i in 0..<7 { dbaActive[i] = false; dbaSegments[i].removeAll(keepingCapacity: true) }
            var out = [Float](repeating: 0, count: Self.samplesPerFrame * 2)
            for blk in 0..<6 {
                guard decodeBlock(&br, blk), !br.overrun else {
                    for ch in 0..<6 { for i in 0..<256 { delay[ch][i] = 0 } }
                    return [Float](repeating: 0, count: Self.samplesPerFrame * 2)
                }
                currentBlock = blk
                synthesize()
                downmix(into: &out, offset: blk * 256)
            }
            return out
        }
    }

    private func parseBSI(_ br: inout BitReader) -> Bool {
        let bsid = br.read(5)
        guard bsid <= 8 else { return false }
        br.skip(3)                                  // bsmod
        acmod = br.read(3)
        nfchans = Self.fullBandwidthChannels[acmod]
        cmixlev = 0; surmixlev = 0
        if acmod & 1 != 0 && acmod != 1 { cmixlev = br.read(2) }
        if acmod & 4 != 0 { surmixlev = br.read(2) }
        if acmod == 2 { br.skip(2) }                // dsurmod
        lfeon = br.readBit() == 1
        br.skip(5)                                  // dialnorm
        if br.readBit() == 1 { br.skip(8) }         // compr
        if br.readBit() == 1 { br.skip(8) }         // langcod
        if br.readBit() == 1 { br.skip(7) }         // mixlevel, roomtyp
        if acmod == 0 {
            br.skip(5)
            if br.readBit() == 1 { br.skip(8) }
            if br.readBit() == 1 { br.skip(8) }
            if br.readBit() == 1 { br.skip(7) }
        }
        br.skip(2)                                  // copyrightb, origbs
        if br.readBit() == 1 { br.skip(14) }        // timecod1 / xbsi1
        if br.readBit() == 1 { br.skip(14) }        // timecod2 / xbsi2
        if br.readBit() == 1 { br.skip((br.read(6) + 1) * 8) } // addbsi
        return !br.overrun
    }

    // MARK: Audio block

    private func dynamicGain(_ code: Int) -> Float {
        guard dynamicRange > 0 else { return 1 }
        let x = (code >> 5) >= 4 ? (code >> 5) - 8 : (code >> 5)
        let gain = Float(pow(2.0, Double(x))) * Float(32 + (code & 0x1F)) / 32
        return dynamicRange == 1 ? gain : pow(gain, dynamicRange)
    }

    private func decodeBlock(_ br: inout BitReader, _ blk: Int) -> Bool {
        for ch in 0..<nfchans { blksw[ch] = br.readBit() == 1 }
        for ch in 0..<nfchans { dithflag[ch] = br.readBit() == 1 }
        if br.readBit() == 1 { dynrng[0] = dynamicGain(br.read(8)) } else if blk == 0 { dynrng[0] = 1 }
        if acmod == 0 {
            if br.readBit() == 1 { dynrng[1] = dynamicGain(br.read(8)) } else if blk == 0 { dynrng[1] = 1 }
        } else {
            dynrng[1] = dynrng[0]
        }

        // Coupling strategy.
        if br.readBit() == 1 {
            cplinu = br.readBit() == 1
            if cplinu {
                for ch in 0..<nfchans { chincpl[ch] = br.readBit() == 1 }
                phsflginu = acmod == 2 ? br.readBit() == 1 : false
                cplbegf = br.read(4)
                cplendf = br.read(4)
                ncplsubnd = 3 + cplendf - cplbegf
                guard ncplsubnd >= 1 else { return false }
                cplbndstrc[0] = false
                for sb in 1..<max(1, ncplsubnd) { cplbndstrc[sb] = br.readBit() == 1 }
                cplstrtmant = cplbegf * 12 + 37
                cplendmant = (cplendf + 3) * 12 + 37
                if !phsflginu { for i in 0..<18 { phsflg[i] = false } }
            } else {
                for ch in 0..<5 { chincpl[ch] = false }
            }
        } else if blk == 0 {
            return false
        }

        // Coupling coordinates and phase flags.
        if cplinu {
            var coordsSent = [Bool](repeating: false, count: 5)
            let bands = (0..<ncplsubnd).filter { !cplbndstrc[$0] }.count
            for ch in 0..<nfchans where chincpl[ch] {
                guard br.readBit() == 1 else { continue }
                coordsSent[ch] = true
                let master = br.read(2) * 3
                var bandValues = [Float](repeating: 0, count: bands)
                for b in 0..<bands {
                    let e = br.read(4), m = br.read(4)
                    let mantissa: Float = e == 15 ? Float(m) / 16 : Float(m + 16) / 32
                    bandValues[b] = mantissa * Self.pow2Neg[e + master]
                }
                var b = -1
                for sb in 0..<ncplsubnd {
                    if !cplbndstrc[sb] { b += 1 }
                    cplco[ch][sb] = bandValues[b]
                }
            }
            if acmod == 2 && phsflginu && (coordsSent[0] || coordsSent[1]) {
                var flags = [Bool](repeating: false, count: bands)
                for b in 0..<bands { flags[b] = br.readBit() == 1 }
                var b = -1
                for sb in 0..<ncplsubnd {
                    if !cplbndstrc[sb] { b += 1 }
                    phsflg[sb] = flags[b]
                }
            }
        }

        // Rematrixing.
        if acmod == 2 {
            if br.readBit() == 1 {
                nrematbd = (!cplinu || cplbegf > 2) ? 4 : (cplbegf > 0 ? 3 : 2)
                for r in 0..<4 { rematflg[r] = r < nrematbd ? br.readBit() == 1 : false }
            } else if blk == 0 {
                nrematbd = 0
            }
        }

        // Exponent strategies.
        if cplinu { expstr[Self.cplIndex] = br.read(2) }
        for ch in 0..<nfchans { expstr[ch] = br.read(2) }
        if lfeon { expstr[Self.lfeIndex] = br.readBit() }
        if blk == 0 {
            for ch in 0..<nfchans where expstr[ch] == 0 { return false }
            if cplinu && expstr[Self.cplIndex] == 0 { return false }
            if lfeon && expstr[Self.lfeIndex] == 0 { return false }
        }
        for ch in 0..<nfchans where expstr[ch] != 0 && !chincpl[ch] {
            chbwcod[ch] = br.read(6)
            guard chbwcod[ch] <= 60 else { return false }
        }

        // Exponents.
        if cplinu && expstr[Self.cplIndex] != 0 {
            let group = [0, 1, 2, 4][expstr[Self.cplIndex]]
            let groups = (cplendmant - cplstrtmant) / (3 * group)
            let absolute = br.read(4) << 1
            guard decodeExponents(&br, channel: Self.cplIndex, groups: groups, groupSize: group,
                                  absolute: absolute, firstBin: cplstrtmant) else { return false }
            endmant[Self.cplIndex] = cplendmant
        }
        for ch in 0..<nfchans where expstr[ch] != 0 {
            endmant[ch] = chincpl[ch] ? cplstrtmant : (chbwcod[ch] + 12) * 3 + 37
            let group = [0, 1, 2, 4][expstr[ch]]
            let groups: Int
            switch expstr[ch] {
            case 1: groups = (endmant[ch] - 1) / 3
            case 2: groups = (endmant[ch] - 1 + 3) / 6
            default: groups = (endmant[ch] - 1 + 9) / 12
            }
            let absolute = br.read(4)
            exps[ch][0] = absolute
            guard decodeExponents(&br, channel: ch, groups: groups, groupSize: group, absolute: absolute, firstBin: 1) else { return false }
            br.skip(2)                              // gainrng
        }
        if lfeon && expstr[Self.lfeIndex] != 0 {
            endmant[Self.lfeIndex] = 7
            let absolute = br.read(4)
            exps[Self.lfeIndex][0] = absolute
            guard decodeExponents(&br, channel: Self.lfeIndex, groups: 2, groupSize: 1, absolute: absolute, firstBin: 1) else { return false }
        }
        // A coupled channel's bandwidth follows the coupling start even when its exponents are reused.
        for ch in 0..<nfchans where chincpl[ch] { endmant[ch] = cplstrtmant }

        // Bit allocation parameters.
        if br.readBit() == 1 {
            sdcycod = br.read(2); fdcycod = br.read(2); sgaincod = br.read(2); dbpbcod = br.read(2); floorcod = br.read(3)
        } else if blk == 0 {
            return false
        }
        if br.readBit() == 1 {
            csnroffst = br.read(6)
            if cplinu { fsnroffst[Self.cplIndex] = br.read(4); fgaincod[Self.cplIndex] = br.read(3) }
            for ch in 0..<nfchans { fsnroffst[ch] = br.read(4); fgaincod[ch] = br.read(3) }
            if lfeon { fsnroffst[Self.lfeIndex] = br.read(4); fgaincod[Self.lfeIndex] = br.read(3) }
        } else if blk == 0 {
            return false
        }
        if cplinu && br.readBit() == 1 {
            cplfleak = br.read(3); cplsleak = br.read(3)
        }

        // Delta bit allocation.
        if br.readBit() == 1 {
            var modes = [Int](repeating: 2, count: 7)
            if cplinu { modes[Self.cplIndex] = br.read(2) }
            for ch in 0..<nfchans { modes[ch] = br.read(2) }
            var order: [Int] = cplinu ? [Self.cplIndex] : []
            order += Array(0..<nfchans)
            for ch in order {
                switch modes[ch] {
                case 0: break                        // reuse
                case 1:
                    dbaSegments[ch].removeAll(keepingCapacity: true)
                    let count = br.read(3) + 1
                    for _ in 0..<count { dbaSegments[ch].append((br.read(5), br.read(4), br.read(3))) }
                    dbaActive[ch] = true
                case 2: dbaActive[ch] = false
                default: return false
                }
            }
        }

        // Skip field.
        if br.readBit() == 1 { br.skip(br.read(9) * 8) }

        computeBitAllocation()
        return readMantissas(&br)
    }

    private func decodeExponents(_ br: inout BitReader, channel: Int, groups: Int, groupSize: Int, absolute: Int, firstBin: Int) -> Bool {
        var previous = absolute
        var bin = firstBin
        for _ in 0..<groups {
            let code = br.read(7)
            guard code < 125 else { return false }
            for d in [code / 25, (code % 25) / 5, code % 5] {
                previous += d - 2
                guard previous >= 0 && previous <= 24 else { return false }
                for _ in 0..<groupSize where bin < 256 {
                    exps[channel][bin] = previous
                    bin += 1
                }
            }
        }
        return true
    }

    // MARK: Bit allocation (A/52 7.2)

    private func computeBitAllocation() {
        var channels = Array(0..<nfchans)
        if cplinu { channels.append(Self.cplIndex) }
        if lfeon { channels.append(Self.lfeIndex) }

        var allZero = csnroffst == 0
        if allZero { for ch in channels where fsnroffst[ch] != 0 { allZero = false } }

        for ch in channels {
            let isCpl = ch == Self.cplIndex
            let start = isCpl ? cplstrtmant : 0
            let end = endmant[ch]
            if allZero || end <= start {
                for i in 0..<256 { bap[ch][i] = 0 }
                continue
            }
            allocate(channel: ch, start: start, end: end, isCoupling: isCpl)
        }
    }

    private func allocate(channel ch: Int, start: Int, end: Int, isCoupling: Bool) {
        let sdecay = Self.slowDecay[sdcycod], fdecay = Self.fastDecay[fdcycod]
        let sgain = Self.slowGain[sgaincod], dbknee = Self.dbPerBit[dbpbcod], floor = Self.floorTable[floorcod]
        let fgain = Self.fastGain[fgaincod[ch]]
        let snroffset = (((csnroffst - 15) << 4) + fsnroffst[ch]) << 2

        for bin in start..<end { psd[bin] = 3072 - (exps[ch][bin] << 7) }

        // PSD integration.
        var j = start
        var k = Self.maskTable[start]
        var lastbin = 0
        repeat {
            lastbin = min(Self.bandStart[k] + Self.bandSize[k], end)
            bandPSD[k] = psd[j]
            j += 1
            while j < lastbin {
                bandPSD[k] = Self.logAddition(bandPSD[k], psd[j])
                j += 1
            }
            k += 1
        } while end > lastbin

        // Excitation.
        let bndstrt = Self.maskTable[start]
        let bndend = Self.maskTable[end - 1] + 1
        var begin: Int
        var fastleak = 0, slowleak = 0
        if bndstrt == 0 {
            var lowcomp = 0
            lowcomp = Self.lowComp(lowcomp, bandPSD[0], bandPSD[1], 0)
            excite[0] = bandPSD[0] - fgain - lowcomp
            lowcomp = Self.lowComp(lowcomp, bandPSD[1], bandPSD[2], 1)
            excite[1] = bandPSD[1] - fgain - lowcomp
            begin = 7
            for bin in 2..<7 {
                if bndend != 7 || bin != 6 {
                    lowcomp = Self.lowComp(lowcomp, bandPSD[bin], bandPSD[bin + 1], bin)
                }
                fastleak = bandPSD[bin] - fgain
                slowleak = bandPSD[bin] - sgain
                excite[bin] = fastleak - lowcomp
                if bndend != 7 || bin != 6 {
                    if bandPSD[bin] <= bandPSD[bin + 1] { begin = bin + 1; break }
                }
            }
            var bin = begin
            while bin < min(bndend, 22) {
                if bndend != 7 || bin != 6 {
                    lowcomp = Self.lowComp(lowcomp, bandPSD[bin], bandPSD[bin + 1], bin)
                }
                fastleak -= fdecay
                fastleak = max(fastleak, bandPSD[bin] - fgain)
                slowleak -= sdecay
                slowleak = max(slowleak, bandPSD[bin] - sgain)
                excite[bin] = max(fastleak - lowcomp, slowleak)
                bin += 1
            }
            begin = 22
        } else {
            begin = bndstrt
            fastleak = (cplfleak << 8) + 768
            slowleak = (cplsleak << 8) + 768
        }
        var bin = begin
        while bin < bndend {
            fastleak -= fdecay
            fastleak = max(fastleak, bandPSD[bin] - fgain)
            slowleak -= sdecay
            slowleak = max(slowleak, bandPSD[bin] - sgain)
            excite[bin] = max(fastleak, slowleak)
            bin += 1
        }

        // Masking curve.
        let hth = Self.hearingThreshold[fscod]
        for b in bndstrt..<bndend {
            if bandPSD[b] < dbknee { excite[b] += (dbknee - bandPSD[b]) >> 2 }
            mask[b] = max(excite[b], hth[b])
        }

        // Delta bit allocation.
        if dbaActive[ch] {
            var band = 0
            for seg in dbaSegments[ch] {
                band += seg.offset
                let delta = seg.ba >= 4 ? (seg.ba - 3) << 7 : (seg.ba - 4) << 7
                for _ in 0..<seg.length where band < 50 {
                    mask[band] += delta
                    band += 1
                }
            }
        }

        // Bit allocation pointers.
        var i = start
        j = Self.maskTable[start]
        repeat {
            lastbin = min(Self.bandStart[j] + Self.bandSize[j], end)
            var m = mask[j] - snroffset - floor
            if m < 0 { m = 0 }
            m &= 0x1fe0
            m += floor
            while i < lastbin {
                let address = min(63, max(0, (psd[i] - m) >> 5))
                bap[ch][i] = Self.bapTable[address]
                i += 1
            }
            j += 1
        } while end > lastbin
        for b in end..<256 { bap[ch][b] = 0 }
    }

    private static func logAddition(_ a: Int, _ b: Int) -> Int {
        let c = a - b
        let address = min(abs(c) >> 1, 255)
        return c >= 0 ? a + logAdd[address] : b + logAdd[address]
    }

    private static func lowComp(_ a: Int, _ b0: Int, _ b1: Int, _ bin: Int) -> Int {
        if bin < 7 {
            if b0 + 256 == b1 { return 384 }
            if b0 > b1 { return max(0, a - 64) }
            return a
        } else if bin < 20 {
            if b0 + 256 == b1 { return 320 }
            if b0 > b1 { return max(0, a - 64) }
            return a
        }
        return max(0, a - 128)
    }

    // MARK: Mantissas (A/52 7.3)

    private func dither() -> Float {
        ditherState = ditherState &* 1_664_525 &+ 1_013_904_223
        return (Float(ditherState >> 8) / Float(1 << 24) * 2 - 1) * 0.707
    }

    private func readMantissa(_ br: inout BitReader, bap b: Int) -> Float {
        switch b {
        case 1:
            if group1.isEmpty {
                let code = min(br.read(5), 26)
                group1 = [Self.q3[code % 3], Self.q3[(code % 9) / 3], Self.q3[code / 9]]
            }
            return group1.removeLast()
        case 2:
            if group2.isEmpty {
                let code = min(br.read(7), 124)
                group2 = [Self.q5[code % 5], Self.q5[(code % 25) / 5], Self.q5[code / 25]]
            }
            return group2.removeLast()
        case 3:
            return Self.q7[min(br.read(3), 6)]
        case 4:
            if group4.isEmpty {
                let code = min(br.read(7), 120)
                group4 = [Self.q11[code % 11], Self.q11[code / 11]]
            }
            return group4.removeLast()
        case 5:
            return Self.q15[min(br.read(4), 14)]
        default:
            let bits = Self.asymmetricBits[b]
            return Float(br.readSigned(bits)) / Float(1 << (bits - 1))
        }
    }

    private func readMantissas(_ br: inout BitReader) -> Bool {
        group1.removeAll(keepingCapacity: true)
        group2.removeAll(keepingCapacity: true)
        group4.removeAll(keepingCapacity: true)
        var gotCoupling = false
        for ch in 0..<nfchans {
            for bin in 0..<endmant[ch] {
                let b = bap[ch][bin]
                let m: Float = b == 0 ? (dithflag[ch] ? dither() : 0) : readMantissa(&br, bap: b)
                coefficients[ch][bin] = m * Self.pow2Neg[exps[ch][bin]]
            }
            for bin in endmant[ch]..<256 { coefficients[ch][bin] = 0 }
            if cplinu && chincpl[ch] && !gotCoupling {
                gotCoupling = true
                let c = Self.cplIndex
                for bin in cplstrtmant..<cplendmant {
                    let b = bap[c][bin]
                    cplZero[bin] = b == 0
                    coefficients[c][bin] = b == 0 ? 0 : readMantissa(&br, bap: b) * Self.pow2Neg[exps[c][bin]]
                }
            }
        }
        if lfeon {
            let l = Self.lfeIndex
            for bin in 0..<7 {
                let b = bap[l][bin]
                coefficients[l][bin] = b == 0 ? 0 : readMantissa(&br, bap: b) * Self.pow2Neg[exps[l][bin]]
            }
            for bin in 7..<256 { coefficients[l][bin] = 0 }
        }
        guard !br.overrun else { return false }

        // Uncouple.
        if cplinu {
            let c = Self.cplIndex
            for ch in 0..<nfchans where chincpl[ch] {
                for sb in 0..<ncplsubnd {
                    let co = cplco[ch][sb] * 8
                    let negate = acmod == 2 && ch == 1 && phsflg[sb]
                    let first = cplstrtmant + sb * 12
                    for bin in first..<(first + 12) {
                        var v: Float
                        if cplZero[bin] {
                            v = dithflag[ch] ? dither() * Self.pow2Neg[exps[c][bin]] : 0
                        } else {
                            v = coefficients[c][bin]
                        }
                        v *= co
                        coefficients[ch][bin] = negate ? -v : v
                    }
                }
                for bin in cplendmant..<256 { coefficients[ch][bin] = 0 }
            }
        }

        // Rematrix.
        if acmod == 2 && nrematbd > 0 {
            let end = min(endmant[0], endmant[1])
            for r in 0..<nrematbd where rematflg[r] {
                let lo = Self.rematrixBands[r]
                let hi = min(Self.rematrixBands[r + 1], end)
                guard lo < hi else { continue }
                for bin in lo..<hi {
                    let l = coefficients[0][bin], rr = coefficients[1][bin]
                    coefficients[0][bin] = l + rr
                    coefficients[1][bin] = l - rr
                }
            }
        }

        // Dynamic range control.
        for ch in 0..<nfchans {
            let g = acmod == 0 ? dynrng[min(ch, 1)] : dynrng[0]
            if g != 1 { for bin in 0..<256 { coefficients[ch][bin] *= g } }
        }
        if lfeon, dynrng[0] != 1 { for bin in 0..<7 { coefficients[Self.lfeIndex][bin] *= dynrng[0] } }
        return true
    }

    // MARK: Transform (A/52 7.9)

    /// Inverse transforms every channel of the current block into `blockPCM`.
    private func synthesize() {
        let count = nfchans + (lfeon ? 1 : 0)
        for out in 0..<count {
            let ch = out < nfchans ? out : Self.lfeIndex
            let short = out < nfchans && blksw[out]
            if short { imdct256(ch) } else { imdct512(ch) }
            let x = transformScratch
            for n in 0..<256 {
                blockPCM[out][n] = 2 * (x[n] + delay[out][n])
                delay[out][n] = x[256 + n]
            }
            if keepsChannels {
                for n in 0..<256 { channelPCM[out][currentBlock * 256 + n] = blockPCM[out][n] }
            }
        }
    }

    private func imdct512(_ ch: Int) {
        let X = coefficients[ch]
        let c1 = Self.cos1, s1 = Self.sin1, w = Self.window
        for k in 0..<128 {
            let a = X[255 - 2 * k], b = X[2 * k]
            re[k] = a * c1[k] - b * s1[k]
            im[k] = b * c1[k] + a * s1[k]
        }
        Self.fft128.inverse(&re, &im)
        for n in 0..<128 {
            let zr = re[n], zi = im[n]
            re[n] = zr * c1[n] - zi * s1[n]
            im[n] = zi * c1[n] + zr * s1[n]
        }
        for n in 0..<64 {
            transformScratch[2 * n] = -im[64 + n] * w[2 * n]
            transformScratch[2 * n + 1] = re[64 - n - 1] * w[2 * n + 1]
            transformScratch[128 + 2 * n] = -re[n] * w[128 + 2 * n]
            transformScratch[128 + 2 * n + 1] = im[128 - n - 1] * w[128 + 2 * n + 1]
            transformScratch[256 + 2 * n] = -re[64 + n] * w[256 - 2 * n - 1]
            transformScratch[256 + 2 * n + 1] = im[64 - n - 1] * w[256 - 2 * n - 2]
            transformScratch[384 + 2 * n] = im[n] * w[128 - 2 * n - 1]
            transformScratch[384 + 2 * n + 1] = -re[128 - n - 1] * w[128 - 2 * n - 2]
        }
    }

    private func imdct256(_ ch: Int) {
        let X = coefficients[ch]
        let c2 = Self.cos2, s2 = Self.sin2, w = Self.window
        // X1 = even coefficients, X2 = odd coefficients (128 each).
        for k in 0..<64 {
            let a1 = X[2 * (128 - 2 * k - 1)], b1 = X[2 * (2 * k)]
            re[k] = a1 * c2[k] - b1 * s2[k]
            im[k] = b1 * c2[k] + a1 * s2[k]
            let a2 = X[2 * (128 - 2 * k - 1) + 1], b2 = X[2 * (2 * k) + 1]
            re2[k] = a2 * c2[k] - b2 * s2[k]
            im2[k] = b2 * c2[k] + a2 * s2[k]
        }
        Self.fft64.inverse(&re, &im)
        Self.fft64.inverse(&re2, &im2)
        for n in 0..<64 {
            var zr = re[n], zi = im[n]
            re[n] = zr * c2[n] - zi * s2[n]
            im[n] = zi * c2[n] + zr * s2[n]
            zr = re2[n]; zi = im2[n]
            re2[n] = zr * c2[n] - zi * s2[n]
            im2[n] = zi * c2[n] + zr * s2[n]
        }
        for n in 0..<64 {
            transformScratch[2 * n] = -im[n] * w[2 * n]
            transformScratch[2 * n + 1] = re[64 - n - 1] * w[2 * n + 1]
            transformScratch[128 + 2 * n] = -re[n] * w[128 + 2 * n]
            transformScratch[128 + 2 * n + 1] = im[64 - n - 1] * w[128 + 2 * n + 1]
            transformScratch[256 + 2 * n] = -re2[n] * w[256 - 2 * n - 1]
            transformScratch[256 + 2 * n + 1] = im2[64 - n - 1] * w[256 - 2 * n - 2]
            transformScratch[384 + 2 * n] = im2[n] * w[128 - 2 * n - 1]
            transformScratch[384 + 2 * n + 1] = -re2[64 - n - 1] * w[128 - 2 * n - 2]
        }
    }

    // MARK: Downmix (A/52 7.8.2, Lo/Ro)

    /// Downmix coefficients for (left, right) per coded channel, normalised so a full-scale
    /// signal in every channel can't overflow.
    private func downmixCoefficients() -> [(Float, Float)] {
        let c = Self.centerMix[cmixlev], s = Self.surroundMix[surmixlev]
        var m: [(Float, Float)]
        switch acmod {
        case 0: m = [(1, 0), (0, 1)]                                // dual mono: Ch1 left, Ch2 right
        case 1: m = [(1, 1)]                                        // mono
        case 2: m = [(1, 0), (0, 1)]
        case 3: m = [(1, 0), (c, c), (0, 1)]
        case 4: m = [(1, 0), (0, 1), (s * 0.7071, s * 0.7071)]
        case 5: m = [(1, 0), (c, c), (0, 1), (s * 0.7071, s * 0.7071)]
        case 6: m = [(1, 0), (0, 1), (s, 0), (0, s)]
        default: m = [(1, 0), (c, c), (0, 1), (s, 0), (0, s)]
        }
        let sumL = m.reduce(0) { $0 + $1.0 }, sumR = m.reduce(0) { $0 + $1.1 }
        let norm = 1 / max(sumL, sumR, 1)
        return m.map { ($0.0 * norm, $0.1 * norm) }
    }

    private func downmix(into out: inout [Float], offset: Int) {
        let coefficients = downmixCoefficients()
        // Multichannel programmes are mixed for headroom; lift them back towards stereo
        // loudness and catch the rare peak with a soft limiter.
        let makeup: Float = acmod >= 3 ? 1.6 : 1
        for n in 0..<256 {
            var l: Float = 0, r: Float = 0
            for ch in 0..<nfchans {
                let v = blockPCM[ch][n]
                l += v * coefficients[ch].0
                r += v * coefficients[ch].1
            }
            out[(offset + n) * 2] = Self.softLimit(l * makeup)
            out[(offset + n) * 2 + 1] = Self.softLimit(r * makeup)
        }
    }

    @inline(__always) private static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.85 else { return x }
        let limited = 0.85 + 0.15 * Float(tanh(Double((a - 0.85) / 0.15)))
        return x < 0 ? -limited : limited
    }

    // MARK: CRC (A/52 7.10)

    private static let crcTable: [UInt16] = (0..<256).map { i in
        var crc = UInt16(i) << 8
        for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        return crc
    }

    static func crcIsValid(_ frame: UnsafeRawBufferPointer, size: Int) -> Bool {
        var crc: UInt16 = 0
        let words = size / 2
        let fiveEighths = ((words >> 1) + (words >> 3)) * 2
        for i in 2..<size {
            crc = (crc << 8) ^ crcTable[Int((crc >> 8) ^ UInt16(frame[i]))]
            if i == fiveEighths - 1 && crc != 0 { return false }
        }
        return crc == 0
    }
}

/// In-place radix-2 complex FFT with a positive exponent and no scaling (the A/52 "IFFT").
final class ComplexFFT: @unchecked Sendable {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init(size: Int) {
        self.size = size
        cosTable = (0..<(size / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<(size / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        let bits = Int(log2(Double(size)))
        reversed = (0..<size).map { i in
            var r = 0, v = i
            for _ in 0..<bits { r = (r << 1) | (v & 1); v >>= 1 }
            return r
        }
    }

    func inverse(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<size {
            let j = reversed[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var half = 1
        while half < size {
            let step = size / (half * 2)
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosTable[k * step], wi = sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += half * 2
            }
            half *= 2
        }
    }
}
