#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Particle Flow scene: tens of thousands of glowing particles drifting in a
// curl-noise flow field. Each particle belongs to one register (bass/mid/
// treble) and lives at that register's altitude (pitch-height correspondence),
// glowing in its register's paint channel. Trails accumulate into a fading
// texture, then go through the same winner-takes-most neon compositing as the
// fluid scene so the look stays cohesive.
// ---------------------------------------------------------------------------

struct Particle {
    float2 pos;
    float2 vel;
    float2 data; // x = band (0/1/2), y = seed
};

struct ParticleUniforms {
    float  dt;
    float  time;
    float  level;
    float  beat;
    float4 bands;   // x = bass, y = mid, z = treble
    float  aspect;
    float  _pad0;
    float  _pad1;
    float  _pad2;
};

static inline float pHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static inline float pNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = pHash(i);
    float b = pHash(i + float2(1, 0));
    float c = pHash(i + float2(0, 1));
    float d = pHash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float pFbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 3; i++) {
        v += amp * pNoise(p);
        p *= 2.03;
        amp *= 0.5;
    }
    return v;
}

// Divergence-free flow direction from the rotated gradient of fbm noise.
static inline float2 pCurl(float2 p) {
    const float e = 0.02;
    float dx = pFbm(p + float2(e, 0)) - pFbm(p - float2(e, 0));
    float dy = pFbm(p + float2(0, e)) - pFbm(p - float2(0, e));
    return float2(dy, -dx) / (2.0 * e);
}

kernel void particleUpdate(device Particle*            particles [[buffer(0)]],
                           constant ParticleUniforms&  u         [[buffer(1)]],
                           uint                        id        [[thread_position_in_grid]])
{
    Particle p = particles[id];
    int band = int(p.data.x);
    float bandEnergy = band == 0 ? u.bands.x : (band == 1 ? u.bands.y : u.bands.z);

    // Curl-noise flow; each register drifts in its own layer and tempo.
    float2 q = p.pos * (2.5 + float(band) * 1.5)
             + float2(p.data.y * 7.31, u.time * (0.03 + float(band) * 0.03));
    float2 flow = pCurl(q) * (0.02 + bandEnergy * 0.10 + u.level * 0.05);

    // Pitch-height: each register is pulled gently toward its home altitude.
    float homeY = 0.25 + float(band) * 0.25;
    flow.y += (homeY - p.pos.y) * 0.08;

    // Onset: radial impulse away from the center.
    if (u.beat > 0.0) {
        float2 d = p.pos - float2(0.5, 0.5);
        d.x *= u.aspect;
        float len = max(length(d), 0.05);
        flow += (d / len) * u.beat * (0.25 + bandEnergy * 0.5);
    }

    p.vel = mix(p.vel, flow, 0.12);
    p.pos += p.vel * u.dt * (0.4 + u.level * 2.2);
    p.pos = fract(p.pos);

    particles[id] = p;
}

// ---------------------------------------------------------------------------
// Point rendering into the (additively blended) accumulation texture.
// ---------------------------------------------------------------------------

struct PVertexOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float3 color;
};

vertex PVertexOut particleVertexFn(const device Particle*     particles [[buffer(0)]],
                                   constant ParticleUniforms& u         [[buffer(1)]],
                                   uint                       vid       [[vertex_id]])
{
    Particle p = particles[vid];
    int band = int(p.data.x);
    float bandEnergy = band == 0 ? u.bands.x : (band == 1 ? u.bands.y : u.bands.z);

    PVertexOut out;
    out.position = float4(p.pos * 2.0 - 1.0, 0.0, 1.0);
    out.pointSize = (band == 0 ? 3.5 : (band == 1 ? 2.5 : 1.8)) + u.beat * 2.0;
    float brightness = bandEnergy * (0.10 + u.level * 0.45);
    out.color = float3(band == 0 ? brightness : 0.0,
                       band == 1 ? brightness : 0.0,
                       band == 2 ? brightness : 0.0);
    return out;
}

fragment float4 particleFragmentFn(PVertexOut in [[stage_in]],
                                   float2     pc [[point_coord]])
{
    float falloff = smoothstep(0.5, 0.05, length(pc - 0.5));
    return float4(in.color * falloff, 1.0);
}

// ---------------------------------------------------------------------------
// Trail fade: multiply the accumulation texture by a decay factor.
// ---------------------------------------------------------------------------
kernel void fadeAccum(texture2d<float, access::read>  src   [[texture(0)]],
                      texture2d<float, access::write> dst   [[texture(1)]],
                      constant float&                 decay [[buffer(0)]],
                      uint2                           gid   [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    dst.write(src.read(gid) * decay, gid);
}

// ---------------------------------------------------------------------------
// Present pass: same winner-takes-most neon compositing as the fluid scene.
// ---------------------------------------------------------------------------

struct PPresentOut {
    float4 position [[position]];
    float2 uv;
};

vertex PPresentOut particlePresentVertex(uint vid [[vertex_id]])
{
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 uvs[3]       = { float2(0.0, 2.0),   float2(0.0, 0.0),  float2(2.0, 0.0) };
    PPresentOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

constexpr sampler pLinearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

fragment float4 particlePresentFragment(PPresentOut in [[stage_in]],
                                        texture2d<float, access::sample> accum [[texture(0)]])
{
    float3 d = max(accum.sample(pLinearSampler, in.uv).rgb, 0.0);

    const float3 paintLow  = float3(1.00, 0.03, 0.08);
    const float3 paintMid  = float3(0.05, 1.00, 0.15);
    const float3 paintHigh = float3(0.07, 0.25, 1.00);

    float3 w = pow(d, 3.0);
    float wsum = w.x + w.y + w.z;
    float3 hue = float3(0.0);
    if (wsum > 1e-6) {
        hue = (w.x * paintLow + w.y * paintMid + w.z * paintHigh) / wsum;
        float mn = min(hue.x, min(hue.y, hue.z));
        hue = max(hue - 0.85 * mn, 0.0);
        hue /= max(max(hue.x, hue.y), max(hue.z, 1e-4));
    }

    float density = d.x + d.y + d.z;
    float intensity = density / (0.5 + density);
    intensity = max(intensity - 0.02, 0.0) * 1.02;
    return float4(hue * pow(intensity, 0.9), 1.0);
}
