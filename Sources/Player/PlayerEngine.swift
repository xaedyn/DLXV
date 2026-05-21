import AVFoundation
import CoreVideo
import QuartzCore

/// Wraps AVPlayer and its video output, exposing decoded frames for rendering.
@MainActor
final class PlayerEngine {
    let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?

    func open(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)
        player.play()
    }

    /// Returns the frame for the current display time, or nil if no new frame is ready.
    func copyPixelBufferForDisplay() -> CVPixelBuffer? {
        guard let videoOutput else { return nil }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        return videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    }
}
