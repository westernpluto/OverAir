// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol.
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

/// Multi-level Huffman lookup table. Symbols are code indices, as in the codebooks of
/// ETSI TS 103 190 (and FFmpeg's `VLC_INIT_STATIC` with no symbol table).
final class AC4VLC: @unchecked Sendable {
    private var lengths: [Int32] = []   // > 0: leaf, bits used at this level; < 0: subtable width; 0: invalid
    private var values: [Int32] = []    // leaf: symbol; subtable: offset
    private let rootBits: Int

    init(bits: [Int], codes: [Int], rootBits: Int = 9) {
        self.rootBits = rootBits
        let entries = zip(bits, codes).enumerated().compactMap { i, e -> (code: UInt64, len: Int, sym: Int)? in
            e.0 > 0 ? (UInt64(e.1), e.0, i) : nil
        }
        _ = build(entries, width: rootBits, consumed: 0)
    }

    private func build(_ entries: [(code: UInt64, len: Int, sym: Int)], width: Int, consumed: Int) -> Int {
        let start = lengths.count
        lengths.append(contentsOf: repeatElement(0, count: 1 << width))
        values.append(contentsOf: repeatElement(0, count: 1 << width))
        var groups: [Int: [(code: UInt64, len: Int, sym: Int)]] = [:]
        for e in entries {
            let remaining = e.len - consumed
            if remaining <= width {
                let bitsHere = Int((e.code >> 0) & ((1 << UInt64(remaining)) - 1))
                let first = bitsHere << (width - remaining)
                for k in 0..<(1 << (width - remaining)) {
                    lengths[start + first + k] = Int32(remaining)
                    values[start + first + k] = Int32(e.sym)
                }
            } else {
                let key = Int((e.code >> UInt64(remaining - width)) & ((1 << UInt64(width)) - 1))
                groups[key, default: []].append(e)
            }
        }
        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            let maxRemaining = group.map { $0.len - consumed - width }.max() ?? 1
            let subWidth = min(maxRemaining, rootBits)
            let offset = build(group, width: subWidth, consumed: consumed + width)
            lengths[start + key] = Int32(-subWidth)
            values[start + key] = Int32(offset)
        }
        return start
    }

    /// The next symbol, or -1 for an invalid code.
    @inline(__always) func decode(_ br: inout BitReader) -> Int {
        var width = rootBits
        var index = br.peek(width)
        while true {
            let l = Int(lengths[index])
            if l > 0 {
                br.skip(l)
                return Int(values[index])
            }
            if l == 0 { return -1 }
            br.skip(width)
            let offset = Int(values[index])
            width = -l
            index = offset + br.peek(width)
        }
    }
}

extension BitReader {
    /// AC-4 `variable_bits()`.
    mutating func ac4Variable(_ bits: Int) -> Int {
        var value = 0
        while true {
            value += read(bits)
            guard readBit() == 1 else { return value }
            value <<= bits
            value += 1 << bits
        }
    }

    /// Counts 1-bits up to the first 0 (consumed), at most `max`.
    mutating func unary(max: Int) -> Int {
        var n = 0
        while n < max {
            if readBit() == 0 { break }
            n += 1
        }
        return n
    }

    mutating func readLong(_ n: Int) -> Int {
        guard n > 24 else { return read(n) }
        let high = read(n - 16)
        return (high << 16) | read(16)
    }

    mutating func skipLong(_ n: Int) { bitPos &+= n }
}
