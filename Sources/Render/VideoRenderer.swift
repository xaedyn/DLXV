import CoreVideo
import Dispatch
import Metal
import QuartzCore

/// Renders decoded video frames to a CAMetalLayer with no CPU-side pixel copies.
/// The frame's IOSurface-backed pixel buffer is wrapped directly as a Metal texture.
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

    // Keeps each in-flight frame's texture alive until the GPU is done with it.
    // A slot is only reused once its frame has signalled completion.
    private var textureRing = [CVMetalTexture?](repeating: nil, count: VideoRenderer.maxFramesInFlight)
    private var ringIndex = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "passthrough_vertex"),
              let fragmentFunction = library.makeFunction(name: "passthrough_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

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

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else { return }

        guard let drawable = layer.nextDrawable() else { return }

        var scale = aspectFitScale(videoWidth: width,
                                   videoHeight: height,
                                   into: layer.drawableSize)

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
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Park the texture in this frame's ring slot. The slot's previous
        // occupant is three frames old, so the GPU has finished reading it.
        textureRing[ringIndex] = cvTexture
        ringIndex = (ringIndex + 1) % Self.maxFramesInFlight

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        completionOwnsPermit = true

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
