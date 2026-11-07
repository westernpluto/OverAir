// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol
// (Copyright (c) 2019 Paul B Mahol), as distributed in github.com/funnymanva/ffmpeg-with-ac4.
//
// This file is part of OverAir's AC-4 decoder, which is free software; you can redistribute it
// and/or modify it under the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your option) any later
// version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU Lesser General Public License for more details.

import Foundation

/// Dolby AC-4 (ETSI TS 103 190) decoder, used for ATSC 3.0 audio. Decodes the first
/// substream of the main presentation to planar Float32 PCM.
final class AC4Decoder {
    enum DecodeError: Error { case invalid(String) }

    struct Format: Equatable {
        var sampleRate: Int
        var channelMode: Int
        var channelCount: Int { AC4Decoder.channelModeChannels[min(channelMode, 16)] }
        var layoutName: String {
            switch channelMode {
            case 0: return "1.0"
            case 1: return "2.0"
            case 2: return "3.0"
            case 3: return "5.0"
            case 4: return "5.1"
            case 5: return "7.0"
            case 6: return "7.1"
            default: return "\(channelCount) ch"
            }
        }
    }

    static let channelModeChannels = [1, 2, 3, 5, 6, 7, 8, 7, 8, 7, 8, 11, 12, 13, 14, 24, 0]

    // MARK: Bitstream structures

    struct SubstreamInfo {
        var susVer = 0
        var channelMode = 0
        var substreamIndex = 0
        var hsfExtSubstreamIndex = 0
        var sfMultiplier = 0
        var bitrateIndicator = 0
        var addChBase = 0
        var iframe = [Int](repeating: 0, count: 4)
        var backChannelsPresent = 0
        var centrePresent = 0
        var topChannelsPresent = 0
    }

    struct SubstreamGroupInfo {
        var channelCoded = 0
        var groupIndex = 0
        var ssinfo = SubstreamInfo()
    }

    struct PresentationInfo {
        var singleSubstream = 0
        var enablePresentation = 0
        var presentationConfig = 0
        var presentationVersion = 0
        var addEmdfSubstreams = 0
        var nAddEmdfSubstreams = 0
        var nSubstreamGroups = 0
        var mdcompat = 0
        var presentationID = 0
        var multiplier = 0
        var multiplierBit = 0
        var preVirtualized = 0
        var frameRateFactor = 1
        var frameRateFraction = 1
        var multiPID = 0
        var hsfExt = 0
        var ssinfo = SubstreamInfo()
    }

    enum SubstreamType { case substream, presentation }

    // MARK: State

    var targetPresentation = 0
    private(set) var format: Format?

    var br = BitReader(data: UnsafePointer(bitPattern: 1)!, byteCount: 0)
    var version = 0
    var sequenceCounter = 0
    var sequenceCounterPrev = 0
    var waitFrames = 0
    var nbWaitFrames = 0
    var fsIndex = 0
    var frameRateIndex = 0
    var frameLenBase = 0
    var frameLenBaseIdx = 0
    var numQMFTimeslots = 0
    var numASPXTimeslots = 0
    var numTSInATS = 0
    var tsOffsetHFGen = 0
    var transformLength = 0
    var iframeGlobal = 0
    var firstFrame = true
    var haveIFrame = false
    var nbPresentations = 0
    var payloadBase = 0
    var shortProgramID = 0
    var nbSubstreams = 0
    var totalGroups = 0
    var substreamSize = [Int](repeating: 0, count: 32)
    var substreamType = [SubstreamType](repeating: .substream, count: 32)
    var pinfo = [PresentationInfo](repeating: PresentationInfo(), count: 8)
    let ss = AC4Substream()
    var winl = [Float](repeating: 0, count: 2048)
    var winr = [Float](repeating: 0, count: 2048)
    var xbuf = [Float](repeating: 0, count: 4096)
    private var padded = [UInt8](repeating: 0, count: 65536 + 16)

