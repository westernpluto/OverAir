import Foundation

/// A decoded frame, valid only for the duration of the `onPicture` callback.
struct MPEG2Picture {
    var y: UnsafePointer<UInt8>
    var cb: UnsafePointer<UInt8>
    var cr: UnsafePointer<UInt8>
    var yStride: Int
    var cStride: Int
    /// Display size (e.g. 1920×1080; the coded frame may be taller).
    var width: Int
    var height: Int
    var pts: Int64?
    var progressive: Bool
    var topFieldFirst: Bool
    var repeatFirstField: Bool
    var codingType: Int
    /// Display aspect ratio (width / height).
    var displayAspect: Double
    var frameRate: Double
    /// CEA-608/708 cc_data triplets (cc_valid/cc_type byte, data1, data2) in display order.
    var captionData: [UInt8]
}

/// A software MPEG-2 Main Profile video decoder (the codec used by most ATSC 1.0 channels).
/// Slices are decoded in parallel across CPU cores.
final class MPEG2VideoDecoder {
    var onPicture: ((MPEG2Picture) -> Void)?
    /// Skip B pictures (used for multiview tiles to save CPU).
    var skipBPictures = false
    private(set) var decodedPictures = 0
    private(set) var errorCount = 0

    // MARK: Sequence state

    private struct Sequence {
        var width = 0, height = 0
        var aspectCode = 3
        var frameRateCode = 4
        var frameRateExtN = 0, frameRateExtD = 0
        var progressiveSequence = false
        var chromaFormat = 1
        var intraMatrix = [UInt8](MPEG2Tables.defaultIntraMatrix)
        var nonIntraMatrix = [UInt8](repeating: 16, count: 64)
        var mbWidth = 0, mbHeight = 0

        var frameRate: Double {
            let base = MPEG2Tables.frameRates[min(max(frameRateCode, 0), 8)]
            return base * Double(frameRateExtN + 1) / Double(frameRateExtD + 1)
        }

        var displayAspect: Double {
            switch aspectCode {
            case 2: return 4.0 / 3.0
            case 3: return 16.0 / 9.0
            case 4: return 2.21
            default: return height > 0 ? Double(width) / Double(height) : 16.0 / 9.0
            }
        }
    }

    private var seq = Sequence()
    private var haveSequence = false
    private var intraMatrix = [UInt8](MPEG2Tables.defaultIntraMatrix)
    private var nonIntraMatrix = [UInt8](repeating: 16, count: 64)

    // MARK: Picture state

    final class Frame {
        let y: UnsafeMutablePointer<UInt8>
        let cb: UnsafeMutablePointer<UInt8>
        let cr: UnsafeMutablePointer<UInt8>
        let yStride: Int, cStride: Int, lumaHeight: Int, chromaHeight: Int
        var pts: Int64?
        var progressive = true, topFieldFirst = true, repeatFirstField = false
        var codingType = 1
        var captions: [UInt8] = []

        init(mbWidth: Int, mbHeight: Int) {
            yStride = mbWidth * 16
            cStride = mbWidth * 8
            lumaHeight = mbHeight * 16
            chromaHeight = mbHeight * 8
            y = .allocate(capacity: yStride * lumaHeight)
            cb = .allocate(capacity: cStride * chromaHeight)
            cr = .allocate(capacity: cStride * chromaHeight)
            y.initialize(repeating: 16, count: yStride * lumaHeight)
            cb.initialize(repeating: 128, count: cStride * chromaHeight)
            cr.initialize(repeating: 128, count: cStride * chromaHeight)
        }

        deinit { y.deallocate(); cb.deallocate(); cr.deallocate() }

        var lumaView: PlaneView { PlaneView(base: y, stride: yStride, width: yStride, height: lumaHeight) }
        var cbView: PlaneView { PlaneView(base: cb, stride: cStride, width: cStride, height: chromaHeight) }
        var crView: PlaneView { PlaneView(base: cr, stride: cStride, width: cStride, height: chromaHeight) }
    }

    private var pool: [Frame] = []
    private var past: Frame?       // older reference
    private var future: Frame?     // newer reference (not yet displayed)
    private var futureShown = true
    private var current: Frame?
    private var expectSecondField = false
    private var firstFieldParity = 0
    private var firstFieldIsP = false
    private var lastPTS: Int64?

    // MARK: Elementary stream buffering

    private var buffer: [UInt8] = []
    private var bufferBase = 0          // absolute stream offset of buffer[0]
    private var scanPos = 0             // next index in buffer to scan for start codes
    private var unitStart: Int?         // index of the current unit's start code
    private var ptsQueue: [(offset: Int, pts: Int64)] = []
    private var totalBytes = 0


    init() {}

    // MARK: Public API

    /// Feeds elementary stream bytes. `pts` (90 kHz) applies to the first picture starting in this chunk.
    func decode(_ bytes: UnsafeRawBufferPointer, pts: Int64?) {
        if let pts { ptsQueue.append((totalBytes, pts)) }
        buffer.append(contentsOf: bytes)
        totalBytes += bytes.count
        processBuffer(flush: false)
    }

    func decode(_ data: [UInt8], pts: Int64?) {
        data.withUnsafeBytes { decode($0, pts: pts) }
    }

    /// Decodes anything still buffered and outputs the last reference frame.
    func flush() {
        processBuffer(flush: true)
        if let f = future, !futureShown { output(f); futureShown = true }
    }

