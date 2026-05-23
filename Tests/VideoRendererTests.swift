import CoreVideo
import Metal
import Testing
@testable import DLXV

/// Characterization tests for `VideoRenderer.decodeFrame`. The tests build
/// CVPixelBuffers with specific format and color attachments and verify the
/// renderer maps them to the expected `DecodedFrame`. They lock in the
/// frame-decoding behavior and protect the per-stream metadata cache against
/// regressions.
@MainActor
struct VideoRendererTests {

    // MARK: - Pixel-format mapping

    @Test func decodes10BitPQasHDR10() throws {
        let renderer = try #require(VideoRenderer())
        let pixelBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        let frame = try #require(renderer.decodeFrame(pixelBuffer))
        #expect(frame.lumaFormat == .r16Unorm)
        #expect(frame.chromaFormat == .rg16Unorm)
        #expect(frame.transferFunction == .pq)
    }

    @Test func decodes10BitHLG() throws {
        let renderer = try #require(VideoRenderer())
        let pixelBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let frame = try #require(renderer.decodeFrame(pixelBuffer))
        #expect(frame.lumaFormat == .r16Unorm)
        #expect(frame.chromaFormat == .rg16Unorm)
        #expect(frame.transferFunction == .hlg)
    }

    @Test func decodes8BitAsSDR() throws {
        let renderer = try #require(VideoRenderer())
        let pixelBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transferFunction: nil)
        let frame = try #require(renderer.decodeFrame(pixelBuffer))
        #expect(frame.lumaFormat == .r8Unorm)
        #expect(frame.chromaFormat == .rg8Unorm)
        #expect(frame.transferFunction == .sdr)
    }

    @Test func returnsNilForUnsupportedPixelFormat() throws {
        let renderer = try #require(VideoRenderer())
        let pixelBuffer = makePixelBuffer(pixelFormat: kCVPixelFormatType_32BGRA)
        #expect(renderer.decodeFrame(pixelBuffer) == nil)
    }

    // MARK: - Caching invariants

    @Test func cacheReturnsConsistentResultForRepeatedCalls() throws {
        let renderer = try #require(VideoRenderer())
        let pixelBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        for _ in 0..<3 {
            let frame = try #require(renderer.decodeFrame(pixelBuffer))
            #expect(frame.lumaFormat == .r16Unorm)
            #expect(frame.chromaFormat == .rg16Unorm)
            #expect(frame.transferFunction == .pq)
        }
    }

    @Test func cacheInvalidatesWhenAttachmentsChange() throws {
        let renderer = try #require(VideoRenderer())
        let pqBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        let hlgBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG)

        let pqFirst = try #require(renderer.decodeFrame(pqBuffer))
        let hlg = try #require(renderer.decodeFrame(hlgBuffer))
        let pqAgain = try #require(renderer.decodeFrame(pqBuffer))

        #expect(pqFirst.transferFunction == .pq)
        #expect(hlg.transferFunction == .hlg)
        #expect(pqAgain.transferFunction == .pq)
    }

    @Test func cacheInvalidatesAcrossBitDepths() throws {
        let renderer = try #require(VideoRenderer())
        let hdrBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        let sdrBuffer = makePixelBuffer(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transferFunction: nil)

        let hdr = try #require(renderer.decodeFrame(hdrBuffer))
        let sdr = try #require(renderer.decodeFrame(sdrBuffer))

        #expect(hdr.lumaFormat == .r16Unorm)
        #expect(sdr.lumaFormat == .r8Unorm)
        #expect(hdr.transferFunction == .pq)
        #expect(sdr.transferFunction == .sdr)
    }

    // MARK: - Helpers

    /// Builds a CVPixelBuffer with the given pixel format and optional color
    /// attachments. Used to exercise VideoRenderer.decodeFrame.
    private func makePixelBuffer(
        width: Int = 16,
        height: Int = 16,
        pixelFormat: OSType,
        matrix: CFString? = nil,
        primaries: CFString? = nil,
        transferFunction: CFString? = nil
    ) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(
            nil, width, height, pixelFormat,
            attributes as CFDictionary, &pixelBuffer)
        precondition(status == kCVReturnSuccess, "Failed to create test pixel buffer")
        let pb = pixelBuffer!
        if let matrix {
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
        if let primaries {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transferFunction {
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)
        }
        return pb
    }
}