    /// (numerator, denominator) of the resampling from the coded frame to real time, by frame rate
    /// index (TS 103 190-1 table 83). 29.97 fps codes 1536 samples per 1/29.97 s.
    static let resamplingRatios: [(Int, Int)] = [
        (25025, 24000), (25, 24), (15, 16), (25025, 24000), (25, 24), (25025, 24000), (25, 24), (15, 16),
        (25025, 24000), (25, 24), (15, 16), (25025, 24000), (25, 24), (1, 1), (1, 1), (1, 1),
    ]

    /// The real sample rate of the decoded PCM: frames hold `frameLenBase` samples but last one
    /// video frame.
    var outputSampleRate: Double {
        let base = fsIndex != 0 ? 48000.0 : 44100.0
        let r = Self.resamplingRatios[frameRateIndex]
        return base * Double(r.1) / Double(r.0)
    }

    struct DecodedFrame {
        /// Planar PCM for L, R, C, LFE, Ls, Rs; nil where the programme has no such channel.
        var channels: [[Float]?]
        var samples: Int
        var sampleRate: Double
    }

    func reset() {
        haveIFrame = false
        sequenceCounter = 0
        sequenceCounterPrev = 0
        for c in ss.ssch {
            for i in c.overlap.indices { c.overlap[i] = 0 }
            c.nPrev = 0
        }
    }

    /// Decodes one AC-4 frame (`raw_ac4_frame`, optionally inside an `ac4_syncframe`). Returns nil
    /// until the first I-frame arrives.
    func decodeFrame(_ bytes: UnsafeRawBufferPointer) throws -> DecodedFrame? {
        guard bytes.count >= 8 else { throw DecodeError.invalid("frame too short") }
        var start = 0
        var end = bytes.count
        if bytes[0] == 0xAC && (bytes[1] == 0x40 || bytes[1] == 0x41) {
            var size = Int(bytes[2]) << 8 | Int(bytes[3])
            start = 4
            if size == 0xFFFF {
                guard bytes.count >= 7 else { throw DecodeError.invalid("frame too short") }
                size = Int(bytes[4]) << 16 | Int(bytes[5]) << 8 | Int(bytes[6])
                start = 7
            }
            end = min(bytes.count, start + size)
        }
        let count = end - start
        guard count > 0, count <= 65536 else { throw DecodeError.invalid("frame size \(count)") }
        for i in 0..<count { padded[i] = bytes[start + i] }
        for i in count..<(count + 16) { padded[i] = 0 }

        return try padded.withUnsafeBufferPointer { buf -> DecodedFrame? in
            br = BitReader(data: buf.baseAddress!, byteCount: count)
            try toc()
            guard haveIFrame else { return nil }
            let presentation = min(targetPresentation, max(0, nbPresentations - 1))
            let ssinfo = version == 2 ? ssgroup[0].ssinfo : pinfo[presentation].ssinfo
            guard ssinfo.channelMode <= 4 else { throw DecodeError.invalid("channel mode \(ssinfo.channelMode)") }
            br.skipLong(payloadBase * 8)
            var decoded = false
            for i in 0..<nbSubstreams {
                if substreamType[i] == .presentation {
                    br.skipLong(substreamSize[i] * 8)
                    continue
                }
                try substream(channelMode: ssinfo.channelMode, iframe: ssinfo.iframe[0])
                decoded = true
                break
            }
            guard decoded else { throw DecodeError.invalid("no audio substream") }
            try synthesize(channelMode: ssinfo.channelMode)
            let tracks = Self.channelModeChannels[ssinfo.channelMode]
            let map = outputMap(channelMode: ssinfo.channelMode)
            let n = frameLenBase
            let channels: [[Float]?] = map.map { t in
                guard let t, t < tracks else { return nil }
                return Array(ss.ssch[t].pcm[0..<n])
            }
            let newFormat = Format(sampleRate: fsIndex != 0 ? 48000 : 44100, channelMode: ssinfo.channelMode)
            if format != newFormat { format = newFormat }
            return DecodedFrame(channels: channels, samples: n, sampleRate: outputSampleRate)
        }
    }

