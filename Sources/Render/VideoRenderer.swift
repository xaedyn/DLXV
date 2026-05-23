import CoreVideo
import Dispatch
import Metal
import QuartzCore
import simd

/// The transfer function of the decoded video, matching the shader's branch IDs.
enum TransferFunction: UInt32 {
    case sdr = 0
    case pq = 1
    case hlg = 2
}

/// Renders decoded biplanar YCbCr video frames to a CAMetalLayer with no
/// CPU-side pixel copies. Each plane's IOSurface-backed memory is wrapped
/// directly as a Metal texture; the shader performs color conversion, HDR
/// transfer-function decoding, gamut conversion, and tone mapping.
///
/// The per-frame hot path is tight by design: pixel-buffer metadata, the
/// render pass descriptor, and the aspect-fit scale are all cached across
/// frames and only rebuilt when their inputs change.
@MainActor
final class VideoRenderer {
    let device: any MTLDevice

    private static let maxFramesInFlight = 3

    private let commandQueue: any MTLCommandQueue
    private let pipelineState: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    // Bounds how many frames the GPU is working on at once. The main thread
    // skips a frame rather than blocking when every slot is occupied.
    private let inFlightSemaphore = DispatchSemaphore(value: VideoRenderer.maxFramesInFlight)

    // Reused across frames; only the texture attachment changes per pass.
    // makeRenderCommandEncoder captures the descriptor's contents at call
    // time, so mutating it after each encoder is created is safe.
    private let passDescriptor: MTLRenderPassDescriptor = {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }()

    // Keeps each in-flight frame's plane textures alive until the GPU is done.
    // A slot is only reused once its frame has signalled completion.
    private var textureRing = [[CVMetalTexture]](repeating: [], count: VideoRenderer.maxFramesInFlight)
    private var ringIndex = 0

    // Metadata read from CVPixelBuffer attachments is constant for a given
    // stream. Cache the decoded result and reuse it while the attachment
    // references are unchanged. CoreVideo returns interned CFString constants
    // for these attachments, so reference identity is a cheap, reliable
    // invalidation signal.
    private var cachedPixelFormat: OSType = 0
    private var cachedMatrixAttachment: AnyObject?
    private var cachedPrimariesAttachment: AnyObject?
    private var cachedTransferAttachment: AnyObject?
    private var cachedFrame: DecodedFrame?

