import AVFoundation
import CoreVideo
import QuartzCore

/// Wraps AVPlayer and its video output, exposing decoded frames for rendering
/// and basic playback control.
@MainActor
final class PlayerEngine {
    let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?

    /// Nominal frame rate of the current video track, in frames per second.
    /// Defaults to 60 until a file is loaded, then updates asynchronously when
    /// each new item's video track reports its rate. The renderer reads this to
    /// match the CADisplayLink to content rate, which lets ProMotion downshift
    /// the panel and avoids redundant per-tick AVFoundation queries.
    private(set) var nominalFrameRate: Float = 60

    /// Monotonically incremented each time a new file is opened so that a
    /// stale async track-load can detect it's been superseded.
    private var loadGeneration: UInt64 = 0

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
        loadNominalFrameRate(for: item)
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

    /// Asynchronously reads the new item's nominal frame rate. The result is
    /// only applied if no newer file has been opened in the meantime.
    private func loadNominalFrameRate(for item: AVPlayerItem) {
        loadGeneration &+= 1
        let myGeneration = loadGeneration
        Task { @MainActor [weak self] in
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                let rate = try await track.load(.nominalFrameRate)
                guard let self, self.loadGeneration == myGeneration else { return }
                self.nominalFrameRate = rate > 0 ? rate : 60
            } catch {
                // Keep the previous rate if the track can't report one.
            }
        }
    }
}
