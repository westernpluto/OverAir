// AC-4 decoder for OverAir. Swift port of the FFmpeg AC-4 decoder by Paul B Mahol.
// Licensed under the GNU Lesser General Public License, version 2.1 or later.

/// A fixed-size 2-D array stored row-major.
struct AC4Grid<T> {
    var data: [T]
    let cols: Int

    init(_ rows: Int, _ cols: Int, _ value: T) {
        data = [T](repeating: value, count: rows * cols)
        self.cols = cols
    }

    @inline(__always) subscript(_ r: Int, _ c: Int) -> T {
        get { data[r &* cols &+ c] }
        set { data[r &* cols &+ c] = newValue }
    }

    mutating func fill(_ value: T) {
        for i in data.indices { data[i] = value }
    }
}

/// Framing parameters of one channel (`SubstreamChannelParameters`).
struct AC4ChannelParams {
    var longFrame = 0
    var transfLengthIdx = [0, 0]
    var transfLength = [0, 0]
    var differentFraming = 0
    var maxSfbSide = [0, 0]
    var maxSfb = [0, 0]
    var scaleFactorGrouping = [Int](repeating: 0, count: 16)
    var numWindows = 0
    var numWindowGroups = 0
    var windowToGroup = [Int](repeating: 0, count: 17)
    var numWinInGroup = [Int](repeating: 0, count: 16)
    var dualMaxsfb = 0
    var sideLimited = 0
    var sideChannel = 0
}

/// Arithmetic decoder state for the speech spectral front end.
struct AC4ACState {
    var low: UInt32 = 0
    var range: UInt32 = 0
    var offset: UInt32 = 0
    var offset2: UInt32 = 0
}

/// Per-channel decoder state (`SubstreamChannel`).
final class AC4Channel {
    var scp = AC4ChannelParams()

    // A-SPX frequency tables
    var masterReset = 0
    var numSbgMaster = 0
    var numSbAspx = 0
    var numSbgNoise = 0
    var numSbgSigHighres = 0
    var numSbgSigLowres = 0
    var sba = 0
    var sbx = 0
    var sbz = 0

    var sapMode = 0
    var nPrev = 0

    var msUsed = AC4Grid(16, 128, 0)
    var sapCoeffUsed = AC4Grid(16, 128, 0)
    var dpcmAlphaQ = AC4Grid(16, 128, 0)
    var deltaCodeTime = 0

    var numSecLsf = [Int](repeating: 0, count: 16)
    var numSec = [Int](repeating: 0, count: 16)
    var sfbCb = AC4Grid(16, 128, 0)
    var sectCb = AC4Grid(16, 128, 0)
    var sectStart = AC4Grid(16, 128, 0)
    var sectEnd = AC4Grid(16, 128, 0)
    var sectSfbOffset = AC4Grid(16, 129, 0)

    var quantSpec = [Int](repeating: 0, count: 2048 + 8)
    var scaledSpec = [Float](repeating: 0, count: 2048)
    var specReord = [Float](repeating: 0, count: 2048)
    var offset2sfb = [Int](repeating: 0, count: 2048 + 8)
    var offset2g = [Int](repeating: 0, count: 2048 + 8)
    var winOffset = [Int](repeating: 0, count: 17)
    var overlap = [Float](repeating: 0, count: 4096)

    var maxQuantIdx = AC4Grid(16, 128, 0)
    var dpcmSf = AC4Grid(16, 128, 0)
    var dpcmSnf = AC4Grid(16, 128, 0)
    var snfDataExists = 0
    var sfGain = AC4Grid(16, 128, Float(0))

