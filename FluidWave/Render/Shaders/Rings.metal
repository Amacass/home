#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Spectrum Rings scene: concentric neon rings, one per register, that breathe
// with the band energies and tick in time with the estimated BPM. Pitch maps
// to radius (bass innermost), onsets fire an expanding ripple. Entirely
// procedural in the fragment shader — zero simulation state on the GPU.
// ---------------------------------------------------------------------------

struct RingsUniforms {
    float time;
    float aspect;
    float level;
    float beatPulse;
    float bass;
    float mid;
    float treble;
    float ripple;     // 0..1 progress of the expanding onset ring (>=1 inactive)
    float bpmPhase;   // fract of beats elapsed; resets to 0 on each beat
    float centroid;
    float2 _pad;
};

struct RVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex RVertexOut ringsVertex(uint vid [[vertex_id]])
{
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 uvs[3]       = { float2(0.0, 2.0),   float2(0.0, 0.0),  float2(2.0, 0.0) };
    RVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

static inline float ringGlow(float r, float target, float width)
{
    float d = (r - target) / max(width, 1e-4);
    return exp(-d * d);
}

fragment float4 ringsFragment(RVertexOut in [[stage_in]],
                              constant RingsUniforms& u [[buffer(0)]])
{
    float2 p = (in.uv - 0.5) * float2(u.aspect, 1.0);
    float r = length(p);
    float ang = atan2(p.y, p.x);

    const float3 paintLow  = float3(1.00, 0.03, 0.08);
    const float3 paintMid  = float3(0.05, 1.00, 0.15);
    const float3 paintHigh = float3(0.07, 0.25, 1.00);

    // Beat-locked breathing: a soft tick that decays over each beat period.
    float tick = exp(-u.bpmPhase * 5.0);

    float3 c = float3(0.0);

    // Bass: innermost ring (pitch -> radius, low register near the core).
    float rBass = 0.14 + u.bass * 0.05 + tick * 0.012;
    c += paintLow * ringGlow(r, rBass, 0.012 + u.bass * 0.025) * (u.bass * 1.6);

    // Mid: petal-modulated middle ring tracing the melody contour.
    float petals = 0.65 + 0.35 * sin(ang * 6.0 + u.time * 0.8);
    float rMid = 0.27 + u.mid * 0.05 + 0.012 * sin(ang * 6.0 + u.time * 0.8);
    c += paintMid * ringGlow(r, rMid, 0.010 + u.mid * 0.018) * (u.mid * 1.5) * petals;

    // Treble: dashed, fast-rotating outer ring.
    float dash = smoothstep(0.1, 0.7, sin(ang * 24.0 - u.time * 5.0) * 0.5 + 0.5);
    float rTre = 0.40 + u.treble * 0.04;
    c += paintHigh * ringGlow(r, rTre, 0.006 + u.treble * 0.012) * (u.treble * 1.6) * dash;

    // Onset ripple: an expanding circle that fades as it travels outward,
    // tinted by the current spectral balance.
    if (u.ripple > 0.0 && u.ripple < 1.0) {
        float rr = 0.10 + u.ripple * 0.45;
        float3 rippleHue = paintLow * u.bass + paintMid * u.mid + paintHigh * u.treble;
        float mx = max(rippleHue.x, max(rippleHue.y, rippleHue.z));
        rippleHue = mx > 1e-4 ? rippleHue / mx : float3(0.0);
        c += rippleHue * ringGlow(r, rr, 0.015) * (1.0 - u.ripple) * u.beatPulse * 1.5;
    }

    // Center glow follows perceived loudness and spectral balance.
    c += (paintLow * u.bass + paintMid * u.mid + paintHigh * u.treble)
         * exp(-r * 9.0) * u.level * 0.8;

    // Tone map; cut faint haze to keep the background pure black.
    c = c / (1.0 + c);
    float lum = max(c.x, max(c.y, c.z));
    c *= smoothstep(0.015, 0.05, lum);
    return float4(c, 1.0);
}
