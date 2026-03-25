#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Fae Lifeform Orb — SDF-Based Metal Fragment Shader
// ============================================================================
//
// Organic blob rendered via signed distance fields with flowing gas texture,
// bioluminescent sparkles, rim glow, and atmospheric halo. Designed to make
// Fae feel like a living being rather than a UI element.
//
// Architecture (back to front):
//   1. Outer atmosphere — soft radial glow beyond the blob edge
//   2. Blob body — SDF-defined organic shape with palette colors
//   3. Internal gas — single-octave 2D simplex noise, flowing
//   4. Core light — radial, audio-reactive
//   5. Internal sparkles — 8 bioluminescent points masked by SDF
//   6. Rim light — Fresnel along SDF boundary with shimmer
//   7. External sparkles — 6 firefly points orbiting outside
//   8. Film grain — subtle texture
//
// Performance: ~230 ops/pixel. At 260x260 @ 30fps ≈ 0.5B ops/s.
// Apple Silicon GPU handles this at well under 1% utilization.
//
// Applied via SwiftUI `.colorEffect()`.
// ============================================================================

// MARK: - Hash Functions

/// Fast 2D hash for grain and sparkle seeds.
static half hashH(half2 p) {
    half3 p3 = fract(half3(p.xyx) * 0.1031h);
    p3 += dot(p3, p3.yzx + 33.33h);
    return fract((p3.x + p3.y) * p3.z);
}

// MARK: - Simplex Noise 2D (half precision)

constant half F2h = 0.36602540378h;  // (sqrt(3) - 1) / 2
constant half G2h = 0.21132486540h;  // (3 - sqrt(3)) / 6

constant half2 grad2h[8] = {
    half2(1, 1), half2(-1, 1), half2(1, -1), half2(-1, -1),
    half2(1, 0), half2(-1, 0), half2(0, 1), half2(0, -1)
};

static half snoise2D(half2 v) {
    half s = (v.x + v.y) * F2h;
    half2 i_floor = floor(v + s);
    half t = (i_floor.x + i_floor.y) * G2h;
    half2 x0 = v - (i_floor - t);

    half2 i1 = (x0.x > x0.y) ? half2(1.0h, 0.0h) : half2(0.0h, 1.0h);
    half2 x1 = x0 - i1 + G2h;
    half2 x2 = x0 - 1.0h + 2.0h * G2h;

    half2 ii = half2(int(i_floor.x) & 255, int(i_floor.y) & 255);
    int gi0 = int(hashH(ii) * 8.0h) & 7;
    int gi1 = int(hashH(ii + i1) * 8.0h) & 7;
    int gi2 = int(hashH(ii + 1.0h) * 8.0h) & 7;

    half n0 = 0.0h, n1 = 0.0h, n2 = 0.0h;

    half t0 = 0.5h - dot(x0, x0);
    if (t0 > 0.0h) { t0 *= t0; n0 = t0 * t0 * dot(grad2h[gi0], x0); }

    half t1 = 0.5h - dot(x1, x1);
    if (t1 > 0.0h) { t1 *= t1; n1 = t1 * t1 * dot(grad2h[gi1], x1); }

    half t2 = 0.5h - dot(x2, x2);
    if (t2 > 0.0h) { t2 *= t2; n2 = t2 * t2 * dot(grad2h[gi2], x2); }

    return 70.0h * (n0 + n1 + n2);  // Range: approximately [-1, 1]
}

// MARK: - SDF Blob Shape

