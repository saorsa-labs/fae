#include <flutter/runtime_effect.glsl>

// Fae golden glass orb — Flutter FragmentShader POC v2.
// Design correction from browser feedback:
// - keep the silhouette almost perfectly circular
// - move organic motion inside the sphere
// - draw the glass/fresnel rim as a final independent layer
// Uniform order must match lib/main.dart.
uniform vec2 uResolution;
uniform float uTime;
uniform float uAudio;
uniform float uQuality;
uniform float uReduceMotion;

out vec4 fragColor;

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, float quality) {
  float v = 0.0;
  float a = 0.5;
  v += a * noise(p); p = p * 2.03 + 17.2; a *= 0.5;
  v += a * noise(p); p = p * 2.07 + 31.7; a *= 0.5;
  v += a * noise(p);
  if (quality > 0.5) {
    p = p * 2.11 + 9.4; a *= 0.5;
    v += a * noise(p);
  }
  return v;
}

mat2 rot(float a) {
  float s = sin(a);
  float c = cos(a);
  return mat2(c, -s, s, c);
}

vec3 palette(float t) {
  vec3 ember = vec3(1.0, 0.30, 0.045);
  vec3 deepGold = vec3(1.0, 0.54, 0.10);
  vec3 gold = vec3(1.0, 0.78, 0.24);
  vec3 cream = vec3(1.0, 0.93, 0.68);
  vec3 c = mix(ember, deepGold, smoothstep(0.00, 0.45, t));
  c = mix(c, gold, smoothstep(0.28, 0.82, t));
  c = mix(c, cream, smoothstep(0.74, 1.00, t) * 0.55);
  return c;
}

