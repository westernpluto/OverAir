// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol.
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

import Foundation

enum AC4DSP {
    /// Modified Bessel function of the first kind, order 0.
    static func besselI0(_ x: Double) -> Double {
        let q = x * x / 4
        var term = 1.0, sum = 1.0
        var k = 1.0
        while term > sum * 1e-17 && k < 500 {
            term *= q / (k * k)
            sum += term
            k += 1
        }
        return sum
    }

    /// Kaiser-Bessel-derived half window of `n` samples (FFmpeg `avpriv_kbd_window_init`).
    static func kbdWindow(alpha: Double, n: Int) -> [Float] {
        let alpha2 = 4 * (alpha * Double.pi / Double(n)) * (alpha * Double.pi / Double(n))
        var temp = [Double](repeating: 0, count: n / 2 + 1)
        var scale = 0.0
        for i in 0...(n / 2) {
            temp[i] = besselI0(sqrt(alpha2 * Double(i * (n - i))))
            scale += temp[i] * ((i != 0 && i < n / 2) ? 2 : 1)
        }
        scale = 1 / (scale + 1)
        var out = [Float](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            sum += i <= n / 2 ? temp[i] : temp[n - i]
            out[i] = Float(sqrt(sum * scale))
        }
        return out
    }
}

/// Mixed-radix (2, 3, 5) complex FFT with a negative exponent.
final class AC4FFT: @unchecked Sendable {
    let n: Int
    private let factors: [Int]
    private let twRe: [Float]
    private let twIm: [Float]
    private var outRe: [Float]
    private var outIm: [Float]

    init?(n: Int) {
        var f: [Int] = []
        var m = n
        for p in [4, 2, 3, 5] {
            while m % p == 0 { f.append(p); m /= p }
        }
        guard m == 1 else { return nil }
        self.n = n
        factors = f
        twRe = (0..<n).map { Float(cos(-2 * Double.pi * Double($0) / Double(n))) }
        twIm = (0..<n).map { Float(sin(-2 * Double.pi * Double($0) / Double(n))) }
        outRe = [Float](repeating: 0, count: n)
        outIm = [Float](repeating: 0, count: n)
    }

    /// In-place forward transform of `re`/`im` (length `n`).
    func forward(_ re: inout [Float], _ im: inout [Float]) {
        re.withUnsafeBufferPointer { ir in
            im.withUnsafeBufferPointer { ii in
                outRe.withUnsafeMutableBufferPointer { orr in
                    outIm.withUnsafeMutableBufferPointer { oi in
                        twRe.withUnsafeBufferPointer { tr in
                            twIm.withUnsafeBufferPointer { ti in
                                rec(ir.baseAddress!, ii.baseAddress!, 0, 1, n, 0,
                                    orr.baseAddress!, oi.baseAddress!, 0, tr.baseAddress!, ti.baseAddress!)
                            }
                        }
                    }
                }
            }
        }
        for i in 0..<n { re[i] = outRe[i]; im[i] = outIm[i] }
    }

    private func rec(_ inRe: UnsafePointer<Float>, _ inIm: UnsafePointer<Float>, _ inOff: Int, _ stride: Int,
                     _ len: Int, _ fi: Int,
                     _ oRe: UnsafeMutablePointer<Float>, _ oIm: UnsafeMutablePointer<Float>, _ oOff: Int,
                     _ tr: UnsafePointer<Float>, _ ti: UnsafePointer<Float>) {
        if len == 1 {
            oRe[oOff] = inRe[inOff]
            oIm[oOff] = inIm[inOff]
            return
        }
        let p = factors[fi]
        let m = len / p
        for r in 0..<p {
            rec(inRe, inIm, inOff + r * stride, stride * p, m, fi + 1, oRe, oIm, oOff + r * m, tr, ti)
        }
        let step = n / len
        var aRe = (Float(0), Float(0), Float(0), Float(0), Float(0))
        var aIm = aRe
        for k in 0..<m {
            // Twiddled inputs t_r = W_len^(r k) * sub_r[k]
            withUnsafeMutableBytes(of: &aRe) { rawRe in
                withUnsafeMutableBytes(of: &aIm) { rawIm in
                    let tRe = rawRe.bindMemory(to: Float.self)
                    let tIm = rawIm.bindMemory(to: Float.self)
                    for r in 0..<p {
                        let idx = oOff + r * m + k
                        let w = (r * k * step) % n
                        let xr = oRe[idx], xi = oIm[idx]
                        tRe[r] = xr * tr[w] - xi * ti[w]
                        tIm[r] = xr * ti[w] + xi * tr[w]
                    }
                    for q in 0..<p {
                        var sr: Float = 0, si: Float = 0
                        for r in 0..<p {
                            let w = (r * q * m * step) % n
                            sr += tRe[r] * tr[w] - tIm[r] * ti[w]
                            si += tRe[r] * ti[w] + tIm[r] * tr[w]
                        }
                        oRe[oOff + q * m + k] = sr
                        oIm[oOff + q * m + k] = si
                    }
                }
            }
        }
    }
}

/// Inverse MDCT returning the middle half of the output (FFmpeg `av_tx` float MDCT, inverse,
/// with scale 1/N): `out[i] = y[N/2 + i]`, `y[n] = 1/N * sum_k X[k] cos(pi/N (n + 1/2 + N/2)(k + 1/2))`.
final class AC4IMDCT: @unchecked Sendable {
    let n: Int
    private let fft: AC4FFT
    private let preRe: [Float], preIm: [Float]
    private let postRe: [Float], postIm: [Float]
    private var re: [Float], im: [Float]

    init?(n: Int) {
        guard n % 2 == 0, let fft = AC4FFT(n: n / 2) else { return nil }
        self.n = n
        self.fft = fft
        let m = n / 2
        preRe = (0..<m).map { Float(cos(-Double.pi * Double($0) / Double(n))) }
        preIm = (0..<m).map { Float(sin(-Double.pi * Double($0) / Double(n))) }
        postRe = (0..<m).map { Float(cos(-Double.pi * (Double($0) + 0.25) / Double(n))) }
        postIm = (0..<m).map { Float(sin(-Double.pi * (Double($0) + 0.25) / Double(n))) }
        re = [Float](repeating: 0, count: m)
        im = [Float](repeating: 0, count: m)
    }

    /// `input` has N coefficients starting at `inOffset`; writes N samples to `out` at `outOffset`.
    func half(_ input: [Float], inOffset: Int, into out: inout [Float], outOffset: Int) {
        let m = n / 2
        // DCT-IV via an N/2-point complex FFT.
        for k in 0..<m {
            let a = input[inOffset + 2 * k], b = input[inOffset + n - 1 - 2 * k]
            re[k] = a * preRe[k] - b * preIm[k]
            im[k] = a * preIm[k] + b * preRe[k]
        }
        fft.forward(&re, &im)
        let scale = 1 / Float(n)
        for k in 0..<m {
            let yr = re[k] * postRe[k] - im[k] * postIm[k]
            let yi = re[k] * postIm[k] + im[k] * postRe[k]
            // DCT-IV: X[2k] = Re(Y[k]), X[N-1-2k] = -Im(Y[k]); output[i] = -X[N-1-i] / N
            out[outOffset + n - 1 - 2 * k] = -yr * scale
            out[outOffset + 2 * k] = yi * scale
        }
    }
}
