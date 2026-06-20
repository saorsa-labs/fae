# P6 / D1 — Linux orb-host render: design (2026-06-20, rev 2 — post-codex)

Branch: `feat/p6-linux-orb`. Reviewer-gated (codex on design + code). macOS lane MUST stay untouched.

Rev 2 folds in codex design review (verdict REVISE): explicit orb opaque smoke fallback, per-surface render
assertions (not whole-root color count), no "build-coverage" contingency, narrowed Done claim, first-paint-safe
pill HTML.

## Objective (from roadmap)

> The Rust orb host (tao/wgpu/wry) renders on Linux; the pill/panels tolerate the WebKitGTK
> transparency/render defects (tauri#12800/#13157/#9220) via the designed **opaque frosted fallback**.

**Done (this PR, narrowed):** orb + pill + a data panel each render real pixels under **headless Xvfb CI**,
proven **per-surface** (each window region independently asserted non-blank), with the opaque pill + opaque
orb-smoke fallback paths in place. **Deferred (tracked, needs Linux desktop access):** acceptance on a real
composited X11/Wayland desktop — the transparent orb float + live pill frost on a real compositor. This PR does
not claim real-desktop acceptance; it claims the render paths exist and are headless-proven.

## What already exists (do not redo)

- `linux-render-spike.yml` already builds `fae-ui-shell` on Ubuntu/WebKitGTK, runs `--smoke-settings-panel`
  under Xvfb, captures `linux-settings-panel.png`, and **gates on ≥8 distinct colors** (passing run = 2,380).
  So: the **opaque Settings panel path is already proven** on Linux.
- `build_webview_for_window` already branches Linux → `WebViewBuilderExtUnix::build_gtk(default_vbox)`,
  non-Linux → `builder.build(window)`. Panels (settings/scheduler/skills) are **already opaque**
  (no `with_transparent`) and render correctly on WebKitGTK.

## The two unproven transparent surfaces (the actual P6 work)

| Surface | Code | macOS path | Linux problem |
|---|---|---|---|
| Orb window | `main.rs:549` wgpu, `with_transparent(true)`, 420×420 | compositor alpha → orb floats on desktop | Xvfb/no-compositor → alpha unavailable; orb must still render (on opaque/black bg) |
| Pill | `main.rs:1399` window `with_transparent(true)`; `:1406` webview `with_transparent(true)` + `with_background_color((0,0,0,0))`; `PILL_HTML:1481` `html,body{background:transparent}` + `#shell{backdrop-filter:blur(22px)}` | WKWebView private drawsBackground + real backdrop blur | WebKitGTK transparent webview is compositor-sensitive (tauri#12800/#9220); `backdrop-filter` does not blur the desktop → black/white box / artifacts |

## Design

### 1. Pill: opaque frosted fallback on Linux

The frosted look on macOS comes from a translucent `#shell` over a transparent window letting the desktop
blur through. On Linux we drop true translucency and render a **self-contained opaque frosted panel** — same
visual language (dark rounded panel, gold/heather accents), but the "frost" is a painted gradient, not a live
desktop blur. This is the designed fallback, not a regression of the macOS lane.

Three coordinated `#[cfg(target_os = "linux")]` changes, all additive and gated:

1. **Pill window** (`open_pill_panel`): on Linux `.with_transparent(false)`. (macOS keeps `true`.)
2. **Pill webview** (`build_webview_for_window` / builder): on Linux do **not** call `with_transparent(true)`
   and set `with_background_color` to the opaque panel color `(22, 20, 28, 255)` instead of `(0,0,0,0)`.
   Keep macOS exactly as-is. Cleanest seam: a small helper that takes a `transparent: bool` and applies the
   right `with_transparent`/`with_background_color`, called with `cfg!(target_os="linux")` → opaque.
3. **Pill HTML (first-paint-safe)**: keep ONE `PILL_HTML` source with the opaque rules baked in as a
   `.fae-opaque` class, and on Linux bake the class onto `<html>` **at build time** (not via JS), so the very
   first paint is already opaque — no white flash. wry installs init scripts at `Start` but only guarantees
   *before `onload`*, not before first paint (codex), so JS toggling is rejected. Implementation:
   `PILL_HTML` contains `<html class="">`; Linux passes `PILL_HTML.replace("<html class=\"\">", "<html class=\"fae-opaque\">")`.
   CSS added to the shared `<style>`:
   ```css
   html.fae-opaque, html.fae-opaque body { background:#16141C; }
   html.fae-opaque #shell { background:#16141C; backdrop-filter:none; -webkit-backdrop-filter:none;
     box-shadow:none; border-color:rgba(180,168,196,.28); }
   ```
   Default (macOS) selectors are untouched: with no class the existing transparent/frosted rules apply
   verbatim. Rounded corners now sit on an opaque window: the 8px inset shows solid corners. Accepted per the
   "tolerate the defects" criterion. (Rejected: a second full HTML const — duplicates ~250 lines and drifts.)

No JS/IPC/gesture logic changes — only paint.

### 1b. Orb: opaque smoke fallback on Linux (codex High)

The orb window is transparent (`main.rs:549`), the surface selects an **alpha-capable** mode
(PreMultiplied→PostMultiplied→first, `main.rs:294`), and the shader returns **premultiplied alpha**
(`orb.wgsl:271`). Under Xvfb (no compositor) this can render black/blank or fail surface present —
`LIBGL_ALWAYS_SOFTWARE=1` does not make X11 wgpu present reliable. We do NOT cripple the real-desktop path
(composited Linux desktops *can* do alpha); instead we add a **render mode** chosen at startup:

- `RenderMode::Floating` (default, all platforms today): transparent window + alpha-capable surface + transparent
  clear — unchanged behavior.
- `RenderMode::Opaque` (selected by the smoke entrypoints, and available as the Linux headless path): orb window
  `.with_transparent(false)`; surface `alpha_mode = CompositeAlphaMode::Opaque` (fallback to first available);
  clear color = an opaque near-black dark tone (≈ `#16141C`; specified in the surface's clear space, exact shade
  non-critical since the orb gradient dominates the region) so the orb composites against a solid background and
  is guaranteed visible. The orb art itself is unchanged (shader untouched); only the surface alpha mode + clear
  color differ.

`State::new` gains a `RenderMode` parameter (or a `composite: CompositeAlphaMode` + `clear: wgpu::Color`).
Smoke modes pass `Opaque`. Real runtime keeps `Floating`. This means CI proves **real orb pixels**, not build
coverage — the codex "no build-coverage contingency" requirement.

### 2. Render proof: new headless smoke mode, per-surface (codex Medium)

A whole-root color count does NOT prove both surfaces rendered — either alone clears ≥8. So smoke mode pins
each window at a **fixed, non-overlapping position** and CI crops + asserts **each region independently**.

`--smoke-pill` (mirrors `run_settings_panel_smoke` structure: open, pump events, exit 0):
- Opens the orb window in `RenderMode::Opaque` at a fixed position (e.g. outer position `(40, 40)`, 420×420)
  and renders ≥ a few frames so the orb gradient paints.
- Opens the pill (opaque Linux path) at a fixed position **clear of the orb rect** (e.g. `(500, 120)`,
  360×52 collapsed), pushes 3 sample messages (you/fae/fae) so the caption + accent dot paint.
- Exits 0 after a bounded number of redraws (deterministic; no wall-clock sleep dependence beyond the existing
  smoke pattern).

The "data panel" leg reuses the already-proven `--smoke-settings-panel` capture (opaque WebKitGTK, 2,380 colors).
Per-surface standard applies there too (it already fills its own window).

No separate `--smoke-orb` is needed because the orb now reliably paints in `Opaque` mode; but the same entry
renders the orb region on its own crop, so the orb is asserted independently of the pill.

### 3. CI extension (`linux-render-spike.yml`)

Add steps after the settings capture:
- run `fae-ui-shell --smoke-pill` under Xvfb, capture full screen `linux-orb-pill.png`,
- **crop the orb region** (`convert linux-orb-pill.png -crop 420x420+40+40 orb.png`) and assert its color count
  exceeds a **non-background threshold** (≥ 16, well above a flat clear which yields ~1–2) — proves real orb pixels,
- **crop the pill region** (`convert ... -crop 360x52+500+120 pill.png`) and assert ≥ 8 colors — proves the pill text/accents,
- upload all three (`linux-orb-pill.png`, `orb.png`, `pill.png`) as artifacts.
Keep the existing settings capture (its own per-window proof). Net: the workflow proves **orb + pill + data
panel** each rendered, per-surface. Thresholds are documented in the workflow with the rationale (flat clear ≈ 1
color; a rendered gradient/text region is dozens+).

## Constraints / non-goals

- **macOS untouched**: every change is `#[cfg(target_os="linux")]` or `cfg!`-guarded; `just check-ui-shell`
  (fmt + clippy `-D warnings -D panic -D unwrap_used -D expect_used` + check) must stay green on macOS, and
  the smoke modes must still `code=0` on macOS.
- No Wayland-vs-X11 branching: CI uses `GDK_BACKEND=x11` + Xvfb (already set). Real-compositor (Wayland blur)
  behavior is a separate desktop-access follow-up, not P6.
- No new deps.

## Verification

1. macOS local: `just check-ui-shell` green; `timeout 8s cargo run -- --smoke-pill` → `code=0`;
   `--smoke-settings-panel` still `code=0`; macOS pill/orb visuals unchanged (no `.fae-opaque`, `Floating`).
2. Linux: `linux-render-spike.yml` green — settings capture as before, plus `--smoke-pill` with **per-surface**
   crops: orb region ≥ 16 colors, pill region ≥ 8 colors.
3. codex review on revised design (this doc) and on the final diff.

## Risks & contingencies

- **Orb present under Xvfb**: `Opaque` alpha mode + opaque clear is the reliable headless path. If `surface.present`
  still fails on the software GL stack, the contingency is an **offscreen render-to-texture readback** in smoke
  mode (render the orb to a texture, copy-to-buffer, write PNG) — this proves the orb pipeline produces pixels
  without depending on X11 surface present at all. This is a *stronger* proof, not a downgrade; we reach for it
  only if windowed present is flaky. No "build coverage" fallback.
- **Pill** `build_gtk` already works for opaque panels, so the opaque pill is low-risk; turning the pill opaque is
  strictly simpler than transparent.
- **Real-desktop transparency** (composited X11/Wayland) is explicitly out of scope here and tracked as deferred
  acceptance — the `Floating` path is unchanged and untested on a real compositor in this PR.
