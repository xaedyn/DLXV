import AppKit
import CoreGraphics
import CoreVideo
import QuartzCore
import SwiftUI

/// SwiftUI wrapper that hosts the Metal-backed video surface.
struct MetalVideoView: NSViewRepresentable {
    let engine: PlayerEngine

    func makeNSView(context: Context) -> MetalVideoLayerView {
        MetalVideoLayerView(engine: engine)
    }

    func updateNSView(_ nsView: MetalVideoLayerView, context: Context) {}
}

/// An NSView backed by an EDR-enabled CAMetalLayer. A display link pulls the
/// decoded frame for each screen refresh and hands it to the renderer.
final class MetalVideoLayerView: NSView {
    private let engine: PlayerEngine
    private let renderer: VideoRenderer?
    private let edrMonitor = EDRMonitor()
    private var renderLink: CADisplayLink?

    init(engine: PlayerEngine) {
        self.engine = engine
        self.renderer = VideoRenderer()
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.framebufferOnly = true
        return metalLayer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        edrMonitor.attach(to: window)
        if window != nil {
            updateDrawableSize()
            startRenderLink()
        } else {
            stopRenderLink()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let backingScale = window?.backingScaleFactor ?? 2.0
        metalLayer.drawableSize = CGSize(width: bounds.width * backingScale,
                                         height: bounds.height * backingScale)
    }

    private func startRenderLink() {
        guard renderLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    private func stopRenderLink() {
        renderLink?.invalidate()
        renderLink = nil
    }

    @objc private func renderFrame(_ link: CADisplayLink) {
        guard let renderer, let metalLayer,
              let pixelBuffer = engine.copyPixelBufferForDisplay()
        else { return }
        renderer.render(pixelBuffer: pixelBuffer, to: metalLayer, headroom: edrMonitor.headroom)
    }
}
