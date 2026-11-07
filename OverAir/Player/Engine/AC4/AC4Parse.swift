// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol.
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

import Foundation

enum AC4 {
    static let sfASF = 0, sfSSF = 1
    static let cmSimple = 0, cmASPX = 1, cmASPXACPL1 = 2, cmASPXACPL2 = 3, cmASPXACPL3 = 4
    static let fixfix = 0, fixvar = 1, varfix = 2, varvar = 3
    static let dtSignal = 0, dtNoise = 1
    static let smLevel = 0, smBalance = 1
    static let hcbF0 = 0, hcbDF = 1, hcbDT = 2
    static let acplFull = 0, acplPartial = 1
    static let alpha1 = 0, alpha2 = 1, beta1 = 2, beta2 = 3, beta3 = 4
    static let gamma1 = 5, gamma2 = 6, gamma3 = 7, gamma4 = 8, gamma5 = 9, gamma6 = 10
    static let longStride = 0, shortStride = 1
}

extension AC4Decoder {
    typealias Err = DecodeError

    // MARK: Configuration

    static func sbToPb(_ id: Int, _ band: Int) -> Int {
        let row: Int
        switch band {
        case 0...8: row = band
        case 9...10: row = 9
        case 11...13: row = 10
        case 14...17: row = 11
        case 18...22: row = 12
        case 23...34: row = 13
        case 35...63: row = 14
        default: return 0
        }
        return AC4Tables.qmf_subbands[row][id]
    }

    func acplConfig1ch(_ mode: Int) {
        ss.acplQmfBand = 0
        ss.acplParamBand = 0
        ss.acplNumParamBandsID = br.read(2)
        ss.acplQuantMode[0] = br.readBit()
        if mode == AC4.acplPartial {
            ss.acplQmfBand = br.read(3) + 1
            ss.acplParamBand = Self.sbToPb(ss.acplNumParamBandsID, ss.acplQmfBand)
        }
    }

    func acplConfig2ch() {
        ss.acplQmfBand = 0
        ss.acplParamBand = 0
        ss.acplNumParamBandsID = br.read(2)
        ss.acplQuantMode[0] = br.readBit()
        ss.acplQuantMode[1] = br.readBit()
    }

    func aspxConfig() {
        ss.aspxQuantModeEnv = br.readBit()
        ss.prevAspxStartFreq = ss.aspxStartFreq
        ss.aspxStartFreq = br.read(3)
        ss.prevAspxStopFreq = ss.aspxStopFreq
        ss.aspxStopFreq = br.read(2)
        ss.prevAspxMasterFreqScale = ss.aspxMasterFreqScale
        ss.aspxMasterFreqScale = br.readBit()
        ss.aspxInterpolation = br.readBit()
        ss.aspxPreflat = br.readBit()
        ss.aspxLimiter = br.readBit()
        ss.aspxNoiseSbg = br.read(2)
        ss.aspxNumEnvBitsFixfix = br.readBit()
        ss.aspxFreqResMode = br.read(2)
    }

    // MARK: Transform framing

    var transfLengthTable: [Int] {
        AC4Tables.transf_length_48khz[frameLenBaseIdx]
    }

    func asfTransformInfo(_ c: AC4Channel) {
        if frameLenBase >= 1536 {
            c.scp.longFrame = br.readBit()
            if c.scp.longFrame == 0 {
                c.scp.transfLengthIdx[0] = br.read(2)
                c.scp.transfLengthIdx[1] = br.read(2)
                c.scp.transfLength[0] = transfLengthTable[c.scp.transfLengthIdx[0]]
                c.scp.transfLength[1] = transfLengthTable[c.scp.transfLengthIdx[1]]
            } else {
                c.scp.transfLength[0] = frameLenBase
                c.scp.transfLength[1] = 0
            }
        } else {
            c.scp.longFrame = 0
            c.scp.transfLengthIdx[0] = br.read(2)
            c.scp.transfLength[0] = transfLengthTable[c.scp.transfLengthIdx[0]]
        }
    }

    static func msfblBits(_ l: Int) -> Int { (1536...2048).contains(l) ? 3 : 2 }

    func grpBits(_ c: AC4Channel) -> Int {
        if frameLenBase >= 1536 && c.scp.longFrame == 1 { return 0 }
        if frameLenBase >= 1536 && c.scp.longFrame == 0 {
            return AC4Tables.n_grp_bits_a[c.scp.transfLengthIdx[0]][c.scp.transfLengthIdx[1]]
        }
        if frameLenBase < 1536 && frameLenBase > 512 { return AC4Tables.n_grp_bits_b[c.scp.transfLengthIdx[0]] }
        if frameLenBase <= 512 { return AC4Tables.n_grp_bits_c[c.scp.transfLengthIdx[0]] }
        return 0
    }

