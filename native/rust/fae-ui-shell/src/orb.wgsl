struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    audio: f32,
    quality: f32,
    is_active: f32,
    status_progress: f32,
    status_visible: f32,
    mode: f32,
    warmth: f32,
    energy: f32,
    _pad: f32,
};

@group(0) @binding(0)
var<uniform> u: Uniforms;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -3.0),
        vec2<f32>(3.0, 1.0),
        vec2<f32>(-1.0, 1.0),
    );
    var out: VertexOut;
    out.position = vec4<f32>(positions[vertex_index], 0.0, 1.0);
    return out;
}

fn hash21(p_in: vec2<f32>) -> f32 {
    var p = fract(p_in * vec2<f32>(123.34, 456.21));
    p = p + dot(p, p + vec2<f32>(45.32, 45.32));
    return fract(p.x * p.y);
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    var f = fract(p);
    f = f * f * (vec2<f32>(3.0, 3.0) - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

fn fbm(p_in: vec2<f32>, quality: f32) -> f32 {
    var p = p_in;
    var v = 0.0;
    var a = 0.5;
    v = v + a * noise(p);
    p = p * 2.03 + vec2<f32>(17.2, 17.2);
    a = a * 0.5;
    v = v + a * noise(p);
    p = p * 2.07 + vec2<f32>(31.7, 31.7);
    a = a * 0.5;
    v = v + a * noise(p);
    if quality > 0.5 {
        p = p * 2.11 + vec2<f32>(9.4, 9.4);
        a = a * 0.5;
        v = v + a * noise(p);
    }
    return v;
}

fn rot(a: f32) -> mat2x2<f32> {
    let s = sin(a);
    let c = cos(a);
    return mat2x2<f32>(vec2<f32>(c, s), vec2<f32>(-s, c));
}

// Ridged noise: folds fbm around its midline so values crest along thin
// curving lines — the spine of every smoke ribbon in the orb.
fn ridged(p: vec2<f32>, quality: f32) -> f32 {
    return 1.0 - abs(2.0 * fbm(p, quality) - 1.0);
}

// Fae's signature fog: ember through deep gold to cream. The single colour
// authority for the orb interior (DESIGN.md: golden fog, glass surface).
const EMBER: vec3<f32> = vec3<f32>(0.62, 0.16, 0.04);
const SMOKE: vec3<f32> = vec3<f32>(0.24, 0.16, 0.11);     // low-warmth haze
const DEEP_GOLD: vec3<f32> = vec3<f32>(1.0, 0.54, 0.10);
const GOLD: vec3<f32> = vec3<f32>(1.0, 0.78, 0.24);
const CREAM: vec3<f32> = vec3<f32>(1.0, 0.93, 0.68);
const GLASS_WHITE: vec3<f32> = vec3<f32>(1.0, 0.97, 0.90); // key specular

// Golden aurora ramp. `warmth` (emotion) biases the whole ramp: concern sinks
// it toward ember/smoke, delight lifts it toward bright cream.
fn palette(t_in: f32, warmth: f32) -> vec3<f32> {
    let t = clamp(t_in * (0.72 + 0.56 * warmth) + (warmth - 0.5) * 0.22, 0.0, 1.0);
    var c = mix(EMBER, DEEP_GOLD, smoothstep(0.0, 0.45, t));
    c = mix(c, GOLD, smoothstep(0.28, 0.82, t));
    c = mix(c, CREAM, smoothstep(0.74, 1.0, t) * 0.55);
    // Low warmth reads as smoke-dimmed embers, not just darker gold.
    let mute = smoothstep(0.35, 0.0, warmth);
    return mix(c, SMOKE + EMBER * 0.4, mute * 0.45);
}

// Warm thin-film iridescence for the glass limb: three phase-shifted lobes
// blended across the gold register — never leaves the signature palette.
fn iridescence(phase: f32) -> vec3<f32> {
    let w = vec3<f32>(
        0.5 + 0.5 * sin(phase),
        0.5 + 0.5 * sin(phase + 2.094),
        0.5 + 0.5 * sin(phase + 4.188),
    );
    return normalize(DEEP_GOLD * w.x + GOLD * w.y + CREAM * w.z) * 1.05;
}

fn gaussian_ring(r: f32, center: f32, width: f32) -> f32 {
    let x = (r - center) / width;
    return exp(-(x * x));
}

@fragment
fn fs_main(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    // S18: the orb is the push-to-talk button — it must stay visible while
    // idle. Inactive renders the same fog, dimmed, never discarded (a fully
    // transparent quiescent orb made every click read as a vanish).
    let presence = mix(0.5, 1.0, clamp(u.is_active, 0.0, 1.0));

    let frag = position.xy;
    let min_res = min(u.resolution.x, u.resolution.y);
    let uv = (frag - 0.5 * u.resolution) / min_res;
    let t = u.time;
    let audio = clamp(u.audio, 0.0, 1.0);
    let quality = clamp(u.quality, 0.0, 1.0);
    let warmth = clamp(u.warmth, 0.0, 1.0);
    let energy = clamp(u.energy, 0.0, 1.0);

    // Demeanor weights: how strongly each pipeline mode shapes the fog.
    let listen_w = clamp(1.0 - abs(u.mode - 1.0), 0.0, 1.0);
    let think_w = clamp(1.0 - abs(u.mode - 2.0), 0.0, 1.0);
    let speak_w = clamp(1.0 - abs(u.mode - 3.0), 0.0, 1.0);

    // Emotional tempo: calm barely stirs, playful churns; thinking adds a
    // deliberate undertow, speaking rides the voice.
    let spd = (0.55 + 0.95 * energy) * (1.0 + think_w * 0.18 + speak_w * 0.30 * audio);

    let r = length(uv);
    let angle = atan2(uv.y, uv.x);

    // Liquid silhouette: slow breath + counter-phased ripples (surface
    // tension, not a drawn circle). Thinking deepens the breath slightly.
    let breath = 0.012 + think_w * 0.004;
    let base_r = 0.365 + breath * sin(t * (0.60 + 0.25 * energy)) + audio * 0.014;
    let micro_wobble = 0.0050 * sin(angle * 5.0 + t * 0.90 * spd)
        + 0.0030 * sin(angle * 9.0 - t * 0.70 * spd)
        + 0.0016 * sin(angle * 13.0 + t * 1.30 * spd);
    let edge_r = base_r + micro_wobble;
    let aa = 0.006;
    let outer_mask = 1.0 - smoothstep(edge_r - aa, edge_r + aa, r);
    let normalized_r = clamp(r / max(base_r, 0.001), 0.0, 1.0);

    // Glass refraction: interior coordinates bow outward toward the limb so
    // the fog appears to bend through a lens, strongest near the edge.
    let lens_uv = uv * (1.0 + 0.22 * normalized_r * normalized_r);

    // Fluid advection: two curl fields plus a global swirl whose rate follows
    // the emotional tempo. Gentle by default; never frantic.
    let swirl = rot(t * 0.045 * spd + audio * 0.10);
    let flow_uv = swirl * lens_uv;
    let curl_a = vec2<f32>(
        fbm(flow_uv * 1.65 + vec2<f32>(t * 0.050 * spd, 4.7), quality) - 0.5,
        fbm(flow_uv * 1.65 + vec2<f32>(9.1, -t * 0.042 * spd), quality) - 0.5,
    );
    let curl_b = vec2<f32>(
        fbm(flow_uv * 3.10 + curl_a * 2.3 + vec2<f32>(-t * 0.034 * spd, 12.0), quality) - 0.5,
        fbm(flow_uv * 3.10 + curl_a * 2.3 + vec2<f32>(2.0, t * 0.038 * spd), quality) - 0.5,
    );
    let fog_uv = flow_uv + curl_a * (0.130 + 0.050 * energy + audio * 0.030) + curl_b * 0.070;

    // Smoke ribbons: two scales of ridged, domain-warped noise. The crest of
    // each ridge is a thin luminous tendril; everything between stays dark
    // glass. This is the whole look — sparse fire-smoke in a black sphere.
    let ribbon_uv = fog_uv * 2.1 + vec2<f32>(t * 0.020 * spd, -t * 0.014 * spd);
    let ridge_a = ridged(ribbon_uv + curl_b * 1.6, quality);
    let wisp_uv = rot(0.7) * fog_uv * 4.3 + vec2<f32>(-t * 0.016 * spd, t * 0.024 * spd);
    let ridge_b = ridged(wisp_uv + curl_a * 2.2, quality);

    // Main ribbons: tight threshold, squared for crisp luminous cores with
    // soft falloff. Fine wisps weave around them at lower weight.
    var ribbon = pow(smoothstep(0.62, 0.96, ridge_a), 2.0);
    var wisp = pow(smoothstep(0.66, 0.98, ridge_b), 2.0) * 0.55;
    // Faint haze hugging the ribbons so they glow into the glass.
    let haze = smoothstep(0.40, 0.85, ridge_a) * 0.16
        + smoothstep(0.45, 0.88, ridge_b) * 0.08;

    // Smoke lives inside the glass: fade before the rim, sit a little
    // heavier in the lower half like the reference.
    let inside = 1.0 - smoothstep(0.86, 0.99, normalized_r);
    let settle = 0.85 + 0.15 * smoothstep(-0.3, 0.3, uv.y);
    ribbon = ribbon * inside * settle;
    wisp = wisp * inside * settle;

    // Thinking: a slow deliberate pulse through the ribbons, as if weighing
    // the answer. Speaking: their glow rides the voice.
    let think_pulse = think_w * (0.5 + 0.5 * sin(t * 2.0)) * 0.18;
    let speak_lift = speak_w * audio * 0.30;
    let glow = 1.0 + speak_lift + think_pulse;

    // Interior: near-black glass, lit only by the smoke. Ribbon intensity
    // indexes the ember->gold->cream ramp so tendril cores run hottest.
    let smoke_i = clamp(ribbon + wisp, 0.0, 1.0);
    let hue_drift = 0.08 * sin(t * 0.18 * spd + angle * 2.0 + smoke_i * 3.0);
    let dark_glass = vec3<f32>(0.030, 0.018, 0.012);
    var interior = dark_glass * (0.6 + 0.4 * (1.0 - normalized_r));
    interior = interior + palette(clamp(smoke_i * 0.9 + hue_drift, 0.0, 1.0), warmth)
        * smoke_i * 1.15 * glow;
    interior = interior + EMBER * haze * (0.8 + 0.4 * warmth) * glow;
    // Hot cores: the very crest of a ribbon burns toward cream.
    interior = interior + CREAM * pow(smoke_i, 3.0) * 0.35 * glow;

    var col = interior * outer_mask;

    // Glass surface: the rim stays QUIET — dark glass reads from the smoke
    // glowing inside it, not from a bright outline. A faint warm thin-film
    // sheen circulates, slightly livelier when attentive or speaking.
    let rim_core = gaussian_ring(r, base_r + 0.001, 0.010);
    let fresnel = pow(normalized_r, 5.0) * outer_mask;
    let sheen_phase = angle * 2.0 - t * (0.45 + 0.25 * listen_w + 0.35 * speak_w) + smoke_i * 1.8;
    let rim_irid = iridescence(sheen_phase);
    let rim_col = mix(rim_irid, DEEP_GOLD, 0.5);
    col = col + rim_col * rim_core * 0.16;
    col = col + DEEP_GOLD * fresnel * 0.07;

    // Single small specular star (key light, upper-left of centre) — the one
    // bright point that sells curved glass, sitting amid the smoke.
    let top_delta = uv - vec2<f32>(-0.07, -0.05);
    let star = exp(-dot(top_delta, top_delta) / 0.0015) * outer_mask;
    let star_bloom = exp(-dot(top_delta, top_delta) / 0.010) * outer_mask;
    col = col + GLASS_WHITE * star * 0.85;
    col = col + CREAM * star_bloom * 0.18;

    // Exterior halo: the faintest warm breath outside the limb.
    let halo = exp(-max(r - base_r, 0.0) * 14.0) * (1.0 - outer_mask) * 0.10;
    col = col + mix(EMBER, DEEP_GOLD, 0.5) * halo;

    // Startup/status information lives in the orb as a progress halo rather
    // than a separate shell screen. Swift drives this through status_progress.
    let progress = clamp(u.status_progress, 0.0, 1.0);
    let progress_angle = atan2(-uv.x, -uv.y) + 3.14159265;
    let progress_fraction = progress_angle / 6.2831853;
    let progress_gate = step(progress_fraction, progress);
    let progress_ring = gaussian_ring(r, base_r + 0.030, 0.010) * progress_gate * u.status_visible;
    col = col + GOLD * progress_ring * 0.95;

    let grain = hash21(frag + floor(vec2<f32>(t * 18.0, t * 18.0)));
    let sparkle_gate = smoothstep(0.45, 0.85, audio) * quality;
    let sparkle = step(0.9985, grain) * outer_mask * sparkle_gate;
    col = col + CREAM * sparkle * 0.42;

    // Small in-orb Messages affordance. The matching Rust hit-zone opens the
    // orb-owned transcript panel; this stays part of the orb instead of adding
    // a separate shell surface. Rendered as a glass bead: ring + soft core, so
    // it reads as part of the material rather than a painted disc.
    let msg_delta = uv - vec2<f32>(0.20, 0.22);
    let msg_r = length(msg_delta);
    let msg_ring = gaussian_ring(msg_r, 0.060, 0.008) * outer_mask;
    let msg_fill = (1.0 - smoothstep(0.040, 0.060, msg_r)) * outer_mask;
    let msg_core = (1.0 - smoothstep(0.014, 0.024, msg_r)) * outer_mask;
    col = mix(col, mix(DEEP_GOLD, GOLD, 0.5), msg_fill * 0.18);
    col = col + GOLD * msg_ring * 0.30;
    col = col + CREAM * msg_core * 0.30;

    let alpha = clamp(outer_mask + rim_core * 0.25 + halo + msg_ring * 0.20, 0.0, 1.0) * presence;
    return vec4<f32>(col * alpha, alpha);
}
