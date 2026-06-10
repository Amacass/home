#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Starfield scene: three parallax layers of stars, each star belonging to a
// register (bass red / mid green / treble blue) and twinkling with that
// band's energy. The field drifts only while music plays; onsets launch
// shooting stars tinted by the dominant register. A faint nebula glows with
// the overall spectral balance.
// ---------------------------------------------------------------------------

struct StarUniforms {
    float time;
    float aspect;
    float level;
    float beat;
    float bass;
    float mid;
    float treble;
    float centroid;
    float drift;       // accumulated travel; frozen during silence
    float _p0;
    float _p1;
    float _p2;
    float4 shooting0;  // x,y = start (aspect-scaled space), z = age (>=1 off), w = angle
    float4 shooting1;
    float4 shooting2;
    float4 shooting3;
    float4 shootingBand; // register index per shooting star
};

struct SVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex SVertexOut starsVertex(uint vid [[vertex_id]])
{
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 uvs[3]       = { float2(0.0, 2.0),   float2(0.0, 0.0),  float2(2.0, 0.0) };
    SVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

static inline float sHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static inline float sNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = sHash(i);
    float b = sHash(i + float2(1, 0));
    float c = sHash(i + float2(0, 1));
    float d = sHash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float sFbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 3; i++) {
        v += amp * sNoise(p);
        p *= 2.07;
        amp *= 0.5;
    }
    return v;
}

static inline float3 registerPaint(int band) {
    return band == 0 ? float3(1.00, 0.03, 0.08)
         : band == 1 ? float3(0.05, 1.00, 0.15)
                     : float3(0.07, 0.25, 1.00);
}

// One parallax layer of register-colored, twinkling stars.
static inline float3 starLayer(float2 p, float scale, float seed,
                               constant StarUniforms& u)
{
    float2 g = p * scale + seed * 17.31;
    float2 cell = floor(g);
    float2 f = g - cell;

    float h = sHash(cell);
    if (h < 0.35) { return float3(0.0); } // empty cells keep the sky sparse

    float2 starPos = float2(sHash(cell + 1.3), sHash(cell + 2.7)) * 0.8 + 0.1;
    float d = length(f - starPos);

    int band = int(h * 7.0) % 3;
    float energy = band == 0 ? u.bass : (band == 1 ? u.mid : u.treble);

    // Twinkle rate rises with timbral brightness (centroid).
    float tw = 0.55 + 0.45 * sin(u.time * (1.5 + h * 4.0) * (1.0 + u.centroid * 2.5) + h * 40.0);

    float core = exp(-d * d * 380.0) + exp(-d * d * 70.0) * 0.12;
    float brightness = core * tw * (0.04 + energy * 0.9) * (0.2 + u.level * 1.3);
    return registerPaint(band) * brightness;
}

fragment float4 starsFragment(SVertexOut in [[stage_in]],
                              constant StarUniforms& u [[buffer(0)]])
{
    float2 p = float2(in.uv.x * u.aspect, in.uv.y);

    float3 c = float3(0.0);

    // Faint nebula tinted by the live spectral balance.
    float3 nebulaHue = registerPaint(0) * u.bass + registerPaint(1) * u.mid
                     + registerPaint(2) * u.treble;
    float mx = max(nebulaHue.x, max(nebulaHue.y, nebulaHue.z));
    if (mx > 1e-4) { nebulaHue /= mx; }
    float nebula = sFbm(p * 1.6 + float2(u.drift * 0.25, u.drift * 0.08));
    c += nebulaHue * nebula * nebula * u.level * 0.10;

    // Parallax star layers; deeper layers drift slower.
    c += starLayer(p + float2(u.drift * 0.020, u.drift * 0.006), 9.0, 1.0, u);
    c += starLayer(p + float2(u.drift * 0.045, u.drift * 0.013), 17.0, 2.0, u);
    c += starLayer(p + float2(u.drift * 0.090, u.drift * 0.027), 30.0, 3.0, u);

    // Shooting stars: a bright head with an exponentially fading tail.
    float4 shooting[4] = { u.shooting0, u.shooting1, u.shooting2, u.shooting3 };
    for (int i = 0; i < 4; i++) {
        float4 s = shooting[i];
        if (s.z >= 1.0) { continue; }
        float2 dir = float2(cos(s.w), sin(s.w));
        float2 head = s.xy + dir * s.z * 0.9;

        float tailLength = 0.16 * (1.0 - s.z * 0.4);
        float2 rel = p - head;
        float along = clamp(dot(rel, -dir), 0.0, tailLength);
        float2 closest = head - dir * along;
        float d = length(p - closest);

        float fade = (1.0 - s.z) * exp(-along * 14.0);
        int band = int(u.shootingBand[i]);
        c += registerPaint(band) * exp(-d * d * 9000.0) * fade * 2.2;
    }

    // Subtle global shimmer on onsets.
    c *= 1.0 + u.beat * 0.25;

    // Tone map; cut faint haze so the sky floor stays near-black.
    c = c / (1.0 + c);
    float lum = max(c.x, max(c.y, c.z));
    c *= smoothstep(0.006, 0.025, lum);
    return float4(c, 1.0);
}