    static func msfbBits(_ l: Int) -> Int {
        if (384...2048).contains(l) { return 6 }
        if (192...256).contains(l) { return 5 }
        return 4
    }

    static func sideBits(_ l: Int) -> Int {
        if (480...2048).contains(l) { return 5 }
        if (240...384).contains(l) { return 4 }
        return 3
    }

    func maxSfb(_ c: AC4Channel, _ g: Int) -> Int {
        var idx = 0
        if frameLenBase >= 1536 && c.scp.longFrame == 0 && c.scp.transfLengthIdx[0] != c.scp.transfLengthIdx[1] {
            let numWindows0 = 1 << (3 - c.scp.transfLengthIdx[0])
            if g >= c.scp.windowToGroup[numWindows0] { idx = 1 }
        }
        if c.scp.sideLimited == 1 || (c.scp.dualMaxsfb == 1 && c.scp.sideChannel == 1) {
            return c.scp.maxSfbSide[idx]
        }
        return c.scp.maxSfb[idx]
    }

    /// Transform length of window group `g`, and its index into the length table.
    func transfLength(_ c: AC4Channel, _ g: Int) -> (length: Int, idx: Int) {
        let tab = transfLengthTable
        if frameLenBase >= 1536 {
            if c.scp.longFrame == 0 {
                let numWindows0 = 1 << (3 - c.scp.transfLengthIdx[0])
                if g < c.scp.windowToGroup[numWindows0] {
                    return (tab[c.scp.transfLengthIdx[0]], c.scp.transfLengthIdx[0])
                }
                return (tab[c.scp.transfLengthIdx[1]], c.scp.transfLengthIdx[1])
            }
            return (frameLenBase, 4)
        }
        return (tab[c.scp.transfLengthIdx[0]], c.scp.transfLengthIdx[0])
    }

    static func sfbOffset(_ l: Int) -> [Int] {
        switch l {
        case 2048: return AC4Tables.sfb_offset_48khz_2048
        case 1920: return AC4Tables.sfb_offset_48khz_1920
        case 1536: return AC4Tables.sfb_offset_48khz_1536
        case 1024: return AC4Tables.sfb_offset_48khz_1024
        case 960: return AC4Tables.sfb_offset_48khz_960
        case 768: return AC4Tables.sfb_offset_48khz_768
        case 512: return AC4Tables.sfb_offset_48khz_512
        case 480: return AC4Tables.sfb_offset_48khz_480
        case 384: return AC4Tables.sfb_offset_48khz_384
        case 256: return AC4Tables.sfb_offset_48khz_256
        case 240: return AC4Tables.sfb_offset_48khz_240
        case 192: return AC4Tables.sfb_offset_48khz_192
        case 128: return AC4Tables.sfb_offset_48khz_128
        case 120: return AC4Tables.sfb_offset_48khz_120
        default: return AC4Tables.sfb_offset_48khz_96
        }
    }

    static func numSfb48(_ l: Int) -> Int {
        switch l {
        case 2048: return 63
        case 1920: return 61
        case 1536: return 55
        case 1024, 960: return 49
        case 768: return 43
        case 512, 480: return 36
        case 384: return 33
        case 256, 240: return 20
        case 192: return 18
        case 128, 120: return 14
        default: return 12
        }
    }

