#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Fae Nebula Orb — Metal Fragment Shader
// ============================================================================
//
// Volumetric nebula effect using domain-warped Fractal Brownian Motion (FBM).
// Creates swirling amber/gold smoke inside a glass-like sphere boundary.
// Applied via SwiftUI `.colorEffect()`.
//
// Draw order:
//   1. Nebula volume (4 depth layers of domain-warped FBM)
//   2. Inner light (radial illumination from center)
//   3. Embers (30 drifting hot spots)
//   4. Rim glow (glass-like Fresnel edge)
//   5. Film grain
//   6. Flash overlay
// ============================================================================

// MARK: - Hash & Random

static float hashF(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float hashF2(float n) {
    return fract(sin(n) * 43758.5453123);
}

// MARK: - Simplex Noise 2D

constant float F2 = 0.36602540378; // 0.5 * (sqrt(3) - 1)
constant float G2 = 0.21132486540; // (3 - sqrt(3)) / 6

constant int2 grad3[8] = {
    int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1),
    int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1)
};

static float snoise2D(float2 v) {
    float s = (v.x + v.y) * F2;
    float2 i_floor = floor(v + s);
    float t = (i_floor.x + i_floor.y) * G2;
    float2 x0 = v - (i_floor - t);

    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + G2;
    float2 x2 = x0 - 1.0 + 2.0 * G2;

    float2 ii = float2(int(i_floor.x) & 255, int(i_floor.y) & 255);
    int gi0 = int(hashF(ii) * 8.0) & 7;
    int gi1 = int(hashF(ii + i1) * 8.0) & 7;
    int gi2 = int(hashF(ii + 1.0) * 8.0) & 7;

    float n0 = 0.0, n1 = 0.0, n2 = 0.0;

    float t0 = 0.5 - dot(x0, x0);
    if (t0 > 0.0) { t0 *= t0; n0 = t0 * t0 * dot(float2(grad3[gi0]), x0); }

    float t1 = 0.5 - dot(x1, x1);
    if (t1 > 0.0) { t1 *= t1; n1 = t1 * t1 * dot(float2(grad3[gi1]), x1); }

    float t2 = 0.5 - dot(x2, x2);
    if (t2 > 0.0) { t2 *= t2; n2 = t2 * t2 * dot(float2(grad3[gi2]), x2); }

    return 70.0 * (n0 + n1 + n2);
}

// MARK: - HSL Helpers

static float hue2rgb(float p, float q, float t_raw) {
    float t = t_raw;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

static float3 rgbToHSL(float3 rgb) {
    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    float l = (maxC + minC) * 0.5;
    if (maxC == minC) return float3(0.0, 0.0, l);
    float d = maxC - minC;
    float s = (l > 0.5) ? d / (2.0 - maxC - minC) : d / (maxC + minC);
    float h;
    if (maxC == rgb.r) {
        h = (rgb.g - rgb.b) / d + ((rgb.g < rgb.b) ? 6.0 : 0.0);
    } else if (maxC == rgb.g) {
        h = (rgb.b - rgb.r) / d + 2.0;
    } else {
        h = (rgb.r - rgb.g) / d + 4.0;
    }
    h /= 6.0;
    return float3(h, s, l);
}

static float3 hslToRGB(float3 hsl) {
    float h = hsl.x, s = hsl.y, l = hsl.z;
    if (s <= 0.0) return float3(l, l, l);
    float q = (l < 0.5) ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return float3(
        hue2rgb(p, q, h + 1.0 / 3.0),
        hue2rgb(p, q, h),
        hue2rgb(p, q, h - 1.0 / 3.0)
    );
}

static float3 applyHueShift(float3 rgb, float hueShiftDeg) {
    if (abs(hueShiftDeg) < 0.01) return rgb;
    float3 hsl = rgbToHSL(rgb);
    hsl.x += hueShiftDeg / 360.0;
    if (hsl.x < 0.0) hsl.x += 1.0;
    if (hsl.x > 1.0) hsl.x -= 1.0;
    return hslToRGB(hsl);
}

// MARK: - Fractal Brownian Motion

/// Layered noise at decreasing scales — creates organic cloud textures.
static float fbm(float2 p, int octaves, float lacunarity, float gain) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        sum += amp * snoise2D(p);
        p *= lacunarity;
        amp *= gain;
    }
    return sum;
}

