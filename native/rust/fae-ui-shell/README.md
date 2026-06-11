# Fae Orb UI Host

Rust-native host for Fae's canonical orb-first UI. The product UI is the orb itself; this process is implementation infrastructure for the orb window, menu, transcript, and temporary panels.

This target is promoted from the `docs/spikes/fae_wgpu_orb_poc` prototype. It is the orb UI direction documented by ADR-009 and is launched by the Swift runtime when a bundled or configured host binary is available.

## What it demonstrates

- `tao` frameless transparent orb window.
- `muda` right-click orb context menu copied from Fae's current orb/menu commands, with Cowork/Open Work removed.
- `wry` browser/data panel opened from the orb menu.
- `wgpu` full-screen triangle renderer.
- WGSL orb shader:
  - circular glass silhouette
  - independent fresnel/rim layer
  - slow, gaseous amber volumetric veils
  - soft filament bands
  - slow spiral smoke
  - depth shadowing
- Active-only render loop for the simplified Fae UX:
  - thinking/speaking: `ControlFlow::Poll`, continuous redraw
  - quiescent: `ControlFlow::Wait`, no redraw loop

## Run

```bash
just run-ui-shell
# or
cd native/rust/fae-ui-shell
cargo run --release
```

## Validate

```bash
just check-ui-shell
```

Controls:

- `Space`: toggle orb active/quiescent in demo mode.
- Left drag: move frameless orb window.
- Right click: open Fae context menu.
- Menu → `Open Browser/Data Panel`: opens a separate `wry` webview panel.
- Menu → `Quit Fae`: exit shell.

## Bridge protocol

The shell reads JSON lines from stdin:

```jsonl
{"type":"state","state":"quiescent"}
{"type":"state","state":"listening"}
{"type":"state","state":"thinking","audio":0.2}
{"type":"state","state":"speaking","audio":0.7}
{"type":"status","phase":"starting","message":"Loading local model","progress":0.42}
{"type":"conversation","role":"user","text":"Hello Fae"}
{"type":"conversation","role":"fae","text":"Hello — I’m here."}
{"type":"show_messages"}
{"type":"hide"}
{"type":"show"}
{"type":"quit"}
```

The shell emits menu actions to stdout as JSON lines:

```jsonl
{"type":"menu","action":"stop"}
{"type":"menu","action":"open_browser_data_panel"}
```

Logs go to stderr via `env_logger`.

`listening` is accepted by the protocol for future feedback, but current Swift bridge policy sends/uses `quiescent` for idle/listening so the orb appears only for startup/status, thinking, speaking, and explicit user interaction.

Startup/status and conversation updates are owned by the orb. Startup progress is rendered as an in-orb progress halo. The lower-right orb hit-zone and `Messages…` menu item open the orb-owned transcript panel; open transcript panels live-refresh as Swift sends conversation/status updates.

## Production interpretation

This target is now the intended orb host shape:

- `tao + wgpu` own the tiny orb surface.
- `muda` owns the right-click control menu.
- `wry` owns temporary orb-launched panels for messages, charts/data/video, scheduler, and skills.
- Bridge wiring connects orb state, status, transcript, scheduler snapshot, skills snapshot, and menu actions to the live Fae runtime.

For Fae's intended UX, the orb must not render while idle/quiescent or merely listening. It appears only for thinking/speaking, then stops its render loop entirely.

## Migration boundary

The Swift app still hosts the live pipeline, settings, memory, permissions, scheduler/skills runtimes, updater, and test server while bridge parity is completed. Scheduler and Skills now open orb-owned temporary panels populated from Swift snapshots instead of Cowork from the Rust orb menu. Do not add new product UI to canvas/Cowork unless it is required for migration safety.
