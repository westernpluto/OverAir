// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol.
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

import Foundation

extension AC4Decoder {
    // MARK: A-SPX framing

    static func noiseMidBorder(_ tsgPtr: Int, _ intClass: Int, _ numAtsgSig: Int) -> Int {
        if tsgPtr == -1 {
            return intClass == AC4.varfix ? 1 : numAtsgSig - 1
        }
        if intClass == AC4.varfix { return numAtsgSig - 1 }
        return max(1, min(numAtsgSig - 1, tsgPtr))
    }

    func freqRes(_ atsgSig: [Int], _ atsg: Int, _ tsgPtr: Int, _ freqResBits: [Int]) -> Int {
        switch ss.aspxFreqResMode {
        case 0: return freqResBits[atsg]
        case 1: return 0
        case 2:
            if (atsg < tsgPtr && numASPXTimeslots > 8) ||
                Double(atsgSig[atsg + 1] - atsgSig[atsg]) > Double(numASPXTimeslots) / 6.0 + 3.25 {
                return 1
            }
            return 0
        default: return 1
        }
    }

    func tabBorder(_ numAtsg: Int) throws -> [Int] {
        let row: Int
        switch numASPXTimeslots {
        case 6: row = 0
        case 8: row = 1
        case 12: row = 2
        case 15: row = 3
        case 16: row = 4
        default: throw Err.invalid("A-SPX timeslots \(numASPXTimeslots)")
        }
        let t = AC4Tables.tab_border[row][numAtsg >> 1]
        return Array(t.prefix(numAtsg + 1))
    }

    func aspxAtsg(_ c: AC4Channel, iframe: Int) throws {
        let numSig = c.aspxNumEnv
        let numNoise = c.aspxNumNoise
        if c.aspxIntClass == AC4.fixfix {
            let sig = try tabBorder(numSig)
            for i in 0..<sig.count { c.atsgSig[i] = sig[i] }
            let noise = try tabBorder(numNoise)
            for i in 0..<noise.count { c.atsgNoise[i] = noise[i] }
            c.atsgFreqres[0] = freqRes(c.atsgSig, 0, 0, c.aspxFreqRes)
            for a in 1..<max(1, numSig) { c.atsgFreqres[a] = c.atsgFreqres[0] }
        } else {
            switch c.aspxIntClass {
            case AC4.fixvar:
                c.atsgSig[0] = 0
                c.atsgSig[numSig] = c.aspxVarBordRight + numASPXTimeslots
                for t in 0..<c.aspxNumRelRight {
                    c.atsgSig[numSig - t - 1] = c.atsgSig[numSig - t] - c.aspxRelBordRight[t]
                }
            case AC4.varfix:
                c.atsgSig[0] = iframe != 0 ? c.aspxVarBordLeft : c.previousStopPos - numASPXTimeslots
                c.atsgSig[numSig] = numASPXTimeslots
                for t in 0..<c.aspxNumRelLeft {
                    c.atsgSig[t + 1] = c.atsgSig[t] + c.aspxRelBordLeft[t]
                }
            default:
                c.atsgSig[0] = iframe != 0 ? c.aspxVarBordLeft : c.previousStopPos - numASPXTimeslots
                c.atsgSig[numSig] = c.aspxVarBordRight + numASPXTimeslots
                for t in 0..<c.aspxNumRelLeft {
                    c.atsgSig[t + 1] = c.atsgSig[t] + c.aspxRelBordLeft[t]
                }
                for t in 0..<c.aspxNumRelRight {
                    c.atsgSig[numSig - t - 1] = c.atsgSig[numSig - t] - c.aspxRelBordRight[t]
                }
            }
            c.atsgNoise[0] = c.atsgSig[0]
            c.atsgNoise[numNoise] = c.atsgSig[numSig]
            if numNoise > 1 {
                let mid = Self.noiseMidBorder(c.aspxTsgPtr, c.aspxIntClass, numSig)
                guard mid >= 0 && mid <= numSig else { throw Err.invalid("A-SPX noise border") }
                c.atsgNoise[1] = c.atsgSig[mid]
            }
            for a in 0..<numSig {
                c.atsgFreqres[a] = freqRes(c.atsgSig, a, c.aspxTsgPtr, c.aspxFreqRes)
            }
        }
        c.previousStopPos = c.atsgSig[numSig]
        for a in 0..<numSig {
            if c.atsgFreqres[a] != 0 {
                c.numSbgSig[a] = c.numSbgSigHighres
                for i in 0..<24 { c.sbgSig[a, i] = c.sbgSigHighres[i] }
            } else {
                c.numSbgSig[a] = c.numSbgSigLowres
                for i in 0..<24 { c.sbgSig[a, i] = c.sbgSigLowres[i] }
            }
        }
    }

