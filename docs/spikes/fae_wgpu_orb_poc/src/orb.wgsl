struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    audio: f32,
    quality: f32,
    is_active: f32,
    _pad: vec2<f32>,
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

fn palette(t: f32) -> vec3<f32> {
    let ember = vec3<f32>(1.0, 0.30, 0.045);
    let deep_gold = vec3<f32>(1.0, 0.54, 0.10);
    let gold = vec3<f32>(1.0, 0.78, 0.24);
    let cream = vec3<f32>(1.0, 0.93, 0.68);
    var c = mix(ember, deep_gold, smoothstep(0.0, 0.45, t));
    c = mix(c, gold, smoothstep(0.28, 0.82, t));
    c = mix(c, cream, smoothstep(0.74, 1.0, t) * 0.55);
    return c;
}

fn gaussian_ring(r: f32, center: f32, width: f32) -> f32 {
    let x = (r - center) / width;
    return exp(-(x * x));
}

@fragment
fn fs_main(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    if u.is_active < 0.5 {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }

    let frag = position.xy;
    let min_res = min(u.resolution.x, u.resolution.y);
    let uv = (frag - 0.5 * u.resolution) / min_res;
    let t = u.time;
    let audio = clamp(u.audio, 0.0, 1.0);
    let quality = clamp(u.quality, 0.0, 1.0);

    let r = length(uv);
    let angle = atan2(uv.y, uv.x);

    let base_r = 0.365 + 0.010 * sin(t * 0.72) + audio * 0.012;
    let micro_wobble = 0.0035 * sin(angle * 6.0 + t * 0.45)
        + 0.0020 * sin(angle * 11.0 - t * 0.31);
    let edge_r = base_r + micro_wobble;
    let aa = 0.006;
    let outer_mask = 1.0 - smoothstep(edge_r - aa, edge_r + aa, r);
    let normalized_r = clamp(r / max(base_r, 0.001), 0.0, 1.0);

    let lens_uv = uv * (1.0 + 0.15 * normalized_r * normalized_r);
    let curl_a = vec2<f32>(
        fbm(lens_uv * 1.65 + vec2<f32>(t * 0.012, 4.7), quality) - 0.5,
        fbm(lens_uv * 1.65 + vec2<f32>(9.1, -t * 0.010), quality) - 0.5,
    );
    let curl_b = vec2<f32>(
        fbm(lens_uv * 3.10 + curl_a * 1.9 + vec2<f32>(-t * 0.008, 12.0), quality) - 0.5,
        fbm(lens_uv * 3.10 + curl_a * 1.9 + vec2<f32>(2.0, t * 0.009), quality) - 0.5,
    );
    let fog_uv = lens_uv + curl_a * (0.085 + audio * 0.012) + curl_b * 0.040;

    var veil = 0.0;
    var filament = 0.0;
    for (var i = 0; i < 4; i = i + 1) {
        let fi = f32(i);
        let depth = fi / 3.0;
        let drift = t * (0.006 + fi * 0.004);
        var layer_uv = rot(t * (0.010 - fi * 0.004)) * fog_uv;
        layer_uv = layer_uv * (1.65 + fi * 0.92) + vec2<f32>(drift, -drift * 0.55 + fi * 6.1);
        let n = fbm(layer_uv + curl_a * (1.3 + depth), quality);
        let soft_veil = smoothstep(0.22, 0.74, n);
        let thread = smoothstep(0.48, 0.82, n) * (1.0 - smoothstep(0.88, 1.0, n));
        veil = veil + soft_veil * (0.34 - fi * 0.045);
        filament = filament + thread * (0.18 - fi * 0.025);
    }
    veil = clamp(veil, 0.0, 1.0);
    filament = clamp(filament, 0.0, 1.0);

    var spiral_coord = angle * 1.25 + normalized_r * 5.4 - t * 0.055 + curl_a.x * 1.8;
    var spiral = 0.5 + 0.5 * sin(spiral_coord);
    spiral = smoothstep(0.46, 0.94, spiral) * (1.0 - smoothstep(0.74, 1.0, normalized_r));

    var blobs = 0.0;
    for (var i = 0; i < 7; i = i + 1) {
        let fi = f32(i);
        let a = fi * 2.399963 + t * (0.030 + 0.004 * fi);
        let orbit = 0.045 + 0.18 * hash21(vec2<f32>(fi, 4.2));
        var c = vec2<f32>(cos(a), sin(a)) * orbit;
        c = c + vec2<f32>(sin(t * 0.11 + fi), cos(t * 0.10 + fi * 1.7)) * 0.022;
        let br = 0.12 + 0.06 * hash21(vec2<f32>(fi, 9.1));
        blobs = blobs + exp(-dot(fog_uv - c, fog_uv - c) / (br * br));
    }
    blobs = clamp(blobs * 0.16, 0.0, 1.0);

    let core_glow = smoothstep(base_r * 0.98, 0.0, r);
    let edge_fade = 1.0 - smoothstep(base_r * 0.70, base_r * 0.99, r);
    let density = clamp(veil * 0.75 + filament * 0.16 + spiral * 0.08 + blobs * 0.12, 0.0, 1.0);
    let fog = 1.0 - exp(-density * 1.7);
    var interior = palette(fog * 0.88 + core_glow * 0.12);
    interior = interior + vec3<f32>(1.0, 0.47, 0.075) * filament * 0.14;
    interior = interior + vec3<f32>(1.0, 0.63, 0.14) * blobs * (0.26 + audio * 0.34);
    interior = interior + vec3<f32>(1.0, 0.86, 0.42) * core_glow * 0.24;
    interior = mix(interior * 0.72, interior, edge_fade);

    let lower_shadow = smoothstep(-0.04, 0.34, uv.y) * smoothstep(0.04, base_r, r);
    let upper_delta = uv - vec2<f32>(-0.06, -0.12);
    let upper_glow = exp(-dot(upper_delta, upper_delta) / 0.070);
    interior = interior * (1.0 - lower_shadow * 0.24);
    interior = interior + vec3<f32>(1.0, 0.70, 0.24) * upper_glow * 0.10 * outer_mask;

    var col = interior * outer_mask;

    let rim_core = gaussian_ring(r, base_r + 0.001, 0.014);
    let inner_rim = gaussian_ring(r, base_r - 0.034, 0.030) * 0.55;
    let fresnel = pow(normalized_r, 4.5) * outer_mask;
    let sheen = 0.5 + 0.5 * sin(angle * 3.0 - t * 0.35 + fog * 1.4);
    let rim_col = mix(vec3<f32>(1.0, 0.42, 0.07), vec3<f32>(1.0, 0.94, 0.72), 0.55 + 0.45 * sheen);
    col = mix(col, rim_col, clamp(rim_core * 0.82 + inner_rim * 0.20, 0.0, 1.0));
    col = col + rim_col * rim_core * 0.48;
    col = col + vec3<f32>(1.0, 0.82, 0.42) * fresnel * 0.13;

    let top_delta = uv - vec2<f32>(-0.11, -0.18);
    let top_glow = exp(-dot(top_delta, top_delta) / 0.030) * outer_mask;
    let dir = normalize(uv + vec2<f32>(0.001, 0.001));
    let crescent_dir = dot(dir, normalize(vec2<f32>(-0.55, -0.83)));
    let crescent = smoothstep(0.58, 0.94, crescent_dir)
        * smoothstep(0.08, 0.30, r)
        * (1.0 - smoothstep(base_r - 0.050, base_r - 0.004, r));
    col = col + vec3<f32>(1.0, 0.91, 0.66) * top_glow * 0.26;
    col = col + vec3<f32>(1.0, 0.96, 0.82) * crescent * 0.18;

    let halo = exp(-max(r - base_r, 0.0) * 11.0) * (1.0 - outer_mask) * 0.24;
    col = col + vec3<f32>(1.0, 0.48, 0.08) * halo;

    let grain = hash21(frag + floor(vec2<f32>(t * 18.0, t * 18.0)));
    let sparkle_gate = smoothstep(0.45, 0.85, audio) * quality;
    let sparkle = step(0.9985, grain) * outer_mask * sparkle_gate;
    col = col + vec3<f32>(1.0, 0.90, 0.55) * sparkle * 0.45;

    let alpha = clamp(outer_mask + rim_core * 0.55 + halo, 0.0, 1.0);
    return vec4<f32>(col * alpha, alpha);
}
