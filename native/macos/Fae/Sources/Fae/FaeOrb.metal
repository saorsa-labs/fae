#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Fae Amber Orb — Noise-Displaced Layer Fragment Shader
// ============================================================================
//
// Faithful Metal port of Benjamin's Canvas 2D orb design.
//
// Architecture (back to front):
//   1. Outer glow — soft radial beyond the orb (baseOrbRadius, NOT mood-scaled)
//   2. 10 noise-displaced layers with 4-stop radial gradients
//   3. Bright wandering point (inner light with warm-white glow)
//   4. 6 deterministic flares (wispy tendrils, replacing Canvas stochastic spawn)
//   5. 30 deterministic particles (orbiting dots, seeded by index)
//   6. Film grain — subtle noise texture
//   7. Flash overlay — success/error indicator
//
// Key parameters from OrbSnapshot:
//   speedScale     → animation speed (Canvas: mood.speed)
//   morphAmplitude → noise displacement amplitude (Canvas: mood.amplitude)
//   radiusBias     → orb size offset (Canvas: mood.size - 1.0)
//   breathAmplitude→ breathing depth (Canvas: 0.015 + amp * 0.02)
//   fogDensity     → outer glow intensity
//   starAlpha      → particle visibility
//   wispAlpha      → flare/wisp intensity
//   innerGlow      → bright point intensity
//
// Colours: c0 = outer/bright, c1 = mid, c2 = inner/dark
//   Matches Canvas: colors[0], colors[1], colors[2]
//
// Performance: ~1500 ops/pixel. At 240×240 @ 30fps ≈ 2.6B ops/s.
// Apple Silicon handles this at well under 1% GPU utilisation.
//
// Applied via SwiftUI `.colorEffect()`.
// ============================================================================

// MARK: - Hash Functions