    func asfPsyElements(_ c: AC4Channel, _ nGrpBits: Int) throws {
        c.scp.numWindows = 1
        c.scp.numWindowGroups = 1
        c.scp.windowToGroup[0] = 0
        if c.scp.longFrame == 0 {
            c.scp.numWindows = nGrpBits + 1
            if c.scp.differentFraming != 0 {
                let numWindows0 = 1 << (3 - c.scp.transfLengthIdx[0])
                var i = nGrpBits
                while i >= numWindows0 && i >= 1 {
                    c.scp.scaleFactorGrouping[i] = c.scp.scaleFactorGrouping[i - 1]
                    i -= 1
                }
                if numWindows0 >= 1 { c.scp.scaleFactorGrouping[numWindows0 - 1] = 0 }
                c.scp.numWindows += 1
            }
            guard c.scp.numWindows <= 16 else { throw Err.invalid("too many windows") }
            for i in 0..<(c.scp.numWindows - 1) {
                if c.scp.scaleFactorGrouping[i] == 0 { c.scp.numWindowGroups += 1 }
                c.scp.windowToGroup[i + 1] = c.scp.numWindowGroups - 1
            }
        }

        var groupOffset = 0, winOffset = 0, win = 0
        for i in c.offset2sfb.indices { c.offset2sfb[i] = 0; c.offset2g[i] = 0 }
        for g in 0..<c.scp.numWindowGroups {
            let tl = transfLength(c, g).length
            let sfbOffset = Self.sfbOffset(tl)
            let sfbMaxSize = sfbOffset.count
            c.scp.numWinInGroup[g] = 0
            for w in 0..<c.scp.numWindows where c.scp.windowToGroup[w] == g {
                c.scp.numWinInGroup[g] += 1
            }
            let mx = maxSfb(c, g)
            guard mx < sfbMaxSize, mx < 128 else { throw Err.invalid("max_sfb \(mx) > \(sfbMaxSize)") }
            for sfb in 0..<mx {
                c.sectSfbOffset[g, sfb] = groupOffset + sfbOffset[sfb] * c.scp.numWinInGroup[g]
            }
            groupOffset += sfbOffset[mx] * c.scp.numWinInGroup[g]
            c.sectSfbOffset[g, mx] = groupOffset
            guard groupOffset <= 2048 else { throw Err.invalid("spectrum too long") }
            for sfb in 0..<mx {
                for j in c.sectSfbOffset[g, sfb]..<c.sectSfbOffset[g, sfb + 1] {
                    c.offset2sfb[j] = sfb
                    c.offset2g[j] = g
                }
            }
            for w in 0..<c.scp.numWinInGroup[g] where win + w < 16 {
                c.winOffset[win + w] = winOffset
                winOffset += tl
            }
            win += c.scp.numWinInGroup[g]
        }
    }

    func asfPsyInfo(_ c: AC4Channel, dualMaxsfb: Int, sideLimited: Int) throws {
        var nSideBits = Self.sideBits(c.scp.transfLength[0])
        var nMsfbBits = Self.msfbBits(c.scp.transfLength[0])
        let nGrpBits = grpBits(c)
        c.scp.differentFraming = 0
        if frameLenBase >= 1536 && c.scp.longFrame == 0 && c.scp.transfLengthIdx[0] != c.scp.transfLengthIdx[1] {
            c.scp.differentFraming = 1
        }
        if sideLimited != 0 {
            c.scp.maxSfbSide[0] = br.read(nSideBits)
        } else {
            c.scp.maxSfb[0] = br.read(nMsfbBits)
            if dualMaxsfb != 0 { c.scp.maxSfbSide[0] = br.read(nMsfbBits) }
        }
        if c.scp.differentFraming != 0 {
            nSideBits = Self.sideBits(c.scp.transfLength[1])
            nMsfbBits = Self.msfbBits(c.scp.transfLength[1])
            if sideLimited != 0 {
                c.scp.maxSfbSide[1] = br.read(nSideBits)
            } else {
                c.scp.maxSfb[1] = br.read(nMsfbBits)
                if dualMaxsfb != 0 { c.scp.maxSfbSide[1] = br.read(nMsfbBits) }
            }
        }
        for i in c.scp.scaleFactorGrouping.indices { c.scp.scaleFactorGrouping[i] = 0 }
        for i in 0..<min(nGrpBits, 15) { c.scp.scaleFactorGrouping[i] = br.readBit() }
        try asfPsyElements(c, nGrpBits)
    }

    func sfInfo(_ c: AC4Channel, frontend: Int, dualMaxsfb: Int, sideLimited: Int) throws {
        c.scp.dualMaxsfb = dualMaxsfb
        c.scp.sideLimited = sideLimited
        if frontend == AC4.sfASF {
            asfTransformInfo(c)
            try asfPsyInfo(c, dualMaxsfb: dualMaxsfb, sideLimited: sideLimited)
        }
    }

    // MARK: Stereo audio processing parameters

    func sapData(_ c: AC4Channel) throws {
        if br.readBit() == 0 {
            for g in 0..<c.scp.numWindowGroups {
                let mx = maxSfb(c, g)
                var sfb = 0
                while sfb < mx {
                    c.sapCoeffUsed[g, sfb] = br.readBit()
                    if sfb + 1 < mx { c.sapCoeffUsed[g, sfb + 1] = c.sapCoeffUsed[g, sfb] }
                    sfb += 2
                }
            }
        } else {
            for g in 0..<c.scp.numWindowGroups {
                for sfb in 0..<maxSfb(c, g) { c.sapCoeffUsed[g, sfb] = 1 }
            }
        }
        c.deltaCodeTime = 0
        if c.scp.numWindowGroups != 1 { c.deltaCodeTime = br.readBit() }
        for g in 0..<c.scp.numWindowGroups {
            let mx = maxSfb(c, g)
            var sfb = 0
            while sfb < mx {
                if c.sapCoeffUsed[g, sfb] != 0 {
                    let v = AC4Codebooks.scaleFactors.decode(&br)
                    guard v >= 0 else { throw Err.invalid("sap data") }
                    c.dpcmAlphaQ[g, sfb] = v
                }
                sfb += 2
            }
        }
    }

