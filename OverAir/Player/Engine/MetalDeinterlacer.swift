import Foundation
import Metal
import CoreVideo

/// Runs the Deinterlace.metal kernel on NV12 pixel buffers.
final class MetalDeinterlacer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache?

    private struct Params {
        var parity: UInt32
        var lowMotion: Float
        var highMotion: Float
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "deinterlacePlane"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
        guard let cache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var tex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &tex) == kCVReturnSuccess,
              let tex, let mtl = CVMetalTextureGetTexture(tex) else { return nil }
        return (tex, mtl)
    }

    /// Produces two progressive frames (first field, second field) from one interlaced frame.
    func deinterlace(current: CVPixelBuffer, previous: CVPixelBuffer?, topFieldFirst: Bool,
                     makeOutput: () -> CVPixelBuffer?) -> (CVPixelBuffer, CVPixelBuffer)? {
        guard let out1 = makeOutput(), let out2 = makeOutput(),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let prev = previous ?? current
        var keep: [Any] = []
        let first: UInt32 = topFieldFirst ? 0 : 1
        for (output, parity) in [(out1, first), (out2, 1 - first)] {
            for plane in 0..<2 {
                let fmt: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
                guard let c = texture(current, plane: plane, format: fmt),
                      let pv = texture(prev, plane: plane, format: fmt),
                      let o = texture(output, plane: plane, format: fmt),
                      let enc = cmd.makeComputeCommandEncoder() else { return nil }
                keep.append(contentsOf: [c.0, pv.0, o.0])
                enc.setComputePipelineState(pipeline)
                enc.setTexture(c.1, index: 0)
                enc.setTexture(pv.1, index: 1)
                enc.setTexture(o.1, index: 2)
                var params = Params(parity: parity, lowMotion: 0.02, highMotion: 0.08)
                enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: (o.1.width + 15) / 16, height: (o.1.height + 15) / 16, depth: 1)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = keep
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferPixelAspectRatioKey] {
            if let v = CVBufferCopyAttachment(current, key, nil) {
                CVBufferSetAttachment(out1, key, v, .shouldPropagate)
                CVBufferSetAttachment(out2, key, v, .shouldPropagate)
            }
        }
        return (out1, out2)
    }
}
