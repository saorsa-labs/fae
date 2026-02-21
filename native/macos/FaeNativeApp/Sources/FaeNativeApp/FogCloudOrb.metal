#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Fae Fog-Cloud Orb — Metal Fragment Shader
// ============================================================================
//
// Faithful port of the Canvas 2D JS orb animation to a single-pass MSL
// fragment shader. Applied via SwiftUI `.colorEffect()`.
//
// Draw order (matches JS exactly):
//   1. Wisps (boundary fog puffs)
//   2. Fog layers (6 displaced radial gradients)
//   3. Blobs (14 orbital fog elements)
//   4. Inner glow
//   5. Stars (120 twinkling points)
//   6. Film grain
//   7. Flash overlay
// ============================================================================

// MARK: - Hash & Random

/// PCG-based hash for deterministic per-element randomness.
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

/// Simplex noise using hash-based gradient selection.
static float snoise2D(float2 v) {
    float s = (v.x + v.y) * F2;
    float2 i_floor = floor(v + s);
    float t = (i_floor.x + i_floor.y) * G2;
    float2 x0 = v - (i_floor - t);

    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + G2;
    float2 x2 = x0 - 1.0 + 2.0 * G2;

    // Gradient via hash.
    float2 ii = float2(int(i_floor.x) & 255, int(i_floor.y) & 255);
    int gi0 = int(hashF(ii) * 8.0) & 7;
    int gi1 = int(hashF(ii + i1) * 8.0) & 7;
    int gi2 = int(hashF(ii + 1.0) * 8.0) & 7;

    float n0 = 0.0, n1 = 0.0, n2 = 0.0;

    float t0 = 0.5 - dot(x0, x0);
    if (t0 > 0.0) {
        t0 *= t0;
        n0 = t0 * t0 * dot(float2(grad3[gi0]), x0);
    }

    float t1 = 0.5 - dot(x1, x1);
    if (t1 > 0.0) {
        t1 *= t1;
        n1 = t1 * t1 * dot(float2(grad3[gi1]), x1);
    }

    float t2 = 0.5 - dot(x2, x2);
    if (t2 > 0.0) {
        t2 *= t2;
        n2 = t2 * t2 * dot(float2(grad3[gi2]), x2);
    }

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

/// Apply hue shift (in degrees) to an RGB colour.
static float3 applyHueShift(float3 rgb, float hueShiftDeg) {
    if (abs(hueShiftDeg) < 0.01) return rgb;
    float3 hsl = rgbToHSL(rgb);
    hsl.x += hueShiftDeg / 360.0;
    if (hsl.x < 0.0) hsl.x += 1.0;
    if (hsl.x > 1.0) hsl.x -= 1.0;
    return hslToRGB(hsl);
}

// MARK: - Morph Field

/// Compute morph displacement at a given angle (continuous, not segmented).
static float getMorphAt(
    float angle,
    float time,
    float morphAmplitude,
    float morphFreq,
    float morphSpeed,
    float shimmer,
    float asymmetry
) {
    float ca = cos(angle);
    float sa = sin(angle);

    float n1 = snoise2D(float2(
        ca * morphFreq + time * morphSpeed,
        sa * morphFreq + time * morphSpeed * 0.7
    ));

    float n2 = snoise2D(float2(
        ca * (morphFreq * 0.5) + time * morphSpeed * 0.3 + 100.0,
        sa * (morphFreq * 0.5) + time * morphSpeed * 0.2 + 100.0
    ));

    float shimN = 0.0;
    if (shimmer > 0.001) {
        shimN = snoise2D(float2(angle * 8.0, time * 3.0)) * shimmer * 0.02;
    }

    float asymF = 1.0 + asymmetry * sin(angle + time * 0.3);
    float displacement = n1 * morphAmplitude * 0.7 + n2 * morphAmplitude * 0.3 + shimN;

    return (1.0 + displacement) * asymF;
}

// MARK: - Main Shader

[[ stitchable ]] half4 fogCloudOrb(
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
    // Colors (passed as individual components — SwiftUI has no .float3 argument)
    float c0r, float c0g, float c0b,
    float c1r, float c1g, float c1b,
    float c2r, float c2g, float c2b,
    // Flash (0=none, 1=error, 2=success)
    float flashType,
    float flashProgress,
    // Anticipation scale
    float anticipationScale
) {
    float W = resolution.x;
    float H = resolution.y;
    float CX = W * 0.5;
    float CY = H * 0.5;
    float R = W * 0.5 * 0.42;

    // Reconstruct colour vectors from individual components.
    float3 color0 = float3(c0r, c0g, c0b);
    float3 color1 = float3(c1r, c1g, c1b);
    float3 color2 = float3(c2r, c2g, c2b);

    // Apply hue shift to colours.
    float3 sColors[3] = {
        applyHueShift(color0, hueShift),
        applyHueShift(color1, hueShift),
        applyHueShift(color2, hueShift)
    };

    // Breathing animation.
    float throb = 1.0 + sin(time * 0.42) * breathAmplitude;
    throb *= anticipationScale;

    // Organic drift.
    float driftX = snoise2D(float2(time * 0.08, 0.0)) * R * 0.06;
    float driftY = snoise2D(float2(0.0, time * 0.08 + 50.0)) * R * 0.06;

    // Pointer influence.
    driftX += (pointerXY.x - 0.5) * 30.0 * pointerInfluence;
    driftY += (pointerXY.y - 0.5) * 30.0 * pointerInfluence;

    // Transform pixel position through throb.
    float2 px = float2(
        CX + (position.x - CX) / throb,
        CY + (position.y - CY) / throb
    );

    // Accumulate colour.
    float3 outColor = float3(0.0);
    float outAlpha = 0.0;

    // ── 1. Wisps (8) ──────────────────────────────────────────────────
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float baseAngle = (fi / 8.0) * 6.28318 + (hashF2(fi * 7.13) - 0.5) * 0.8;
        float dist = 0.6 + hashF2(fi * 3.17) * 0.35;
        float sizeBase = 0.7 + hashF2(fi * 11.37) * 0.6;
        float driftSpeed = 0.03 + hashF2(fi * 5.71) * 0.08;
        float noiseSeed = fi * 345.0;
        float alphaBase = 0.7 + hashF2(fi * 9.23) * 0.6;
        int colorIdx = i % 3;

        float wAngle = baseAngle + snoise2D(float2(noiseSeed + time * driftSpeed, fi * 3.0)) * 0.6;
        float morph = getMorphAt(wAngle, time, morphAmplitude, morphFreq, morphSpeed, shimmer, asymmetry);
        float wDist = dist * R * morph;

        float wx = CX + cos(wAngle) * wDist + driftX * 0.5;
        float wy = CY + sin(wAngle) * wDist + driftY * 0.5;

        float wR = wispSize * sizeBase * R;
        float wPulse = 1.0 + sin(time * 0.3 + fi * 1.5) * 0.15;
        wR *= wPulse;

        float wa = wispAlpha * alphaBase;

        float d = length(px - float2(wx, wy));
        float g = saturate(1.0 - d / max(wR, 0.001));
        float gradAlpha;
        if (d / wR < 0.5) {
            gradAlpha = wa;
        } else {
            gradAlpha = wa * saturate(1.0 - (d / wR - 0.5) / 0.5) * 0.4;
        }
        gradAlpha *= g;

        float3 wColor = sColors[colorIdx];
        outColor += wColor * gradAlpha;
        outAlpha = max(outAlpha, gradAlpha);
    }

    // ── 2. Fog Layers (6) ─────────────────────────────────────────────
    for (int layer = 0; layer < 6; layer++) {
        float fl = float(layer);
        float layerT = fl / 5.0;
        float layerR = R * (0.25 + layerT * 0.8);

        float lAngle = (fl / 6.0) * 6.28318;
        float lMorph = getMorphAt(lAngle + time * 0.05, time, morphAmplitude, morphFreq, morphSpeed, shimmer, asymmetry);

        float lx = CX + snoise2D(float2(fl * 12.0 + time * 0.06, 0.0)) * R * 0.1 * lMorph + driftX;
        float ly = CY + snoise2D(float2(0.0, fl * 12.0 + time * 0.06)) * R * 0.1 * lMorph + driftY;

        float layerAlpha = fogDensity * (0.2 - layerT * 0.1);

        float3 c = sColors[layer % 3];

        float d = length(px - float2(lx, ly));
        float outerR = layerR * 1.2;
        float normD = d / max(outerR, 0.001);
        float g;
        if (normD <= 0.6) {
            g = layerAlpha;
        } else {
            g = layerAlpha * saturate(1.0 - (normD - 0.6) / 0.4) * 0.5;
        }

        outColor += c * g;
        outAlpha = max(outAlpha, g);
    }

    // ── 3. Blobs (14) ─────────────────────────────────────────────────
    for (int i = 0; i < 14; i++) {
        float fi = float(i);
        float orbitRadius = 0.08 + (fi / 14.0) * 0.38;
        float phaseOffset = fmod(fi * 2.399, 6.28318);
        float speedVariance = 0.7 + hashF2(fi * 23.17) * 0.6;
        float noiseSeed = fi * 137.5;
        int colorIdx = i % 3;

        float speed = speedScale * speedVariance;
        float phase = time * (0.2 + fi * 0.07 + speed * 0.08) + phaseOffset;

        float nx = snoise2D(float2(noiseSeed + time * 0.15 * speed, fi * 0.3));
        float ny = snoise2D(float2(noiseSeed + 100.0 + time * 0.13 * speed, fi * 0.3 + 50.0));

        float orbitR = orbitRadius * R;

        float bx = CX + cos(phase) * orbitR + nx * orbitR * 0.5 + driftX * 0.3;
        float by = CY + sin(phase * 0.9) * orbitR + ny * orbitR * 0.5 + driftY * 0.3;

        float blobR = R * 0.28 + sin(phase * 1.7) * R * 0.05;

        // Fade near boundary.
        float dfc = length(float2(bx, by) - float2(CX, CY));
        float bFade = saturate(1.0 - dfc / (R * 1.2));
        bFade = pow(bFade, 0.6);

        float3 c = sColors[colorIdx];

        float d = length(px - float2(bx, by));
        float g = saturate(1.0 - d / max(blobR, 0.001));
        float a = blobAlpha * bFade * g;

        outColor += c * a;
        outAlpha = max(outAlpha, a);
    }

    // ── 4. Inner Glow ─────────────────────────────────────────────────
    {
        float2 glowCenter = float2(CX + driftX, CY + driftY);
        float d = length(px - glowCenter);
        float g = saturate(1.0 - d / (R * 0.5));
        float a = innerGlow * g;
        outColor += sColors[0] * a;
        outAlpha = max(outAlpha, a);
    }

    // ── 5. Stars (120: 100 inner + 20 outer) ──────────────────────────
    for (int i = 0; i < 120; i++) {
        float fi = float(i);
        bool isOuter = (i >= 100);

        // Deterministic spawn parameters from star ID.
        float seed = fi * 17.31;
        float speed0 = 0.015 + hashF2(seed + 2.0) * 0.12;
        bool isBright = hashF2(seed + 3.0) < 0.06;
        float size0 = isBright ? (0.8 + hashF2(seed + 4.0) * 0.5) : (0.2 + hashF2(seed + 4.0) * 0.7);
        float lifespan = 3.0 + hashF2(seed + 5.0) * 8.0;
        float noiseSeed2 = hashF2(seed + 6.0) * 1000.0;
        int colorIdx = int(hashF2(seed + 7.0) * 3.0) % 3;
        float twinkleRate = 1.5 + hashF2(seed + 8.0) * 4.0;
        float twinklePhase = hashF2(seed + 9.0) * 6.28318;

        // Compute current generation (respawn cycle).
        float generation = floor(time / lifespan);
        float age = fmod(time, lifespan);

        // Re-seed per generation for variety.
        float genSeed = seed + generation * 100.0;
        float angle = hashF2(genSeed) * 6.28318;
        float dist = isOuter ? (0.7 + hashF2(genSeed + 1.0) * 0.35) : (0.04 + hashF2(genSeed + 1.0) * 0.62);

        // Fade in/out over lifespan.
        float lifeT = age / lifespan;
        float alpha;
        if (lifeT < 0.1) {
            alpha = lifeT / 0.1;
        } else if (lifeT > 0.8) {
            alpha = (1.0 - lifeT) / 0.2;
        } else {
            alpha = 1.0;
        }

        // Twinkle.
        float twinkleVal = 0.4 + 0.6 * sin(time * twinkleRate + twinklePhase);
        alpha *= twinkleVal;

        // Base alpha.
        float baseA = isOuter ? outerAlpha : starAlpha;
        alpha *= isBright ? baseA : (baseA * 0.6);

        if (alpha < 0.003) continue;

        // Orbital motion.
        float pNx = snoise2D(float2(noiseSeed2 + time * 0.08, noiseSeed2 * 0.3));
        float orbitSpeed = speed0 * (1.0 + (1.0 - dist) * 0.5) * speedScale;
        float sAngle = angle + time * orbitSpeed;
        float sDist = dist * R * (isOuter ? 1.4 : 1.0) + pNx * R * 0.06;

        float sx = CX + cos(sAngle) * sDist + driftX * (isOuter ? 0.2 : 0.4);
        float sy = CY + sin(sAngle) * sDist + driftY * (isOuter ? 0.2 : 0.4);

        // Edge fade for inner stars.
        if (!isOuter) {
            float dfc2 = length(float2(sx, sy) - float2(CX, CY));
            float edgeFade = saturate(1.0 - dfc2 / (R * 1.15));
            edgeFade = pow(edgeFade, 0.4);
            alpha *= edgeFade;
        }

        if (alpha < 0.003) continue;

        float3 sColor = sColors[colorIdx];
        float sSize = size0 * 2.0; // Scale for pixel density.

        // Bright star glow halo.
        if (isBright && alpha > 0.08) {
            float glowR = sSize * 2.5;
            float dGlow = length(px - float2(sx, sy));
            float gGlow = saturate(1.0 - dGlow / max(glowR, 0.001));
            float glowA = alpha * 0.3 * gGlow;
            outColor += sColor * glowA;
            outAlpha = max(outAlpha, glowA);
        }

        // Star point.
        float dStar = length(px - float2(sx, sy));
        if (dStar < sSize) {
            float sA = alpha * saturate(1.0 - dStar / sSize);
            outColor += sColor * sA;
            outAlpha = max(outAlpha, sA);
        }
    }

    // ── 6. Film Grain ─────────────────────────────────────────────────
    {
        float2 grainUV = fmod(px + float2(time * 12.0, time * 7.0), 128.0) / 128.0;
        float grain = hashF(grainUV * 1000.0 + float2(time * 0.1, 0.0));
        outColor += float3(grain) * 0.025;
    }

    // ── 7. Flash Overlay ──────────────────────────────────────────────
    if (flashType > 0.5 && flashProgress < 1.0) {
        float flashAlpha;
        if (flashProgress < 0.3) {
            flashAlpha = flashProgress / 0.3;
        } else {
            flashAlpha = 1.0 - (flashProgress - 0.3) / 0.7;
        }
        flashAlpha = max(0.0, flashAlpha * 0.35);

        float3 flashColor = (flashType < 1.5)
            ? float3(180.0 / 255.0, 60.0 / 255.0, 50.0 / 255.0)  // Error: red-brown
            : float3(210.0 / 255.0, 180.0 / 255.0, 60.0 / 255.0); // Success: gold

        float d = length(px - float2(CX, CY));
        float g = saturate(1.0 - d / R);
        float fA = flashAlpha * g;

        outColor += flashColor * fA;
        outAlpha = max(outAlpha, fA);
    }

    // ── Edge Mask ─────────────────────────────────────────────────────
    // Soft circular mask to fade the orb at its boundary.
    {
        float d = length(px - float2(CX, CY));
        float edgeMask = saturate(1.0 - (d - R * 0.85) / (R * 0.55));
        outAlpha *= edgeMask;
        outColor *= edgeMask;
    }

    return half4(half3(outColor), half(outAlpha));
}