    /// Spectral processing and transform of every track (FFmpeg `ac4_decode_frame` tail).
    func synthesize(channelMode: Int) throws {
        let tracks = Self.channelModeChannels[channelMode]
        for t in 0..<tracks { scaleSpec(ss.ssch[t]) }
        switch channelMode {
        case 1:
            if ss.mdctStereoProc[0] != 0 { twoChannelProcessing(ss.ssch[0], ss.ssch[1]) }
        case 3, 4:
            if ss.codecMode == AC4.cmSimple || ss.codecMode == AC4.cmASPX {
                if ss.codingConfig == 0 {
                    if ss.mdctStereoProc[0] != 0 { twoChannelProcessing(ss.ssch[0], ss.ssch[1]) }
                    if ss.mdctStereoProc[1] != 0 { twoChannelProcessing(ss.ssch[2], ss.ssch[3]) }
                }
            } else if ss.codingConfig == 0 && ss.mdctStereoProc[0] != 0 {
                twoChannelProcessing(ss.ssch[0], ss.ssch[1])
            }
        default:
            break
        }
        for t in 0..<tracks {
            let c = ss.ssch[t]
            spectralReordering(c)
            spectralSynthesis(c)
            // The spectrum is in 16-bit units; bring PCM to [-1, 1].
            for i in 0..<frameLenBase { c.pcm[i] *= 1.0 / 32768 }
        }
        try aspxSynthesis(channelMode: channelMode, tracks: tracks)
    }

    /// High-frequency reconstruction; filled in by the A-SPX stage.
    func aspxSynthesis(channelMode: Int, tracks: Int) throws {}
    var usesSpeechFrontend = false
    var lastAudioSize = 0
    var lastConsumed = 0
    var ssgroup = [SubstreamGroupInfo](repeating: SubstreamGroupInfo(), count: 8)

    // MARK: Table of contents (TS 103 190-2 4.2.3)

    func checkSequence() throws {
        if sequenceCounter > 1020 { throw DecodeError.invalid("sequence counter \(sequenceCounter)") }
        if sequenceCounter == sequenceCounterPrev + 1 { return }
        if sequenceCounter != 0 && sequenceCounterPrev == 0 { return }
        if sequenceCounter == 1 && sequenceCounterPrev == 1020 { return }
        if sequenceCounter == 0 && sequenceCounterPrev == 0 { return }
        throw DecodeError.invalid("unexpected sequence counter \(sequenceCounter) after \(sequenceCounterPrev)")
    }

    func frameRateMultiplyInfo(_ p: inout PresentationInfo) {
        p.multiplierBit = 0
        switch frameRateIndex {
        case 2, 3, 4:
            p.multiplier = br.readBit()
            if p.multiplier != 0 { p.multiplierBit = br.readBit() }
            p.frameRateFactor = p.multiplier != 0 ? (p.multiplierBit != 0 ? 4 : 2) : 1
        case 0, 1, 7, 8, 9:
            p.multiplier = br.readBit()
            p.frameRateFactor = p.multiplier != 0 ? 2 : 1
        default:
            p.frameRateFactor = 1
        }
    }

    func emdfInfo() {
        var version = br.read(2)
        if version == 3 { version += br.ac4Variable(2) }
        var keyID = br.read(3)
        if keyID == 7 { keyID += br.ac4Variable(3) }
        if br.readBit() == 1 {
            let index = br.read(2)
            if index == 3 { _ = br.ac4Variable(2) }
        }
        // emdf_protection
        let first = br.read(2), second = br.read(2)
        for p in [first, second] {
            switch p {
            case 1: br.skip(8)
            case 2: br.skipLong(32)
            case 3: br.skipLong(128)
            default: break
            }
        }
    }

    func contentType() {
        br.skip(3)
        if br.readBit() == 1 {
            if br.readBit() == 1 {
                br.skip(1)
                br.skip(16)
            } else {
                let bytes = br.read(6)
                br.skipLong(8 * bytes)
            }
        }
    }

    func hsfExtSubstreamInfo(_ ssi: inout SubstreamInfo, present: Bool) {
        if present {
            ssi.hsfExtSubstreamIndex = br.read(2)
            if ssi.hsfExtSubstreamIndex == 3 { ssi.hsfExtSubstreamIndex += br.ac4Variable(2) }
        }
    }