    /// Drops all state (channel change, seek, stream discontinuity).
    func reset() {
        buffer.removeAll(keepingCapacity: true)
        bufferBase = totalBytes
        scanPos = 0
        unitStart = nil
        ptsQueue.removeAll()
        past = nil; future = nil; current = nil
        futureShown = true
        expectSecondField = false
        lastPTS = nil
    }

    // MARK: Start-code scanning

    private func processBuffer(flush: Bool) {
        let count = buffer.count
        var units: [(start: Int, end: Int)] = []
        buffer.withUnsafeBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            var i = max(scanPos, 0)
            while i + 3 < count {
                if p[i + 2] > 1 { i += 3; continue }
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                    let code = p[i + 3]
                    if code == 0x00 || code == 0xB3 || code == 0xB8 || code == 0xB7 {
                        if let s = unitStart { units.append((s, i)) }
                        unitStart = i
                    }
                    i += 4
                } else {
                    i += 1
                }
            }
            scanPos = max(count - 3, 0)
        }
        if flush, let s = unitStart, s < count {
            units.append((s, count))
            unitStart = nil
            scanPos = count
        }
        for u in units { decodeUnit(start: u.start, end: u.end) }

        // Compact consumed bytes.
        let keepFrom = unitStart ?? scanPos
        if keepFrom > 1 << 20 || (keepFrom > 0 && keepFrom == buffer.count) {
            buffer.removeFirst(keepFrom)
            bufferBase += keepFrom
            scanPos -= keepFrom
            if unitStart != nil { unitStart! -= keepFrom }
        }
    }

    /// Splits a unit into its start-code delimited parts and handles them.
    private func decodeUnit(start: Int, end: Int) {
        let length = end - start
        guard length > 4 else { return }
        // Copy into a zero-padded scratch buffer for the bit reader.
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: length + 16)
        defer { scratch.deallocate() }
        buffer.withUnsafeBufferPointer { buf in
            scratch.initialize(from: buf.baseAddress! + start, count: length)
        }
        (scratch + length).initialize(repeating: 0, count: 16)

        var parts: [(code: UInt8, offset: Int, end: Int)] = []
        var i = 0
        var lastCode: UInt8 = 0, lastOffset = -1
        while i + 3 < length {
            if scratch[i] == 0 && scratch[i + 1] == 0 && scratch[i + 2] == 1 {
                if lastOffset >= 0 { parts.append((lastCode, lastOffset, i)) }
                lastCode = scratch[i + 3]
                lastOffset = i + 4
                i += 4
            } else {
                i += 1
            }
        }
        if lastOffset >= 0 { parts.append((lastCode, lastOffset, length)) }
        guard let first = parts.first else { return }

        switch first.code {
        case 0xB3:
            for part in parts {
                var br = BitReader(data: scratch + part.offset, byteCount: part.end - part.offset)
                if part.code == 0xB3 { parseSequenceHeader(&br) }
                else if part.code == 0xB5 { parseExtension(&br) }
            }
        case 0x00:
            let absolute = bufferBase + start
            decodePicture(scratch: scratch, parts: parts, absoluteOffset: absolute)
        case 0xB7:
            // Sequence end: show the last reference frame.
            if let f = future, !futureShown { output(f); futureShown = true }
        default:
            break // GOP header: nothing we need.
        }
    }

    // MARK: Headers

    private func parseSequenceHeader(_ br: inout BitReader) {
        let w = br.read(12), h = br.read(12)
        let aspect = br.read(4), rate = br.read(4)
        br.skip(18) // bit_rate
        br.skip(1)  // marker
        br.skip(10) // vbv_buffer_size
        br.skip(1)  // constrained_parameters_flag
        var intra = [UInt8](MPEG2Tables.defaultIntraMatrix)
        if br.readBit() == 1 {
            for i in 0..<64 { intra[Int(MPEG2Tables.zigzag[i])] = UInt8(br.read(8)) }
        }
        var nonIntra = [UInt8](repeating: 16, count: 64)
        if br.readBit() == 1 {
            for i in 0..<64 { nonIntra[Int(MPEG2Tables.zigzag[i])] = UInt8(br.read(8)) }
        }
        let sizeChanged = w != seq.width || h != seq.height
        seq.width = w
        seq.height = h
        seq.aspectCode = aspect
        seq.frameRateCode = rate
        seq.intraMatrix = intra
        seq.nonIntraMatrix = nonIntra
        intraMatrix = intra
        nonIntraMatrix = nonIntra
        if sizeChanged { haveSequence = false }
        recomputeSize()
    }

    private func recomputeSize() {
        guard seq.width > 0, seq.height > 0 else { return }
        let mbw = (seq.width + 15) / 16
        let mbh = seq.progressiveSequence ? (seq.height + 15) / 16 : 2 * ((seq.height + 31) / 32)
        if mbw != seq.mbWidth || mbh != seq.mbHeight {
            seq.mbWidth = mbw
            seq.mbHeight = mbh
            pool.removeAll()
            past = nil; future = nil; current = nil
            futureShown = true
            expectSecondField = false
        }
        haveSequence = true
    }

    // Picture coding extension values.
    private struct PictureCoding {
        var fCode: [[Int]] = [[15, 15], [15, 15]]
        var intraDCPrecision = 0
        var structure = 3
        var topFieldFirst = true
        var framePredFrameDCT = true
        var concealment = false
        var qScaleType = false
        var intraVLCFormat = false
        var alternateScan = false
        var repeatFirstField = false
        var progressiveFrame = true
    }

    private var pictureCoding = PictureCoding()

    private func parseExtension(_ br: inout BitReader) {
        let id = br.read(4)
        switch id {
        case 1: // sequence extension
            br.skip(8) // profile_and_level_indication
            seq.progressiveSequence = br.readBit() == 1
            seq.chromaFormat = br.read(2)
            let hExt = br.read(2), vExt = br.read(2)
            br.skip(12) // bit_rate_extension
            br.skip(1)
            br.skip(8)  // vbv_buffer_size_extension
            br.skip(1)  // low_delay
            seq.frameRateExtN = br.read(2)
            seq.frameRateExtD = br.read(5)
            seq.width = (seq.width & 0xFFF) | (hExt << 12)
            seq.height = (seq.height & 0xFFF) | (vExt << 12)
            recomputeSize()
        case 3: // quant matrix extension
            if br.readBit() == 1 {
                for i in 0..<64 { intraMatrix[Int(MPEG2Tables.zigzag[i])] = UInt8(br.read(8)) }
            }
            if br.readBit() == 1 {
                for i in 0..<64 { nonIntraMatrix[Int(MPEG2Tables.zigzag[i])] = UInt8(br.read(8)) }
            }
        case 8: // picture coding extension
            var pc = PictureCoding()
            pc.fCode = [[br.read(4), br.read(4)], [br.read(4), br.read(4)]]
            pc.intraDCPrecision = br.read(2)
            pc.structure = br.read(2)
            pc.topFieldFirst = br.readBit() == 1
            pc.framePredFrameDCT = br.readBit() == 1
            pc.concealment = br.readBit() == 1
            pc.qScaleType = br.readBit() == 1
            pc.intraVLCFormat = br.readBit() == 1
            pc.alternateScan = br.readBit() == 1
            pc.repeatFirstField = br.readBit() == 1
            br.skip(1) // chroma_420_type
            pc.progressiveFrame = br.readBit() == 1
            pictureCoding = pc
        default:
            break
        }
    }

    // MARK: Pictures

    private func takeFrame() -> Frame {
        let busy = [past, future, current].compactMap { $0 }
        if let i = pool.firstIndex(where: { f in !busy.contains { $0 === f } }) {
            let f = pool.remove(at: i)
            return f
        }
        return Frame(mbWidth: seq.mbWidth, mbHeight: seq.mbHeight)
    }

    private func recycle(_ f: Frame?) {
        guard let f else { return }
        if pool.count < 4 && !pool.contains(where: { $0 === f }) { pool.append(f) }
    }

    private func pts(forPictureAt absoluteOffset: Int) -> Int64? {
        var result: Int64?
        while let first = ptsQueue.first, first.offset <= absoluteOffset {
            result = first.pts
            ptsQueue.removeFirst()
        }
        return result
    }

    private func decodePicture(scratch: UnsafeMutablePointer<UInt8>, parts: [(code: UInt8, offset: Int, end: Int)], absoluteOffset: Int) {
        let pts = pts(forPictureAt: absoluteOffset)
        guard haveSequence, seq.chromaFormat == 1, seq.mbWidth > 0 else { return }

        // Picture header.
        guard let header = parts.first, header.code == 0x00 else { return }
        var hb = BitReader(data: scratch + header.offset, byteCount: header.end - header.offset)
        hb.skip(10) // temporal_reference
        let codingType = hb.read(3)
        guard (1...3).contains(codingType) else { return }

        pictureCoding = PictureCoding()
        var captions: [UInt8] = []
        var slices: [(row: Int, offset: Int, end: Int)] = []
        for part in parts.dropFirst() {
            switch part.code {
            case 0xB5:
                var br = BitReader(data: scratch + part.offset, byteCount: part.end - part.offset)
                parseExtension(&br)
            case 0xB2:
                captions.append(contentsOf: Self.parseCaptionUserData(scratch + part.offset, count: part.end - part.offset))
            case 0x01...0xAF:
                slices.append((Int(part.code) - 1, part.offset, part.end))
            default:
                break
            }
        }

        let pc = pictureCoding
        let isFieldPicture = pc.structure != 3
        let parity = pc.structure == 2 ? 1 : 0
        let isSecondField = isFieldPicture && expectSecondField && parity != firstFieldParity

        if codingType == 3 && skipBPictures { expectSecondField = false; return }

        // Reference management.
        var fwd: Frame?, bwd: Frame?
        if !isSecondField {
            if codingType == 3 {
                guard let p = past, let f = future else { expectSecondField = false; return } // B needs two refs
                fwd = p; bwd = f
                current = takeFrame()
            } else {
                if codingType == 2 && future == nil { expectSecondField = false; return } // P needs a ref
                fwd = future
                // A new reference frame: display the previous one now (display order).
                if let f = future, !futureShown { output(f) }
                if let old = past, old !== future { recycle(old) }
                past = future
                let frame = takeFrame()
                future = frame
                futureShown = false
                current = frame
            }
            guard let cur = current else { return }
            cur.pts = pts
            cur.progressive = pc.progressiveFrame
            cur.topFieldFirst = isFieldPicture ? (parity == 0) : pc.topFieldFirst
            cur.repeatFirstField = pc.repeatFirstField
            cur.codingType = codingType
            cur.captions = captions
            expectSecondField = isFieldPicture
            firstFieldParity = parity
        } else {
            guard let cur = current else { return }
            cur.captions.append(contentsOf: captions)
            if codingType == 3 { fwd = past; bwd = future } else { fwd = (current === future) ? past : future }
            expectSecondField = false
        }
        guard let cur = current else { return }

        let params = SliceParams(
            codingType: codingType,
            structure: pc.structure,
            isSecondField: isSecondField,
            fCode: pc.fCode,
            intraDCPrecision: pc.intraDCPrecision,
            framePredFrameDCT: isFieldPicture ? false : pc.framePredFrameDCT,
            concealment: pc.concealment,
            qScaleType: pc.qScaleType,
            intraVLCFormat: pc.intraVLCFormat,
            scan: pc.alternateScan ? MPEG2Tables.alternateScan : MPEG2Tables.zigzag,
            intraMatrix: intraMatrix.map { Int32($0) },
            nonIntraMatrix: nonIntraMatrix.map { Int32($0) },
            topFieldFirst: pc.topFieldFirst,
            mbWidth: seq.mbWidth,
            mbRows: isFieldPicture ? seq.mbHeight / 2 : seq.mbHeight,
            current: cur, forward: fwd, backward: bwd)

        // Decode slices in parallel (slices are independent within a picture).
        let errors = UnsafeMutablePointer<Int>.allocate(capacity: max(slices.count, 1))
        errors.initialize(repeating: 0, count: max(slices.count, 1))
        defer { errors.deallocate() }
        DispatchQueue.concurrentPerform(iterations: slices.count) { idx in
            let s = slices[idx]
            guard s.row < params.mbRows else { errors[idx] = 1; return }
            var dec = SliceDecoder(params: params, data: scratch + s.offset, count: s.end - s.offset, row: s.row)
            if !dec.run() { errors[idx] = 1 }
        }
        for i in 0..<slices.count where errors[i] != 0 { errorCount += 1 }

        // A frame is complete after a frame picture or the second field.
        let complete = !isFieldPicture || isSecondField
        if complete {
            decodedPictures += 1
            if codingType == 3 || cur.codingType == 3 {
                output(cur)
                current = nil
                recycle(cur)
            }
        }
    }

    private func output(_ f: Frame) {
        var pts = f.pts
        let rate = seq.frameRate > 0 ? seq.frameRate : 29.97
        if pts == nil, let last = lastPTS { pts = last + Int64(90000.0 / rate) }
        if let p = pts { lastPTS = p }
        guard let cb = onPicture else { return }
        let picture = MPEG2Picture(
            y: UnsafePointer(f.y), cb: UnsafePointer(f.cb), cr: UnsafePointer(f.cr),
            yStride: f.yStride, cStride: f.cStride,
            width: seq.width, height: seq.height,
            pts: pts,
            progressive: f.progressive || seq.progressiveSequence,
            topFieldFirst: f.topFieldFirst,
            repeatFirstField: f.repeatFirstField,
            codingType: f.codingType,
            displayAspect: seq.displayAspect,
            frameRate: rate,
            captionData: f.captions)
        cb(picture)
    }

    /// ATSC A/53 "GA94" caption user data → cc_data triplets.
    static func parseCaptionUserData(_ p: UnsafePointer<UInt8>, count: Int) -> [UInt8] {
        guard count >= 7, p[0] == 0x47, p[1] == 0x41, p[2] == 0x39, p[3] == 0x34, p[4] == 0x03 else { return [] }
        let flags = p[5]
        guard flags & 0x40 != 0 else { return [] } // process_cc_data_flag
        let ccCount = Int(flags & 0x1F)
        var out: [UInt8] = []
        var i = 7 // skip em_data
        for _ in 0..<ccCount {
            guard i + 2 < count else { break }
            out.append(p[i]); out.append(p[i + 1]); out.append(p[i + 2])
            i += 3
        }
        return out
    }
}

