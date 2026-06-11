# Fae wgpu Orb POC

Rust-native GPU proof of concept for Fae's active-only golden glass/fog orb.

This spike is intentionally standalone and is **not** part of the main Fae workspace or CI path.

## What it demonstrates

- `tao` frameless transparent orb window.
- `muda` right-click orb context menu copied from Fae's current orb/menu commands.
- `wry` browser/data panel opened from the orb menu.
- `wgpu` full-screen triangle renderer.
- WGSL port of the Flutter v3 orb shader:
  - circular glass silhouette
  - independent fresnel/rim layer
  - slower, more gaseous amber volumetric veils
  - softer filament bands
  - slow spiral smoke
  - depth shadowing
- Active-only render loop for the simplified Fae UX:
  - active/thinking/speaking: `ControlFlow::Poll`, continuous redraw
  - quiescent: `ControlFlow::Wait`, no redraw loop
- Space or left click toggles active/quiescent.

## Run

```bash
cd docs/spikes/fae_wgpu_orb_poc
cargo run --release
```

Controls:

- `Space`: toggle orb active/quiescent.
- Left drag: move frameless orb window.
- Right click: open Fae context menu.
- Menu → `Open Browser/Data Panel`: opens a separate `wry` webview panel.
- Close window: exit.

## Production interpretation

`wgpu` is a renderer, not an app shell. If Fae moves to a Rust shell:

- use **Tauri 2** for simple menus/tray/webviews/mobile path, or
- use **wry + tao + muda** for a smaller bespoke shell, and
- embed/pair a `wgpu` orb only if browser/WebGL/Flutter rendering is not the chosen path.

For Fae's intended UX, the orb should not render while idle/quiescent. It should appear only for thinking/speaking/listening, then stop its render loop entirely.