    func aspxFraming(_ c: AC4Channel, iframe: Int) throws {
        c.aspxNumRelLeft = 0
        c.aspxNumRelRight = 0
        c.aspxIntClass = AC4Codebooks.aspxIntClass.decode(&br)
        guard c.aspxIntClass >= 0 else { throw Err.invalid("A-SPX interval class") }
        c.aspxNumEnvPrev = c.aspxNumEnv
        let relBits = 1 + (numASPXTimeslots > 8 ? 1 : 0)
        switch c.aspxIntClass {
        case AC4.fixfix:
            // TS 103 190-1 4.2.12.4: aspx_num_env = 1 << tmp_num_env (the reference decoder used
            // 1 + tmp_num_env, which is wrong for four envelopes).
            c.aspxNumEnv = 1 << br.read(1 + ss.aspxNumEnvBitsFixfix)
            guard c.aspxNumEnv <= 4 else { throw Err.invalid("A-SPX envelopes \(c.aspxNumEnv)") }
            if ss.aspxFreqResMode == 0 { c.aspxFreqRes[0] = br.readBit() }
        case AC4.fixvar:
            c.aspxVarBordRight = br.read(2)
            c.aspxNumRelRight = br.read(relBits)
            for i in 0..<c.aspxNumRelRight { c.aspxRelBordRight[i] = 2 * br.read(relBits) + 2 }
        case AC4.varfix:
            if iframe != 0 { c.aspxVarBordLeft = br.read(2) }
            c.aspxNumRelLeft = br.read(relBits)
            for i in 0..<c.aspxNumRelLeft { c.aspxRelBordLeft[i] = 2 * br.read(relBits) + 2 }
        default:
            if iframe != 0 { c.aspxVarBordLeft = br.read(2) }
            c.aspxNumRelLeft = br.read(relBits)
            for i in 0..<c.aspxNumRelLeft { c.aspxRelBordLeft[i] = 2 * br.read(relBits) + 2 }
            c.aspxVarBordRight = br.read(2)
            c.aspxNumRelRight = br.read(relBits)
            for i in 0..<c.aspxNumRelRight { c.aspxRelBordRight[i] = 2 * br.read(relBits) + 2 }
        }
        if c.aspxIntClass != AC4.fixfix {
            c.aspxNumEnv = c.aspxNumRelLeft + c.aspxNumRelRight + 1
            guard c.aspxNumEnv <= 5 else { throw Err.invalid("A-SPX envelopes \(c.aspxNumEnv)") }
            let ptrBits = Int(ceilf(logf(Float(c.aspxNumEnv + 2)) / logf(2)))
            c.aspxTsgPtrPrev = c.aspxTsgPtr
            c.aspxTsgPtr = br.read(ptrBits) - 1
            if ss.aspxFreqResMode == 0 {
                for env in 0..<c.aspxNumEnv { c.aspxFreqRes[env] = br.readBit() }
            }
        }
        c.aspxNumNoisePrev = c.aspxNumNoise
        c.aspxNumNoise = c.aspxNumEnv > 1 ? 2 : 1
        if c.aspxNumEnvPrev == 0 { c.aspxNumEnvPrev = c.aspxNumEnv }
        if c.aspxNumNoisePrev == 0 { c.aspxNumNoisePrev = c.aspxNumNoise }
        try aspxAtsg(c, iframe: iframe)
    }