    // A-SPX framing and data
    var aspxIntClass = 0
    var aspxNumNoise = 0
    var aspxNumNoisePrev = 0
    var aspxNumRelLeft = 0
    var aspxNumRelRight = 0
    var aspxNumEnv = 0
    var aspxNumEnvPrev = 0
    var aspxFreqRes = [Int](repeating: 0, count: 9)
    var aspxVarBordLeft = 0
    var aspxVarBordRight = 0
    var aspxRelBordLeft = [Int](repeating: 0, count: 8)
    var aspxRelBordRight = [Int](repeating: 0, count: 8)
    var aspxTsgPtr = 0
    var aspxTsgPtrPrev = 0
    var aspxQmodeEnv = 0
    var aspxSigDeltaDir = [Int](repeating: 0, count: 9)
    var aspxNoiseDeltaDir = [Int](repeating: 0, count: 2)
    var aspxTnaMode = [Int](repeating: 0, count: 32)
    var aspxTnaModePrev = [Int](repeating: 0, count: 32)
    var aspxAddHarmonic = [Int](repeating: 0, count: 32)
    var aspxFicUsedInSfb = [Int](repeating: 0, count: 32)
    var aspxTicUsedInSlot = [Int](repeating: 0, count: 32)
    var aspxXoverSubbandOffset = 0
    var aspxBalance = 0

    var atsgFreqres = [Int](repeating: 0, count: 9)
    var atsgFreqresPrev = [Int](repeating: 0, count: 9)
    var atsgSig = [Int](repeating: 0, count: 10)
    var atsgNoise = [Int](repeating: 0, count: 4)
    var previousStopPos = 0

    var sbgNoise = [Int](repeating: 0, count: 8)
    var sbgSigLowres = [Int](repeating: 0, count: 32)
    var sbgSigHighres = [Int](repeating: 0, count: 32)
    var sbgLim = [Int](repeating: 0, count: 40)
    var sbgPatches = [Int](repeating: 0, count: 8)
    var sbgPatchNumSb = [Int](repeating: 0, count: 8)
    var sbgPatchStartSb = [Int](repeating: 0, count: 8)
    var sbgMaster = [Int](repeating: 0, count: 32)

    var numSbgSig = [Int](repeating: 0, count: 9)
    var sbgSig = AC4Grid(9, 32, 0)
    var numSbgPatches = 0
    var numSbgLim = 0

    /// [signal/noise][envelope][subband group]
    var aspxData = [AC4Grid(8, 64, 0), AC4Grid(8, 64, 0)]

    var qscfPrev = AC4Grid(8, 64, 0)
    var qscfNoisePrev = AC4Grid(2, 64, 0)
    var qscfSigSbg = AC4Grid(8, 64, 0)
    var qscfSigSbgPrev = AC4Grid(8, 64, 0)
    var qscfNoiseSbg = AC4Grid(2, 64, 0)
    var scfNoiseSbg = AC4Grid(2, 64, Float(0))
    var scfSigSbg = AC4Grid(8, 64, Float(0))
    var scfSigSb = AC4Grid(8, 64, Float(0))
    var scfNoiseSb = AC4Grid(8, 64, Float(0))

    var gainVec = [Float](repeating: 0, count: 32)
    var chirpArr = [Float](repeating: 0, count: 8)
    var chirpArrPrev = [Float](repeating: 0, count: 8)
    var estSigSb = AC4Grid(8, 64, Float(0))
    var sineIdxSb = AC4Grid(8, 64, Float(0))
    var sineIdxSbPrev = AC4Grid(8, 64, Float(0))
    var sineAreaSb = AC4Grid(8, 64, Float(0))
    var sineLevSb = AC4Grid(8, 64, Float(0))
    var noiseLevSb = AC4Grid(8, 64, Float(0))
    var sigGainSb = AC4Grid(8, 64, Float(0))
    var maxSigGainSbg = AC4Grid(8, 64, Float(0))
    var maxSigGainSb = AC4Grid(8, 64, Float(0))
    var noiseLevSbLim = AC4Grid(8, 64, Float(0))
    var sigGainSbLim = AC4Grid(8, 64, Float(0))
    var boostFactSbg = AC4Grid(8, 64, Float(0))
    var boostFactSb = AC4Grid(8, 64, Float(0))
    var sigGainSbAdj = AC4Grid(8, 64, Float(0))
    var noiseLevSbAdj = AC4Grid(8, 64, Float(0))
    var sineLevSbAdj = AC4Grid(8, 64, Float(0))

    var sineIdxPrev = AC4Grid(42, 64, 0)
    var noiseIdxPrev = AC4Grid(42, 64, 0)