/// Fast 2D float hash for deterministic pseudo-random values.
static float hashF(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Half-precision hash for film grain.
static half hashH(half2 p) {
    half3 p3 = fract(half3(p.xyx) * 0.1031h);
    p3 += dot(p3, p3.yzx + 33.33h);
    return fract((p3.x + p3.y) * p3.z);
}

// MARK: - Simplex Noise 2D (float precision)

constant float F2 = 0.36602540378;   // (sqrt(3) - 1) / 2
constant float G2 = 0.21132486540;   // (3 - sqrt(3)) / 6

constant float2 grad2[8] = {
    float2( 1,  1), float2(-1,  1), float2( 1, -1), float2(-1, -1),
    float2( 1,  0), float2(-1,  0), float2( 0,  1), float2( 0, -1)
};

/// Standard simplex noise 2D returning approximately [-1, 1].
/// Uses hash-based gradient selection (stateless — no permutation table).
static float snoise2D(float2 v) {
    float s = (v.x + v.y) * F2;
    float2 i_floor = floor(v + s);
    float tf = (i_floor.x + i_floor.y) * G2;
    float2 x0 = v - (i_floor - tf);

    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float2 x1 = x0 - i1 + G2;
    float2 x2 = x0 - 1.0 + 2.0 * G2;

    float2 ii = float2(int(i_floor.x) & 255, int(i_floor.y) & 255);
    int gi0 = int(hashF(ii) * 8.0) & 7;
    int gi1 = int(hashF(ii + i1) * 8.0) & 7;
    int gi2 = int(hashF(ii + 1.0) * 8.0) & 7;

    float n0 = 0.0, n1 = 0.0, n2 = 0.0;

    float t0 = 0.5 - dot(x0, x0);
    if (t0 > 0.0) { t0 *= t0; n0 = t0 * t0 * dot(grad2[gi0], x0); }

    float t1 = 0.5 - dot(x1, x1);
    if (t1 > 0.0) { t1 *= t1; n1 = t1 * t1 * dot(grad2[gi1], x1); }

    float t2 = 0.5 - dot(x2, x2);
    if (t2 > 0.0) { t2 *= t2; n2 = t2 * t2 * dot(grad2[gi2], x2); }

    return 70.0 * (n0 + n1 + n2);
}

// MARK: - Gradient Helper

/// Canvas 4-stop radial gradient:
///   t=0.00 → alpha × 2.0
///   t=0.30 → alpha × 1.2
///   t=0.65 → alpha × 0.4
///   t=1.00 → 0
static float layerGradient(float t, float alpha) {
    if (t <= 0.0)  return alpha * 2.0;
    if (t <= 0.3)  return mix(alpha * 2.0, alpha * 1.2, t / 0.3);
    if (t <= 0.65) return mix(alpha * 1.2, alpha * 0.4, (t - 0.3) / 0.35);
    if (t <= 1.0)  return mix(alpha * 0.4, 0.0, (t - 0.65) / 0.35);
    return 0.0;
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
    float W = resolution.x;
    float H = resolution.y;

    // Centre UV so (0,0) is the middle; view width spans [-0.5, 0.5].
    float2 uv = (position - float2(W, H) * 0.5) / W;

    // Tremor displacement (concern / nervousness).
    if (tremor > 0.001) {
        float tremorT = time * 12.0 * speedScale;
        uv.x += tremor * 0.008 * sin(tremorT * 7.3 + uv.y * 20.0);
        uv.y += tremor * 0.008 * cos(tremorT * 5.7 + uv.x * 20.0);
    }

    // ── Mapped Parameters ──────────────────────────────────────────
    float speed     = speedScale;               // Animation speed
    float amp       = morphAmplitude;            // Noise displacement magnitude
    float sizeScale = 1.0 + radiusBias;          // Orb size (1.0 = normal)

    // Palette: c0 = outer/bright, c1 = mid, c2 = inner/dark.
    half3 color0 = half3(c0r, c0g, c0b);
    half3 color1 = half3(c1r, c1g, c1b);
    half3 color2 = half3(c2r, c2g, c2b);

    // Base orb radius: 0.3 of view width (Canvas: size × 0.3 / size = 0.3).
    float baseOrbRadius = 0.3;
    float orbRadius = baseOrbRadius * sizeScale * anticipationScale;

    // Breathing — rate tied to speed & amplitude, depth from OrbSnapshot.
    // Canvas: breathPhase rate = speed × (0.8 + amp × 0.5)
    //         breathDepth = 0.015 + amp × 0.02
    float breathRate  = speed * (0.8 + amp * 0.5);
    float breathDepth = breathAmplitude;
    float breathScale = 1.0 + sin(time * breathRate) * breathDepth;

    // Mouse lean in UV space.
    // Canvas: mx = (mouseX - 0.5) × 10 on 520px → 10/520 ≈ 0.019 normalised.
    float2 mouseUV = (pointerXY - 0.5) * pointerInfluence * 0.019;

    float dist  = length(uv);
    float angle = atan2(uv.y, uv.x);

    // Output — starts transparent.
    half4 result = half4(0.0h);

    // ── 1. Outer Glow ──────────────────────────────────────────────
    // Radial from baseOrbRadius × 0.6 to baseOrbRadius × 1.8.
    // Uses baseOrbRadius (NOT mood-scaled) — matches Canvas `this.baseOrbRadius`.
    {
        float glowInner = baseOrbRadius * 0.6;
        float glowOuter = baseOrbRadius * 1.8;

        if (dist < glowOuter) {
            half3  glowColor;
            float glowAlpha;

            if (dist <= glowInner) {
                // Inside inner radius — first gradient stop.
                glowColor = color0;
                glowAlpha = 0.25;
            } else {
                float gt = (dist - glowInner) / (glowOuter - glowInner);
                // Canvas stops: 0→(c0, 0.25), 0.3→(c1, 0.12),
                //               0.6→(c2, 0.04), 1.0→(_, 0)
                if (gt <= 0.3) {
                    float t = gt / 0.3;
                    glowColor = mix(color0, color1, half(t));
                    glowAlpha = mix(0.25, 0.12, t);
                } else if (gt <= 0.6) {
                    float t = (gt - 0.3) / 0.3;
                    glowColor = mix(color1, color2, half(t));
                    glowAlpha = mix(0.12, 0.04, t);
                } else {
                    float t = (gt - 0.6) / 0.4;
                    glowColor = color2;
                    glowAlpha = mix(0.04, 0.0, t);
                }
            }

            glowAlpha *= fogDensity;
            // Premultiplied alpha output.
            result.rgb = glowColor * half(glowAlpha);
            result.a   = half(glowAlpha);
        }
    }

    // ── 2. Ten Noise-Displaced Layers ──────────────────────────────
    // Each layer: noise-displaced boundary checked per-pixel at exact angle.
    // Back-to-front (l=0 innermost, l=9 outermost).
    for (int l = 0; l < 10; l++) {
        float fl = float(l);
        float layerT = fl / 10.0;

        // Layer geometry — Canvas exact values.
        float layerRadius = orbRadius * (0.15 + layerT * 0.85) * breathScale;
        float noiseScale  = 1.0 + layerT * 0.7;
        // Canvas: noiseAmp = (40 + layerT × 65) × amp   [pixels on 520px]
        // Normalised: (40/520 + layerT × 65/520) × amp
        float noiseAmp = (0.0769 + layerT * 0.125) * amp;
        float alpha    = 0.08 + layerT * 0.14;

        // Colour ramp: inner dark → mid → outer bright.
        // Canvas: layerT < 0.35 → lerp(colors[2], colors[1])
        //         layerT ≥ 0.35 → lerp(colors[1], colors[0])
        half3 layerColor;
        if (layerT < 0.35) {
            layerColor = mix(color2, color1, half(layerT / 0.35));
        } else {
            layerColor = mix(color1, color0, half((layerT - 0.35) / 0.65));
        }

        // Two-octave simplex noise at this pixel's angle.
        // Canvas: n1 blended 55% + n2 blended 45%.
        float ca = cos(angle);
        float sa = sin(angle);

        float n1 = snoise2D(float2(
            ca * noiseScale * 0.5  + time * 0.2  * speed + fl * 0.7,
            sa * noiseScale * 0.5  + time * 0.15 * speed + fl * 0.5
        ));
        float n2 = snoise2D(float2(
            ca * noiseScale * 2.2  + time * 0.35 * speed + fl * 1.3 + 5.5,
            sa * noiseScale * 2.2  + time * 0.25 * speed + fl * 0.9 + 5.5
        ));
        float n = n1 * 0.55 + n2 * 0.45;

        // Noise-displaced boundary + mouse lean.
        float boundary = layerRadius + n * noiseAmp
                       + mouseUV.x * ca + mouseUV.y * sa;

        if (dist < boundary) {
            // Radial gradient: t = dist / (layerRadius × 1.1).
            float gradT = saturate(dist / max(layerRadius * 1.1, 0.001));
            float gradAlpha = layerGradient(gradT, alpha);

            // Anti-aliased edge (2px soft feather).
            float edgePx = 2.0 / W;
            gradAlpha *= saturate((boundary - dist) / edgePx);

            // Subtle audio reactivity.
            gradAlpha *= 1.0 + audioRMS * 0.15;

            // Source-over compositing (premultiplied alpha).
            half srcA = half(gradAlpha);
            result.rgb = result.rgb * (1.0h - srcA) + layerColor * srcA;
            result.a   = srcA + result.a * (1.0h - srcA);
        }
    }

    // ── 3. Bright Wandering Point ──────────────────────────────────
    // Canvas: bpAngle = time × 0.15 + sin(time × 0.23) × 0.8
    //         bpR     = orbRadius × (0.2 + sin(time × 0.18) × 0.12)
    if (innerGlow > 0.01) {
        float bpAngle = time * 0.15 + sin(time * 0.23) * 0.8;
        float bpR     = orbRadius * (0.2 + sin(time * 0.18) * 0.12);
        float2 bpPos  = float2(cos(bpAngle) * bpR, sin(bpAngle) * bpR);
        float bpDist  = length(uv - bpPos);

        // Wide soft glow — Canvas: orbRadius × 0.12 radius.
        float wideR = orbRadius * 0.12;
        if (bpDist < wideR) {
            float bt = bpDist / wideR;
            // Canvas gradient stops:
            //   0.0 → rgba(255,240,200, 0.25)
            //   0.2 → rgba(245,220,160, 0.12)
            //   0.5 → rgba(230,190,120, 0.04)
            //   1.0 → rgba(220,170,100, 0)
            float bpAlpha;
            half3 bpColor;
            if (bt <= 0.2) {
                float t = bt / 0.2;
                bpColor = mix(half3(1.000h, 0.941h, 0.784h),
                              half3(0.961h, 0.863h, 0.627h), half(t));
                bpAlpha = mix(0.25, 0.12, t);
            } else if (bt <= 0.5) {
                float t = (bt - 0.2) / 0.3;
                bpColor = mix(half3(0.961h, 0.863h, 0.627h),
                              half3(0.902h, 0.745h, 0.471h), half(t));
                bpAlpha = mix(0.12, 0.04, t);
            } else {
                float t = (bt - 0.5) / 0.5;
                bpColor = half3(0.863h, 0.667h, 0.392h);
                bpAlpha = mix(0.04, 0.0, t);
            }
            bpAlpha *= innerGlow;
            half srcA = half(bpAlpha);
            result.rgb = result.rgb * (1.0h - srcA) + bpColor * srcA;
            result.a   = max(result.a, srcA);
        }

        // Tiny bright core — Canvas: 1.5px radius.
        float coreR = 1.5 / W;
        if (bpDist < coreR) {
            float coreAlpha = (1.0 - bpDist / coreR) * 0.8 * innerGlow;
            half srcA = half(coreAlpha);
            half3 coreColor = half3(1.0h, 0.980h, 0.933h);
            result.rgb = result.rgb * (1.0h - srcA) + coreColor * srcA;
            result.a   = max(result.a, srcA);
        }
    }

    // ── 4. Flares (6 Deterministic Wisps) ──────────────────────────
    // Replaces Canvas stochastic spawn with time-based lifecycle per slot.
    // Each slot cycles with its own period; active for 30% of cycle.
    if (wispAlpha > 0.01) {
        for (int i = 0; i < 6; i++) {
            float fi = float(i);

            // Deterministic lifecycle.
            float period = 4.0 + fi * 1.3;            // 4.0 – 10.5 s
            float phase  = fract(time / period + fi * 0.618);
            float life   = 0.0;
            if (phase < 0.3) {
                // Rise 0→1 in first half, fall 1→0 in second half.
                life = phase < 0.15
                     ? (phase / 0.15)
                     : ((0.3 - phase) / 0.15);
                life = life * life * life;             // Cubic ease
            }
            if (life < 0.01) continue;

            // Slowly wobbling direction, ~60° spacing.
            float flareAngle = fi * 1.047 + sin(time * 0.1 + fi * 2.0) * 0.5;
            float reach  = orbRadius * (0.3 + hashF(float2(fi, 0.0)) * 0.55);
            float startR = orbRadius * 0.1;
            float endR   = startR + reach * life;

            // Project pixel onto flare spine.
            float2 spineDir = float2(cos(flareAngle), sin(flareAngle));
            float proj = dot(uv, spineDir);
            float perp = abs(dot(uv, float2(-spineDir.y, spineDir.x)));

            if (proj >= startR && proj <= endR) {
                float flareT = (proj - startR) / max(endR - startR, 0.001);
                float taper  = (1.0 - flareT * flareT) * life;
                float baseW  = (6.0 + hashF(float2(fi, 1.0)) * 8.0) / W;
                float halfW  = max(0.001, taper * baseW * 0.5);

                if (perp < halfW) {
                    float crossFade = 1.0 - perp / halfW;

                    // Outer envelope + brighter inner core.
                    float coreW  = halfW * 0.45;
                    float outerA = crossFade * taper * 0.15;
                    float coreA  = (perp < coreW)
                                 ? (1.0 - perp / coreW) * taper * 0.30
                                 : 0.0;

                    float flareA = (outerA + coreA) * wispAlpha;
                    half3 flareColor = mix(color0, color1, 0.2h);
                    half srcA = half(min(flareA, 1.0));
                    result.rgb = result.rgb * (1.0h - srcA) + flareColor * srcA;
                    result.a   = max(result.a, srcA * 0.5h);
                }
            }
        }
    }

    // ── 5. Particles (30 Orbiting Dots) ────────────────────────────
    // Canvas: 30 particles with deterministic init, orbit via angle += speed × dt × v².
    if (starAlpha > 0.05) {
        for (int i = 0; i < 30; i++) {
            float fi = float(i);

            // Deterministic properties seeded by particle index.
            float pAngle0 = hashF(float2(fi * 1.1, 0.0)) * 6.2832;
            float pRadius = 0.35 + hashF(float2(fi * 1.3, 1.0)) * 0.25;
            float pSpeed  = 0.00006 + hashF(float2(fi * 1.7, 2.0)) * 0.00012;
            float pSz     = (1.5 + hashF(float2(fi * 2.1, 3.0)) * 2.5) / W;
            float pAlpha  = 0.3 + hashF(float2(fi * 2.3, 4.0)) * 0.45;
            float pPhase0 = hashF(float2(fi * 2.7, 5.0)) * 6.2832;

            // Canvas: p.angle += p.speed × dt × speed × speed
            // Accumulated: angle0 + pSpeed × totalMs × speed²
            float pAngle = pAngle0 + pSpeed * time * 1000.0 * speed * speed;

            // Radial drift (Canvas: sin(phase) × 0.05).
            float pPhase = pPhase0 + time;
            float drift  = sin(pPhase) * 0.05;
            float r      = (pRadius + drift) * 0.5;

            float2 pPos = float2(cos(pAngle) * r, sin(pAngle) * r);
            float pDist = length(uv - pPos);

            if (pDist < pSz * 2.0) {
                // Twinkle (Canvas: 0.6 + sin(phase × 2) × 0.4).
                float twinkle = 0.6 + sin(pPhase * 2.0) * 0.4;
                float pA = pAlpha * twinkle * starAlpha;

                // Soft dot.
                pA *= smoothstep(pSz, pSz * 0.3, pDist);

                // Colour cycles with orbital angle.
                float normA = fmod(pAngle, 6.2832);
                if (normA < 0.0) normA += 6.2832;
                int ci = int(normA / 2.094) % 3;
                half3 pColor = (ci == 0) ? color0
                             : (ci == 1) ? color1
                                         : color2;

                half srcA = half(min(pA, 1.0));
                result.rgb = result.rgb * (1.0h - srcA) + pColor * srcA;
                result.a   = max(result.a, srcA);
            }
        }
    }

    // ── 6. Film Grain ──────────────────────────────────────────────
    half grain = hashH(half2(position) * 0.5h + half2(half(time) * 100.0h));
    result.rgb += (grain - 0.5h) * 0.015h;

    // ── 7. Flash Overlay ───────────────────────────────────────────
    if (flashType > 0.5 && flashProgress > 0.0 && flashProgress < 1.0) {
        if (dist < orbRadius * 1.1) {
            half flashA = half(1.0 - flashProgress) * 0.4h;
            half3 flashCol = (flashType < 1.5)
                ? half3(0.3h, 1.0h, 0.5h)     // Success: green
                : half3(1.0h, 0.3h, 0.3h);    // Error: red
            result.rgb = mix(result.rgb, flashCol, flashA);
        }
    }

    // Clamp output.
    result.rgb = clamp(result.rgb, 0.0h, 1.0h);
    result.a   = clamp(result.a, 0.0h, 1.0h);

    return result;
}