    func aspxDeltaDir(_ c: AC4Channel) {
        for env in 0..<c.aspxNumEnv { c.aspxSigDeltaDir[env] = br.readBit() }
        for env in 0..<c.aspxNumNoise { c.aspxNoiseDeltaDir[env] = br.readBit() }
    }

    func aspxHfgenIwc2ch(_ c0: AC4Channel, _ c1: AC4Channel, balance: Int) {
        c0.aspxTnaModePrev = c0.aspxTnaMode
        c1.aspxTnaModePrev = c1.aspxTnaMode
        for n in 0..<c0.numSbgNoise { c0.aspxTnaMode[n] = br.read(2) }
        if balance == 0 {
            for n in 0..<c0.numSbgNoise { c1.aspxTnaMode[n] = br.read(2) }
        } else {
            for n in 0..<c0.numSbgNoise { c1.aspxTnaMode[n] = c0.aspxTnaMode[n] }
        }
        if br.readBit() == 1 {
            for n in 0..<c0.numSbgSigHighres { c0.aspxAddHarmonic[n] = br.readBit() }
        }
        if br.readBit() == 1 {
            for n in 0..<c0.numSbgSigHighres { c1.aspxAddHarmonic[n] = br.readBit() }
        }
        for n in 0..<c0.numSbgSigHighres { c0.aspxFicUsedInSfb[n] = 0; c1.aspxFicUsedInSfb[n] = 0 }
        if br.readBit() == 1 {
            if br.readBit() == 1 {
                for n in 0..<c0.numSbgSigHighres { c0.aspxFicUsedInSfb[n] = br.readBit() }
            }
            if br.readBit() == 1 {
                for n in 0..<c0.numSbgSigHighres { c1.aspxFicUsedInSfb[n] = br.readBit() }
            }
        }
        for n in 0..<numASPXTimeslots { c0.aspxTicUsedInSlot[n] = 0; c1.aspxTicUsedInSlot[n] = 0 }
        if br.readBit() == 1 {
            let copy = br.readBit()
            var left = 0, right = 0
            if copy == 0 {
                left = br.readBit()
                right = br.readBit()
            }
            if copy != 0 || left != 0 {
                for n in 0..<numASPXTimeslots { c0.aspxTicUsedInSlot[n] = br.readBit() }
            }
            if right != 0 {
                for n in 0..<numASPXTimeslots { c1.aspxTicUsedInSlot[n] = br.readBit() }
            }
            if copy != 0 {
                for n in 0..<numASPXTimeslots { c1.aspxTicUsedInSlot[n] = c0.aspxTicUsedInSlot[n] }
            }
        }
    }

    func aspxHuffData(dataType: Int, numSbg: Int, quantMode: Int, stereoMode: Int, direction: Int,
                      into grid: inout AC4Grid<Int>, row: Int) throws {
        func book(_ hcb: Int) -> (AC4VLC, Int) {
            if dataType == AC4.dtSignal {
                return (AC4Codebooks.aspxSignal[stereoMode][quantMode][hcb], AC4Tables.aspx_codebook_signal_off[stereoMode][quantMode][hcb])
            }
            return (AC4Codebooks.aspxNoise[stereoMode][hcb], AC4Tables.aspx_codebook_noise_off[stereoMode][hcb])
        }
        guard numSbg <= 64 else { throw Err.invalid("A-SPX bands") }
        if direction == 0 {
            var (cb, off) = book(AC4.hcbF0)
            guard numSbg > 0 else { return }
            let v = cb.decode(&br)
            guard v >= 0 else { throw Err.invalid("A-SPX F0") }
            grid[row, 0] = v - off
            (cb, off) = book(AC4.hcbDF)
            for i in 1..<max(1, numSbg) {
                let d = cb.decode(&br)
                guard d >= 0 else { throw Err.invalid("A-SPX DF") }
                grid[row, i] = d - off
            }
        } else {
            let (cb, off) = book(AC4.hcbDT)
            for i in 0..<numSbg {
                let d = cb.decode(&br)
                guard d >= 0 else { throw Err.invalid("A-SPX DT") }
                grid[row, i] = d - off
            }
        }
    }

