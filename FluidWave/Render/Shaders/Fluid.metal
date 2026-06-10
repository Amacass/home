#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Uniform structs (must match the Swift-side layout in FluidRenderer.swift)
// ---------------------------------------------------------------------------

struct SimpleUniforms {
    float2 texelSize;
};

struct AdvectUniforms {
    float2 texelSize;
    float  dt;
    float  dissipation;
};

struct VorticityUniforms {
    float2 texelSize;
    float  dt;
    float  strength;
};

struct SplatUniforms {
    float2 texelSize;
    float2 point;     // normalized [0,1] target point
    float  radius;    // gaussian falloff (squared radius)
    float  aspect;    // width / height, to keep splats round
    float4 value;     // amount to add (xy = velocity, or rgb = dye)
};

// A nearest sampler for finite-difference operators and a linear sampler for
// semi-Lagrangian advection.
constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

static inline float2 cellUV(uint2 gid, float2 texelSize) {
    return (float2(gid) + 0.5) * texelSize;
}

// ---------------------------------------------------------------------------
// Semi-Lagrangian advection: move `source` along the velocity field.
// ---------------------------------------------------------------------------
kernel void advect(texture2d<float, access::sample> source   [[texture(0)]],
                   texture2d<float, access::sample> velocity [[texture(1)]],
                   texture2d<float, access::write>  dest     [[texture(2)]],
                   constant AdvectUniforms&         u        [[buffer(0)]],
                   uint2                            gid      [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 uv  = cellUV(gid, u.texelSize);
    float2 vel = velocity.sample(linearSampler, uv).xy;

    // Trace backwards. Velocity is expressed in cells/second, so multiply by
    // texelSize to convert into normalized-texture space.
    float2 prev = uv - u.dt * vel * u.texelSize;
    float4 result = source.sample(linearSampler, prev);

    dest.write(result * u.dissipation, gid);
}

// ---------------------------------------------------------------------------
// Divergence of the velocity field.
// ---------------------------------------------------------------------------
kernel void divergence(texture2d<float, access::sample> velocity [[texture(0)]],
                       texture2d<float, access::write>  dest     [[texture(1)]],
                       constant SimpleUniforms&         u        [[buffer(0)]],
                       uint2                            gid      [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 uv = cellUV(gid, u.texelSize);
    float  L = velocity.sample(nearestSampler, uv - float2(u.texelSize.x, 0)).x;
    float  R = velocity.sample(nearestSampler, uv + float2(u.texelSize.x, 0)).x;
    float  B = velocity.sample(nearestSampler, uv - float2(0, u.texelSize.y)).y;
    float  T = velocity.sample(nearestSampler, uv + float2(0, u.texelSize.y)).y;

    float div = 0.5 * ((R - L) + (T - B));
    dest.write(float4(div, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// One Jacobi iteration of the pressure Poisson solve.
// ---------------------------------------------------------------------------
kernel void jacobi(texture2d<float, access::sample> pressure   [[texture(0)]],
                   texture2d<float, access::sample> divergence [[texture(1)]],
                   texture2d<float, access::write>  dest       [[texture(2)]],
                   constant SimpleUniforms&         u          [[buffer(0)]],
                   uint2                            gid        [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 uv = cellUV(gid, u.texelSize);
    float  L = pressure.sample(nearestSampler, uv - float2(u.texelSize.x, 0)).x;
    float  R = pressure.sample(nearestSampler, uv + float2(u.texelSize.x, 0)).x;
    float  B = pressure.sample(nearestSampler, uv - float2(0, u.texelSize.y)).x;
    float  T = pressure.sample(nearestSampler, uv + float2(0, u.texelSize.y)).x;
    float  d = divergence.sample(nearestSampler, uv).x;

    float p = (L + R + B + T - d) * 0.25;
    dest.write(float4(p, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Subtract the pressure gradient to make the velocity field divergence-free.
// ---------------------------------------------------------------------------
kernel void subtractGradient(texture2d<float, access::sample> pressure [[texture(0)]],
                             texture2d<float, access::sample> velocity [[texture(1)]],
                             texture2d<float, access::write>  dest     [[texture(2)]],
                             constant SimpleUniforms&         u        [[buffer(0)]],
                             uint2                            gid      [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 uv = cellUV(gid, u.texelSize);
    float  L = pressure.sample(nearestSampler, uv - float2(u.texelSize.x, 0)).x;
    float  R = pressure.sample(nearestSampler, uv + float2(u.texelSize.x, 0)).x;
    float  B = pressure.sample(nearestSampler, uv - float2(0, u.texelSize.y)).x;
    float  T = pressure.sample(nearestSampler, uv + float2(0, u.texelSize.y)).x;

    float2 vel = velocity.sample(nearestSampler, uv).xy;
    vel -= 0.5 * float2(R - L, T - B);
    dest.write(float4(vel, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Curl (vorticity) of the velocity field: w = dVy/dx - dVx/dy.
// ---------------------------------------------------------------------------
kernel void curl(texture2d<float, access::sample> velocity [[texture(0)]],
                 texture2d<float, access::write>  dest     [[texture(1)]],
                 constant SimpleUniforms&         u        [[buffer(0)]],
                 uint2                            gid      [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 uv = cellUV(gid, u.texelSize);
    float  L = velocity.sample(nearestSampler, uv - float2(u.texelSize.x, 0)).y;
    float  R = velocity.sample(nearestSampler, uv + float2(u.texelSize.x, 0)).y;
    float  B = velocity.sample(nearestSampler, uv - float2(0, u.texelSize.y)).x;
    float  T = velocity.sample(nearestSampler, uv + float2(0, u.texelSize.y)).x;

    float w = 0.5 * ((R - L) - (T - B));
    dest.write(float4(w, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Vorticity confinement (Fedkiw, Stam & Jensen 2001, "Visual Simulation of
// Smoke"): re-inject the small-scale swirls that the semi-Lagrangian advection
// numerically dissipates. This is what keeps strokes crisp instead of blurry.
// ---------------------------------------------------------------------------
kernel void vorticity(texture2d<float, access::sample> velocity [[texture(0)]],
                      texture2d<float, access::sample> curlTex  [[texture(1)]],
                      texture2d<float, access::write>  dest     [[texture(2)]],
                      constant VorticityUniforms&      u        [[buffer(0)]],
                      uint2                            gid      [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 uv = cellUV(gid, u.texelSize);
    float  L = curlTex.sample(nearestSampler, uv - float2(u.texelSize.x, 0)).x;
    float  R = curlTex.sample(nearestSampler, uv + float2(u.texelSize.x, 0)).x;
    float  B = curlTex.sample(nearestSampler, uv - float2(0, u.texelSize.y)).x;
    float  T = curlTex.sample(nearestSampler, uv + float2(0, u.texelSize.y)).x;
    float  C = curlTex.sample(nearestSampler, uv).x;

    float2 force = 0.5 * float2(abs(T) - abs(B), abs(R) - abs(L));
    force /= length(force) + 1e-4;
    force *= u.strength * C;
    force.y = -force.y;

    float2 vel = velocity.sample(nearestSampler, uv).xy;
    dest.write(float4(vel + force * u.dt, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Add a gaussian "splat" of force or dye. Ping-pongs source -> dest.
// ---------------------------------------------------------------------------
kernel void splat(texture2d<float, access::read>  source [[texture(0)]],
                  texture2d<float, access::write> dest   [[texture(1)]],
                  constant SplatUniforms&         u      [[buffer(0)]],
                  uint2                           gid    [[thread_position_in_grid]])
{
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) { return; }

    float2 p = cellUV(gid, u.texelSize);
    float2 d = p - u.point;
    d.x *= u.aspect;
    float  g = exp(-dot(d, d) / max(u.radius, 1e-6));

    float4 base = source.read(gid);
    dest.write(base + u.value * g, gid);
}

// ---------------------------------------------------------------------------
// Display pass: a full-screen triangle that tone-maps the dye field.
// ---------------------------------------------------------------------------
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut displayVertex(uint vid [[vertex_id]])
{
    // Oversized triangle covering the whole screen.
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 uvs[3]       = { float2(0.0, 2.0),   float2(0.0, 0.0),  float2(2.0, 0.0) };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 displayFragment(VertexOut in [[stage_in]],
                                texture2d<float, access::sample> dye [[texture(0)]])
{
    // The dye texture stores DENSITIES of three independent fluorescent
    // paints (x = bass, y = mid, z = treble), not an RGB color. Compositing
    // is winner-takes-most: weights are raised to a power so the locally
    // dominant paint dictates the hue. Paints therefore displace each other
    // instead of additively blending into white/mud.
    float3 d = max(dye.sample(linearSampler, in.uv).rgb, 0.0);

    const float3 paintLow  = float3(1.00, 0.03, 0.08); // neon red    (bass)
    const float3 paintMid  = float3(0.05, 1.00, 0.15); // neon green  (mid)
    const float3 paintHigh = float3(0.07, 0.25, 1.00); // neon blue   (treble)

    const float dominance = 3.0;
    float3 w = pow(d, dominance);
    float  wsum = w.x + w.y + w.z;

    float3 hue = float3(0.0);
    if (wsum > 1e-6) {
        hue = (w.x * paintLow + w.y * paintMid + w.z * paintHigh) / wsum;
        // Force full neon saturation: strip any common (whitening) component
        // and renormalize the peak channel to 1.
        float mn = min(hue.x, min(hue.y, hue.z));
        hue = max(hue - 0.85 * mn, 0.0);
        hue /= max(max(hue.x, hue.y), max(hue.z, 1e-4));
    }

    // Brightness from total paint density, tone-mapped. A small floor cut
    // kills residual haze so the background stays pure black.
    float density = d.x + d.y + d.z;
    float intensity = density / (0.55 + density);
    intensity = max(intensity - 0.03, 0.0) * 1.03;
    intensity = pow(intensity, 0.85);

    return float4(hue * intensity, 1.0);
}