    func substreamInfo(frameRateFactor: Int, _ ssi: inout SubstreamInfo) throws {
        ssi.susVer = 0
        ssi.channelMode = AC4Codebooks.channelMode.decode(&br)
        if ssi.channelMode < 0 { throw DecodeError.invalid("channel mode") }
        if ssi.channelMode == 16 { ssi.channelMode += br.ac4Variable(2) }
        if fsIndex == 1 && br.readBit() == 1 { ssi.sfMultiplier = 1 + br.readBit() }
        if br.readBit() == 1 { ssi.bitrateIndicator = AC4Codebooks.bitrateIndicator.decode(&br) }
        if (7...10).contains(ssi.channelMode) { ssi.addChBase = br.readBit() }
        if br.readBit() == 1 { contentType() }
        for i in 0..<frameRateFactor { ssi.iframe[i] = br.readBit() }
        ssi.substreamIndex = br.read(2)
        if ssi.substreamIndex == 3 { ssi.substreamIndex += br.ac4Variable(2) }
        guard ssi.substreamIndex < 32 else { throw DecodeError.invalid("substream index") }
        substreamType[ssi.substreamIndex] = .substream
    }

    func presentationConfigExtInfo() {
        var n = br.read(5)
        if br.readBit() == 1 { n += br.ac4Variable(2) << 5 }
        br.skipLong(8 * n)
    }

    func presentationInfo(_ p: inout PresentationInfo) throws {
        p.singleSubstream = br.readBit()
        if p.singleSubstream != 1 {
            p.presentationConfig = br.read(3)
            if p.presentationConfig == 7 { p.presentationConfig += br.ac4Variable(2) }
        }
        p.presentationVersion = br.unary(max: 31)
        p.addEmdfSubstreams = 0
        if p.singleSubstream != 1 && p.presentationConfig == 6 {
            p.addEmdfSubstreams = 1
        } else {
            p.mdcompat = br.read(3)
            if br.readBit() == 1 { p.presentationID = br.ac4Variable(2) }
            frameRateMultiplyInfo(&p)
            emdfInfo()
            if p.singleSubstream == 1 {
                try substreamInfo(frameRateFactor: p.frameRateFactor, &p.ssinfo)
            } else {
                p.hsfExt = br.readBit()
                switch p.presentationConfig {
                case 0:
                    try substreamInfo(frameRateFactor: p.frameRateFactor, &p.ssinfo)
                    hsfExtSubstreamInfo(&p.ssinfo, present: true)
                    try substreamInfo(frameRateFactor: p.frameRateFactor, &p.ssinfo)
                default:
                    presentationConfigExtInfo()
                }
            }
            p.preVirtualized = br.readBit()
            p.addEmdfSubstreams = br.readBit()
        }
        if p.addEmdfSubstreams != 0 {
            p.nAddEmdfSubstreams = br.read(2)
            if p.nAddEmdfSubstreams == 0 { p.nAddEmdfSubstreams = br.ac4Variable(2) + 4 }
            for _ in 0..<p.nAddEmdfSubstreams { emdfInfo() }
        }
    }

    func substreamIndexTable() {
        nbSubstreams = br.read(2)
        if nbSubstreams == 0 { nbSubstreams = br.ac4Variable(2) + 4 }
        nbSubstreams = min(nbSubstreams, 32)
        let sizePresent = nbSubstreams == 1 ? br.readBit() == 1 : true
        if sizePresent {
            for i in 0..<nbSubstreams {
                let more = br.readBit()
                substreamSize[i] = br.read(10)
                if more == 1 { substreamSize[i] += br.ac4Variable(2) << 10 }
            }
        }
    }

    func presentationSubstreamInfo() throws {
        _ = br.readBit()                             // alternative
        _ = br.readBit()                             // pres_ndot
        var index = br.read(2)
        if index == 3 { index += br.ac4Variable(2) }
        guard index < 32 else { throw DecodeError.invalid("presentation substream index") }
        substreamType[index] = .presentation
    }