    func aspxECData(_ c: AC4Channel, dataType: Int, numEnv: Int, quantMode: Int, stereoMode: Int, directions: [Int]) throws {
        for env in 0..<numEnv {
            let numSbg: Int
            if dataType == AC4.dtSignal {
                numSbg = c.atsgFreqres[env] != 0 ? c.numSbgSigHighres : c.numSbgSigLowres
            } else {
                numSbg = c.numSbgNoise
            }
            try aspxHuffData(dataType: dataType, numSbg: numSbg, quantMode: quantMode, stereoMode: stereoMode,
                             direction: directions[env], into: &c.aspxData[dataType], row: env)
        }
    }

    // MARK: A-SPX frequency tables

    func aspxElements(_ c: AC4Channel, iframe: Int) throws {
        let reset = ((ss.prevAspxStartFreq != ss.aspxStartFreq ? 1 : 0) +
                     (ss.prevAspxStopFreq != ss.aspxStopFreq ? 1 : 0) +
                     (ss.prevAspxMasterFreqScale != ss.aspxMasterFreqScale ? 1 : 0)) * iframe
        c.masterReset = reset
        if reset != 0 || c.numSbgMaster == 0 {
            let highres = ss.aspxMasterFreqScale == 1
            let template = highres ? AC4Tables.sbg_template_highres : AC4Tables.sbg_template_lowres
            c.numSbgMaster = (highres ? 22 : 20) - 2 * ss.aspxStartFreq - 2 * ss.aspxStopFreq
            guard c.numSbgMaster > 0, c.numSbgMaster < 24 else { throw Err.invalid("A-SPX master bands") }
            for sbg in 0...c.numSbgMaster {
                let i = 2 * ss.aspxStartFreq + sbg
                guard i < template.count else { throw Err.invalid("A-SPX template") }
                c.sbgMaster[sbg] = template[i]
            }
        }
        c.sba = c.sbgMaster[0]
        c.sbz = c.sbgMaster[c.numSbgMaster]

        c.numSbgSigHighres = c.numSbgMaster - c.aspxXoverSubbandOffset
        guard c.numSbgSigHighres >= 1 else { throw Err.invalid("A-SPX crossover") }
        for sbg in 0...c.numSbgSigHighres {
            c.sbgSigHighres[sbg] = c.sbgMaster[sbg + c.aspxXoverSubbandOffset]
        }
        c.sbx = c.sbgSigHighres[0]
        guard c.sbx > 0 else { throw Err.invalid("A-SPX sbx") }
        c.numSbAspx = c.sbgSigHighres[c.numSbgSigHighres] - c.sbx

        c.numSbgSigLowres = c.numSbgSigHighres - c.numSbgSigHighres / 2
        c.sbgSigLowres[0] = c.sbgSigHighres[0]
        if c.numSbgSigHighres & 1 == 0 {
            for sbg in stride(from: 1, through: c.numSbgSigLowres, by: 1) { c.sbgSigLowres[sbg] = c.sbgSigHighres[2 * sbg] }
        } else {
            for sbg in stride(from: 1, through: c.numSbgSigLowres, by: 1) { c.sbgSigLowres[sbg] = c.sbgSigHighres[2 * sbg - 1] }
        }
        c.numSbgSig[0] = c.numSbgSigLowres
        c.numSbgSig[1] = c.numSbgSigHighres

        c.numSbgNoise = max(1, Int(floorf(Float(ss.aspxNoiseSbg) * log2f(Float(c.sbz) / Float(c.sbx)) + 0.5)))
        guard c.numSbgNoise <= 5 else { throw Err.invalid("A-SPX noise bands \(c.numSbgNoise)") }
        var idx = [Int](repeating: 0, count: 8)
        c.sbgNoise[0] = c.sbgSigLowres[0]
        for sbg in stride(from: 1, through: c.numSbgNoise, by: 1) {
            idx[sbg] = idx[sbg - 1] + Int(floorf(Float(c.numSbgSigLowres - idx[sbg - 1]) / Float(c.numSbgNoise + 1 - sbg)))
            c.sbgNoise[sbg] = c.sbgSigLowres[idx[sbg]]
        }

        // Patches.
        var msb = c.sba, usb = c.sbx
        c.numSbgPatches = 0
        let goalSb = fsIndex != 0 ? 43 : 46
        let sourceBandLow = ss.aspxMasterFreqScale == 1 ? 4 : 2
        var sbg = 0
        if goalSb < c.sbx + c.numSbAspx {
            var i = 0
            while i <= c.numSbgMaster && c.sbgMaster[i] < goalSb { sbg = i + 1; i += 1 }
        } else {
            sbg = c.numSbgMaster
        }
        var sb = 0, j = 0
        var guardCount = 0
        repeat {
            j = sbg
            sb = c.sbgMaster[j]
            var odd = (sb - 2 + c.sba) % 2
            while sb > (c.sba - sourceBandLow + msb - odd) && j >= 1 {
                j -= 1
                sb = c.sbgMaster[j]
                odd = (sb - 2 + c.sba) % 2
            }
            guard c.numSbgPatches < 7 else { throw Err.invalid("A-SPX patches") }
            c.sbgPatchNumSb[c.numSbgPatches] = max(sb - usb, 0)
            c.sbgPatchStartSb[c.numSbgPatches] = c.sba - odd - max(sb - usb, 0)
            if c.sbgPatchNumSb[c.numSbgPatches] > 0 {
                usb = sb
                msb = sb
                c.numSbgPatches += 1
            } else {
                msb = c.sbx
            }
            if c.sbgMaster[sbg] - sb < 3 { sbg = c.numSbgMaster }
            guardCount += 1
            guard guardCount < 64 else { throw Err.invalid("A-SPX patch loop") }
        } while sb != (c.sbx + c.numSbAspx) && j > 0
        if c.numSbgPatches > 1 && c.sbgPatchNumSb[c.numSbgPatches - 1] < 3 { c.numSbgPatches -= 1 }
        guard c.numSbgPatches <= 6 else { throw Err.invalid("A-SPX patches") }
        c.sbgPatches[0] = c.sbx
        for i in stride(from: 1, through: c.numSbgPatches, by: 1) {
            c.sbgPatches[i] = c.sbgPatches[i - 1] + c.sbgPatchNumSb[i - 1]
        }

        // Limiter bands.
        for s in 0...c.numSbgSigLowres { c.sbgLim[s] = c.sbgSigLowres[s] }
        if c.numSbgPatches > 1 {
            for s in 1..<c.numSbgPatches { c.sbgLim[s + c.numSbgSigLowres] = c.sbgPatches[s] }
        }
        c.numSbgLim = c.numSbgSigLowres + c.numSbgPatches - 1
        // Sort all num_sbg_lim + 1 borders (the reference sorts one fewer, leaving the last
        // patch border out of order).
        if c.numSbgLim >= 0 {
            let sorted = c.sbgLim[0...c.numSbgLim].sorted()
            for i in 0...c.numSbgLim { c.sbgLim[i] = sorted[i] }
        }
        func inPatches(_ v: Int) -> Bool {
            for i in 0...c.numSbgPatches where c.sbgPatches[i] == v { return true }
            return false
        }
        func remove(_ at: Int) {
            for i in at..<max(at, c.numSbgLim) { c.sbgLim[i] = c.sbgLim[i + 1] }
        }
        var s = 1
        while s <= c.numSbgLim {
            let octaves = log2(Double(c.sbgLim[s]) / Double(c.sbgLim[s - 1]))
            if octaves < 0.245 {
                if c.sbgLim[s] == c.sbgLim[s - 1] {
                    remove(s); c.numSbgLim -= 1
                } else if inPatches(c.sbgLim[s]) {
                    if inPatches(c.sbgLim[s - 1]) {
                        s += 1
                    } else {
                        remove(s - 1); c.numSbgLim -= 1
                    }
                } else {
                    remove(s); c.numSbgLim -= 1
                }
            } else {
                s += 1
            }
        }
    }

