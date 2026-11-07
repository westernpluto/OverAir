import Foundation

/// Inverse DCT and motion-compensation primitives for the MPEG-2 decoder.
enum MPEG2DSP {
    private static let w1: Int32 = 2841
    private static let w2: Int32 = 2676
    private static let w3: Int32 = 2408
    private static let w5: Int32 = 1609
    private static let w6: Int32 = 1108
    private static let w7: Int32 = 565

    @inline(__always) private static func iclip(_ v: Int32) -> Int32 { v < -256 ? -256 : (v > 255 ? 255 : v) }
    @inline(__always) static func clip255(_ v: Int32) -> UInt8 { UInt8(truncatingIfNeeded: v < 0 ? 0 : (v > 255 ? 255 : v)) }
    @inline(__always) static func avg2(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(truncatingIfNeeded: (UInt16(a) &+ UInt16(b) &+ 1) >> 1) }
    @inline(__always) static func avg4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt8 {
        UInt8(truncatingIfNeeded: (UInt16(a) &+ UInt16(b) &+ UInt16(c) &+ UInt16(d) &+ 2) >> 2)
    }

    /// IEEE-1180 compliant 8×8 integer IDCT (Chen–Wang, as in the MPEG Software Simulation Group decoder).
    static func idct(_ blk: UnsafeMutablePointer<Int32>) {
        for r in 0..<8 { idctRow(blk + r &* 8) }
        for c in 0..<8 { idctCol(blk + c) }
    }

    @inline(__always) private static func idctRow(_ b: UnsafeMutablePointer<Int32>) {
        var x1 = b[4] << 11, x2 = b[6], x3 = b[2], x4 = b[1], x5 = b[7], x6 = b[5], x7 = b[3]
        if (x1 | x2 | x3 | x4 | x5 | x6 | x7) == 0 {
            let v = b[0] << 3
            b[0] = v; b[1] = v; b[2] = v; b[3] = v; b[4] = v; b[5] = v; b[6] = v; b[7] = v
            return
        }
        var x0 = (b[0] << 11) &+ 128
        var x8 = w7 &* (x4 &+ x5)
        x4 = x8 &+ (w1 &- w7) &* x4
        x5 = x8 &- (w1 &+ w7) &* x5
        x8 = w3 &* (x6 &+ x7)
        x6 = x8 &- (w3 &- w5) &* x6
        x7 = x8 &- (w3 &+ w5) &* x7
        x8 = x0 &+ x1
        x0 = x0 &- x1
        x1 = w6 &* (x3 &+ x2)
        x2 = x1 &- (w2 &+ w6) &* x2
        x3 = x1 &+ (w2 &- w6) &* x3
        x1 = x4 &+ x6
        x4 = x4 &- x6
        x6 = x5 &+ x7
        x5 = x5 &- x7
        x7 = x8 &+ x3
        x8 = x8 &- x3
        x3 = x0 &+ x2
        x0 = x0 &- x2
        x2 = (181 &* (x4 &+ x5) &+ 128) >> 8
        x4 = (181 &* (x4 &- x5) &+ 128) >> 8
        b[0] = (x7 &+ x1) >> 8
        b[1] = (x3 &+ x2) >> 8
        b[2] = (x0 &+ x4) >> 8
        b[3] = (x8 &+ x6) >> 8
        b[4] = (x8 &- x6) >> 8
        b[5] = (x0 &- x4) >> 8
        b[6] = (x3 &- x2) >> 8
        b[7] = (x7 &- x1) >> 8
    }

    @inline(__always) private static func idctCol(_ b: UnsafeMutablePointer<Int32>) {
        var x1 = b[32] << 8, x2 = b[48], x3 = b[16], x4 = b[8], x5 = b[56], x6 = b[40], x7 = b[24]
        if (x1 | x2 | x3 | x4 | x5 | x6 | x7) == 0 {
            let v = iclip((b[0] &+ 32) >> 6)
            b[0] = v; b[8] = v; b[16] = v; b[24] = v; b[32] = v; b[40] = v; b[48] = v; b[56] = v
            return
        }
        var x0 = (b[0] << 8) &+ 8192
        var x8 = w7 &* (x4 &+ x5) &+ 4
        x4 = (x8 &+ (w1 &- w7) &* x4) >> 3
        x5 = (x8 &- (w1 &+ w7) &* x5) >> 3
        x8 = w3 &* (x6 &+ x7) &+ 4
        x6 = (x8 &- (w3 &- w5) &* x6) >> 3
        x7 = (x8 &- (w3 &+ w5) &* x7) >> 3
        x8 = x0 &+ x1
        x0 = x0 &- x1
        x1 = w6 &* (x3 &+ x2) &+ 4
        x2 = (x1 &- (w2 &+ w6) &* x2) >> 3
        x3 = (x1 &+ (w2 &- w6) &* x3) >> 3
        x1 = x4 &+ x6
        x4 = x4 &- x6
        x6 = x5 &+ x7
        x5 = x5 &- x7
        x7 = x8 &+ x3
        x8 = x8 &- x3
        x3 = x0 &+ x2
        x0 = x0 &- x2
        x2 = (181 &* (x4 &+ x5) &+ 128) >> 8
        x4 = (181 &* (x4 &- x5) &+ 128) >> 8
        b[0] = iclip((x7 &+ x1) >> 14)
        b[8] = iclip((x3 &+ x2) >> 14)
        b[16] = iclip((x0 &+ x4) >> 14)
        b[24] = iclip((x8 &+ x6) >> 14)
        b[32] = iclip((x8 &- x6) >> 14)
        b[40] = iclip((x0 &- x4) >> 14)
        b[48] = iclip((x3 &- x2) >> 14)
        b[56] = iclip((x7 &- x1) >> 14)
    }

