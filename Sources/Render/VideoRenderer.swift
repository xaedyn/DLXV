import CoreVideo
import Dispatch
import Metal
import QuartzCore
import simd

/// Renders decoded biplanar YCbCr video frames to a CAMetalLayer with no
/// CPU-side pixel copies. Each plane's IOSurface-backed memory is wrapped
/// directly as a Metal texture; the shader performs the YCbCr -> RGB conversion.
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

    // Keeps each in-flight frame's plane textures alive until the GPU is done.
    // A slot is only reused once its frame has signalled completion.
    private var textureRing = [[CVMetalTexture]](repeating: [], count: VideoRenderer.maxFramesInFlight)
    private var ringIndex = 0

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

    func render(pixelBuffer: CVPixelBuffer, to layer: CAMetalLayer) {
        // Skip this frame instead of blocking the main thread if the GPU is behind.
        guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
        var completionOwnsPermit = false
        defer { if !completionOwnsPermit { inFlightSemaphore.signal() } }

        guard let frame = decodeFrame(pixelBuffer),
              let luma = makeTexture(from: pixelBuffer, plane: 0, format: frame.lumaFormat),
              let chroma = makeTexture(from: pixelBuffer, plane: 1, format: frame.chromaFormat),
              let drawable = layer.nextDrawable()
        else { return }

        var scale = aspectFitScale(videoWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                                   videoHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                                   into: layer.drawableSize)
        var colorMatrix = frame.conversion.matrix
        var colorOffset = frame.conversion.offset

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(luma.texture, index: 0)
        encoder.setFragmentTexture(chroma.texture, index: 1)
        encoder.setFragmentBytes(&colorMatrix, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        encoder.setFragmentBytes(&colorOffset, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
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

    private struct DecodedFrame {
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat
        let conversion: ColorConversion
    }

    /// Reads the pixel format and color metadata needed to render the frame,
    /// or nil if the frame is not a supported biplanar YCbCr format.
    private func decodeFrame(_ pixelBuffer: CVPixelBuffer) -> DecodedFrame? {
        let bitDepth: ColorConversion.BitDepth
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
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

        let fallback: ColorConversion.Standard = switch bitDepth {
        case .ten: .rec2020
        case .eight: .rec709
        }
        return DecodedFrame(
            lumaFormat: lumaFormat,
            chromaFormat: chromaFormat,
            conversion: ColorConversion(standard: ycbcrStandard(of: pixelBuffer, fallback: fallback),
                                        bitDepth: bitDepth))
    }

    /// Reads the YCbCr matrix attachment, falling back when it is absent.
    private func ycbcrStandard(of pixelBuffer: CVPixelBuffer,
                               fallback: ColorConversion.Standard) -> ColorConversion.Standard {
        guard let name = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        else { return fallback }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return .rec2020 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return .rec601 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { return .rec709 }
        return fallback
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
        guard size.width > 0, size.height > 0, videoWidth > 0, videoHeight > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let videoAspect = Float(videoWidth) / Float(videoHeight)
        let layerAspect = Float(size.width) / Float(size.height)
        if videoAspect > layerAspect {
            return SIMD2<Float>(1, layerAspect / videoAspect)
        } else {
            return SIMD2<Float>(videoAspect / layerAspect, 1)
        }
    }
}