// MARK: - Slice decoding

struct SliceParams {
    let codingType: Int
    let structure: Int
    let isSecondField: Bool
    let fCode: [[Int]]
    let intraDCPrecision: Int
    let framePredFrameDCT: Bool
    let concealment: Bool
    let qScaleType: Bool
    let intraVLCFormat: Bool
    let scan: [UInt8]
    let intraMatrix: [Int32]
    let nonIntraMatrix: [Int32]
    let topFieldFirst: Bool
    let mbWidth: Int
    let mbRows: Int
    let current: MPEG2VideoDecoder.Frame
    let forward: MPEG2VideoDecoder.Frame?
    let backward: MPEG2VideoDecoder.Frame?
}

private struct SliceDecoder {
    // Motion types
    static let mtFrame = 0, mtField = 1, mt16x8 = 2, mtDMV = 3

    let p: SliceParams
    var br: BitReader
    let row: Int
    let isFrame: Bool
    let parity: Int
    let fCode: (Int, Int, Int, Int)
    let scan: UnsafeMutablePointer<Int32>
    let intraW: UnsafeMutablePointer<Int32>
    let nonIntraW: UnsafeMutablePointer<Int32>
    let blocks: UnsafeMutablePointer<Int32>

    var qscale: Int32 = 0
    var dcPred: (Int32, Int32, Int32) = (128, 128, 128)
    var pmv = [Int](repeating: 0, count: 8) // [r][s][t] → r*4 + s*2 + t

