// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol.
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

import Foundation

/// Lookup tables shared by every decoder instance.
enum AC4Synth {
    static let quantLUT: [Float] = (0..<8192).map { powf(Float($0), 4.0 / 3.0) }

    /// KBD half windows, [frame length index][transform length index].
    static let kbdWindows: [[[Float]]] = (0..<8).map { j in
        (0..<5).map { i in
            let n = AC4Tables.transf_length_48khz[j][i]
            let alpha = Double(AC4Tables.kbd_window_alpha[j][i])
            return alpha > 0 ? AC4DSP.kbdWindow(alpha: alpha, n: n) : [Float](repeating: 1, count: n)
        }
    }

    private static let imdctLock = NSLock()
    nonisolated(unsafe) private static var imdcts: [Int: AC4IMDCT] = [:]

    static func imdct(_ n: Int) -> AC4IMDCT? {
        imdctLock.lock(); defer { imdctLock.unlock() }
        if let m = imdcts[n] { return m }
        let m = AC4IMDCT(n: n)
        imdcts[n] = m
        return m
    }
}

extension AC4Decoder {
    // MARK: Spectrum

    func spectralReordering(_ c: AC4Channel) {
        var k = 0, win = 0
        for i in c.specReord.indices { c.specReord[i] = 0 }
        for g in 0..<c.scp.numWindowGroups {
            let tl = transfLength(c, g).length
            let sfbOffset = Self.sfbOffset(tl)
            let mx = min(maxSfb(c, g), sfbOffset.count - 1)
            for sfb in 0..<mx {
                for w in 0..<c.scp.numWinInGroup[g] {
                    let base = c.winOffset[min(win + w, 16)]
                    for l in sfbOffset[sfb]..<sfbOffset[sfb + 1] where k < 2048 && base + l < 2048 {
                        c.specReord[base + l] = c.scaledSpec[k]
                        k += 1
                    }
                }
            }
            win += c.scp.numWinInGroup[g]
        }
    }

    func scaleSpec(_ c: AC4Channel) {
        let lut = AC4Synth.quantLUT
        for k in 0..<2048 { c.scaledSpec[k] = 0 }
        for k in 0..<frameLenBase {
            let x = c.quantSpec[k]
            guard x != 0 else { continue }
            let a = abs(x)
            let mag = a < 8192 ? lut[a] : powf(Float(a), 4.0 / 3.0)
            c.scaledSpec[k] = c.sfGain[c.offset2g[k], c.offset2sfb[k]] * (x < 0 ? -mag : mag)
        }
    }

    // MARK: Stereo audio processing (TS 103 190-1 5.3.2)

    func twoChannelProcessing(_ c0: AC4Channel, _ c1: AC4Channel) {
        ss.alphaQ.fill(0)
        var maxSfbPrev = maxSfb(c0, 0)
        for g in 0..<c0.scp.numWindowGroups {
            let mx = maxSfb(c0, g)
            for sfb in 0..<min(mx, 128) {
                var m: (Float, Float, Float, Float)
                if c0.sapMode == 0 || (c0.sapMode == 1 && c0.msUsed[g, sfb] == 0) {
                    m = (1, 0, 0, 1)
                } else if c0.sapMode == 2 || (c0.sapMode == 1 && c0.msUsed[g, sfb] == 1) {
                    m = (1, 1, 1, -1)
                } else if c0.sapCoeffUsed[g, sfb] != 0 {
                    if sfb & 1 != 0 {
                        ss.alphaQ[g, sfb] = ss.alphaQ[g, sfb - 1]
                    } else {
                        let delta = Float(c0.dpcmAlphaQ[g, sfb] - 60)
                        let codeDelta = (g == 0 || mx != maxSfbPrev) ? 0 : c0.deltaCodeTime
                        if codeDelta != 0 {
                            ss.alphaQ[g, sfb] = ss.alphaQ[g - 1, sfb] + delta
                        } else if sfb == 0 {
                            ss.alphaQ[g, sfb] = delta
                        } else {
                            ss.alphaQ[g, sfb] = ss.alphaQ[g, sfb - 2] + delta
                        }
                    }
                    let gain = ss.alphaQ[g, sfb] * 0.1
                    m = (1 + gain, 1, 1 - gain, -1)
                } else {
                    m = (1, 0, 0, 1)
                }
                let base = (g * 128 + sfb) * 4
                ss.matrixStereo[base] = m.0
                ss.matrixStereo[base + 1] = m.1
                ss.matrixStereo[base + 2] = m.2
                ss.matrixStereo[base + 3] = m.3
            }
            maxSfbPrev = mx
        }
        for k in 0..<frameLenBase {
            let base = (c0.offset2g[k] * 128 + c0.offset2sfb[k]) * 4
            let a = ss.matrixStereo[base], b = ss.matrixStereo[base + 1]
            let c = ss.matrixStereo[base + 2], d = ss.matrixStereo[base + 3]
            let i0 = c0.scaledSpec[k], i1 = c1.scaledSpec[k]
            c0.scaledSpec[k] = i0 * a + i1 * b
            c1.scaledSpec[k] = i0 * c + i1 * d
        }
    }

