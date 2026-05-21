import simd

/// Linear-light gamut conversion between RGB color spaces that share the
/// D65 white point (BT.709, Display P3, BT.2020).
struct GamutConversion {
    /// Column-major 3x3 matrix: destinationRGB = matrix * sourceRGB, in linear light.
    let matrix: simd_float3x3

    /// CIE xy chromaticities of an RGB color space's primaries and white point.
    struct Primaries {
        let red: SIMD2<Float>
        let green: SIMD2<Float>
        let blue: SIMD2<Float>
        let white: SIMD2<Float>

        static let rec709 = Primaries(
            red: SIMD2(0.640, 0.330),
            green: SIMD2(0.300, 0.600),
            blue: SIMD2(0.150, 0.060),
            white: SIMD2(0.3127, 0.3290))

        static let displayP3 = Primaries(
            red: SIMD2(0.680, 0.320),
            green: SIMD2(0.265, 0.690),
            blue: SIMD2(0.150, 0.060),
            white: SIMD2(0.3127, 0.3290))

        static let rec2020 = Primaries(
            red: SIMD2(0.708, 0.292),
            green: SIMD2(0.170, 0.797),
            blue: SIMD2(0.131, 0.046),
            white: SIMD2(0.3127, 0.3290))
    }

    init(from source: Primaries, to destination: Primaries) {
        let sourceToXYZ = GamutConversion.linearRGBToXYZ(source)
        let destinationToXYZ = GamutConversion.linearRGBToXYZ(destination)
        matrix = destinationToXYZ.inverse * sourceToXYZ
    }

    /// Builds the linear RGB -> CIE XYZ matrix for a set of primaries, scaled so
    /// that RGB (1, 1, 1) yields the white point's XYZ.
    private static func linearRGBToXYZ(_ p: Primaries) -> simd_float3x3 {
        func xyz(_ c: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3(c.x / c.y, 1, (1 - c.x - c.y) / c.y)
        }
        let primaryXYZ = simd_float3x3(columns: (xyz(p.red), xyz(p.green), xyz(p.blue)))
        let scale = primaryXYZ.inverse * xyz(p.white)
        return primaryXYZ * simd_float3x3(diagonal: scale)
    }
}