    // Motion of the last macroblock (re-used by skipped B macroblocks).
    var mvType = 0
    var dir = 0
    var mv = [Int](repeating: 0, count: 16) // [s][k][t] → s*8 + k*2 + t
    var fieldSelect = [Int](repeating: 0, count: 4) // [s][k] → s*2 + k

    init(params: SliceParams, data: UnsafePointer<UInt8>, count: Int, row: Int) {
        p = params
        br = BitReader(data: data, byteCount: count)
        self.row = row
        isFrame = params.structure == 3
        parity = params.structure == 2 ? 1 : 0
        fCode = (params.fCode[0][0], params.fCode[0][1], params.fCode[1][0], params.fCode[1][1])
        scan = .allocate(capacity: 64)
        intraW = .allocate(capacity: 64)
        nonIntraW = .allocate(capacity: 64)
        for i in 0..<64 {
            scan[i] = Int32(params.scan[i])
            intraW[i] = params.intraMatrix[i]
            nonIntraW[i] = params.nonIntraMatrix[i]
        }
        blocks = .allocate(capacity: 64 * 6)
        blocks.initialize(repeating: 0, count: 64 * 6)
    }

    func release() {
        scan.deallocate(); intraW.deallocate(); nonIntraW.deallocate(); blocks.deallocate()
    }

