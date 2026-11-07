import Foundation

// Tables from ISO/IEC 13818-2 (MPEG-2 video), Annex B.

/// Big-endian bit reader over a buffer that is padded with at least 8 zero bytes.
struct BitReader {
    let data: UnsafePointer<UInt8>
    let byteCount: Int
    var bitPos: Int = 0

    init(data: UnsafePointer<UInt8>, byteCount: Int, bitPos: Int = 0) {
        self.data = data
        self.byteCount = byteCount
        self.bitPos = bitPos
    }

    @inline(__always) var bitsLeft: Int { byteCount &* 8 &- bitPos }
    @inline(__always) var overrun: Bool { bitPos > byteCount &* 8 }

    /// The next 32 bits, MSB first.
    @inline(__always) func peek32() -> UInt32 {
        let p = data + (bitPos >> 3)
        let v = (UInt64(p[0]) << 32) | (UInt64(p[1]) << 24) | (UInt64(p[2]) << 16) | (UInt64(p[3]) << 8) | UInt64(p[4])
        return UInt32(truncatingIfNeeded: v >> UInt64(8 &- (bitPos & 7)))
    }

    /// Peeks `n` bits (1...32).
    @inline(__always) func peek(_ n: Int) -> Int { Int(peek32() >> UInt32(32 &- n)) }
    @inline(__always) mutating func skip(_ n: Int) { bitPos &+= n }
    @inline(__always) mutating func read(_ n: Int) -> Int { let v = peek(n); bitPos &+= n; return v }
    @inline(__always) mutating func readBit() -> Int { let v = Int(peek32() >> 31); bitPos &+= 1; return v }
    @inline(__always) mutating func readSigned(_ n: Int) -> Int {
        let v = read(n)
        return v >= (1 << (n &- 1)) ? v &- (1 << n) : v
    }
}

/// A two-level variable-length-code lookup table.
final class VLCTable: @unchecked Sendable {
    static let invalid = Int.min

    let bits: Int
    let entries: UnsafeMutablePointer<Int32>

    /// `codes`: (code bits, code length, decoded value).
    init(_ codes: [(UInt32, Int, Int32)], primaryBits: Int) {
        bits = primaryBits
        var table = [Int32](repeating: 0, count: 1 << primaryBits)
        var groups: [Int: [(UInt32, Int, Int32)]] = [:]
        for (code, len, value) in codes {
            if len <= primaryBits {
                let shift = primaryBits - len
                let start = Int(code) << shift
                for i in 0..<(1 << shift) { table[start + i] = (value << 8) | Int32(len) }
            } else {
                let prefix = Int(code >> UInt32(len - primaryBits))
                groups[prefix, default: []].append((code, len, value))
            }
        }
        for (prefix, list) in groups.sorted(by: { $0.key < $1.key }) {
            let maxLen = list.map { $0.1 }.max() ?? primaryBits
            let subBits = maxLen - primaryBits
            let offset = table.count
            table.append(contentsOf: repeatElement(0, count: 1 << subBits))
            table[prefix] = (Int32(offset) << 8) | Int32(UInt8(bitPattern: Int8(-subBits)))
            for (code, len, value) in list {
                let rem = len - primaryBits
                let low = Int(code) & ((1 << rem) - 1)
                let shift = subBits - rem
                let start = offset + (low << shift)
                for i in 0..<(1 << shift) { table[start + i] = (value << 8) | Int32(rem) }
            }
        }
        entries = .allocate(capacity: table.count)
        entries.initialize(from: table, count: table.count)
    }

    /// Returns the decoded value or `VLCTable.invalid`.
    @inline(__always) func decode(_ br: inout BitReader) -> Int {
        var e = entries[br.peek(bits)]
        var len = Int(Int8(truncatingIfNeeded: e))
        if len < 0 {
            br.skip(bits)
            e = entries[Int(e >> 8) &+ br.peek(-len)]
            len = Int(Int8(truncatingIfNeeded: e))
        }
        if len == 0 { return VLCTable.invalid }
        br.skip(len)
        return Int(e >> 8)
    }
}

enum MBFlag {
    static let quant = 1
    static let forward = 2
    static let backward = 4
    static let pattern = 8
    static let intra = 16
}

enum MPEG2Tables {
    static let mbaEscape: Int32 = -1
    static let mbaStuffing: Int32 = -2
    static let dctEOB = -1
    static let dctEscape = -2