    func frameRateFractionsInfo(_ p: inout PresentationInfo) {
        p.frameRateFraction = 1
        if (5...9).contains(frameRateIndex), p.frameRateFactor == 1, br.readBit() == 1 {
            p.frameRateFraction = 2
        }
        if (10...12).contains(frameRateIndex), br.readBit() == 1 {
            p.frameRateFraction = br.readBit() == 1 ? 4 : 2
        }
    }

    func substreamInfoChan(_ g: inout SubstreamGroupInfo, substreamsPresent: Bool, susVer: Int) throws {
        g.ssinfo.susVer = susVer
        g.ssinfo.channelMode = AC4Codebooks.channelMode.decode(&br)
        if g.ssinfo.channelMode < 0 { throw DecodeError.invalid("channel mode") }
        if g.ssinfo.channelMode == 16 { g.ssinfo.channelMode += br.ac4Variable(2) }
        if (11...14).contains(g.ssinfo.channelMode) {
            g.ssinfo.backChannelsPresent = br.readBit()
            g.ssinfo.centrePresent = br.readBit()
            g.ssinfo.topChannelsPresent = br.read(2)
        }
        if fsIndex != 0 && br.readBit() == 1 { g.ssinfo.sfMultiplier = 1 + br.readBit() }
        if br.readBit() == 1 { g.ssinfo.bitrateIndicator = AC4Codebooks.bitrateIndicator.decode(&br) }
        if (7...10).contains(g.ssinfo.channelMode) { g.ssinfo.addChBase = br.readBit() }
        for i in 0..<pinfo[0].frameRateFactor { g.ssinfo.iframe[i] = br.readBit() }
        if substreamsPresent {
            g.ssinfo.substreamIndex = br.read(2)
            if g.ssinfo.substreamIndex == 3 { g.ssinfo.substreamIndex += br.ac4Variable(2) }
        }
    }

    func substreamGroupInfo(_ g: inout SubstreamGroupInfo) throws {
        let substreamsPresent = br.readBit() == 1
        let hsfExt = br.readBit() == 1
        var nLFSubstreams: Int
        if br.readBit() == 1 {
            nLFSubstreams = 1
        } else {
            nLFSubstreams = br.read(2) + 2
            if nLFSubstreams == 5 { nLFSubstreams += br.ac4Variable(2) }
        }
        g.channelCoded = br.readBit()
        guard g.channelCoded != 0 else {
            throw DecodeError.invalid("object-based audio is not supported")
        }
        for _ in 0..<nLFSubstreams {
            let susVer = version == 1 ? br.readBit() : 1
            try substreamInfoChan(&g, substreamsPresent: substreamsPresent, susVer: susVer)
            if hsfExt { hsfExtSubstreamInfo(&g.ssinfo, present: substreamsPresent) }
        }
        if br.readBit() == 1 { contentType() }
    }

    func sgiSpecifier(_ index: Int) throws {
        guard version != 1 else { throw DecodeError.invalid("substream group info in version 1") }
        var gi = br.read(3)
        if gi == 7 { gi += br.ac4Variable(2) }
        ssgroup[index].groupIndex = gi
        totalGroups = max(totalGroups, gi)
        guard totalGroups < 8 else { throw DecodeError.invalid("too many substream groups") }
    }