/// Domain warping: displace coordinates using noise before sampling noise again.
/// Creates the swirling, organic smoke effect.
static float warpedFBM(float2 p, float time, float warpAmount, float warpSpeed) {
    float2 q = float2(
        fbm(p + float2(0.0, 0.0) + time * warpSpeed, 5, 2.0, 0.5),
        fbm(p + float2(5.2, 1.3) + time * warpSpeed * 0.8, 5, 2.0, 0.5)
    );
    float2 r = float2(
        fbm(p + 4.0 * q + float2(1.7, 9.2) + time * warpSpeed * 0.6, 5, 2.0, 0.5),
        fbm(p + 4.0 * q + float2(8.3, 2.8) + time * warpSpeed * 0.4, 5, 2.0, 0.5)
    );
    return fbm(p + warpAmount * r, 5, 2.0, 0.5);
}

// MARK: - Main Shader

[[ stitchable ]] half4 nebulaOrb(
    float2 position,
    half4 currentColor,
    // Time & geometry
    float time,
    float2 resolution,
    // Audio & interaction
    float audioRMS,
    float2 pointerXY,
    float pointerInfluence,
    // Snapshot properties (15 floats)
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
    // Colors (passed as individual components)
    float c0r, float c0g, float c0b,
    float c1r, float c1g, float c1b,
    float c2r, float c2g, float c2b,
    // Flash (0=none, 1=error, 2=success)
    float flashType,
    float flashProgress,
    // Anticipation scale
    float anticipationScale,
    // Enchantment
    float tremor,
    float sparkleIntensity,
    float liquidFlow,
    float radiusBias
) {
    float W = resolution.x;
    float H = resolution.y;
    float CX = W * 0.5;
    float CY = H * 0.5;
    float R = W * 0.5 * 0.42;

    // Reconstruct colour vectors.
    float3 color0 = float3(c0r, c0g, c0b);
    float3 color1 = float3(c1r, c1g, c1b);
    float3 color2 = float3(c2r, c2g, c2b);

    // Apply hue shift.
    float3 sColors[3] = {
        applyHueShift(color0, hueShift),
        applyHueShift(color1, hueShift),
        applyHueShift(color2, hueShift)
    };

    // Breathing animation — modulated by audio.
    float breath = 1.0 + sin(time * 0.42) * breathAmplitude;
    breath += audioRMS * 0.03;
    breath *= anticipationScale;

    // Organic drift.
    float driftX = snoise2D(float2(time * 0.08, 0.0)) * R * 0.06;
    float driftY = snoise2D(float2(0.0, time * 0.08 + 50.0)) * R * 0.06;

    // Pointer influence.
    driftX += (pointerXY.x - 0.5) * 30.0 * pointerInfluence;
    driftY += (pointerXY.y - 0.5) * 30.0 * pointerInfluence;

    // Transform pixel through breathing.
    float2 px = float2(
        CX + (position.x - CX) / breath,
        CY + (position.y - CY) / breath
    );

    float2 center = float2(CX + driftX, CY + driftY);

    // Normalised UV for noise sampling (centered on orb).
    float2 uv = (px - center) / R;

    // Tremor — shake effect for concern/distress
    float2 tremoruv = uv + tremor * float2(
        sin(time * 12.0 + uv.y * 8.0),
        cos(time * 11.0 + uv.x * 7.0)
    ) * 0.008;

    // Accumulate colour.
    float3 outColor = float3(0.0);
    float outAlpha = 0.0;

    // Nebula turbulence responds to audio.
    float warpAmount = morphAmplitude * (1.0 + audioRMS * 0.5);

    // Amber/gold reference colours for the nebula volume.
    float3 darkAmber = sColors[1] * 0.4;
    float3 brightGold = sColors[0];
    float3 hotWhite = float3(1.0, 0.97, 0.88);

    // ── 1. Nebula Volume (4 depth layers) ───────────────────────────────
    for (int layer = 0; layer < 4; layer++) {
        float layerDepth = float(layer) / 3.0;
        float scale = 2.0 + layerDepth * 1.5;
        float speed = (0.06 + layerDepth * 0.04) * speedScale * morphSpeed / 0.18 * liquidFlow;
        float warp = warpAmount * (1.0 - layerDepth * 0.3);

        float2 uv_layer = tremoruv * scale + float2(float(layer) * 3.7, float(layer) * 2.1);
        float density = warpedFBM(uv_layer, time, warp, speed);

        // Colour mapping: density -> dark amber -> bright gold -> white.
        float3 layerColor = mix(darkAmber, brightGold, saturate(density * 1.5 + 0.5));
        if (density > 0.3) {
            layerColor = mix(layerColor, hotWhite, saturate((density - 0.3) * 1.5));
        }

        // Mix in the third colour for variety.
        layerColor = mix(layerColor, sColors[2], 0.15 * (1.0 - layerDepth));

        // Depth-based alpha: front layers more opaque.
        float layerAlpha = (0.35 - layerDepth * 0.12) * fogDensity;
        layerAlpha *= saturate(density * 1.5 + 0.6);

        // Asymmetry — bias density based on angle.
        float uvAngle = atan2(uv.y, uv.x);
        float asymBias = 1.0 + asymmetry * sin(uvAngle + time * 0.3);
        layerAlpha *= asymBias;

        outColor = outColor + layerColor * layerAlpha * (1.0 - outAlpha);
        outAlpha = outAlpha + layerAlpha * (1.0 - outAlpha);
    }

    // Add secondary nebula layer (repurpose blobAlpha).
    {
        float2 uv2 = uv * 1.5 + float2(time * 0.02, time * 0.015);
        float secondary = warpedFBM(uv2, time * 0.7, warpAmount * 0.6, morphSpeed * 0.3);
        float3 secColor = mix(sColors[2], sColors[0], saturate(secondary + 0.5));
        float secAlpha = blobAlpha * saturate(secondary * 1.2 + 0.4);
        outColor = outColor + secColor * secAlpha * (1.0 - outAlpha);
        outAlpha = outAlpha + secAlpha * (1.0 - outAlpha);
    }

    // ── 2. Inner Light ──────────────────────────────────────────────────
    {
        float lightDist = length(uv);
        float lightBoost = innerGlow * (1.0 + audioRMS * 0.3);
        float lightIntensity = lightBoost * exp(-lightDist * lightDist * 6.0);
        float3 lightColor = mix(brightGold, hotWhite, lightIntensity);
        outColor += lightColor * lightIntensity;
        outAlpha = saturate(outAlpha + lightIntensity * 0.5);
    }

    // ── 3. Embers (30 drifting hot spots) ───────────────────────────────
    for (int i = 0; i < 30; i++) {
        float fi = float(i);
        float seed = fi * 17.31;

        // Position driven by noise (flows with the nebula).
        float2 emberPos = float2(
            snoise2D(float2(seed, time * 0.1)) * R * 0.7,
            snoise2D(float2(seed + 50.0, time * 0.1)) * R * 0.7
        );

        float rate = 1.5 + hashF2(seed + 1.0) * 3.0;
        float phase = hashF2(seed + 2.0) * 6.28318;
        float brightness = pow(saturate(sin(time * rate + phase) * 0.5 + 0.5), 3.0);

        float glowR = 3.0 + brightness * 4.0;
        float d = length(px - (center + emberPos));
        float glow = exp(-d * d / (glowR * glowR)) * brightness * starAlpha;

        if (glow > 0.003) {
            // Colour: mix between palette and hot white based on brightness.
            float3 emberColor = mix(sColors[int(fi) % 3], hotWhite, brightness * 0.6);
            outColor += emberColor * glow;
            outAlpha = saturate(outAlpha + glow * 0.3);
        }
    }

    // ── 4. Outer glow halo ──────────────────────────────────────────────
    {
        float dist = length(px - center);
        float haloStart = R * 0.9;
        float haloEnd = R * 1.4;
        if (dist > haloStart && dist < haloEnd) {
            float haloT = (dist - haloStart) / (haloEnd - haloStart);
            float haloAlpha = outerAlpha * (1.0 - haloT) * (1.0 - haloT);
            float3 haloColor = sColors[0] * 0.5;
            outColor += haloColor * haloAlpha;
            outAlpha = saturate(outAlpha + haloAlpha * 0.3);
        }
    }

    // ── 5. Rim Glow (Fresnel-like glass edge) ───────────────────────────
    {
        float dist = length(uv);
        float rimStart = 0.7;
        float rimEnd = 1.0;
        if (dist > rimStart && dist < rimEnd) {
            float rimT = (dist - rimStart) / (rimEnd - rimStart);
            float rimGlow = wispAlpha * rimT * rimT * (1.0 - rimT) * 4.0;

            // Shimmer adds high-frequency sparkle to the rim.
            float rimShimmer = 1.0 + shimmer * snoise2D(float2(atan2(uv.y, uv.x) * 8.0, time * 3.0)) * 2.0;
            rimGlow *= rimShimmer;

            float3 rimColor = mix(sColors[0], hotWhite, 0.3);
            outColor += rimColor * rimGlow * wispSize * 4.0;
            outAlpha = saturate(outAlpha + rimGlow * 0.2);
        }
    }

    // ── 5.5. Sparkles ─────────────────────────────────────────────────
    {
        float sparkleAcc = 0.0;
        for (int si = 0; si < 8; si++) {
            float fi2 = float(si);
            float2 seed2 = float2(fi2 * 137.508, fi2 * 98.324);
            float2 spos = float2(
                hashF2(seed2.x) * 2.0 - 1.0,
                hashF2(seed2.y) * 2.0 - 1.0
            ) * 0.6;
            float sdist = length(uv - spos);
            float blink = sin(time * (3.0 + fi2 * 1.3) + seed2.x) * 0.5 + 0.5;
            blink = pow(blink, 8.0);
            sparkleAcc += blink * smoothstep(0.04, 0.0, sdist);
        }
        float3 sparkleColor = float3(1.0, 0.95, 0.85);
        outColor += sparkleIntensity * sparkleAcc * sparkleColor;
        outAlpha = saturate(outAlpha + sparkleIntensity * sparkleAcc * 0.2);
    }

    // ── 6. Film Grain ───────────────────────────────────────────────────
    {
        float2 grainUV = fmod(px + float2(time * 12.0, time * 7.0), 128.0) / 128.0;
        float grain = hashF(grainUV * 1000.0 + float2(time * 0.1, 0.0));
        outColor += float3(grain) * 0.02;
    }

    // ── 7. Flash Overlay ────────────────────────────────────────────────
    if (flashType > 0.5 && flashProgress < 1.0) {
        float flashAlpha;
        if (flashProgress < 0.3) {
            flashAlpha = flashProgress / 0.3;
        } else {
            flashAlpha = 1.0 - (flashProgress - 0.3) / 0.7;
        }
        flashAlpha = max(0.0, flashAlpha * 0.35);

        float3 flashColor = (flashType < 1.5)
            ? float3(180.0 / 255.0, 60.0 / 255.0, 50.0 / 255.0)
            : float3(210.0 / 255.0, 180.0 / 255.0, 60.0 / 255.0);

        float d = length(uv);
        float g = saturate(1.0 - d);
        float fA = flashAlpha * g;

        outColor += flashColor * fA;
        outAlpha = max(outAlpha, fA);
    }

    // ── Sphere Boundary Mask ────────────────────────────────────────────
    // Soft sphere mask with glass-like Fresnel fall-off.
    {
        float dist = length(uv);
        float rimInner = 0.85 - radiusBias * 0.15;
        float rimOuter = 1.05 + radiusBias * 0.05;
        float sphereMask = smoothstep(rimOuter, rimInner, dist);
        outAlpha *= sphereMask;
        outColor *= sphereMask;
    }

    return half4(half3(outColor), half(outAlpha));
}