    // The aspect-fit scale is stable across frames at the same drawable size
    // and source dimensions. Recompute only when one of the inputs changes.
    private var cachedScale: SIMD2<Float> = SIMD2<Float>(1, 1)
    private var cachedScaleSourceWidth: Int = 0
    private var cachedScaleSourceHeight: Int = 0
    private var cachedScaleDrawableWidth: CGFloat = 0
    private var cachedScaleDrawableHeight: CGFloat = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "video_vertex"),
              let fragmentFunction = library.makeFunction(name: "video_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.textureCache = cache
    }

    func render(pixelBuffer: CVPixelBuffer, to layer: CAMetalLayer, headroom: Float) {
        // Skip this frame instead of blocking the main thread if the GPU is behind.
        guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
        var completionOwnsPermit = false
        defer { if !completionOwnsPermit { inFlightSemaphore.signal() } }

        guard let frame = decodeFrame(pixelBuffer),
              let luma = makeTexture(from: pixelBuffer, plane: 0, format: frame.lumaFormat),
              let chroma = makeTexture(from: pixelBuffer, plane: 1, format: frame.chromaFormat),
              let drawable = layer.nextDrawable()
        else { return }

        var scale = aspectFitScale(
            videoWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            videoHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            into: layer.drawableSize)
        var colorMatrix = frame.conversion.matrix
        var colorOffset = frame.conversion.offset
        var gamutMatrix = frame.gamut.matrix
        var transferFunction = frame.transferFunction.rawValue
        var displayHeadroom = max(headroom, 1.0)

        passDescriptor.colorAttachments[0].texture = drawable.texture

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(luma.texture, index: 0)
        encoder.setFragmentTexture(chroma.texture, index: 1)
        encoder.setFragmentBytes(&colorMatrix, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        encoder.setFragmentBytes(&colorOffset, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&gamutMatrix, length: MemoryLayout<simd_float3x3>.stride, index: 2)
        encoder.setFragmentBytes(&transferFunction, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setFragmentBytes(&displayHeadroom, length: MemoryLayout<Float>.stride, index: 4)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Park both plane textures in this frame's ring slot. The slot's previous
        // occupants are three frames old, so the GPU has finished reading them.
        textureRing[ringIndex] = [luma.cvTexture, chroma.cvTexture]
        ringIndex = (ringIndex + 1) % Self.maxFramesInFlight

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        completionOwnsPermit = true

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Frame decoding

    struct DecodedFrame {
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat
        let conversion: ColorConversion
        let gamut: GamutConversion
        let transferFunction: TransferFunction
    }

    /// Reads the pixel format and color metadata needed to render the frame,
    /// or nil if the frame is not a supported biplanar YCbCr format. Results
    /// are cached across frames keyed on the source attachment references —
    /// CoreVideo returns interned CFString constants for these attachments,
    /// so reference identity is a cheap and reliable invalidation signal.
    func decodeFrame(_ pixelBuffer: CVPixelBuffer) -> DecodedFrame? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let matrixAttachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as AnyObject?
        let primariesAttachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as AnyObject?
        let transferAttachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as AnyObject?

        if let cachedFrame,
           pixelFormat == cachedPixelFormat,
           matrixAttachment === cachedMatrixAttachment,
           primariesAttachment === cachedPrimariesAttachment,
           transferAttachment === cachedTransferAttachment {
            return cachedFrame
        }

        guard let frame = decodeFrameUncached(
            pixelFormat: pixelFormat,
            matrixName: matrixAttachment as? String,
            primariesName: primariesAttachment as? String,
            transferName: transferAttachment as? String)
        else { return nil }

        cachedPixelFormat = pixelFormat
        cachedMatrixAttachment = matrixAttachment
        cachedPrimariesAttachment = primariesAttachment
        cachedTransferAttachment = transferAttachment
        cachedFrame = frame
        return frame
    }

    private func decodeFrameUncached(
        pixelFormat: OSType,
        matrixName: String?,
        primariesName: String?,
        transferName: String?
    ) -> DecodedFrame? {
        let bitDepth: ColorConversion.BitDepth
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            bitDepth = .ten
            lumaFormat = .r16Unorm
            chromaFormat = .rg16Unorm
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            bitDepth = .eight
            lumaFormat = .r8Unorm
            chromaFormat = .rg8Unorm
        default:
            return nil
        }

        let fallbackStandard: ColorConversion.Standard = switch bitDepth {
        case .ten: .rec2020
        case .eight: .rec709
        }
        let fallbackPrimaries: GamutConversion.Primaries = switch bitDepth {
        case .ten: .rec2020
        case .eight: .rec709
        }

        return DecodedFrame(
            lumaFormat: lumaFormat,
            chromaFormat: chromaFormat,
            conversion: ColorConversion(
                standard: ycbcrStandard(named: matrixName, fallback: fallbackStandard),
                bitDepth: bitDepth),
            gamut: GamutConversion(
                from: sourcePrimaries(named: primariesName, fallback: fallbackPrimaries),
                to: .displayP3),
            transferFunction: transferFunction(named: transferName))
    }

    private func ycbcrStandard(named name: String?,
                               fallback: ColorConversion.Standard) -> ColorConversion.Standard {
        guard let name else { return fallback }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return .rec2020 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return .rec601 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { return .rec709 }
        return fallback
    }

    private func sourcePrimaries(named name: String?,
                                 fallback: GamutConversion.Primaries) -> GamutConversion.Primaries {
        guard let name else { return fallback }
        if name == kCVImageBufferColorPrimaries_ITU_R_2020 as String { return .rec2020 }
        if name == kCVImageBufferColorPrimaries_ITU_R_709_2 as String { return .rec709 }
        if name == kCVImageBufferColorPrimaries_P3_D65 as String { return .displayP3 }
        return fallback
    }

    private func transferFunction(named name: String?) -> TransferFunction {
        guard let name else { return .sdr }
        if name == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        if name == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        return .sdr
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat
    ) -> (texture: any MTLTexture, cvTexture: CVMetalTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil,
                format, width, height, plane, &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else { return nil }
        return (texture, cvTexture)
    }

    private func aspectFitScale(videoWidth: Int, videoHeight: Int, into size: CGSize) -> SIMD2<Float> {
        if videoWidth == cachedScaleSourceWidth,
           videoHeight == cachedScaleSourceHeight,
           size.width == cachedScaleDrawableWidth,
           size.height == cachedScaleDrawableHeight {
            return cachedScale
        }

        let scale: SIMD2<Float>
        if size.width > 0, size.height > 0, videoWidth > 0, videoHeight > 0 {
            let videoAspect = Float(videoWidth) / Float(videoHeight)
            let layerAspect = Float(size.width) / Float(size.height)
            if videoAspect > layerAspect {
                scale = SIMD2<Float>(1, layerAspect / videoAspect)
            } else {
                scale = SIMD2<Float>(videoAspect / layerAspect, 1)
            }
        } else {
            scale = SIMD2<Float>(1, 1)
        }

        cachedScale = scale
        cachedScaleSourceWidth = videoWidth
        cachedScaleSourceHeight = videoHeight
        cachedScaleDrawableWidth = size.width
        cachedScaleDrawableHeight = size.height
        return scale
    }
}