    /// Table B.1 — macroblock_address_increment.
    static let mba: VLCTable = {
        let codes: [(UInt32, Int)] = [
            (0x1, 1), (0x3, 3), (0x2, 3), (0x3, 4), (0x2, 4), (0x3, 5), (0x2, 5), (0x7, 7), (0x6, 7),
            (0xb, 8), (0xa, 8), (0x9, 8), (0x8, 8), (0x7, 8), (0x6, 8), (0x17, 10), (0x16, 10), (0x15, 10),
            (0x14, 10), (0x13, 10), (0x12, 10), (0x23, 11), (0x22, 11), (0x21, 11), (0x20, 11), (0x1f, 11),
            (0x1e, 11), (0x1d, 11), (0x1c, 11), (0x1b, 11), (0x1a, 11), (0x19, 11), (0x18, 11),
        ]
        var list = codes.enumerated().map { ($0.element.0, $0.element.1, Int32($0.offset + 1)) }
        list.append((0x8, 11, mbaEscape))
        list.append((0xf, 11, mbaStuffing))
        return VLCTable(list, primaryBits: 11)
    }()

    /// Tables B.2–B.4 — macroblock_type for I, P and B pictures.
    static let mbTypeI = VLCTable([(1, 1, Int32(MBFlag.intra)), (1, 2, Int32(MBFlag.quant | MBFlag.intra))], primaryBits: 2)

    static let mbTypeP = VLCTable([
        (3, 5, Int32(MBFlag.intra)),
        (1, 2, Int32(MBFlag.pattern)),
        (1, 3, Int32(MBFlag.forward)),
        (1, 1, Int32(MBFlag.forward | MBFlag.pattern)),
        (1, 6, Int32(MBFlag.quant | MBFlag.intra)),
        (1, 5, Int32(MBFlag.quant | MBFlag.pattern)),
        (2, 5, Int32(MBFlag.quant | MBFlag.forward | MBFlag.pattern)),
    ], primaryBits: 6)

    static let mbTypeB = VLCTable([
        (3, 5, Int32(MBFlag.intra)),
        (2, 3, Int32(MBFlag.backward)),
        (3, 3, Int32(MBFlag.backward | MBFlag.pattern)),
        (2, 4, Int32(MBFlag.forward)),
        (3, 4, Int32(MBFlag.forward | MBFlag.pattern)),
        (2, 2, Int32(MBFlag.forward | MBFlag.backward)),
        (3, 2, Int32(MBFlag.forward | MBFlag.backward | MBFlag.pattern)),
        (1, 6, Int32(MBFlag.quant | MBFlag.intra)),
        (2, 6, Int32(MBFlag.quant | MBFlag.backward | MBFlag.pattern)),
        (3, 6, Int32(MBFlag.quant | MBFlag.forward | MBFlag.pattern)),
        (2, 5, Int32(MBFlag.quant | MBFlag.forward | MBFlag.backward | MBFlag.pattern)),
    ], primaryBits: 6)

    /// Table B.9 — coded_block_pattern (index = pattern value).
    static let cbp: VLCTable = {
        let codes: [(UInt32, Int)] = [
            (0x1, 9), (0xb, 5), (0x9, 5), (0xd, 6), (0xd, 4), (0x17, 7), (0x13, 7), (0x1f, 8),
            (0xc, 4), (0x16, 7), (0x12, 7), (0x1e, 8), (0x13, 5), (0x1b, 8), (0x17, 8), (0x13, 8),
            (0xb, 4), (0x15, 7), (0x11, 7), (0x1d, 8), (0x11, 5), (0x19, 8), (0x15, 8), (0x11, 8),
            (0xf, 6), (0xf, 8), (0xd, 8), (0x3, 9), (0xf, 5), (0xb, 8), (0x7, 8), (0x7, 9),
            (0xa, 4), (0x14, 7), (0x10, 7), (0x1c, 8), (0xe, 6), (0xe, 8), (0xc, 8), (0x2, 9),
            (0x10, 5), (0x18, 8), (0x14, 8), (0x10, 8), (0xe, 5), (0xa, 8), (0x6, 8), (0x6, 9),
            (0x12, 5), (0x1a, 8), (0x16, 8), (0x12, 8), (0xd, 5), (0x9, 8), (0x5, 8), (0x5, 9),
            (0xc, 5), (0x8, 8), (0x4, 8), (0x4, 9), (0x7, 3), (0xa, 5), (0x8, 5), (0xc, 6),
        ]
        return VLCTable(codes.enumerated().map { ($0.element.0, $0.element.1, Int32($0.offset)) }, primaryBits: 9)
    }()