    // MARK: Inverse transform with block switching (TS 103 190-1 5.5)

    func computeWindow(_ w: inout [Float], _ N: Int, _ NPrev: Int, dir: Int) {
        let lengths = AC4Tables.transf_length_48khz[frameLenBaseIdx]
        let Nw = min(N, NPrev)
        let idx = lengths.firstIndex(of: Nw) ?? 4
        let nSkip = (N - Nw) / 2
        let kernel = AC4Synth.kbdWindows[frameLenBaseIdx][idx]
        for n in 0..<N {
            if n < nSkip {
                w[n] = Float(dir)
            } else if n < Nw + nSkip {
                w[n] = dir == 0 ? kernel[n - nSkip] : kernel[Nw - n + nSkip - 1]
            } else {
                w[n] = Float(1 - dir)
            }
        }
    }

    func spectralSynthesis(_ c: AC4Channel) {
        let nFull = frameLenBase
        var win = 0
        for g in 0..<c.scp.numWindowGroups {
            let N = transfLength(c, g).length
            if c.nPrev == 0 { c.nPrev = nFull }
            computeWindow(&winl, N, c.nPrev, dir: 0)
            computeWindow(&winr, c.nPrev, N, dir: 1)
            guard let imdct = AC4Synth.imdct(N) else { continue }
            for w in 0..<c.scp.numWinInGroup[g] {
                let nSkip = (nFull - N) / 2
                let nSkipPrev = (nFull - c.nPrev) / 2
                let off = c.winOffset[min(win + w, 16)]
                guard off + N <= 2048 else { continue }
                imdct.half(c.specReord, inOffset: off, into: &xbuf, outOffset: N / 2)
                for n in 0..<(N / 2) {
                    xbuf[n] = -xbuf[N - n - 1]
                    xbuf[N * 2 - n - 1] = xbuf[N + n]
                }
                for n in 0..<N { xbuf[n] *= winl[n] }
                for n in 0..<c.nPrev { c.overlap[nSkipPrev + n] *= winr[n] }
                for n in 0..<N { c.overlap[nSkip + n] += xbuf[n] }
                for n in 0..<N { c.pcm[off + n] = c.overlap[n] }
                for n in 0..<nSkip { c.overlap[n] = c.overlap[N + n] }
                for n in 0..<N { c.overlap[nSkip + n] = xbuf[N + n] }
            }
            c.nPrev = N
            win += c.scp.numWinInGroup[g]
        }
    }

    // MARK: Frame

    /// Track index for each output speaker (L, R, C, LFE, Ls, Rs), or nil if absent.
    func outputMap(channelMode: Int) -> [Int?] {
        switch channelMode {
        case 0: return [0, nil, nil, nil, nil, nil]
        case 1: return [0, 1, nil, nil, nil, nil]
        case 2: return [0, 1, 2, nil, nil, nil]
        default:
            let lfe: Int? = channelMode == 4 ? 5 : nil
            switch ss.codingConfig {
            case 0:
                return ss.mode2ch == 0 ? [0, 1, 4, lfe, 2, 3] : [0, 2, 4, lfe, 1, 3]
            case 1: return [0, 1, 2, lfe, 3, 4]
            case 2: return [0, 1, 4, lfe, 2, 3]
            default: return [0, 1, 2, lfe, 3, 4]
            }
        }
    }
}