    // MARK: A-SPX data

    func aspxData2ch(_ c0: AC4Channel, _ c1: AC4Channel, iframe: Int) throws {
        if iframe != 0 {
            c0.aspxXoverSubbandOffset = br.read(3)
            c1.aspxXoverSubbandOffset = c0.aspxXoverSubbandOffset
        }
        try aspxElements(c0, iframe: iframe)
        try aspxElements(c1, iframe: iframe)
        try aspxFraming(c0, iframe: iframe)
        c0.aspxQmodeEnv = ss.aspxQuantModeEnv
        c1.aspxQmodeEnv = ss.aspxQuantModeEnv
        if c0.aspxIntClass == AC4.fixfix && c0.aspxNumEnv == 1 {
            c0.aspxQmodeEnv = 0
            c1.aspxQmodeEnv = 0
        }
        c0.aspxBalance = br.readBit()
        c1.aspxBalance = c0.aspxBalance
        if c0.aspxBalance == 0 {
            try aspxFraming(c1, iframe: iframe)
            c1.aspxQmodeEnv = ss.aspxQuantModeEnv
            if c1.aspxIntClass == AC4.fixfix && c1.aspxNumEnv == 1 { c1.aspxQmodeEnv = 0 }
        } else {
            c1.aspxNumEnv = c0.aspxNumEnv
            c1.aspxNumNoise = c0.aspxNumNoise
            c1.atsgFreqres = c0.atsgFreqres
        }
        aspxDeltaDir(c0)
        aspxDeltaDir(c1)
        aspxHfgenIwc2ch(c0, c1, balance: c0.aspxBalance)
        let sm1 = c0.aspxBalance != 0 ? AC4.smBalance : AC4.smLevel
        try aspxECData(c0, dataType: AC4.dtSignal, numEnv: c0.aspxNumEnv, quantMode: c0.aspxQmodeEnv,
                       stereoMode: AC4.smLevel, directions: c0.aspxSigDeltaDir)
        try aspxECData(c1, dataType: AC4.dtSignal, numEnv: c1.aspxNumEnv, quantMode: c1.aspxQmodeEnv,
                       stereoMode: sm1, directions: c1.aspxSigDeltaDir)
        try aspxECData(c0, dataType: AC4.dtNoise, numEnv: c0.aspxNumNoise, quantMode: 0,
                       stereoMode: AC4.smLevel, directions: c0.aspxNoiseDeltaDir)
        try aspxECData(c1, dataType: AC4.dtNoise, numEnv: c1.aspxNumNoise, quantMode: 0,
                       stereoMode: sm1, directions: c1.aspxNoiseDeltaDir)
    }