    /// Table B.10 — motion_code magnitude (sign bit follows for non-zero codes).
    static let motion: VLCTable = {
        let codes: [(UInt32, Int)] = [
            (0x1, 1), (0x1, 2), (0x1, 3), (0x1, 4), (0x3, 6), (0x5, 7), (0x4, 7), (0x3, 7), (0xb, 9),
            (0xa, 9), (0x9, 9), (0x11, 10), (0x10, 10), (0xf, 10), (0xe, 10), (0xd, 10), (0xc, 10),
        ]
        return VLCTable(codes.enumerated().map { ($0.element.0, $0.element.1, Int32($0.offset)) }, primaryBits: 10)
    }()

    /// Table B.11 — dmvector.
    static let dmv = VLCTable([(0, 1, 0), (2, 2, 1), (3, 2, -1)], primaryBits: 2)

    /// Tables B.12 / B.13 — dct_dc_size.
    static let dcLuma: VLCTable = {
        let code: [UInt32] = [0x4, 0x0, 0x1, 0x5, 0x6, 0xe, 0x1e, 0x3e, 0x7e, 0xfe, 0x1fe, 0x1ff]
        let bits = [3, 2, 2, 3, 3, 4, 5, 6, 7, 8, 9, 9]
        return VLCTable((0..<12).map { (code[$0], bits[$0], Int32($0)) }, primaryBits: 9)
    }()

    static let dcChroma: VLCTable = {
        let code: [UInt32] = [0x0, 0x1, 0x2, 0x6, 0xe, 0x1e, 0x3e, 0x7e, 0xfe, 0x1fe, 0x3fe, 0x3ff]
        let bits = [2, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10]
        return VLCTable((0..<12).map { (code[$0], bits[$0], Int32($0)) }, primaryBits: 10)
    }()