    @inline(__always) func f(_ s: Int, _ t: Int) -> Int {
        switch (s, t) {
        case (0, 0): return fCode.0
        case (0, 1): return fCode.1
        case (1, 0): return fCode.2
        default: return fCode.3
        }
    }

    @inline(__always) mutating func resetDC() {
        let v = Int32(128 << p.intraDCPrecision)
        dcPred = (v, v, v)
    }

    @inline(__always) mutating func quantScale(_ code: Int) -> Int32 {
        p.qScaleType ? MPEG2Tables.nonLinearQScale[code & 31] : Int32(code << 1)
    }

    mutating func run() -> Bool {
        defer { release() }
        qscale = quantScale(br.read(5))
        if br.readBit() == 1 {
            br.skip(8) // intra_slice_flag, intra_slice, reserved
            while br.readBit() == 1 { br.skip(8) }
        }
        resetDC()
        for i in 0..<8 { pmv[i] = 0 }

        // First macroblock address increment gives the column.
        var mbx = -1
        var inc = 0
        while true {
            let v = MPEG2Tables.mba.decode(&br)
            if v == VLCTable.invalid { return false }
            if v == Int(MPEG2Tables.mbaEscape) { inc += 33; continue }
            if v == Int(MPEG2Tables.mbaStuffing) { continue }
            inc += v
            break
        }
        mbx = inc - 1
        if mbx < 0 || mbx >= p.mbWidth { return false }
        var mby = row

        while true {
            if !decodeMacroblock(mbx: mbx, mby: mby) { return false }
            if br.overrun { return false }
            // End of slice: next 23 bits are zero (a start code follows).
            if br.bitsLeft <= 0 || br.peek(23) == 0 { return true }
            // Next macroblock address increment.
            inc = 0
            while true {
                let v = MPEG2Tables.mba.decode(&br)
                if v == VLCTable.invalid { return false }
                if v == Int(MPEG2Tables.mbaEscape) { inc += 33; continue }
                if v == Int(MPEG2Tables.mbaStuffing) { continue }
                inc += v
                break
            }
            // Skipped macroblocks.
            for _ in 0..<(inc - 1) {
                mbx += 1
                if mbx >= p.mbWidth { mbx = 0; mby += 1 }
                if mby >= p.mbRows { return false }
                if !skipMacroblock(mbx: mbx, mby: mby) { return false }
            }
            mbx += 1
            if mbx >= p.mbWidth { mbx = 0; mby += 1 }
            if mby >= p.mbRows { return false }
        }
    }

    // MARK: Macroblocks

    mutating func skipMacroblock(mbx: Int, mby: Int) -> Bool {
        resetDC()
        if p.codingType == 1 { return false }
        mvType = isFrame ? Self.mtFrame : Self.mtField
        if p.codingType == 2 {
            dir = 1
            for i in 0..<16 { mv[i] = 0 }
            for i in 0..<8 { pmv[i] = 0 }
            fieldSelect[0] = parity
        } else {
            mv[0] = pmv[0]; mv[1] = pmv[1]       // forward: PMV[0][0]
            mv[8] = pmv[2]; mv[9] = pmv[3]       // backward: PMV[0][1]
            fieldSelect[0] = parity
            fieldSelect[2] = parity
        }
        predictMacroblock(mbx: mbx, mby: mby)
        return true
    }