    func aspxHfgenIwc1ch(_ c: AC4Channel) {
        c.aspxTnaModePrev = c.aspxTnaMode
        for n in 0..<c.numSbgNoise { c.aspxTnaMode[n] = br.read(2) }
        if br.readBit() == 1 {
            for n in 0..<c.numSbgSigHighres { c.aspxAddHarmonic[n] = br.readBit() }
        }
        for n in 0..<c.numSbgSigHighres { c.aspxFicUsedInSfb[n] = 0 }
        if br.readBit() == 1 {
            for n in 0..<c.numSbgSigHighres { c.aspxFicUsedInSfb[n] = br.readBit() }
        }
        for n in 0..<numASPXTimeslots { c.aspxTicUsedInSlot[n] = 0 }
        if br.readBit() == 1 {
            for n in 0..<numASPXTimeslots { c.aspxTicUsedInSlot[n] = br.readBit() }
        }
    }

    func aspxData1ch(_ c: AC4Channel, iframe: Int) throws {
        if iframe != 0 { c.aspxXoverSubbandOffset = br.read(3) }
        c.aspxBalance = 0
        try aspxElements(c, iframe: iframe)
        try aspxFraming(c, iframe: iframe)
        c.aspxQmodeEnv = ss.aspxQuantModeEnv
        if c.aspxIntClass == AC4.fixfix && c.aspxNumEnv == 1 { c.aspxQmodeEnv = 0 }
        aspxDeltaDir(c)
        aspxHfgenIwc1ch(c)
        try aspxECData(c, dataType: AC4.dtSignal, numEnv: c.aspxNumEnv, quantMode: c.aspxQmodeEnv,
                       stereoMode: 0, directions: c.aspxSigDeltaDir)
        try aspxECData(c, dataType: AC4.dtNoise, numEnv: c.aspxNumNoise, quantMode: 0,
                       stereoMode: 0, directions: c.aspxNoiseDeltaDir)
    }

