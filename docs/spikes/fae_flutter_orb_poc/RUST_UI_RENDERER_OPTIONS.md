# Rust UI / renderer options for a simpler Fae UX

Context: Fae may become a very simple assistant shell: show the orb only while thinking/speaking, and use system/web browsers or embedded webviews for rich data, charts, and video. That means we do **not** need a large custom canvas/cowork surface.

## Best-fit Rust options

### 1. Tauri 2 — strongest Rust webview shell candidate

Tauri describes itself as building tiny, fast binaries for desktop and mobile, using any HTML/CSS/JS frontend with Rust/Swift/Kotlin backend logic. It is built on:

- `tao` for windows/event loop
- `wry` for webview rendering

Why it fits this simplified Fae direction:

- Native desktop shell + mobile support path.
- Webview is a natural place for charts, docs, video, and external UI panels.
- Rust backend can host Fae commands/state.
- Native menus are available through Tauri's menu APIs.
- We can keep the orb as a tiny native/web shader view, and open browser/webview windows only on demand.

Risks:

- Mobile is supported but still a larger integration surface than Flutter for polished mobile UI.
- If we need a highly custom animated transparent always-on-top orb, we may still need platform-specific window polish.

### 2. wry + tao directly — lowest-level Rust webview shell

`wry` is a cross-platform WebView rendering library. `tao` is a cross-platform application window/event-loop library.

Why consider it:

- Smaller than full Tauri.
- Good if Fae wants a bespoke tiny shell: tray/menu/orb + webview windows.
- Lets us own the UX with fewer framework conventions.

Risks:

- More platform glue to write ourselves.
- Mobile story is more work than Tauri or Flutter.
- Plugin/security/update ecosystem is less complete than Tauri.

### 3. wgpu — strongest Rust GPU shader foundation

`wgpu` is a safe portable graphics API for Rust based on WebGPU. It runs natively on Vulkan, Metal, DirectX 12, OpenGL ES, and in browsers via WebAssembly/WebGPU/WebGL2.

Why consider it:

- Best Rust-native path for a high-quality procedural orb shader.
- Maps well to a single WGSL shader source.
- Could render the orb only during thinking/speaking, then sleep completely.

Risks:

- It is rendering infrastructure, not a full UI/menu/webview framework.
- Pair with Tauri/wry/tao/winit for windows and menus.

### 4. miniquad — lightweight cross-platform rendering

Miniquad supports Windows, Linux, macOS, iOS, Android, and WASM/WebGL.

Why consider it:

- Very small rendering layer for an orb-only surface.
- More direct/simple than wgpu for a tiny shader demo.

Risks:

- Less modern than wgpu for long-term shader portability.
- Not a full app/menu/webview solution.

## Less ideal for this Fae direction

### egui / eframe

Good native/web immediate-mode GUI, but less aligned if Fae's rich UI is mostly browsers/webviews. Immediate-mode UI often wants regular repainting, which is not ideal for a mostly quiescent assistant.

### Slint

Polished declarative UI for Rust/C++/JS/Python across embedded, desktop, mobile. Worth considering for a conventional native control surface, but likely unnecessary if Fae's UX is intentionally minimal and browser-first.

### Vello

Promising GPU compute-centric 2D renderer. Excellent project to watch, but not a complete app/webview/menu framework and less directly useful than wgpu for a shader orb.

### skia-safe

Powerful Skia bindings and relevant to shader/vector rendering, but heavier and more build complexity than we need for a simple orb + webview shell.

## Recommendation

If we stay Swift-native now: keep the current Metal orb and simplify app UX.

If we want Rust as the cross-platform shell:

1. **Tauri 2** for app shell, menus, tray, webviews, and mobile path.
2. **wgpu** for an optional native orb renderer if the webview/CSS/WebGL orb is not good enough.
3. Keep Fae quiescent by default: no orb render loop while idle; render only thinking/speaking/listening.

A very lean architecture could be:

```text
Fae core process
  -> state: idle | listening | thinking | speaking
  -> shell command/event API

Rust/Tauri shell
  -> tray/menu/status
  -> tiny orb window only when active
  -> webview/browser panels for charts/data/video
  -> no cowork/canvas surface

Orb renderer
  -> Flutter shader POC now
  -> later: Metal on Apple or WGSL/wgpu for Rust shell
  -> render loop paused completely when quiescent
```
