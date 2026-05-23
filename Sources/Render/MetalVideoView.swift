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
/// decoded frame for each screen refresh and hands it to the renderer. The
/// view also handles keyboard and click playback controls.
final class MetalVideoLayerView: NSView {
    private let engine: PlayerEngine
    private let renderer: VideoRenderer?
    private let edrMonitor = EDRMonitor()
    private var renderLink: CADisplayLink?

    // The frame rate currently programmed into the display link. Kept here so
    // we only reprogram the link when the engine's reported rate actually
    // changes (e.g. when a new file with a different frame rate is opened).
    private var appliedFrameRate: Float = 0

    init(engine: PlayerEngine) {
        self.engine = engine
        self.renderer = VideoRenderer()
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

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
            window?.makeFirstResponder(self)
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
        // Match the display link to the current video's frame rate. ProMotion
        // (and VRR external displays) can then downshift the panel instead of
        // refreshing faster than the content has frames to show.
        let targetRate = engine.nominalFrameRate
        if targetRate != appliedFrameRate {
            appliedFrameRate = targetRate
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: targetRate, maximum: targetRate, preferred: targetRate)
        }

        guard let renderer, let metalLayer,
              let pixelBuffer = engine.copyPixelBufferForDisplay()
        else { return }
        renderer.render(pixelBuffer: pixelBuffer, to: metalLayer, headroom: edrMonitor.headroom)
    }

    // MARK: - Playback controls

    override func mouseDown(with event: NSEvent) {
        engine.togglePlayPause()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: engine.togglePlayPause()    // space
        case 123: engine.seek(by: -10)        // left arrow
        case 124: engine.seek(by: 10)         // right arrow
        default:
            if event.charactersIgnoringModifiers == "f" {
                window?.toggleFullScreen(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