    func presentationV1Info(_ p: inout PresentationInfo) throws {
        let singleGroup = br.readBit()
        if singleGroup != 1 {
            p.presentationConfig = br.read(3)
            if p.presentationConfig == 7 { p.presentationConfig += br.ac4Variable(2) }
        }
        if version != 1 { p.presentationVersion = br.unary(max: 31) }
        if singleGroup != 1 && p.presentationConfig == 6 {
            p.addEmdfSubstreams = 1
        } else {
            if version != 1 { p.mdcompat = br.read(3) }
            if br.readBit() == 1 { p.presentationID = br.ac4Variable(2) }
            frameRateMultiplyInfo(&p)
            frameRateFractionsInfo(&p)
            emdfInfo()
            if br.readBit() == 1 { p.enablePresentation = br.readBit() }
            if singleGroup == 1 {
                try sgiSpecifier(0)
                p.nSubstreamGroups = 1
            } else {
                p.multiPID = br.readBit()
                switch p.presentationConfig {
                case 0, 2:
                    try sgiSpecifier(0); try sgiSpecifier(1); p.nSubstreamGroups = 2
                case 1:
                    try sgiSpecifier(0); try sgiSpecifier(1); p.nSubstreamGroups = 1
                case 3:
                    try sgiSpecifier(0); try sgiSpecifier(1); try sgiSpecifier(2); p.nSubstreamGroups = 3
                case 4:
                    try sgiSpecifier(0); try sgiSpecifier(1); try sgiSpecifier(2); p.nSubstreamGroups = 2
                case 5:
                    p.nSubstreamGroups = br.read(2) + 2
                    if p.nSubstreamGroups == 5 { p.nSubstreamGroups += br.ac4Variable(2) }
                    guard p.nSubstreamGroups <= 8 else { throw DecodeError.invalid("substream groups") }
                    for sg in 0..<p.nSubstreamGroups { try sgiSpecifier(sg) }
                default:
                    presentationConfigExtInfo()
                }
            }
            p.preVirtualized = br.readBit()
            p.addEmdfSubstreams = br.readBit()
            try presentationSubstreamInfo()
        }
        if p.addEmdfSubstreams != 0 {
            p.nAddEmdfSubstreams = br.read(2)
            if p.nAddEmdfSubstreams == 0 { p.nAddEmdfSubstreams = br.ac4Variable(2) + 4 }
            for _ in 0..<p.nAddEmdfSubstreams { emdfInfo() }
        }
    }

    func toc() throws {
        version = br.read(2)
        if version == 3 { version += br.ac4Variable(2) }
        sequenceCounterPrev = sequenceCounter
        sequenceCounter = br.read(10)
        waitFrames = br.readBit()
        if waitFrames != 0 {
            nbWaitFrames = br.read(3)
            if nbWaitFrames > 0 { br.skip(2) }
        }
        fsIndex = br.readBit()
        frameRateIndex = br.read(4)
        frameLenBase = AC4Tables.frame_len_base_48khz[frameRateIndex]
        guard frameLenBase > 0 else { throw DecodeError.invalid("frame rate index \(frameRateIndex)") }
        numTSInATS = (1536...2048).contains(frameLenBase) ? 2 : 1
        frameLenBaseIdx = AC4Tables.frame_len_base_idx_48khz[frameRateIndex]
        numQMFTimeslots = frameLenBase / 64
        numASPXTimeslots = numQMFTimeslots / numTSInATS
        tsOffsetHFGen = 3 * numTSInATS
        iframeGlobal = br.readBit()
        if iframeGlobal != 0 {
            haveIFrame = true
        } else {
            try checkSequence()
        }
        if br.readBit() == 1 {
            nbPresentations = 1
        } else if br.readBit() == 1 {
            nbPresentations = 2 + br.ac4Variable(2)
        } else {
            nbPresentations = 0
        }
        guard nbPresentations <= 8 else { throw DecodeError.invalid("presentations") }
        payloadBase = 0
        if br.readBit() == 1 {
            payloadBase = br.read(5) + 1
            if payloadBase == 0x20 { payloadBase += br.ac4Variable(3) }
        }
        for i in 0..<32 { substreamType[i] = .substream }
        totalGroups = 0
        if version <= 1 {
            for i in 0..<nbPresentations { try presentationInfo(&pinfo[i]) }
        } else {
            if br.readBit() == 1 {
                shortProgramID = br.read(16)
                if br.readBit() == 1 { br.skipLong(16 * 8) }
            }
            for i in 0..<nbPresentations { try presentationV1Info(&pinfo[i]) }
            for i in 0...totalGroups { try substreamGroupInfo(&ssgroup[i]) }
        }
        substreamIndexTable()
        br.bitPos = (br.bitPos + 7) & ~7
        if br.overrun { throw DecodeError.invalid("table of contents overrun") }
    }
}

