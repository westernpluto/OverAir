import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Converts decoded MPEG-2 pictures into IOSurface-backed NV12 pixel buffers.
final class PixelBufferFactory {
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    func makeBuffer(from pic: MPEG2Picture) -> CVPixelBuffer? {
        let w = pic.width & ~1, h = pic.height & ~1
        guard w > 0, h > 0, let buffer = makeBuffer(width: w, height: h) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let cDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for r in 0..<h {
            (yDst + r * yStride).update(from: pic.y + r * pic.yStride, count: w)
        }
        let cw = w / 2
        for r in 0..<(h / 2) {
            let cb = pic.cb + r * pic.cStride, cr = pic.cr + r * pic.cStride
            let d = cDst + r * cStride
            for i in 0..<cw {
                d[2 * i] = cb[i]
                d[2 * i + 1] = cr[i]
            }
        }
        Self.tag(buffer, width: w, height: h, displayAspect: pic.displayAspect)
        return buffer
    }

    /// Colorimetry and pixel aspect ratio (SD broadcasts are anamorphic).
    static func tag(_ buffer: CVPixelBuffer, width: Int, height: Int, displayAspect: Double) {
        let hd = height >= 720
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let par = displayAspect * Double(height) / Double(width)
        if abs(par - 1) > 0.01 {
            let h = 1000, v = Int((1000 / par).rounded())
            let dict = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: h, kCVImageBufferPixelAspectRatioVerticalSpacingKey: v] as CFDictionary
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, dict, .shouldPropagate)
        }
    }

    static func sampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }
}

/// Packages H.264 / HEVC access units (Annex B) as compressed sample buffers for
/// AVSampleBufferDisplayLayer, which decodes them in hardware. Also extracts captions from SEI.
final class CompressedVideoPackager {
    let isHEVC: Bool
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []
    private(set) var width = 0
    private(set) var height = 0
    var onCaptions: (([UInt8], Int64?) -> Void)?

    init(hevc: Bool) { isHEVC = hevc }

    /// Splits an Annex B buffer into NAL units (without start codes).
    static func nalUnits(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var i = 0, start = -1
        let n = d.count
        while i + 2 < n {
            if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 {
                if start >= 0 {
                    var e = i
                    while e > start && d[e - 1] == 0 { e -= 1 }
                    units.append(d[start..<e])
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < n { units.append(d[start..<n]) }
        return units
    }

    func makeSampleBuffer(_ payload: [UInt8], pts: Int64?, dts: Int64?) -> CMSampleBuffer? {
        let nals = Self.nalUnits(payload)
        var sets: [[UInt8]] = []
        var body: [UInt8] = []
        var isKey = false
        for nal in nals where !nal.isEmpty {
            let type: Int
            if isHEVC { type = Int((nal.first! >> 1) & 0x3F) } else { type = Int(nal.first! & 0x1F) }
            if isHEVC {
                switch type {
                case 32, 33, 34: sets.append(Array(nal)); continue
                case 35: continue // AUD
                case 39: handleSEI(Array(nal), pts: pts, hevc: true)
                case 16...21: isKey = true
                default: break
                }
            } else {
                switch type {
                case 7, 8: sets.append(Array(nal)); continue
                case 9: continue // AUD
                case 6: handleSEI(Array(nal), pts: pts, hevc: false)
                case 5: isKey = true
                default: break
                }
            }
            let len = UInt32(nal.count)
            body.append(UInt8(len >> 24)); body.append(UInt8((len >> 16) & 0xFF))
            body.append(UInt8((len >> 8) & 0xFF)); body.append(UInt8(len & 0xFF))
            body.append(contentsOf: nal)
        }
        if !sets.isEmpty && sets != parameterSets { updateFormat(sets) }
        guard let format, !body.isEmpty else { return nil }

        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: body.count,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: body.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        body.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: body.count) }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts.map { CMTime(value: $0, timescale: 90000) } ?? .invalid,
                                        decodeTimeStamp: (dts ?? pts).map { CMTime(value: $0, timescale: 90000) } ?? .invalid)
        var size = body.count
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sb)
        if let sb, !isKey, let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    private func updateFormat(_ sets: [[UInt8]]) {
        var newFormat: CMVideoFormatDescription?
        let ptrs = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let pointers = ptrs.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        let status: OSStatus
        if isHEVC {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
        }
        if status == noErr, let newFormat {
            format = newFormat
            parameterSets = sets
            let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
            width = Int(dims.width); height = Int(dims.height)
        }
    }

    /// SEI: user_data_registered_itu_t_t35 carrying ATSC "GA94" cc_data.
    private func handleSEI(_ nal: [UInt8], pts: Int64?, hevc: Bool) {
        let rbsp = Self.removeEmulation(nal, from: hevc ? 2 : 1)
        var i = 0
        while i + 2 < rbsp.count {
            var type = 0, size = 0
            while i < rbsp.count && rbsp[i] == 0xFF { type += 255; i += 1 }
            guard i < rbsp.count else { return }
            type += Int(rbsp[i]); i += 1
            while i < rbsp.count && rbsp[i] == 0xFF { size += 255; i += 1 }
            guard i < rbsp.count else { return }
            size += Int(rbsp[i]); i += 1
            guard i + size <= rbsp.count else { return }
            if type == 4 && size > 10 && rbsp[i] == 0xB5 {
                // country 0xB5, provider 0x0031, then "GA94" user data
                let start = i + 3
                let cc = rbsp[start..<(i + size)].withUnsafeBufferPointer {
                    MPEG2VideoDecoder.parseCaptionUserData($0.baseAddress!, count: $0.count)
                }
                if !cc.isEmpty { onCaptions?(cc, pts) }
            }
            i += size
            if i < rbsp.count && rbsp[i] == 0x80 { break }
        }
    }

    static func removeEmulation(_ d: [UInt8], from start: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(d.count)
        var zeros = 0
        var i = start
        while i < d.count {
            let b = d[i]
            if zeros >= 2 && b == 3 { zeros = 0; i += 1; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
            i += 1
        }
        return out
    }
}
