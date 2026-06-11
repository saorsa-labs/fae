# Fae Flutter Orb POC

A minimal Flutter fragment-shader proof of concept for Fae's cross-platform golden glass/fog orb.

## v2/v3 visual correction

The first browser preview looked close, but too organic/non-circular and the glass rim was buried under the fog. v2/v3 changes the rendering model:

- The silhouette is now nearly circular, with only tiny breathing-scale motion.
- Organic motion is moved inside the sphere via warped fog coordinates.
- The rim is drawn last as an independent fresnel/glass layer so it stays visible.
- Sparkle/grain is heavily restrained so it does not obscure the glass.
- The edge fog is dimmed near the boundary to make the sphere read as glass.
- v3 adds slower domain-warped amber veils, filament bands, and depth shading for more realistic/alluring fog.

## What this demonstrates

- Single-pass procedural orb shader.
- Orange/golden Fae fog palette with Siri-like glass rim.
- Simulated voice-reactive motion.
- Quality tier uniform.
- Reduced-motion toggle.
- No CPU particle simulation; animation is driven by shader uniforms.

## Run the Flutter POC

Flutter is not installed in the current agent environment, but this project is ready to run in a Flutter setup:

```bash
cd docs/spikes/fae_flutter_orb_poc
flutter pub get
flutter run -d macos
# or
flutter run -d chrome
```

## Immediate browser preview

A plain WebGL preview is included so the visual direction can be opened without Flutter:

```bash
open docs/spikes/fae_flutter_orb_poc/web/fae_orb_webgl_demo.html
```

That file is not the production path; it is only a convenient preview of the shader look.

## Files

- `lib/main.dart` — Flutter app, controls, `CustomPainter`, shader uniforms.
- `shaders/fae_orb.frag` — Flutter-compatible GLSL fragment shader.
- `web/fae_orb_webgl_demo.html` — immediate preview using WebGL GLSL.

## Production notes

For the real product, keep the current Fae adaptive frame-rate policy:

- idle: ~1fps
- listening: ~10fps
- thinking/speaking: ~30fps
- hidden/collapsed: paused
- reduced rendering / thermal pressure: ~0.5fps or static

Use the same uniform contract across renderers:

```text
uResolution
uTime
uAudio
uQuality
uReduceMotion
```

Future platform ports can map this same shader idea to Metal, AGSL, SkSL, or Flutter FragmentShader.
