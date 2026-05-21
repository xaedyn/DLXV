import Testing
import simd
@testable import DLXV

private func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-3) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.z - b.z) < tolerance
}

struct GamutConversionTests {

    @Test func sameGamutIsIdentity() {
        let c = GamutConversion(from: .rec709, to: .rec709)
        #expect(approx(c.matrix * SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 0, 0)))
        #expect(approx(c.matrix * SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)))
        #expect(approx(c.matrix * SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1)))
    }

    @Test func whiteIsPreservedRec709ToDisplayP3() {
        // Both spaces use the D65 white point, so white maps to white.
        let c = GamutConversion(from: .rec709, to: .displayP3)
        #expect(approx(c.matrix * SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1)))
    }

    @Test func whiteIsPreservedRec2020ToDisplayP3() {
        let c = GamutConversion(from: .rec2020, to: .displayP3)
        #expect(approx(c.matrix * SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1)))
    }

    @Test func sharedBluePrimaryStaysOnBlueAxis() {
        // BT.709 and Display P3 share the same blue primary chromaticity,
        // so pure BT.709 blue maps to pure Display P3 blue.
        let c = GamutConversion(from: .rec709, to: .displayP3)
        let blue = c.matrix * SIMD3<Float>(0, 0, 1)
        #expect(abs(blue.x) < 1e-3)
        #expect(abs(blue.y) < 1e-3)
        #expect(blue.z > 0.5)
    }

    @Test func roundTripIsIdentity() {
        let forward = GamutConversion(from: .rec709, to: .displayP3).matrix
        let back = GamutConversion(from: .displayP3, to: .rec709).matrix
        let identity = back * forward
        #expect(approx(identity * SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 0, 0)))
        #expect(approx(identity * SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)))
        #expect(approx(identity * SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1)))
    }
}