    mutating func decodeMacroblock(mbx: Int, mby: Int) -> Bool {
        let type: Int
        switch p.codingType {
        case 1: type = MPEG2Tables.mbTypeI.decode(&br)
        case 2: type = MPEG2Tables.mbTypeP.decode(&br)
        default: type = MPEG2Tables.mbTypeB.decode(&br)
        }
        if type == VLCTable.invalid { return false }
        let intra = type & MBFlag.intra != 0
        var dctType = 0

        if intra {
            if isFrame && !p.framePredFrameDCT { dctType = br.readBit() }
            if type & MBFlag.quant != 0 { qscale = quantScale(br.read(5)) }
            if p.concealment {
                if !isFrame { br.skip(1) }
                let mx = decodeMotion(f(0, 0), pmv[0])
                pmv[0] = mx; pmv[4] = mx
                let my = decodeMotion(f(0, 1), pmv[1])
                pmv[1] = my; pmv[5] = my
                br.skip(1) // marker
            } else {
                for i in 0..<8 { pmv[i] = 0 }
            }
            let table = p.intraVLCFormat ? MPEG2Tables.dct1 : MPEG2Tables.dct0
            for b in 0..<6 {
                if !decodeIntraBlock(b, table: table) { return false }
            }
            reconstructIntra(mbx: mbx, mby: mby, dctType: dctType)
            mvType = Self.mtFrame
            dir = 0
            return true
        }

        resetDC()
        if p.codingType == 2 && type & MBFlag.forward == 0 {
            // P macroblock without motion compensation: zero vector from the forward reference.
            if isFrame && !p.framePredFrameDCT { dctType = br.readBit() }
            mvType = isFrame ? Self.mtFrame : Self.mtField
            fieldSelect[0] = parity
            dir = 1
            for i in 0..<8 { mv[i] = 0 }
            pmv[0] = 0; pmv[1] = 0; pmv[4] = 0; pmv[5] = 0
            if type & MBFlag.quant != 0 { qscale = quantScale(br.read(5)) }
        } else {
            var motionType: Int
            if isFrame && p.framePredFrameDCT {
                motionType = 2
            } else {
                motionType = br.read(2)
                if isFrame && type & MBFlag.pattern != 0 { dctType = br.readBit() }
            }
            if type & MBFlag.quant != 0 { qscale = quantScale(br.read(5)) }
            dir = (type & MBFlag.forward != 0 ? 1 : 0) | (type & MBFlag.backward != 0 ? 2 : 0)
            for s in 0..<2 where dir & (1 << s) != 0 {
                switch motionType {
                case 2:
                    if isFrame {
                        mvType = Self.mtFrame
                        let mx = decodeMotion(f(s, 0), pmv[s * 2])
                        pmv[s * 2] = mx; pmv[4 + s * 2] = mx
                        let my = decodeMotion(f(s, 1), pmv[s * 2 + 1])
                        pmv[s * 2 + 1] = my; pmv[4 + s * 2 + 1] = my
                        mv[s * 8] = mx; mv[s * 8 + 1] = my
                    } else {
                        mvType = Self.mt16x8
                        for j in 0..<2 {
                            fieldSelect[s * 2 + j] = br.readBit()
                            for t in 0..<2 {
                                let v = decodeMotion(f(s, t), pmv[j * 4 + s * 2 + t])
                                pmv[j * 4 + s * 2 + t] = v
                                mv[s * 8 + j * 2 + t] = v
                            }
                        }
                    }
                case 1:
                    mvType = Self.mtField
                    if isFrame {
                        for j in 0..<2 {
                            fieldSelect[s * 2 + j] = br.readBit()
                            let mx = decodeMotion(f(s, 0), pmv[j * 4 + s * 2])
                            pmv[j * 4 + s * 2] = mx
                            mv[s * 8 + j * 2] = mx
                            let my = decodeMotion(f(s, 1), pmv[j * 4 + s * 2 + 1] >> 1)
                            pmv[j * 4 + s * 2 + 1] = my * 2
                            mv[s * 8 + j * 2 + 1] = my
                        }
                    } else {
                        fieldSelect[s * 2] = br.readBit()
                        for t in 0..<2 {
                            let v = decodeMotion(f(s, t), pmv[s * 2 + t])
                            pmv[s * 2 + t] = v; pmv[4 + s * 2 + t] = v
                            mv[s * 8 + t] = v
                        }
                    }
                case 3:
                    mvType = Self.mtDMV
                    let shift = isFrame ? 1 : 0
                    let mx = decodeMotion(f(s, 0), pmv[s * 2])
                    pmv[s * 2] = mx; pmv[4 + s * 2] = mx
                    let dmx = MPEG2Tables.dmv.decode(&br)
                    let my = decodeMotion(f(s, 1), pmv[s * 2 + 1] >> shift)
                    let dmy = MPEG2Tables.dmv.decode(&br)
                    if dmx == VLCTable.invalid || dmy == VLCTable.invalid { return false }
                    pmv[s * 2 + 1] = my << shift; pmv[4 + s * 2 + 1] = my << shift
                    mv[s * 8] = mx; mv[s * 8 + 1] = my
                    mv[s * 8 + 2] = mx; mv[s * 8 + 3] = my
                    if isFrame {
                        var m = p.topFieldFirst ? 1 : 3
                        mv[s * 8 + 4] = ((mx * m + (mx > 0 ? 1 : 0)) >> 1) + dmx
                        mv[s * 8 + 5] = ((my * m + (my > 0 ? 1 : 0)) >> 1) + dmy - 1
                        m = 4 - m
                        mv[s * 8 + 6] = ((mx * m + (mx > 0 ? 1 : 0)) >> 1) + dmx
                        mv[s * 8 + 7] = ((my * m + (my > 0 ? 1 : 0)) >> 1) + dmy + 1
                    } else {
                        mv[s * 8 + 4] = ((mx + (mx > 0 ? 1 : 0)) >> 1) + dmx
                        mv[s * 8 + 5] = ((my + (my > 0 ? 1 : 0)) >> 1) + dmy + (parity == 0 ? -1 : 1)
                    }
                default:
                    return false
                }
            }
        }

        predictMacroblock(mbx: mbx, mby: mby)

        if type & MBFlag.pattern != 0 {
            let cbp = MPEG2Tables.cbp.decode(&br)
            if cbp == VLCTable.invalid { return false }
            for b in 0..<6 where cbp & (32 >> b) != 0 {
                if !decodeNonIntraBlock(b) { return false }
                addResidual(block: b, mbx: mbx, mby: mby, dctType: dctType)
            }
        }
        return true
    }