    func chparamInfo(_ c: AC4Channel) throws {
        c.sapMode = br.read(2)
        if c.sapMode == 1 {
            for g in 0..<c.scp.numWindowGroups {
                for sfb in 0..<maxSfb(c, g) { c.msUsed[g, sfb] = br.readBit() }
            }
        }
        if c.sapMode == 3 { try sapData(c) }
    }

    // MARK: Speech spectral front end (parsed, not synthesised)

    func ssfStData(_ c: AC4Channel, iframe: Int) {
        c.envIdx[0] = br.read(5)
        if iframe == 1 && c.strideFlag == AC4.shortStride { _ = br.read(5) }
        if c.strideFlag == AC4.shortStride {
            for block in 0..<4 { c.gainBits[block] = br.read(4) }
        }
        let numBlocks = c.strideFlag == AC4.shortStride ? 4 : 1
        for block in 0..<numBlocks {
            if block >= c.startBlock && block < c.endBlock && c.predictorPresence[block] != 0 {
                if c.delta[block] != 0 {
                    c.predictorLagDelta[block] = br.read(4)
                } else {
                    c.predictorLag[block] = br.read(9)
                }
            }
            c.variancePreserving[block] = br.readBit()
            c.allocOffset[block] = br.read(5)
        }
    }

    func ssfACData(_ c: AC4Channel) {
        // ac_init
        c.acs.low = 0
        c.acs.range = 1 << 29
        c.acs.offset = UInt32(br.readBit())
        for _ in 1..<30 { c.acs.offset = (c.acs.offset << 1) &+ UInt32(br.readBit()) }
        c.acs.offset2 = c.acs.offset
        // ac_decode_finish (no symbols are decoded in the reference implementation)
        c.acs.low = c.acs.offset & ((1 << 29) - 1)
        c.acs.low = c.acs.low &+ ((1 << 29) &- c.acs.offset)
    }

    func ssfGranule(_ c: AC4Channel, iframe: Int) {
        c.strideFlag = br.readBit()
        if iframe != 0 { c.numBands = br.read(3) + 12 }
        c.startBlock = 0
        c.endBlock = 0
        if c.strideFlag == AC4.longStride && iframe == 0 { c.endBlock = 1 }
        if c.strideFlag == AC4.shortStride {
            c.endBlock = 4
            if iframe != 0 { c.startBlock = 1 }
        }
        if c.startBlock < c.endBlock {
            for block in c.startBlock..<c.endBlock {
                c.predictorPresence[block] = br.readBit()
                if c.predictorPresence[block] != 0 {
                    c.delta[block] = (c.startBlock == 1 && block == 1) ? 0 : br.readBit()
                }
            }
        }
        ssfStData(c, iframe: iframe)
        ssfACData(c)
    }

    func ssfData(_ c: AC4Channel, iframe: Int) {
        let ssfIframe = iframe != 0 ? 1 : br.readBit()
        ssfGranule(c, iframe: ssfIframe)
        if frameLenBase >= 1536 { ssfGranule(c, iframe: 0) }
    }

    // MARK: Audio spectral front end

    func asfSectionData(_ c: AC4Channel) throws {
        c.sectCb.fill(0)
        c.sfbCb.fill(0)
        for g in 0..<c.scp.numWindowGroups {
            let (tl, gidx) = transfLength(c, g)
            let nSectBits = gidx <= 2 ? 3 : 5
            let sectEscVal = (1 << nSectBits) - 1
            let nsfb = Self.numSfb48(tl)
            var k = 0, i = 0
            c.numSecLsf[g] = 0
            let mx = maxSfb(c, g)
            while k < mx {
                guard i < 126 else { throw Err.invalid("too many sections") }
                c.sectCb[g, i] = br.read(4)
                guard c.sectCb[g, i] <= 11 else { throw Err.invalid("sect_cb > 11") }
                var sectLen = 1
                var incr = br.read(nSectBits)
                while incr == sectEscVal {
                    sectLen += sectEscVal
                    incr = br.read(nSectBits)
                    guard !br.overrun else { throw Err.invalid("section overrun") }
                }
                sectLen += incr
                guard k + sectLen <= 128 else { throw Err.invalid("section too long") }
                c.sectStart[g, i] = k
                c.sectEnd[g, i] = k + sectLen
                if c.sectStart[g, i] < nsfb && c.sectEnd[g, i] >= nsfb {
                    c.numSecLsf[g] = i + 1
                    if c.sectEnd[g, i] > nsfb {
                        c.sectEnd[g, i] = nsfb
                        i += 1
                        c.sectStart[g, i] = nsfb
                        c.sectEnd[g, i] = k + sectLen
                        c.sectCb[g, i] = c.sectCb[g, i - 1]
                    }
                }
                for sfb in k..<(k + sectLen) { c.sfbCb[g, sfb] = c.sectCb[g, i] }
                k += sectLen
                i += 1
            }
            c.numSec[g] = i
            if c.numSecLsf[g] == 0 { c.numSecLsf[g] = c.numSec[g] }
        }
    }

