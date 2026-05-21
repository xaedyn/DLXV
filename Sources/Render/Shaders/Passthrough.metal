#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Draws a single aspect-fit quad. `scale` shrinks the quad on one axis so the
// video keeps its aspect ratio; the uncovered area shows the clear color.
vertex VertexOut passthrough_vertex(uint vertexID [[vertex_id]],
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

fragment float4 passthrough_fragment(VertexOut in [[stage_in]],
                                     texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);
    return videoTexture.sample(textureSampler, in.texCoord);
}