    @inline(__always) mutating func decodeMotion(_ fcode: Int, _ pred: Int) -> Int {
        let code = MPEG2Tables.motion.decode(&br)
        if code == 0 || code == VLCTable.invalid { return pred }
        let sign = br.readBit()
        let shift = fcode - 1
        var val = code
        if shift > 0 {
            val = ((val - 1) << shift) | br.read(shift)
            val += 1
        }
        if sign == 1 { val = -val }
        val += pred
        // Wrap into [-16f, 16f - 1].
        let bits = 5 + shift
        let s = 64 - bits
        return (val << s) >> s
    }

    // MARK: Blocks

    mutating func decodeIntraBlock(_ b: Int, table: VLCTable) -> Bool {
        let blk = blocks + b * 64
        let size = b < 4 ? MPEG2Tables.dcLuma.decode(&br) : MPEG2Tables.dcChroma.decode(&br)
        if size == VLCTable.invalid { return false }
        var diff: Int32 = 0
        if size > 0 {
            let v = br.read(size)
            diff = Int32(v < (1 << (size - 1)) ? v - (1 << size) + 1 : v)
        }
        let dc: Int32
        switch b {
        case 0...3: dcPred.0 &+= diff; dc = dcPred.0
        case 4: dcPred.1 &+= diff; dc = dcPred.1
        default: dcPred.2 &+= diff; dc = dcPred.2
        }
        blk[0] = dc << Int32(3 - p.intraDCPrecision)
        var sum = blk[0]
        var i = 0
        let q = qscale
        while true {
            let v = table.decode(&br)
            if v == MPEG2Tables.dctEOB { break }
            var level: Int32
            if v == MPEG2Tables.dctEscape {
                i += br.read(6) + 1
                level = Int32(br.readSigned(12))
            } else if v == VLCTable.invalid {
                return false
            } else {
                i += (v >> 8) + 1
                level = Int32(v & 0xFF)
                if br.readBit() == 1 { level = -level }
            }
            if i > 63 { return false }
            let j = Int(scan[i])
            var val = (abs(level) &* q &* intraW[j]) >> 4
            if level < 0 { val = -val }
            if val > 2047 { val = 2047 } else if val < -2048 { val = -2048 }
            blk[j] = val
            sum ^= val
        }
        if sum & 1 == 0 { blk[63] ^= 1 }
        return true
    }

    mutating func decodeNonIntraBlock(_ b: Int) -> Bool {
        let blk = blocks + b * 64
        var sum: Int32 = 0
        var i = -1
        let q = qscale
        var first = true
        while true {
            var level: Int32
            if first && br.peek(1) == 1 {
                br.skip(1)
                i += 1
                level = br.readBit() == 1 ? -1 : 1
            } else {
                let v = MPEG2Tables.dct0.decode(&br)
                if v == MPEG2Tables.dctEOB { break }
                if v == MPEG2Tables.dctEscape {
                    i += br.read(6) + 1
                    level = Int32(br.readSigned(12))
                } else if v == VLCTable.invalid {
                    return false
                } else {
                    i += (v >> 8) + 1
                    level = Int32(v & 0xFF)
                    if br.readBit() == 1 { level = -level }
                }
            }
            first = false
            if i > 63 { return false }
            let j = Int(scan[i])
            var val = ((2 &* abs(level) &+ 1) &* q &* nonIntraW[j]) >> 5
            if level < 0 { val = -val }
            if val > 2047 { val = 2047 } else if val < -2048 { val = -2048 }
            blk[j] = val
            sum ^= val
        }
        if sum & 1 == 0 { blk[63] ^= 1 }
        return true
    }

    // MARK: Reconstruction

    /// Destination pointer and stride for block `b` of macroblock (mbx, mby).
    @inline(__always) func blockDest(_ b: Int, mbx: Int, mby: Int, dctType: Int) -> (UnsafeMutablePointer<UInt8>, Int) {
        let cur = p.current
        if b < 4 {
            let bx = (b & 1) * 8
            if isFrame {
                if dctType == 0 {
                    let by = (b >> 1) * 8
                    return (cur.y + (mby * 16 + by) * cur.yStride + mbx * 16 + bx, cur.yStride)
                } else {
                    let field = b >> 1
                    return (cur.y + (mby * 16 + field) * cur.yStride + mbx * 16 + bx, cur.yStride * 2)
                }
            } else {
                let by = (b >> 1) * 8
                let stride = cur.yStride * 2
                return (cur.y + parity * cur.yStride + (mby * 16 + by) * stride + mbx * 16 + bx, stride)
            }
        }
        let plane = b == 4 ? cur.cb : cur.cr
        if isFrame {
            return (plane + mby * 8 * cur.cStride + mbx * 8, cur.cStride)
        } else {
            let stride = cur.cStride * 2
            return (plane + parity * cur.cStride + mby * 8 * stride + mbx * 8, stride)
        }
    }

    mutating func reconstructIntra(mbx: Int, mby: Int, dctType: Int) {
        for b in 0..<6 {
            let blk = blocks + b * 64
            let (dst, stride) = blockDest(b, mbx: mbx, mby: mby, dctType: dctType)
            MPEG2DSP.idct(blk)
            MPEG2DSP.put(blk, dst, stride)
            blk.update(repeating: 0, count: 64)
        }
    }

    mutating func addResidual(block b: Int, mbx: Int, mby: Int, dctType: Int) {
        let blk = blocks + b * 64
        let (dst, stride) = blockDest(b, mbx: mbx, mby: mby, dctType: dctType)
        MPEG2DSP.idct(blk)
        MPEG2DSP.add(blk, dst, stride)
        blk.update(repeating: 0, count: 64)
    }