    func extDecode() -> Int {
        var nExt = 0
        while br.readBit() == 1 && nExt < 16 { nExt += 1 }
        let v = br.read(nExt + 4)
        return (1 << (nExt + 4)) + v
    }

    func asfSpectralData(_ c: AC4Channel) throws {
        c.maxQuantIdx.fill(0)
        for i in c.quantSpec.indices { c.quantSpec[i] = 0 }
        for g in 0..<c.scp.numWindowGroups {
            for i in 0..<c.numSecLsf[g] {
                let sc = c.sectCb[g, i]
                if sc == 0 || sc > 11 { continue }
                let startLine = c.sectSfbOffset[g, c.sectStart[g, i]]
                let endLine = min(c.sectSfbOffset[g, c.sectEnd[g, i]], 2048)
                let cb = sc - 1
                let off = AC4Tables.asf_codebook_off[cb]
                let mod = AC4Tables.asf_codebook_mod[cb]
                let unsigned = AC4Tables.asf_codebook_unsigned[cb] != 0
                let vlc = AC4Codebooks.asf[cb]
                var k = startLine
                while k < endLine {
                    if AC4Tables.asf_codebook_dim[cb] == 4 {
                        var idx = vlc.decode(&br)
                        guard idx >= 0 else { throw Err.invalid("codebook dim 4") }
                        var q = [0, 0, 0, 0]
                        q[0] = idx / 27 - off; idx -= (q[0] + off) * 27
                        q[1] = idx / 9 - off; idx -= (q[1] + off) * 9
                        q[2] = idx / mod - off; idx -= (q[2] + off) * mod
                        q[3] = idx - off
                        for j in 0..<4 {
                            if unsigned && q[j] != 0 && br.readBit() == 1 { q[j] = -q[j] }
                            c.quantSpec[k + j] = q[j]
                            let x = c.offset2sfb[k + j]
                            c.maxQuantIdx[g, x] = max(c.maxQuantIdx[g, x], abs(q[j]))
                        }
                        k += 4
                    } else {
                        var idx = vlc.decode(&br)
                        guard idx >= 0 else { throw Err.invalid("codebook dim 2") }
                        var q0 = idx / mod - off
                        idx -= (q0 + off) * mod
                        var q1 = idx - off
                        var sign0 = false, sign1 = false
                        if unsigned {
                            if q0 != 0 && br.readBit() == 1 { sign0 = true }
                            if q1 != 0 && br.readBit() == 1 { sign1 = true }
                        }
                        if sc == 11 {
                            if q0 == 16 { q0 = extDecode() }
                            if q1 == 16 { q1 = extDecode() }
                        }
                        if sign0 { q0 = -q0 }
                        if sign1 { q1 = -q1 }
                        c.quantSpec[k] = q0
                        c.quantSpec[k + 1] = q1
                        var x = c.offset2sfb[k]
                        c.maxQuantIdx[g, x] = max(c.maxQuantIdx[g, x], abs(q0))
                        x = c.offset2sfb[k + 1]
                        c.maxQuantIdx[g, x] = max(c.maxQuantIdx[g, x], abs(q1))
                        k += 2
                    }
                }
            }
        }
    }

    func asfScalefacData(_ c: AC4Channel) throws {
        var firstFound = false
        var scaleFactor = br.read(8)
        c.sfGain.fill(0)
        for g in 0..<c.scp.numWindowGroups {
            let mx = min(maxSfb(c, g), Self.numSfb48(transfLength(c, g).length))
            for sfb in 0..<mx where c.sfbCb[g, sfb] != 0 && c.maxQuantIdx[g, sfb] > 0 {
                if firstFound {
                    let d = AC4Codebooks.scaleFactors.decode(&br)
                    guard d >= 0 else { throw Err.invalid("scale factor") }
                    c.dpcmSf[g, sfb] = d
                    scaleFactor += d - 60
                } else {
                    firstFound = true
                }
                c.sfGain[g, sfb] = powf(2, 0.25 * Float(scaleFactor - 100))
            }
        }
    }