/// Compute the signed distance from point `uv` (centered at origin, normalised
/// so that the view half-width = 0.5) to the organic blob boundary.
///
/// Negative = inside the blob, positive = outside.
static float sdfBlob(
    float2 uv,
    float time,
    float morphAmplitude,
    float morphFreq,
    float morphSpeed,
    float asymmetry,
    float breathAmplitude,
    float speedScale,
    float radiusBias,
    float anticipationScale,
    float audioRMS
) {
    float angle = atan2(uv.y, uv.x);
    float r = length(uv);

    // 4 harmonics for organic blob shape — cheap (just sin calls).
    // Scale factor 0.15: OrbSnapshot morphAmplitude values (0.03–0.12) were tuned
    // for the old NebulaOrb domain-warp shader. In SDF they directly displace
    // the radius, so we scale down to get subtle organic wobble (~2-8% variation).
    float mf = morphFreq;
    float ms = morphSpeed * speedScale;
    float scaledMorph = morphAmplitude * 0.15;
    float distortion = scaledMorph * (
        sin(angle * mf + time * ms) * 0.45 +
        sin(angle * (mf + 1.0) + time * ms * 0.7) * 0.28 +
        sin(angle * (mf + 2.7) + time * ms * 1.3) * 0.17 +
        sin(angle * (mf + 4.1) + time * ms * 0.5) * 0.10
    );

    // Asymmetry: directional lean that slowly rotates.
    distortion += asymmetry * 0.15 * sin(angle + time * 0.3);

    // Breathing: slow sinusoidal radius modulation.
    // Scale 0.3: breathAmplitude values (0.008–0.018 base, up to 3.5x in thinking)
    // need damping to avoid the orb pulsing like a balloon.
    float breath = breathAmplitude * 0.3 * sin(time * 0.42 * speedScale);

    // Audio reactivity: subtle radius pulse with speech.
    float audioPulse = audioRMS * 0.015;

    // Base radius + all modulations.
    // radiusBias scaled 0.2: values like +0.1 (delight) / -0.06 (focus) are
    // too large as direct radius offsets on a 0.34 base.
    float baseR = 0.34 + radiusBias * 0.2 + breath + audioPulse;
    baseR *= anticipationScale;

    return r - (baseR + distortion);
}

// MARK: - Main Shader