    // MARK: Motion compensation

    /// Reference frame for direction `s` and field select `fs` (field pictures only).
    @inline(__always) func reference(_ s: Int, fieldSelect fs: Int) -> MPEG2VideoDecoder.Frame? {
        if s == 0 {
            if !isFrame && p.isSecondField && p.codingType == 2 && fs != parity {
                return p.current // opposite parity of the same frame (first field)
            }
            return p.forward
        }
        return p.backward
    }

    mutating func predictMacroblock(mbx: Int, mby: Int) {
        var first = true
        for s in 0..<2 where dir & (1 << s) != 0 {
            predictDirection(s, mbx: mbx, mby: mby, average: !first)
            first = false
        }
    }

    @inline(__always)
    func mc(_ ref: MPEG2VideoDecoder.Frame, refField: Int?, dstField: Int?, mbx: Int, lumaY: Int, chromaY: Int,
            mvx: Int, mvy: Int, h: Int, average: Bool) {
        let cur = p.current
        var srcY = ref.lumaView, srcCb = ref.cbView, srcCr = ref.crView
        var dstY = cur.lumaView, dstCb = cur.cbView, dstCr = cur.crView
        if let rf = refField {
            srcY = srcY.field(rf == 1); srcCb = srcCb.field(rf == 1); srcCr = srcCr.field(rf == 1)
        }
        if let df = dstField {
            dstY = dstY.field(df == 1); dstCb = dstCb.field(df == 1); dstCr = dstCr.field(df == 1)
        }
        let lx = mbx * 16
        srcY.predict(into: dstY.base + lumaY * dstY.stride + lx, dstStride: dstY.stride,
                     x2: lx * 2 + mvx, y2: lumaY * 2 + mvy, w: 16, h: h, average: average)
        let cmx = mvx / 2, cmy = mvy / 2
        let cx = mbx * 8
        srcCb.predict(into: dstCb.base + chromaY * dstCb.stride + cx, dstStride: dstCb.stride,
                      x2: cx * 2 + cmx, y2: chromaY * 2 + cmy, w: 8, h: h / 2, average: average)
        srcCr.predict(into: dstCr.base + chromaY * dstCr.stride + cx, dstStride: dstCr.stride,
                      x2: cx * 2 + cmx, y2: chromaY * 2 + cmy, w: 8, h: h / 2, average: average)
    }

    func predictDirection(_ s: Int, mbx: Int, mby: Int, average: Bool) {
        let base = s * 8
        if isFrame {
            switch mvType {
            case Self.mtFrame:
                guard let ref = reference(s, fieldSelect: 0) else { return }
                mc(ref, refField: nil, dstField: nil, mbx: mbx, lumaY: mby * 16, chromaY: mby * 8,
                   mvx: mv[base], mvy: mv[base + 1], h: 16, average: average)
            case Self.mtField:
                guard let ref = reference(s, fieldSelect: 0) else { return }
                for j in 0..<2 {
                    mc(ref, refField: fieldSelect[s * 2 + j], dstField: j, mbx: mbx, lumaY: mby * 8, chromaY: mby * 4,
                       mvx: mv[base + j * 2], mvy: mv[base + j * 2 + 1], h: 8, average: average)
                }
            case Self.mtDMV:
                guard let ref = reference(s, fieldSelect: 0) else { return }
                for i in 0..<2 {
                    for j in 0..<2 {
                        let k = 2 * i + j
                        mc(ref, refField: j ^ i, dstField: j, mbx: mbx, lumaY: mby * 8, chromaY: mby * 4,
                           mvx: mv[base + k * 2], mvy: mv[base + k * 2 + 1], h: 8, average: average || i == 1)
                    }
                }
            default:
                break
            }
        } else {
            switch mvType {
            case Self.mtField, Self.mtFrame:
                let fs = fieldSelect[s * 2]
                guard let ref = reference(s, fieldSelect: fs) else { return }
                mc(ref, refField: fs, dstField: parity, mbx: mbx, lumaY: mby * 16, chromaY: mby * 8,
                   mvx: mv[base], mvy: mv[base + 1], h: 16, average: average)
            case Self.mt16x8:
                for j in 0..<2 {
                    let fs = fieldSelect[s * 2 + j]
                    guard let ref = reference(s, fieldSelect: fs) else { continue }
                    mc(ref, refField: fs, dstField: parity, mbx: mbx, lumaY: mby * 16 + 8 * j, chromaY: mby * 8 + 4 * j,
                       mvx: mv[base + j * 2], mvy: mv[base + j * 2 + 1], h: 8, average: average)
                }
            case Self.mtDMV:
                // Same parity with the decoded vector, then average with the opposite parity.
                if let ref = reference(s, fieldSelect: parity) {
                    mc(ref, refField: parity, dstField: parity, mbx: mbx, lumaY: mby * 16, chromaY: mby * 8,
                       mvx: mv[base], mvy: mv[base + 1], h: 16, average: average)
                }
                let opposite = 1 - parity
                if let ref = reference(s, fieldSelect: opposite) {
                    mc(ref, refField: opposite, dstField: parity, mbx: mbx, lumaY: mby * 16, chromaY: mby * 8,
                       mvx: mv[base + 4], mvy: mv[base + 5], h: 16, average: true)
                }
            default:
                break
            }
        }
    }
}