    func asfSnfData(_ c: AC4Channel) throws {
        c.snfDataExists = br.readBit()
        guard c.snfDataExists != 0 else { return }
        for g in 0..<c.scp.numWindowGroups {
            let mx = min(maxSfb(c, g), Self.numSfb48(transfLength(c, g).length))
            for sfb in 0..<mx where c.sfbCb[g, sfb] == 0 || c.maxQuantIdx[g, sfb] == 0 {
                let d = AC4Codebooks.snf.decode(&br)
                guard d >= 0 else { throw Err.invalid("snf data") }
                c.dpcmSnf[g, sfb] = d
            }
        }
    }

    func sfData(_ c: AC4Channel, iframe: Int, frontend: Int) throws {
        if frontend == AC4.sfASF {
            try asfSectionData(c)
            try asfSpectralData(c)
            try asfScalefacData(c)
            try asfSnfData(c)
        } else {
            ssfData(c, iframe: iframe)
            usesSpeechFrontend = true
        }
    }

    // MARK: Channel elements

    func stereoData(iframe: Int) throws {
        let c0 = ss.ssch[0], c1 = ss.ssch[1]
        ss.mdctStereoProc[0] = br.readBit()
        if ss.mdctStereoProc[0] != 0 {
            ss.specFrontendL = AC4.sfASF
            ss.specFrontendR = AC4.sfASF
            try sfInfo(c0, frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
            c1.copyFraming(from: c0)
            try chparamInfo(c0)
        } else {
            ss.specFrontendL = br.readBit()
            try sfInfo(c0, frontend: ss.specFrontendL, dualMaxsfb: 0, sideLimited: 0)
            ss.specFrontendR = br.readBit()
            try sfInfo(c1, frontend: ss.specFrontendR, dualMaxsfb: 0, sideLimited: 0)
        }
        try sfData(c0, iframe: iframe, frontend: ss.specFrontendL)
        try sfData(c1, iframe: iframe, frontend: ss.specFrontendR)
    }

    func compandingControl(_ numChan: Int) {
        let sync = numChan > 1 ? br.readBit() : 0
        let nc = sync != 0 ? 1 : numChan
        var needAvg = false
        for i in 0..<nc {
            ss.compandOn[i] = br.readBit()
            if ss.compandOn[i] == 0 { needAvg = true }
        }
        if needAvg { ss.compandAvg = br.readBit() }
    }

    func channelPairElement(iframe: Int) throws {
        let c0 = ss.ssch[0], c1 = ss.ssch[1]
        ss.codecMode = br.read(2)
        if iframe != 0 {
            if ss.codecMode != AC4.cmSimple { aspxConfig() }
            if ss.codecMode == AC4.cmASPXACPL1 { acplConfig1ch(AC4.acplPartial) }
            if ss.codecMode == AC4.cmASPXACPL2 { acplConfig1ch(AC4.acplFull) }
        }
        switch ss.codecMode {
        case AC4.cmSimple:
            try stereoData(iframe: iframe)
        case AC4.cmASPX:
            compandingControl(2)
            try stereoData(iframe: iframe)
            try aspxData2ch(c0, c1, iframe: iframe)
        case AC4.cmASPXACPL1:
            compandingControl(1)
            ss.mdctStereoProc[0] = br.readBit()
            if ss.mdctStereoProc[0] != 0 {
                ss.specFrontendM = AC4.sfASF
                ss.specFrontendS = AC4.sfASF
                try sfInfo(c0, frontend: AC4.sfASF, dualMaxsfb: 1, sideLimited: 0)
                c1.copyFraming(from: c0)
                try chparamInfo(c0)
            } else {
                ss.specFrontendM = br.readBit()
                try sfInfo(c0, frontend: ss.specFrontendM, dualMaxsfb: 0, sideLimited: 0)
                ss.specFrontendS = br.readBit()
                try sfInfo(c1, frontend: ss.specFrontendS, dualMaxsfb: 0, sideLimited: 1)
            }
            try sfData(c0, iframe: iframe, frontend: ss.specFrontendM)
            try sfData(c1, iframe: iframe, frontend: ss.specFrontendM)
            try aspxData1ch(c0, iframe: iframe)
            try acplData1ch(c0)
        case AC4.cmASPXACPL2:
            compandingControl(1)
            let fe = br.readBit()
            try sfInfo(c0, frontend: fe, dualMaxsfb: 0, sideLimited: 0)
            try sfData(c0, iframe: iframe, frontend: fe)
            try aspxData1ch(c0, iframe: iframe)
            try acplData1ch(c0)
        default:
            throw Err.invalid("codec mode")
        }
    }

    func fourChannelData(iframe: Int) throws {
        try sfInfo(ss.ssch[0], frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
        for i in 1..<4 { ss.ssch[i].copyFraming(from: ss.ssch[0]) }
        for i in 0..<4 { try chparamInfo(ss.ssch[i]) }
        for i in 0..<4 { try sfData(ss.ssch[i], iframe: iframe, frontend: AC4.sfASF) }
    }

    func fiveChannelData(iframe: Int) throws {
        try sfInfo(ss.ssch[0], frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
        for i in 1..<5 { ss.ssch[i].copyFraming(from: ss.ssch[0]) }
        ss.chelMatsel = br.read(4)
        for i in 0..<5 { try chparamInfo(ss.ssch[i]) }
        for i in 0..<5 { try sfData(ss.ssch[i], iframe: iframe, frontend: AC4.sfASF) }
    }

    func sfInfoLFE(_ c: AC4Channel) throws {
        let nMsfblBits = Self.msfblBits(frameLenBase)
        let nGrpBits = grpBits(c)
        c.scp.longFrame = 1
        c.scp.maxSfb[0] = br.read(nMsfblBits)
        c.scp.numWindowGroups = 1
        c.scp.transfLengthIdx[0] = 4
        c.scp.sideLimited = 0
        c.scp.dualMaxsfb = 0
        try asfPsyElements(c, nGrpBits)
    }

    func monoData(_ c: AC4Channel, lfe: Bool, iframe: Int) throws {
        let fe: Int
        if lfe {
            fe = AC4.sfASF
            try sfInfoLFE(c)
        } else {
            fe = br.readBit()
            try sfInfo(c, frontend: fe, dualMaxsfb: 0, sideLimited: 0)
        }
        try sfData(c, iframe: iframe, frontend: fe)
    }

    func threeChannelData(_ c0: AC4Channel, _ c1: AC4Channel, _ c2: AC4Channel) throws {
        try sfInfo(c0, frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
        c1.copyFraming(from: c0)
        c2.copyFraming(from: c0)
        ss.chelMatsel = br.read(4)
        try chparamInfo(c0)
        try chparamInfo(c1)
        try sfData(c0, iframe: 0, frontend: AC4.sfASF)
        try sfData(c1, iframe: 0, frontend: AC4.sfASF)
        try sfData(c2, iframe: 0, frontend: AC4.sfASF)
    }

    func twoChannelData(_ c0: AC4Channel, _ c1: AC4Channel, _ x: Int) throws {
        guard br.bitsLeft > 0 else { throw Err.invalid("two channel data underflow") }
        ss.mdctStereoProc[x] = br.readBit()
        if ss.mdctStereoProc[x] != 0 {
            try sfInfo(c0, frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
            c1.copyFraming(from: c0)
            try chparamInfo(c0)
        } else {
            try sfInfo(c0, frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
            try sfInfo(c1, frontend: AC4.sfASF, dualMaxsfb: 0, sideLimited: 0)
        }
        try sfData(c0, iframe: 0, frontend: AC4.sfASF)
        try sfData(c1, iframe: 0, frontend: AC4.sfASF)
    }

    func channelElement3x(iframe: Int) throws {
        ss.codecMode = br.readBit()
        if ss.codecMode == AC4.cmASPX {
            if iframe != 0 { aspxConfig() }
            compandingControl(3)
        }
        ss.codingConfig = br.readBit()
        if ss.codingConfig == 0 {
            try stereoData(iframe: iframe)
            try monoData(ss.ssch[2], lfe: false, iframe: iframe)
        } else {
            try threeChannelData(ss.ssch[0], ss.ssch[1], ss.ssch[2])
        }
        if ss.codecMode == AC4.cmASPX {
            try aspxData2ch(ss.ssch[0], ss.ssch[1], iframe: iframe)
            try aspxData1ch(ss.ssch[2], iframe: iframe)
        }
    }

    func channelElement5x(lfe: Bool, iframe: Int) throws {
        let c = ss.ssch
        ss.codecMode = br.read(3)
        if iframe != 0 {
            if ss.codecMode != AC4.cmSimple { aspxConfig() }
            if ss.codecMode == AC4.cmASPXACPL1 { acplConfig1ch(AC4.acplPartial) }
            if ss.codecMode == AC4.cmASPXACPL2 { acplConfig1ch(AC4.acplFull) }
            if ss.codecMode == AC4.cmASPXACPL3 { acplConfig2ch() }
        }
        if lfe { try monoData(c[5], lfe: true, iframe: iframe) }
        switch ss.codecMode {
        case AC4.cmSimple, AC4.cmASPX:
            if ss.codecMode == AC4.cmASPX { compandingControl(5) }
            ss.codingConfig = br.read(2)
            switch ss.codingConfig {
            case 0:
                ss.mode2ch = br.readBit()
                try twoChannelData(c[0], c[1], 0)
                try twoChannelData(c[2], c[3], 1)
                try monoData(c[4], lfe: false, iframe: iframe)
            case 1:
                try threeChannelData(c[0], c[1], c[2])
                try twoChannelData(c[3], c[4], 0)
            case 2:
                try fourChannelData(iframe: iframe)
                try monoData(c[4], lfe: false, iframe: iframe)
            default:
                try fiveChannelData(iframe: iframe)
            }
            if ss.codecMode == AC4.cmASPX {
                try aspxData2ch(c[0], c[1], iframe: iframe)
                try aspxData2ch(c[2], c[3], iframe: iframe)
                try aspxData1ch(c[4], iframe: iframe)
            }
        case AC4.cmASPXACPL1, AC4.cmASPXACPL2:
            compandingControl(3)
            ss.codingConfig = br.readBit()
            if ss.codingConfig != 0 {
                try threeChannelData(c[0], c[1], c[2])
            } else {
                try twoChannelData(c[0], c[1], 0)
            }
            if ss.codecMode == AC4.cmASPXACPL1 {
                ss.maxSfbMaster = br.read(5)
                try chparamInfo(c[3])
                try chparamInfo(c[4])
                try sfData(c[3], iframe: iframe, frontend: AC4.sfASF)
                try sfData(c[4], iframe: iframe, frontend: AC4.sfASF)
            }
            if ss.codingConfig == 0 { try monoData(c[2], lfe: false, iframe: iframe) }
            try aspxData2ch(c[0], c[1], iframe: iframe)
            try aspxData1ch(c[2], iframe: iframe)
            try acplData1ch(c[0])
            try acplData1ch(c[1])
        case AC4.cmASPXACPL3:
            compandingControl(2)
            try stereoData(iframe: iframe)
            try aspxData2ch(c[0], c[1], iframe: iframe)
            try acplData2ch(c[0], c[1])
        default:
            throw Err.invalid("codec mode \(ss.codecMode)")
        }
    }

    func channelElement7x(channelMode: Int, iframe: Int) throws {
        ss.codecMode = br.read(2)
        if iframe != 0 {
            if ss.codecMode != AC4.cmSimple { aspxConfig() }
            if ss.codecMode == AC4.cmASPXACPL1 { acplConfig1ch(AC4.acplPartial) }
            if ss.codecMode == AC4.cmASPXACPL2 { acplConfig1ch(AC4.acplFull) }
        }
        if channelMode == 6 { try monoData(ss.ssch[7], lfe: true, iframe: iframe) }
        if ss.codecMode == AC4.cmASPXACPL1 || ss.codecMode == AC4.cmASPXACPL2 { compandingControl(5) }
        ss.codingConfig = br.read(2)
        switch ss.codingConfig {
        case 2: try fourChannelData(iframe: iframe)
        case 3: try fiveChannelData(iframe: iframe)
        default: break
        }
    }

    func singleChannelElement(iframe: Int) throws {
        ss.codecMode = br.readBit()
        if iframe != 0 && ss.codecMode == AC4.cmASPX { aspxConfig() }
        if ss.codecMode == AC4.cmSimple {
            try monoData(ss.ssch[0], lfe: false, iframe: iframe)
        } else {
            compandingControl(1)
            try monoData(ss.ssch[0], lfe: false, iframe: iframe)
            try aspxData1ch(ss.ssch[0], iframe: iframe)
        }
    }

    func audioData(channelMode: Int, iframe: Int) throws {
        switch channelMode {
        case 0: try singleChannelElement(iframe: iframe)
        case 1: try channelPairElement(iframe: iframe)
        case 2: try channelElement3x(iframe: iframe)
        case 3: try channelElement5x(lfe: false, iframe: iframe)
        case 4: try channelElement5x(lfe: true, iframe: iframe)
        case 5, 6: try channelElement7x(channelMode: channelMode, iframe: iframe)
        default: throw Err.invalid("channel mode \(channelMode) is not supported")
        }
    }

    /// Parses one audio substream (`ac4_substream`). Returns false if the audio data didn't
    /// end where its declared size says it should.
    func substream(channelMode: Int, iframe: Int) throws {
        var audioSize = br.read(15)
        if br.readBit() == 1 { audioSize += br.ac4Variable(7) << 15 }
        guard audioSize <= 131072 else { throw Err.invalid("audio size \(audioSize)") }
        br.bitPos = (br.bitPos + 7) & ~7
        let start = br.bitPos >> 3
        try audioData(channelMode: channelMode, iframe: iframe)
        br.bitPos = (br.bitPos + 7) & ~7
        let consumed = (br.bitPos >> 3) - start
        lastAudioSize = audioSize
        lastConsumed = consumed
        if consumed > audioSize { throw Err.invalid("substream overread by \(consumed - audioSize) bytes") }
    }
}
