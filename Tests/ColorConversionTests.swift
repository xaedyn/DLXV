import Testing
import simd
@testable import DLXV

private func approx(_ a: Float, _ b: Float, tolerance: Float = 1e-3) -> Bool {
    abs(a - b) < tolerance
}

struct ColorConversionTests {

    // Reference matrices: published BT.601/709/2020 limited-range 8-bit
    // Y'CbCr -> R'G'B' coefficients.

    @Test func rec709VideoRange8BitMatchesReferenceMatrix() {
        let c = ColorConversion(standard: .rec709, bitDepth: .eight)
        #expect(approx(c.matrix.columns.0.x, 1.16438356))   // luma scale
        #expect(approx(c.matrix.columns.2.x, 1.79274107))   // R from Cr
        #expect(approx(c.matrix.columns.1.y, -0.21324861))  // G from Cb
        #expect(approx(c.matrix.columns.2.y, -0.53290933))  // G from Cr
        #expect(approx(c.matrix.columns.1.z, 2.11240179))   // B from Cb
    }

    @Test func rec601VideoRange8BitMatchesReferenceMatrix() {
        let c = ColorConversion(standard: .rec601, bitDepth: .eight)
        #expect(approx(c.matrix.columns.0.x, 1.16438356))
        #expect(approx(c.matrix.columns.2.x, 1.59602678))
        #expect(approx(c.matrix.columns.1.y, -0.39176229))
        #expect(approx(c.matrix.columns.2.y, -0.81296765))
        #expect(approx(c.matrix.columns.1.z, 2.01723214))
    }

    @Test func rec2020VideoRange8BitMatchesReferenceMatrix() {
        let c = ColorConversion(standard: .rec2020, bitDepth: .eight)
        #expect(approx(c.matrix.columns.0.x, 1.16438356))
        #expect(approx(c.matrix.columns.2.x, 1.67867410))
        #expect(approx(c.matrix.columns.1.y, -0.18732601))
        #expect(approx(c.matrix.columns.2.y, -0.65042418))
        #expect(approx(c.matrix.columns.1.z, 2.14177196))
    }

    // Range handling: video-range white/black must map to exactly 1.0 / 0.0
    // regardless of the color standard.

    @Test func videoRange8BitWhiteMapsToFullWhite() {
        let c = ColorConversion(standard: .rec709, bitDepth: .eight)
        let white = SIMD3<Float>(235.0 / 255, 128.0 / 255, 128.0 / 255)
        let rgb = c.matrix * (white - c.offset)
        #expect(approx(rgb.x, 1))
        #expect(approx(rgb.y, 1))
        #expect(approx(rgb.z, 1))
    }

    @Test func videoRange8BitBlackMapsToZero() {
        let c = ColorConversion(standard: .rec709, bitDepth: .eight)
        let black = SIMD3<Float>(16.0 / 255, 128.0 / 255, 128.0 / 255)
        let rgb = c.matrix * (black - c.offset)
        #expect(approx(rgb.x, 0))
        #expect(approx(rgb.y, 0))
        #expect(approx(rgb.z, 0))
    }

    // 10-bit samples sit in the MSBs of 16-bit words: code << 6, then /65535.

    @Test func videoRange10BitWhiteMapsToFullWhite() {
        let c = ColorConversion(standard: .rec2020, bitDepth: .ten)
        let s: Float = 64.0 / 65535.0
        let white = SIMD3<Float>(940 * s, 512 * s, 512 * s)
        let rgb = c.matrix * (white - c.offset)
        #expect(approx(rgb.x, 1))
        #expect(approx(rgb.y, 1))
        #expect(approx(rgb.z, 1))
    }

    @Test func videoRange10BitBlackMapsToZero() {
        let c = ColorConversion(standard: .rec2020, bitDepth: .ten)
        let s: Float = 64.0 / 65535.0
        let black = SIMD3<Float>(64 * s, 512 * s, 512 * s)
        let rgb = c.matrix * (black - c.offset)
        #expect(approx(rgb.x, 0))
        #expect(approx(rgb.y, 0))
        #expect(approx(rgb.z, 0))
    }
}