float gaussianRing(float r, float center, float width) {
  float x = (r - center) / width;
  return exp(-(x * x));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = (frag - 0.5 * uResolution) / min(uResolution.x, uResolution.y);

  float t = mix(uTime, 2.0, clamp(uReduceMotion, 0.0, 1.0));
  float audio = clamp(uAudio, 0.0, 1.0);
  float quality = clamp(uQuality, 0.0, 1.0);

  float r = length(uv);
  float angle = atan(uv.y, uv.x);

  // Nearly circular outer glass. Breathing changes scale subtly; silhouette wobble is tiny.
  float baseR = 0.365 + 0.010 * sin(t * 0.72) + audio * 0.012;
  float microWobble = 0.0035 * sin(angle * 6.0 + t * 0.45)
                    + 0.0020 * sin(angle * 11.0 - t * 0.31);
  float edgeR = baseR + microWobble;
  float aa = 0.006;
  float outerMask = 1.0 - smoothstep(edgeR - aa, edgeR + aa, r);
  float innerMask = 1.0 - smoothstep(baseR - 0.045, baseR - 0.006, r);

  // Internal lensing/flow. The masks use uv; only the fog uses warped coordinates.
  float normalizedR = clamp(r / max(baseR, 0.001), 0.0, 1.0);
  vec2 lensUv = uv * (1.0 + 0.13 * normalizedR * normalizedR);

  // Volumetric-looking domain warp: slow curl fields, not noisy flicker.
  vec2 curlA = vec2(
    fbm(lensUv * 2.15 + vec2(t * 0.030, 4.7), quality) - 0.5,
    fbm(lensUv * 2.15 + vec2(9.1, -t * 0.026), quality) - 0.5
  );
  vec2 curlB = vec2(
    fbm(lensUv * 4.20 + curlA * 1.6 + vec2(-t * 0.018, 12.0), quality) - 0.5,
    fbm(lensUv * 4.20 + curlA * 1.6 + vec2(2.0, t * 0.022), quality) - 0.5
  );
  vec2 fogUv = lensUv + curlA * (0.060 + audio * 0.016) + curlB * 0.028;

  // Layered amber veils: three depths with different scale, drift, and softness.
  float veil = 0.0;
  float filament = 0.0;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    float depth = fi / 2.0;
    float drift = t * (0.020 + fi * 0.014);
    vec2 layerUv = rot(t * (0.025 - fi * 0.013)) * fogUv;
    layerUv = layerUv * (2.45 + fi * 1.55) + vec2(drift, -drift * 0.7 + fi * 6.1);
    float n = fbm(layerUv + curlA * (1.1 + depth), quality);
    float softVeil = smoothstep(0.30, 0.78, n);
    float thread = smoothstep(0.58, 0.86, n) * (1.0 - smoothstep(0.86, 1.0, n));
    veil += softVeil * (0.46 - fi * 0.10);
    filament += thread * (0.34 - fi * 0.07);
  }
  veil = clamp(veil, 0.0, 1.0);
  filament = clamp(filament, 0.0, 1.0);

  // Slow spiral smoke bands, kept inside the glass.
  float spiralCoord = angle * 1.75 + normalizedR * 7.2 - t * 0.18 + curlA.x * 1.4;
  float spiral = 0.5 + 0.5 * sin(spiralCoord);
  spiral = smoothstep(0.54, 0.92, spiral) * (1.0 - smoothstep(0.72, 1.0, normalizedR));

  // Analytic internal fog globes. They never deform the silhouette.
  float blobs = 0.0;
  for (int i = 0; i < 7; i++) {
    float fi = float(i);
    float a = fi * 2.399963 + t * (0.075 + 0.010 * fi);
    float orbit = 0.045 + 0.18 * hash21(vec2(fi, 4.2));
    vec2 c = vec2(cos(a), sin(a)) * orbit;
    c += vec2(sin(t * 0.11 + fi), cos(t * 0.10 + fi * 1.7)) * 0.022;
    float br = 0.12 + 0.06 * hash21(vec2(fi, 9.1));
    blobs += exp(-dot(fogUv - c, fogUv - c) / (br * br));
  }
  blobs = clamp(blobs * 0.16, 0.0, 1.0);

  float coreGlow = smoothstep(baseR * 0.98, 0.0, r);
  float edgeFade = 1.0 - smoothstep(baseR * 0.70, baseR * 0.99, r);
  float fog = clamp(veil * 0.62 + filament * 0.28 + spiral * 0.20 + blobs * 0.18, 0.0, 1.0);
  vec3 interior = palette(fog * 0.88 + coreGlow * 0.12);
  interior += vec3(1.0, 0.47, 0.075) * filament * 0.25;
  interior += vec3(1.0, 0.63, 0.14) * blobs * (0.26 + audio * 0.34);
  interior += vec3(1.0, 0.86, 0.42) * coreGlow * 0.24;
  interior = mix(interior * 0.72, interior, edgeFade); // keep edge clearer so glass rim reads.

  // Depth cues: warm lower shadow and subtle upper internal glow.
  float lowerShadow = smoothstep(-0.04, 0.34, uv.y) * smoothstep(0.04, baseR, r);
  float upperGlow = exp(-dot(uv - vec2(-0.06, -0.12), uv - vec2(-0.06, -0.12)) / 0.070);
  interior *= 1.0 - lowerShadow * 0.24;
  interior += vec3(1.0, 0.70, 0.24) * upperGlow * 0.10 * outerMask;

  vec3 col = interior * outerMask;

  // Independent glass layers drawn after the fog so the rim cannot be obscured.
  float rimCore = gaussianRing(r, baseR + 0.001, 0.014);
  float innerRim = gaussianRing(r, baseR - 0.034, 0.030) * 0.55;
  float fresnel = pow(normalizedR, 4.5) * outerMask;
  float sheen = 0.5 + 0.5 * sin(angle * 3.0 - t * 0.35 + fog * 1.4);
  vec3 rimCol = mix(vec3(1.0, 0.42, 0.07), vec3(1.0, 0.94, 0.72), 0.55 + 0.45 * sheen);
  col = mix(col, rimCol, clamp(rimCore * 0.82 + innerRim * 0.20, 0.0, 1.0));
  col += rimCol * rimCore * 0.48;
  col += vec3(1.0, 0.82, 0.42) * fresnel * 0.13;

  // Glass highlights: top-left soft specular and a crescent sweep.
  float topGlow = exp(-dot(uv - vec2(-0.11, -0.18), uv - vec2(-0.11, -0.18)) / 0.030) * outerMask;
  vec2 dir = normalize(uv + vec2(0.001));
  float crescentDir = dot(dir, normalize(vec2(-0.55, -0.83)));
  float crescent = smoothstep(0.58, 0.94, crescentDir)
                * smoothstep(0.08, 0.30, r)
                * (1.0 - smoothstep(baseR - 0.050, baseR - 0.004, r));
  col += vec3(1.0, 0.91, 0.66) * topGlow * 0.26;
  col += vec3(1.0, 0.96, 0.82) * crescent * 0.18;

  // Outer aura, separate from sphere body.
  float halo = exp(-max(r - baseR, 0.0) * 11.0) * (1.0 - outerMask) * 0.24;
  col += vec3(1.0, 0.48, 0.08) * halo;

  // Sparkle is restrained; it should never hide the glass.
  float grain = hash21(frag + floor(t * 18.0));
  float sparkleGate = smoothstep(0.45, 0.85, audio) * quality;
  float sparkle = step(0.9985, grain) * outerMask * sparkleGate;
  col += vec3(1.0, 0.90, 0.55) * sparkle * 0.45;

  float alpha = clamp(outerMask + rimCore * 0.55 + halo, 0.0, 1.0);
  fragColor = vec4(col, alpha);
}