    private static let rlLevel: [Int32] = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
        25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 1, 2, 3, 4, 1, 2, 3, 1, 2,
        3, 1, 2, 3, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    ]
    private static let rlRun: [Int32] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5,
        5, 6, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    ]

    private static func dctTable(_ codes: [(UInt32, Int)]) -> VLCTable {
        var list: [(UInt32, Int, Int32)] = []
        for i in 0..<111 { list.append((codes[i].0, codes[i].1, (rlRun[i] << 8) | rlLevel[i])) }
        list.append((codes[111].0, codes[111].1, Int32(dctEscape)))
        list.append((codes[112].0, codes[112].1, Int32(dctEOB)))
        return VLCTable(list, primaryBits: 10)
    }

    /// Table B.14 — DCT coefficients, table zero. Values are (run << 8) | level.
    static let dct0: VLCTable = dctTable([
        (0x3, 2), (0x4, 4), (0x5, 5), (0x6, 7), (0x26, 8), (0x21, 8), (0xa, 10), (0x1d, 12),
        (0x18, 12), (0x13, 12), (0x10, 12), (0x1a, 13), (0x19, 13), (0x18, 13), (0x17, 13), (0x1f, 14),
        (0x1e, 14), (0x1d, 14), (0x1c, 14), (0x1b, 14), (0x1a, 14), (0x19, 14), (0x18, 14), (0x17, 14),
        (0x16, 14), (0x15, 14), (0x14, 14), (0x13, 14), (0x12, 14), (0x11, 14), (0x10, 14), (0x18, 15),
        (0x17, 15), (0x16, 15), (0x15, 15), (0x14, 15), (0x13, 15), (0x12, 15), (0x11, 15), (0x10, 15),
        (0x3, 3), (0x6, 6), (0x25, 8), (0xc, 10), (0x1b, 12), (0x16, 13), (0x15, 13), (0x1f, 15),
        (0x1e, 15), (0x1d, 15), (0x1c, 15), (0x1b, 15), (0x1a, 15), (0x19, 15), (0x13, 16), (0x12, 16),
        (0x11, 16), (0x10, 16), (0x5, 4), (0x4, 7), (0xb, 10), (0x14, 12), (0x14, 13), (0x7, 5),
        (0x24, 8), (0x1c, 12), (0x13, 13), (0x6, 5), (0xf, 10), (0x12, 12), (0x7, 6), (0x9, 10),
        (0x12, 13), (0x5, 6), (0x1e, 12), (0x14, 16), (0x4, 6), (0x15, 12), (0x7, 7), (0x11, 12),
        (0x5, 7), (0x11, 13), (0x27, 8), (0x10, 13), (0x23, 8), (0x1a, 16), (0x22, 8), (0x19, 16),
        (0x20, 8), (0x18, 16), (0xe, 10), (0x17, 16), (0xd, 10), (0x16, 16), (0x8, 10), (0x15, 16),
        (0x1f, 12), (0x1a, 12), (0x19, 12), (0x17, 12), (0x16, 12), (0x1f, 13), (0x1e, 13), (0x1d, 13),
        (0x1c, 13), (0x1b, 13), (0x1f, 16), (0x1e, 16), (0x1d, 16), (0x1c, 16), (0x1b, 16),
        (0x1, 6), (0x2, 2),
    ])

    /// Table B.15 — DCT coefficients, table one (intra blocks when intra_vlc_format = 1).
    static let dct1: VLCTable = dctTable([
        (0x02, 2), (0x06, 3), (0x07, 4), (0x1c, 5), (0x1d, 5), (0x05, 6), (0x04, 6), (0x7b, 7),
        (0x7c, 7), (0x23, 8), (0x22, 8), (0xfa, 8), (0xfb, 8), (0xfe, 8), (0xff, 8), (0x1f, 14),
        (0x1e, 14), (0x1d, 14), (0x1c, 14), (0x1b, 14), (0x1a, 14), (0x19, 14), (0x18, 14), (0x17, 14),
        (0x16, 14), (0x15, 14), (0x14, 14), (0x13, 14), (0x12, 14), (0x11, 14), (0x10, 14), (0x18, 15),
        (0x17, 15), (0x16, 15), (0x15, 15), (0x14, 15), (0x13, 15), (0x12, 15), (0x11, 15), (0x10, 15),
        (0x02, 3), (0x06, 5), (0x79, 7), (0x27, 8), (0x20, 8), (0x16, 13), (0x15, 13), (0x1f, 15),
        (0x1e, 15), (0x1d, 15), (0x1c, 15), (0x1b, 15), (0x1a, 15), (0x19, 15), (0x13, 16), (0x12, 16),
        (0x11, 16), (0x10, 16), (0x05, 5), (0x07, 7), (0xfc, 8), (0x0c, 10), (0x14, 13), (0x07, 5),
        (0x26, 8), (0x1c, 12), (0x13, 13), (0x06, 6), (0xfd, 8), (0x12, 12), (0x07, 6), (0x04, 9),
        (0x12, 13), (0x06, 7), (0x1e, 12), (0x14, 16), (0x04, 7), (0x15, 12), (0x05, 7), (0x11, 12),
        (0x78, 7), (0x11, 13), (0x7a, 7), (0x10, 13), (0x21, 8), (0x1a, 16), (0x25, 8), (0x19, 16),
        (0x24, 8), (0x18, 16), (0x05, 9), (0x17, 16), (0x07, 9), (0x16, 16), (0x0d, 10), (0x15, 16),
        (0x1f, 12), (0x1a, 12), (0x19, 12), (0x17, 12), (0x16, 12), (0x1f, 13), (0x1e, 13), (0x1d, 13),
        (0x1c, 13), (0x1b, 13), (0x1f, 16), (0x1e, 16), (0x1d, 16), (0x1c, 16), (0x1b, 16),
        (0x01, 6), (0x06, 4),
    ])

    static let zigzag: [UInt8] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    static let alternateScan: [UInt8] = [
        0, 8, 16, 24, 1, 9, 2, 10, 17, 25, 32, 40, 48, 56, 57, 49,
        41, 33, 26, 18, 3, 11, 4, 12, 19, 27, 34, 42, 50, 58, 35, 43,
        51, 59, 20, 28, 5, 13, 6, 14, 21, 29, 36, 44, 52, 60, 37, 45,
        53, 61, 22, 30, 7, 15, 23, 31, 38, 46, 54, 62, 39, 47, 55, 63,
    ]

    /// Default intra quantiser matrix in raster order.
    static let defaultIntraMatrix: [UInt8] = [
        8, 16, 19, 22, 26, 27, 29, 34,
        16, 16, 22, 24, 27, 29, 34, 37,
        19, 22, 26, 27, 29, 34, 34, 38,
        22, 22, 26, 27, 29, 34, 37, 40,
        22, 26, 27, 29, 32, 35, 40, 48,
        26, 27, 29, 32, 35, 40, 48, 58,
        26, 27, 29, 34, 38, 46, 56, 69,
        27, 29, 35, 38, 46, 56, 69, 83,
    ]

    static let nonLinearQScale: [Int32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22,
        24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 104, 112,
    ]

    /// frame_rate_code → frames per second.
    static let frameRates: [Double] = [0, 24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]
}
