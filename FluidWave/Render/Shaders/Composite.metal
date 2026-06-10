#include <metal_stdlib>
using namespace metal;

// Final pass: crossfade between two scene targets onto the drawable.

struct CVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CVertexOut compositeVertex(uint vid [[vertex_id]])
{
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 uvs[3]       = { float2(0.0, 2.0),   float2(0.0, 0.0),  float2(2.0, 0.0) };
    CVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

constexpr sampler cLinearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

fragment float4 compositeFragment(CVertexOut in [[stage_in]],
                                  texture2d<float, access::sample> sceneA [[texture(0)]],
                                  texture2d<float, access::sample> sceneB [[texture(1)]],
                                  constant float& mixT [[buffer(0)]])
{
    float3 a = sceneA.sample(cLinearSampler, in.uv).rgb;
    float3 b = sceneB.sample(cLinearSampler, in.uv).rgb;
    return float4(mix(a, b, mixT), 1.0);
}
