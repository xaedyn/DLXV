#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Aspect-fit quad. `scale` shrinks one axis so the video keeps its aspect ratio;
// the uncovered area shows the clear color.
vertex VertexOut video_vertex(uint vertexID [[vertex_id]],
                              constant float2 &scale [[buffer(0)]]) {
    const float2 quad[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    const float2 uv[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(quad[vertexID] * scale, 0.0, 1.0);
    out.texCoord = uv[vertexID];
    return out;
}

// SDR reference white in nits (BT.2408): the linear value treated as 1.0 output.
constant float referenceWhiteNits = 203.0;

// SMPTE ST 2084 (PQ) EOTF: encoded [0,1] -> linear luminance in nits.
static float3 pqToLinearNits(float3 e) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    float3 ep = pow(e, 1.0 / m2);
    float3 num = max(ep - c1, 0.0);
    float3 den = max(c2 - c3 * ep, 1e-6);
    return 10000.0 * pow(num / den, 1.0 / m1);
}

// BT.2100 HLG inverse OETF: signal [0,1] -> scene linear [0,1].
static float3 hlgInverseOETF(float3 v) {
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    float3 lo = v * v / 3.0;
    float3 hi = (exp((v - c) / a) + b) / 12.0;
    return select(lo, hi, v > 0.5);
}

// BT.1886 display decode for SDR video.
static float3 sdrToLinear(float3 v) {
    return pow(v, 2.4);
}

// Smooth highlight roll-off so values stay within the display's EDR headroom.
// Content at or below SDR white is never altered.
static float3 toneMap(float3 x, float headroom) {
    float knee = max(headroom * 0.8, 1.0);
    float span = max(headroom - knee, 1e-4);
    float3 over = max(x - knee, 0.0);
    float3 rolled = knee + span * (1.0 - exp(-over / span));
    return select(x, rolled, x > knee);
}

// Samples biplanar YCbCr, converts to linear-light display-gamut RGB, and
// tone-maps HDR highlights into the display's headroom.
fragment float4 video_fragment(VertexOut in [[stage_in]],
                               texture2d<float> lumaTexture [[texture(0)]],
                               texture2d<float> chromaTexture [[texture(1)]],
                               constant float3x3 &colorMatrix [[buffer(0)]],
                               constant float3 &colorOffset [[buffer(1)]],
                               constant float3x3 &gamutMatrix [[buffer(2)]],
                               constant uint &transferFunction [[buffer(3)]],
                               constant float &headroom [[buffer(4)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);
    float luma = lumaTexture.sample(textureSampler, in.texCoord).r;
    float2 chroma = chromaTexture.sample(textureSampler, in.texCoord).rg;
    float3 yuv = float3(luma, chroma.r, chroma.g);
    float3 encoded = clamp(colorMatrix * (yuv - colorOffset), 0.0, 1.0);

    float3 linearRGB;
    if (transferFunction == 1u) {            // PQ (HDR10 / Dolby Vision)
        linearRGB = pqToLinearNits(encoded) / referenceWhiteNits;
    } else if (transferFunction == 2u) {     // HLG
        linearRGB = hlgInverseOETF(encoded) * (1000.0 / referenceWhiteNits);
    } else {                                  // SDR
        linearRGB = sdrToLinear(encoded);
    }

    linearRGB = max(gamutMatrix * linearRGB, 0.0);
    linearRGB = toneMap(linearRGB, headroom);
    return float4(linearRGB, 1.0);
}
