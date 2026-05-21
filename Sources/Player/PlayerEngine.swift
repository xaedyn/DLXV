import AVFoundation
import CoreVideo
import QuartzCore

/// Wraps AVPlayer and its video output, exposing decoded frames for rendering
/// and basic playback control.
@MainActor
final class PlayerEngine {
    let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?

    func open(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Seeks relative to the current time by the given number of seconds.
    func seek(by seconds: Double) {
        let target = CMTimeAdd(player.currentTime(),
                               CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: target)
    }

    /// Returns the frame for the current display time, or nil if no new frame is ready.
    func copyPixelBufferForDisplay() -> CVPixelBuffer? {
        guard let videoOutput else { return nil }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        return videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    }
}