[[ stitchable ]] half4 faeOrb(
    float2 position,
    half4 currentColor,
    // Time & geometry
    float time,
    float2 resolution,
    // Audio & interaction
    float audioRMS,
    float2 pointerXY,
    float pointerInfluence,
    // OrbSnapshot properties (15 floats)
    float hueShift,
    float speedScale,
    float breathAmplitude,
    float fogDensity,
    float morphAmplitude,
    float morphFreq,
    float morphSpeed,
    float shimmer,
    float asymmetry,
    float starAlpha,
    float outerAlpha,
    float wispSize,
    float wispAlpha,
    float blobAlpha,
    float innerGlow,
    // Colors (9 floats: 3 × RGB)
    float c0r, float c0g, float c0b,
    float c1r, float c1g, float c1b,
    float c2r, float c2g, float c2b,
    // Flash
    float flashType,
    float flashProgress,
    // Anticipation
    float anticipationScale,
    // Enchantment
    float tremor,
    float sparkleIntensity,
    float liquidFlow,
    float radiusBias
) {
    // Scale time by speed
    float t = time * speedScale;

    // Normalise UV to [-0.5, 0.5] with aspect correction.
    float W = resolution.x;
    float H = resolution.y;
    float2 uv = (position - float2(W, H) * 0.5) / W;

    // Apply tremor (UV displacement for concern/nervousness).
    if (tremor > 0.001) {
        float tremorT = time * 12.0 * speedScale;
        uv.x += tremor * 0.008 * sin(tremorT * 7.3 + uv.y * 20.0);
        uv.y += tremor * 0.008 * cos(tremorT * 5.7 + uv.x * 20.0);
    }

    // Pointer drift: orb leans toward mouse.
    if (pointerInfluence > 0.001) {
        float2 pNorm = pointerXY - 0.5;
        uv -= pNorm * pointerInfluence * 0.04;
    }

    // Palette colors.
    half3 color0 = half3(c0r, c0g, c0b);  // Primary
    half3 color1 = half3(c1r, c1g, c1b);  // Secondary
    half3 color2 = half3(c2r, c2g, c2b);  // Tertiary

    // ── SDF Computation ──────────────────────────────────────────────

    float sdf = sdfBlob(
        uv, time, morphAmplitude, morphFreq, morphSpeed,
        asymmetry, breathAmplitude, speedScale, radiusBias,
        anticipationScale, audioRMS
    );

    float dist = length(uv);

    // Soft blob edge (smooth over ~3-4 pixel band at 120px).
    float edgeSoftness = 2.5 / W;  // ~2.5 pixels
    half blobMask = half(1.0 - smoothstep(-edgeSoftness, edgeSoftness, sdf));

    // ── Layer 1: Outer Atmosphere ────────────────────────────────────

    // Soft glow that extends beyond the blob boundary.
    float atmosphereExtent = 0.15;  // How far the glow reaches
    half atmosphereAlpha = half(outerAlpha) *
        half(smoothstep(atmosphereExtent, 0.0, max(float(sdf), 0.0)));
    // Fade at far edge using distance from center.
    atmosphereAlpha *= half(1.0 - smoothstep(0.35, 0.50, dist));

    half3 atmosphereColor = mix(color1, color2, half(0.5));
    half4 result = half4(atmosphereColor * atmosphereAlpha, atmosphereAlpha);

    // ── Layer 2: Blob Body ───────────────────────────────────────────

    // Base body color: radial gradient from primary (center) to secondary (edge).
    half bodyBlend = half(smoothstep(0.0, 0.35, dist));
    half3 bodyColor = mix(color0, color1, bodyBlend);

    // ── Layer 3: Internal Gas Texture ────────────────────────────────

    // Flowing plasma from simplex noise.
    float flowT = time * 0.08 * liquidFlow * speedScale;
    half2 gasUV = half2(uv * 3.5 + float2(flowT, flowT * 1.3));
    half gasNoise = snoise2D(gasUV) * 0.5h + 0.5h;  // Remap to [0, 1]

    // Secondary slower gas layer for depth.
    half2 gasUV2 = half2(uv * 2.0 - float2(flowT * 0.6, flowT * 0.4));
    half gasNoise2 = snoise2D(gasUV2) * 0.5h + 0.5h;

    // Mix gas layers.
    half gasMix = gasNoise * half(fogDensity) * 0.7h +
                  gasNoise2 * half(blobAlpha) * 0.5h;

    // Color the gas: primary in dense regions, tertiary in thin regions.
    half3 gasColor = mix(color2, color0, gasMix);
    bodyColor = mix(bodyColor, gasColor, gasMix * 0.6h);

    // ── Layer 4: Core Light ──────────────────────────────────────────

    // Radial illumination from center, audio-reactive.
    half coreIntensity = half(innerGlow) * (1.0h + half(audioRMS) * 0.5h);
    half coreFalloff = half(exp(-float(dist * dist) * 18.0));
    half3 coreColor = mix(color0, half3(1.0h), 0.6h);  // Warm white
    bodyColor = mix(bodyColor, coreColor, coreFalloff * coreIntensity);

    // Composite body onto atmosphere.
    result.rgb = mix(result.rgb, bodyColor, blobMask);
    result.a = max(result.a, blobMask * 0.95h);

    // ── Layer 5: Internal Sparkles (Bioluminescent) ──────────────────

    if (sparkleIntensity > 0.05) {
        half sparkleAcc = 0.0h;
        for (int i = 0; i < 8; i++) {
            float fi = float(i);
            float seed = fi * 1.618033988;  // Golden ratio spacing

            // Orbital path inside the blob.
            float sparkleAngle = seed * 6.2831 + t * (0.15 + fi * 0.03);
            float sparkleRadius = 0.12 + 0.10 * sin(t * 0.3 + seed * 3.0);
            float2 sparklePos = float2(
                cos(sparkleAngle) * sparkleRadius,
                sin(sparkleAngle) * sparkleRadius * 0.85  // Slight vertical squash
            );

            float sparkleD = length(uv - sparklePos);

            // Twinkle: sharp power curve for on/off blinking.
            half twinkle = half(pow(
                max(sin(time * (1.5 + fi * 0.4) + seed * 5.0) * 0.5 + 0.5, 0.0),
                6.0
            ));

            // Soft glow around sparkle point.
            half glow = half(smoothstep(0.025, 0.0, sparkleD));
            sparkleAcc += glow * twinkle;
        }

        half3 sparkleColor = mix(color0, half3(1.0h), 0.7h);
        half sparkleAlpha = min(sparkleAcc * half(sparkleIntensity), 1.0h) * blobMask;
        result.rgb = mix(result.rgb, sparkleColor, sparkleAlpha * 0.8h);
        result.a = max(result.a, sparkleAlpha * 0.5h);
    }

    // ── Layer 6: Rim Light (Fresnel) ─────────────────────────────────

    if (wispAlpha > 0.01) {
        // Compute rim from SDF: brightest right at the edge.
        float rimBand = wispSize * 0.3;
        half rimGlow = half(1.0 - smoothstep(0.0, rimBand, abs(sdf)));

        // Add shimmer noise along the rim.
        if (shimmer > 0.01) {
            half shimmerAngle = half(atan2(uv.y, uv.x));
            half shimmerNoise = snoise2D(
                half2(shimmerAngle * 4.0h, half(time * 2.0 * speedScale))
            );
            rimGlow *= (1.0h + half(shimmer) * shimmerNoise * 3.0h);
        }

        half3 rimColor = mix(color0, half3(1.0h), 0.5h);
        half rimAlpha = rimGlow * half(wispAlpha) * 0.7h;
        result.rgb = mix(result.rgb, rimColor, rimAlpha);
        result.a = max(result.a, rimAlpha * 0.6h);
    }

    // ── Layer 7: External Sparkles (Fireflies) ───────────────────────

    if (starAlpha > 0.05) {
        half fireflyAcc = 0.0h;
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float seed = fi * 2.399963 + 0.5;  // Plastic constant spacing

            // Orbit just outside the blob boundary.
            float orbitAngle = seed * 6.2831 + t * (0.08 + fi * 0.02);
            float orbitRadius = 0.38 + radiusBias + 0.06 * sin(t * 0.2 + seed);
            float2 fireflyPos = float2(
                cos(orbitAngle) * orbitRadius,
                sin(orbitAngle) * orbitRadius
            );

            float fireflyD = length(uv - fireflyPos);

            // Twinkle: very sharp for starlike effect.
            half twinkle = half(pow(
                max(sin(time * (1.0 + fi * 0.3) + seed * 4.0) * 0.5 + 0.5, 0.0),
                8.0
            ));

            half glow = half(smoothstep(0.018, 0.0, fireflyD));
            fireflyAcc += glow * twinkle;
        }

        half3 fireflyColor = mix(color2, half3(1.0h), 0.5h);
        half fireflyAlpha = min(fireflyAcc * half(starAlpha), 1.0h);
        result.rgb = mix(result.rgb, fireflyColor, fireflyAlpha * 0.6h);
        result.a = max(result.a, fireflyAlpha * 0.4h);
    }

    // ── Layer 8: Film Grain ──────────────────────────────────────────

    half grain = hashH(half2(half2(position) * 0.5h + half2(half(time) * 100.0h)));
    result.rgb += (grain - 0.5h) * 0.015h;

    // ── Flash Overlay ────────────────────────────────────────────────

    if (flashType > 0.5 && flashProgress > 0.0 && flashProgress < 1.0) {
        half flashAlpha = half(1.0 - flashProgress) * blobMask * 0.4h;
        half3 flashColor;
        if (flashType < 1.5) {
            flashColor = half3(0.3h, 1.0h, 0.5h);  // Success: green
        } else {
            flashColor = half3(1.0h, 0.3h, 0.3h);  // Error: red
        }
        result.rgb = mix(result.rgb, flashColor, flashAlpha);
    }

    // Clamp output.
    result.rgb = clamp(result.rgb, 0.0h, 1.0h);
    result.a = clamp(result.a, 0.0h, 1.0h);

    return result;
}