    // A-CPL
    var acplInterpolationType = 0
    var acplNumParamSetsCod = 0
    var acplParamTimeslot = [0, 0]
    var acplData = AC4Grid(11, 16, 0)

    // Speech spectral front end (parsed only)
    var startBlock = 0, endBlock = 0
    var strideFlag = 0
    var numBands = 0
    var predictorPresence = [0, 0, 0, 0]
    var predictorLagDelta = [0, 0, 0, 0]
    var predictorLag = [0, 0, 0, 0]
    var variancePreserving = [0, 0, 0, 0]
    var allocOffset = [0, 0, 0, 0]
    var delta = [0, 0, 0, 0]
    var gainBits = [0, 0, 0, 0]
    var envIdx = [Int](repeating: 0, count: 19)
    var acs = AC4ACState()

    // Synthesis buffers
    var pcm = [Float](repeating: 0, count: 2048)
    var qmfFilt = [Float](repeating: 0, count: 640)
    var qsynFilt = [Float](repeating: 0, count: 1280)
    /// QMF matrices, [re/im][timeslot 0..<42][subband 0..<64] flattened.
    var Q = [Float](repeating: 0, count: 2 * 42 * 64)
    var QPrev = [Float](repeating: 0, count: 2 * 42 * 64)
    var QLow = [Float](repeating: 0, count: 2 * 42 * 64)
    var QLowPrev = [Float](repeating: 0, count: 2 * 42 * 64)
    var QLowExt = [Float](repeating: 0, count: 2 * 42 * 64)
    var QHigh = [Float](repeating: 0, count: 2 * 42 * 64)
    /// [subband][3][3][re/im]
    var cov = [Float](repeating: 0, count: 64 * 3 * 3 * 2)
    var alpha0 = [Float](repeating: 0, count: 64 * 2)
    var alpha1 = [Float](repeating: 0, count: 64 * 2)
    var Y = [Float](repeating: 0, count: 2 * 42 * 64)
    var YPrev = [Float](repeating: 0, count: 2 * 42 * 64)
    var qmfSine = [Float](repeating: 0, count: 2 * 42 * 64)
    var qmfNoise = [Float](repeating: 0, count: 2 * 42 * 64)

    /// Copies the transform framing from another channel that shares it.
    func copyFraming(from o: AC4Channel) {
        scp = o.scp
        sectSfbOffset = o.sectSfbOffset
        offset2sfb = o.offset2sfb
        offset2g = o.offset2g
        winOffset = o.winOffset
    }
}

/// Index into a [2][42][64] QMF matrix.
@inline(__always) func qi(_ c: Int, _ ts: Int, _ sb: Int) -> Int { (c &* 42 &+ ts) &* 64 &+ sb }

/// State shared by the channels of a substream (`Substream`).
final class AC4Substream {
    var codecMode = 0

    var aspxQuantModeEnv = 0
    var aspxStartFreq = 0
    var prevAspxStartFreq = 0
    var aspxStopFreq = 0
    var prevAspxStopFreq = 0
    var aspxMasterFreqScale = 0
    var prevAspxMasterFreqScale = 0
    var aspxInterpolation = 0
    var aspxPreflat = 0
    var aspxLimiter = 0
    var aspxNoiseSbg = 0
    var aspxNumEnvBitsFixfix = 0
    var aspxFreqResMode = 0

    var acplQmfBand = 0
    var acplParamBand = 0
    var acplNumParamBandsID = 0
    var acplQuantMode = [0, 0]

    var mode2ch = 0
    var chelMatsel = 0

    var compandOn = [Int](repeating: 0, count: 5)
    var compandAvg = 0

    var maxSfbMaster = 0

    var codingConfig = 0
    var mdctStereoProc = [0, 0]
    /// [window group][sfb][2][2]
    var matrixStereo = [Float](repeating: 0, count: 16 * 128 * 4)
    var alphaQ = AC4Grid(16, 128, Float(0))

    var specFrontendL = 0
    var specFrontendR = 0
    var specFrontendM = 0
    var specFrontendS = 0

    let ssch: [AC4Channel] = (0..<9).map { _ in AC4Channel() }
}