    // MARK: A-CPL data (parsed; parametric upmix is not synthesised)

    func acplFramingData(_ c: AC4Channel) {
        c.acplInterpolationType = br.readBit()
        c.acplNumParamSetsCod = br.readBit()
        if c.acplInterpolationType != 0 {
            for ps in 0..<(c.acplNumParamSetsCod + 1) { c.acplParamTimeslot[ps] = br.read(5) }
        }
    }

    func acplHuffData(dataType: Int, dataBands: Int, startBand: Int, quantMode: Int, _ c: AC4Channel, row: Int) throws {
        let type: Int
        switch dataType {
        case AC4.alpha1, AC4.alpha2: type = 0
        case AC4.beta1, AC4.beta2: type = 1
        case AC4.beta3: type = 2
        default: type = 3
        }
        guard dataBands <= 16, startBand < 16 else { throw Err.invalid("A-CPL bands") }
        if br.readBit() == 0 {
            let f0 = AC4Codebooks.acpl[type][quantMode][AC4.hcbF0]
            let v = f0.decode(&br)
            guard v >= 0 else { throw Err.invalid("A-CPL F0") }
            c.acplData[row, startBand] = v
            let df = AC4Codebooks.acpl[type][quantMode][AC4.hcbDF]
            var i = startBand + 1
            while i < dataBands {
                let d = df.decode(&br)
                guard d >= 0 else { throw Err.invalid("A-CPL DF") }
                c.acplData[row, i] = d
                i += 1
            }
        } else {
            let dt = AC4Codebooks.acpl[type][quantMode][AC4.hcbDT]
            var i = startBand
            while i < dataBands {
                let d = dt.decode(&br)
                guard d >= 0 else { throw Err.invalid("A-CPL DT") }
                c.acplData[row, i] = d
                i += 1
            }
        }
    }

    func acplECData(_ c: AC4Channel, dataType: Int, bands: Int, start: Int, quantMode: Int) throws {
        for _ in 0..<(c.acplNumParamSetsCod + 1) {
            try acplHuffData(dataType: dataType, dataBands: bands, startBand: start, quantMode: quantMode, c, row: dataType)
        }
    }

    func acplData2ch(_ c0: AC4Channel, _ c1: AC4Channel) throws {
        acplFramingData(c0)
        let bands = AC4Tables.acpl_num_param_bands[ss.acplNumParamBandsID]
        let st = ss.acplParamBand
        for t in [AC4.alpha1, AC4.alpha2, AC4.beta1, AC4.beta2, AC4.beta3] {
            try acplECData(c0, dataType: t, bands: bands, start: st, quantMode: ss.acplQuantMode[0])
        }
        for t in [AC4.gamma1, AC4.gamma2, AC4.gamma3, AC4.gamma4, AC4.gamma5, AC4.gamma6] {
            try acplECData(c1, dataType: t, bands: bands, start: st, quantMode: ss.acplQuantMode[1])
        }
    }

    func acplData1ch(_ c: AC4Channel) throws {
        acplFramingData(c)
        let bands = AC4Tables.acpl_num_param_bands[ss.acplNumParamBandsID]
        let start = ss.acplParamBand
        try acplECData(c, dataType: AC4.alpha1, bands: bands, start: start, quantMode: ss.acplQuantMode[0])
        try acplECData(c, dataType: AC4.beta1, bands: bands, start: start, quantMode: ss.acplQuantMode[0])
    }
}