/// Huffman codebooks built from `AC4Tables` (TS 103 190-1 Annex A).
enum AC4Codebooks {
    static let channelMode = AC4VLC(bits: AC4Tables.channel_mode_bits, codes: AC4Tables.channel_mode_codes)
    static let bitrateIndicator = AC4VLC(bits: AC4Tables.bitrate_indicator_bits, codes: AC4Tables.bitrate_indicator_codes)
    static let scaleFactors = AC4VLC(bits: AC4Tables.scale_factors_bits, codes: AC4Tables.scale_factors_codes)
    static let snf = AC4VLC(bits: AC4Tables.snf_bits, codes: AC4Tables.snf_codes)
    static let aspxIntClass = AC4VLC(bits: AC4Tables.aspx_int_class_bits, codes: AC4Tables.aspx_int_class_codes)
    static let asf: [AC4VLC] = [
        AC4VLC(bits: AC4Tables.asf_codebook_1_bits, codes: AC4Tables.asf_codebook_1_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_2_bits, codes: AC4Tables.asf_codebook_2_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_3_bits, codes: AC4Tables.asf_codebook_3_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_4_bits, codes: AC4Tables.asf_codebook_4_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_5_bits, codes: AC4Tables.asf_codebook_5_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_6_bits, codes: AC4Tables.asf_codebook_6_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_7_bits, codes: AC4Tables.asf_codebook_7_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_8_bits, codes: AC4Tables.asf_codebook_8_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_9_bits, codes: AC4Tables.asf_codebook_9_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_10_bits, codes: AC4Tables.asf_codebook_10_codes),
        AC4VLC(bits: AC4Tables.asf_codebook_11_bits, codes: AC4Tables.asf_codebook_11_codes),
    ]
    /// [level/balance][quant 1.5/3.0][F0/DF/DT]
    static let aspxSignal: [[[AC4VLC]]] = [
        [
            [AC4VLC(bits: AC4Tables.aspx_hcb_env_level_15_f0_bits, codes: AC4Tables.aspx_hcb_env_level_15_f0_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_level_15_df_bits, codes: AC4Tables.aspx_hcb_env_level_15_df_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_level_15_dt_bits, codes: AC4Tables.aspx_hcb_env_level_15_dt_codes)],
            [AC4VLC(bits: AC4Tables.aspx_hcb_env_level_30_f0_bits, codes: AC4Tables.aspx_hcb_env_level_30_f0_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_level_30_df_bits, codes: AC4Tables.aspx_hcb_env_level_30_df_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_level_30_dt_bits, codes: AC4Tables.aspx_hcb_env_level_30_dt_codes)],
        ],
        [
            [AC4VLC(bits: AC4Tables.aspx_hcb_env_balance_15_f0_bits, codes: AC4Tables.aspx_hcb_env_balance_15_f0_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_balance_15_df_bits, codes: AC4Tables.aspx_hcb_env_balance_15_df_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_balance_15_dt_bits, codes: AC4Tables.aspx_hcb_env_balance_15_dt_codes)],
            [AC4VLC(bits: AC4Tables.aspx_hcb_env_balance_30_f0_bits, codes: AC4Tables.aspx_hcb_env_balance_30_f0_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_balance_30_df_bits, codes: AC4Tables.aspx_hcb_env_balance_30_df_codes),
             AC4VLC(bits: AC4Tables.aspx_hcb_env_balance_30_dt_bits, codes: AC4Tables.aspx_hcb_env_balance_30_dt_codes)],
        ],
    ]
    /// [level/balance][F0/DF/DT]
    static let aspxNoise: [[AC4VLC]] = [
        [AC4VLC(bits: AC4Tables.aspx_hcb_noise_level_f0_bits, codes: AC4Tables.aspx_hcb_noise_level_f0_codes),
         AC4VLC(bits: AC4Tables.aspx_hcb_noise_level_df_bits, codes: AC4Tables.aspx_hcb_noise_level_df_codes),
         AC4VLC(bits: AC4Tables.aspx_hcb_noise_level_dt_bits, codes: AC4Tables.aspx_hcb_noise_level_dt_codes)],
        [AC4VLC(bits: AC4Tables.aspx_hcb_noise_balance_f0_bits, codes: AC4Tables.aspx_hcb_noise_balance_f0_codes),
         AC4VLC(bits: AC4Tables.aspx_hcb_noise_balance_df_bits, codes: AC4Tables.aspx_hcb_noise_balance_df_codes),
         AC4VLC(bits: AC4Tables.aspx_hcb_noise_balance_dt_bits, codes: AC4Tables.aspx_hcb_noise_balance_dt_codes)],
    ]
    /// [alpha/beta/beta3/gamma][fine/coarse][F0/DF/DT]
    static let acpl: [[[AC4VLC]]] = [
        [
            [AC4VLC(bits: AC4Tables.acpl_hcb_alpha_fine_f0_bits, codes: AC4Tables.acpl_hcb_alpha_fine_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_alpha_fine_df_bits, codes: AC4Tables.acpl_hcb_alpha_fine_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_alpha_fine_dt_bits, codes: AC4Tables.acpl_hcb_alpha_fine_dt_codes)],
            [AC4VLC(bits: AC4Tables.acpl_hcb_alpha_coarse_f0_bits, codes: AC4Tables.acpl_hcb_alpha_coarse_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_alpha_coarse_df_bits, codes: AC4Tables.acpl_hcb_alpha_coarse_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_alpha_coarse_dt_bits, codes: AC4Tables.acpl_hcb_alpha_coarse_dt_codes)],
        ],
        [
            [AC4VLC(bits: AC4Tables.acpl_hcb_beta_fine_f0_bits, codes: AC4Tables.acpl_hcb_beta_fine_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta_fine_df_bits, codes: AC4Tables.acpl_hcb_beta_fine_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta_fine_dt_bits, codes: AC4Tables.acpl_hcb_beta_fine_dt_codes)],
            [AC4VLC(bits: AC4Tables.acpl_hcb_beta_coarse_f0_bits, codes: AC4Tables.acpl_hcb_beta_coarse_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta_coarse_df_bits, codes: AC4Tables.acpl_hcb_beta_coarse_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta_coarse_dt_bits, codes: AC4Tables.acpl_hcb_beta_coarse_dt_codes)],
        ],
        [
            [AC4VLC(bits: AC4Tables.acpl_hcb_beta3_fine_f0_bits, codes: AC4Tables.acpl_hcb_beta3_fine_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta3_fine_df_bits, codes: AC4Tables.acpl_hcb_beta3_fine_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta3_fine_dt_bits, codes: AC4Tables.acpl_hcb_beta3_fine_dt_codes)],
            [AC4VLC(bits: AC4Tables.acpl_hcb_beta3_coarse_f0_bits, codes: AC4Tables.acpl_hcb_beta3_coarse_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta3_coarse_df_bits, codes: AC4Tables.acpl_hcb_beta3_coarse_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_beta3_coarse_dt_bits, codes: AC4Tables.acpl_hcb_beta3_coarse_dt_codes)],
        ],
        [
            [AC4VLC(bits: AC4Tables.acpl_hcb_gamma_fine_f0_bits, codes: AC4Tables.acpl_hcb_gamma_fine_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_gamma_fine_df_bits, codes: AC4Tables.acpl_hcb_gamma_fine_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_gamma_fine_dt_bits, codes: AC4Tables.acpl_hcb_gamma_fine_dt_codes)],
            [AC4VLC(bits: AC4Tables.acpl_hcb_gamma_coarse_f0_bits, codes: AC4Tables.acpl_hcb_gamma_coarse_f0_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_gamma_coarse_df_bits, codes: AC4Tables.acpl_hcb_gamma_coarse_df_codes),
             AC4VLC(bits: AC4Tables.acpl_hcb_gamma_coarse_dt_bits, codes: AC4Tables.acpl_hcb_gamma_coarse_dt_codes)],
        ],
    ]
}
