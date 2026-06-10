#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Waveform Lines scene: three neon oscilloscope traces, one per register.
// The bass trace (heavily smoothed waveform) sweeps low on screen, mids in
// the center, the raw high-detail trace on top — same pitch-height layout
// and paint palette as every other scene. Lines are drawn analytically in
// the fragment shader as glowing distance fields around the sampled curve.
// ---------------------------------------------------------------------------

constant int kWaveLength = 256;

struct WaveUniforms {
    float time;
    float aspect;
    float level;
    float beat;
    float bass;
    float mid;
    float treble;
    float beatPulse;
};

struct WVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex WVertexOut waveVertex(uint vid [[vertex_id]])
{
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 uvs[3]       = { float2(0.0, 2.0),   float2(0.0, 0.0),  float2(2.0, 0.0) };
    WVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

// Linearly interpolated sample of line `lineIndex` at horizontal position x.
static inline float sampleLine(const device float* lines, int lineIndex, float x)
{
    float fx = clamp(x, 0.0, 1.0) * float(kWaveLength - 1);
    int i0 = int(fx);
    int i1 = min(i0 + 1, kWaveLength - 1);
    float fr = fx - float(i0);
    int base = lineIndex * kWaveLength;
    return mix(lines[base + i0], lines[base + i1], fr);
}

// Bright core + soft halo around the trace.
static inline float lineGlow(float d, float coreWidth, float haloWidth)
{
    float core = exp(-(d * d) / (coreWidth * coreWidth));
    float halo = exp(-(d * d) / (haloWidth * haloWidth)) * 0.25;
    return core + halo;
}

fragment float4 waveFragment(WVertexOut in [[stage_in]],
                             const device float*     lines [[buffer(0)]],
                             constant WaveUniforms&  u     [[buffer(1)]])
{
    const float3 paintLow  = float3(1.00, 0.03, 0.08);
    const float3 paintMid  = float3(0.05, 1.00, 0.15);
    const float3 paintHigh = float3(0.07, 0.25, 1.00);

    float kick = 1.0 + u.beatPulse * 0.5;
    float3 c = float3(0.0);

    // Bass trace: low altitude, big slow swells.
    {
        float w = sampleLine(lines, 0, in.uv.x);
        float y = 0.28 + w * (0.05 + u.bass * 0.16) * kick;
        float d = in.uv.y - y;
        c += paintLow * lineGlow(d, 0.0045, 0.022) * (0.05 + u.bass * 1.6) * u.level;
    }

    // Mid trace: center, the melody's contour.
    {
        float w = sampleLine(lines, 1, in.uv.x);
        float y = 0.50 + w * (0.04 + u.mid * 0.14) * kick;
        float d = in.uv.y - y;
        c += paintMid * lineGlow(d, 0.0035, 0.018) * (0.05 + u.mid * 1.5) * u.level;
    }

    // Treble trace: top, thin and detailed.
    {
        float w = sampleLine(lines, 2, in.uv.x);
        float y = 0.72 + w * (0.03 + u.treble * 0.12) * kick;
        float d = in.uv.y - y;
        c += paintHigh * lineGlow(d, 0.0022, 0.012) * (0.05 + u.treble * 1.6) * u.level;
    }

    // Tone map; cut faint haze so the background stays pure black.
    c = c / (1.0 + c);
    float lum = max(c.x, max(c.y, c.z));
    c *= smoothstep(0.012, 0.04, lum);
    return float4(c, 1.0);
}
