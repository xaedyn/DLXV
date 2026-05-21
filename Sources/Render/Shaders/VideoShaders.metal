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

// Samples biplanar YCbCr (luma in texture 0, interleaved Cb/Cr in texture 1)
// and converts to R'G'B' with the supplied matrix: rgb = matrix * (yuv - offset).
fragment float4 video_fragment(VertexOut in [[stage_in]],
                               texture2d<float> lumaTexture [[texture(0)]],
                               texture2d<float> chromaTexture [[texture(1)]],
                               constant float3x3 &colorMatrix [[buffer(0)]],
                               constant float3 &colorOffset [[buffer(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);
    float luma = lumaTexture.sample(textureSampler, in.texCoord).r;
    float2 chroma = chromaTexture.sample(textureSampler, in.texCoord).rg;
    float3 yuv = float3(luma, chroma.r, chroma.g);
    float3 rgb = colorMatrix * (yuv - colorOffset);
    return float4(rgb, 1.0);
}