    /// Writes an intra block (IDCT output is the pixel value).
    @inline(__always) static func put(_ blk: UnsafeMutablePointer<Int32>, _ dst: UnsafeMutablePointer<UInt8>, _ stride: Int) {
        var d = dst, s = blk
        for _ in 0..<8 {
            d[0] = clip255(s[0]); d[1] = clip255(s[1]); d[2] = clip255(s[2]); d[3] = clip255(s[3])
            d[4] = clip255(s[4]); d[5] = clip255(s[5]); d[6] = clip255(s[6]); d[7] = clip255(s[7])
            d += stride; s += 8
        }
    }

    /// Adds a residual block onto the prediction.
    @inline(__always) static func add(_ blk: UnsafeMutablePointer<Int32>, _ dst: UnsafeMutablePointer<UInt8>, _ stride: Int) {
        var d = dst, s = blk
        for _ in 0..<8 {
            for i in 0..<8 { d[i] = clip255(Int32(d[i]) &+ s[i]) }
            d += stride; s += 8
        }
    }

    @inline(__always) static func putDC(_ v: Int32, _ dst: UnsafeMutablePointer<UInt8>, _ stride: Int) {
        let p = clip255(v)
        var d = dst
        for _ in 0..<8 { d.update(repeating: p, count: 8); d += stride }
    }

    @inline(__always) static func addDC(_ v: Int32, _ dst: UnsafeMutablePointer<UInt8>, _ stride: Int) {
        var d = dst
        for _ in 0..<8 {
            for i in 0..<8 { d[i] = clip255(Int32(d[i]) &+ v) }
            d += stride
        }
    }
}

/// A view onto one plane of a frame, or onto one field of it (every other line).
struct PlaneView {
    var base: UnsafeMutablePointer<UInt8>
    var stride: Int
    var width: Int
    var height: Int

    func field(_ bottom: Bool) -> PlaneView {
        PlaneView(base: base + (bottom ? stride : 0), stride: stride &* 2, width: width, height: height / 2)
    }

    /// Motion-compensated prediction of a `w`×`h` block into `dst`.
    /// (`x2`, `y2`) is the source position in half-pel units. `average` blends with what's already in `dst`.
    @inline(__always)
    func predict(into dst: UnsafeMutablePointer<UInt8>, dstStride: Int, x2: Int, y2: Int, w: Int, h: Int, average: Bool) {
        let x = x2 >> 1, y = y2 >> 1
        let hx = x2 & 1, hy = y2 & 1
        guard x >= 0 && y >= 0 && x &+ w &+ hx <= width && y &+ h &+ hy <= height else {
            predictClamped(into: dst, dstStride: dstStride, x: x, y: y, hx: hx, hy: hy, w: w, h: h, average: average)
            return
        }
        let src = base + (y &* stride &+ x)
        let mode = hx | (hy << 1)
        var s = src, d = dst
        for _ in 0..<h {
            let s1 = s + stride
            switch mode {
            case 0:
                if average {
                    for i in 0..<w { d[i] = MPEG2DSP.avg2(d[i], s[i]) }
                } else {
                    d.update(from: s, count: w)
                }
            case 1:
                for i in 0..<w {
                    let v = MPEG2DSP.avg2(s[i], s[i &+ 1])
                    d[i] = average ? MPEG2DSP.avg2(d[i], v) : v
                }
            case 2:
                for i in 0..<w {
                    let v = MPEG2DSP.avg2(s[i], s1[i])
                    d[i] = average ? MPEG2DSP.avg2(d[i], v) : v
                }
            default:
                for i in 0..<w {
                    let v = MPEG2DSP.avg4(s[i], s[i &+ 1], s1[i], s1[i &+ 1])
                    d[i] = average ? MPEG2DSP.avg2(d[i], v) : v
                }
            }
            s += stride
            d += dstStride
        }
    }

    /// Slow path for vectors that reach outside the picture: clamps every sample.
    private func predictClamped(into dst: UnsafeMutablePointer<UInt8>, dstStride: Int, x: Int, y: Int, hx: Int, hy: Int,
                                w: Int, h: Int, average: Bool) {
        for r in 0..<h {
            let d = dst + r &* dstStride
            for i in 0..<w {
                let a = sample(x &+ i, y &+ r)
                let v: UInt8
                switch (hx, hy) {
                case (1, 1): v = MPEG2DSP.avg4(a, sample(x &+ i &+ 1, y &+ r), sample(x &+ i, y &+ r &+ 1), sample(x &+ i &+ 1, y &+ r &+ 1))
                case (1, 0): v = MPEG2DSP.avg2(a, sample(x &+ i &+ 1, y &+ r))
                case (0, 1): v = MPEG2DSP.avg2(a, sample(x &+ i, y &+ r &+ 1))
                default: v = a
                }
                d[i] = average ? MPEG2DSP.avg2(d[i], v) : v
            }
        }
    }

    @inline(__always) private func sample(_ x: Int, _ y: Int) -> UInt8 {
        let cx = x < 0 ? 0 : (x >= width ? width &- 1 : x)
        let cy = y < 0 ? 0 : (y >= height ? height &- 1 : y)
        return base[cy &* stride &+ cx]
    }
}
