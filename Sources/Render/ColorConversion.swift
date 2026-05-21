import simd

/// YCbCr -> R'G'B' conversion parameters for a video-range decoded frame.
///
/// The renderer applies this in the shader as `rgb = matrix * (yuv - offset)`,
/// where `yuv` holds the normalized luma and chroma texture samples.
struct ColorConversion {
    /// Maps the offset-removed (Y, Cb, Cr) sample to (R, G, B). Column-major.
    let matrix: simd_float3x3
    /// Subtracted from the normalized (Y, Cb, Cr) sample before the matrix.
    let offset: SIMD3<Float>

    /// The YCbCr standard, which sets the luma weighting coefficients.
    enum Standard {
        case rec601
        case rec709
        case rec2020

        fileprivate var lumaWeights: (kr: Float, kb: Float) {
            switch self {
            case .rec601:  (0.299, 0.114)
            case .rec709:  (0.2126, 0.0722)
            case .rec2020: (0.2627, 0.0593)
            }
        }
    }

    /// Bit depth of the decoded luma and chroma samples.
    enum BitDepth {
        case eight
        case ten

        /// Video-range code values scale by 2^(N-8) relative to 8-bit.
        fileprivate var codeMultiplier: Float {
            switch self {
            case .eight: 1
            case .ten:   4
            }
        }

        /// Factor mapping a code value to the normalized texture sample.
        /// 8-bit (r8Unorm): code / 255.
        /// 10-bit: 10 bits in the MSBs of 16 bits -> (code << 6) / 65535.
        fileprivate var sampleScale: Float {
            switch self {
            case .eight: 1.0 / 255.0
            case .ten:   64.0 / 65535.0
            }
        }
    }

    init(standard: Standard, bitDepth: BitDepth) {
        let codeScale = bitDepth.codeMultiplier
        let sampleScale = bitDepth.sampleScale

        let lumaBlack = 16 * codeScale
        let lumaRange = 219 * codeScale
        let chromaCenter = 128 * codeScale
        let chromaRange = 224 * codeScale

        offset = SIMD3<Float>(lumaBlack, chromaCenter, chromaCenter) * sampleScale

        let lumaScale = 1 / (lumaRange * sampleScale)
        let chromaScale = 1 / (chromaRange * sampleScale)

        let (kr, kb) = standard.lumaWeights
        let kg = 1 - kr - kb

        // De-scaled YCbCr -> RGB with the video-range scaling folded into each column.
        let yColumn = SIMD3<Float>(repeating: lumaScale)
        let cbColumn = SIMD3<Float>(
            0,
            chromaScale * (-2 * kb * (1 - kb) / kg),
            chromaScale * (2 * (1 - kb))
        )
        let crColumn = SIMD3<Float>(
            chromaScale * (2 * (1 - kr)),
            chromaScale * (-2 * kr * (1 - kr) / kg),
            0
        )
        matrix = simd_float3x3(columns: (yColumn, cbColumn, crColumn))
    }
}
