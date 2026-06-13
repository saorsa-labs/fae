# Fae Rust Orb UI

Date: 2026-06-11  
Status: canonical orb UI direction, bridge migration in progress

## Summary

Fae's product UI is now the **orb itself**, hosted by Rust infrastructure:

```text
native/rust/fae-ui-shell/
```

The shell uses:

- `tao` for the native frameless transparent orb window
- `wgpu` for the golden glass/fog orb renderer
- `muda` for the right-click orb menu
- `wry` for browser/data/video panels

The previous Swift main window and canvas surfaces are no longer the desired product UI. Cowork is removed from the new orb UI. Remaining Swift UI code is migration source while the Rust orb bridge reaches parity with the live Fae runtime.

## UX principles

1. **Quiescent means quiet.** When Fae is idle, the orb is hidden/transparent and no render loop runs.
2. **The orb appears only for visible activity.** Thinking and speaking show the orb; idle and merely listening stay visually quiescent.
3. **Startup belongs to the orb.** Loading/model/runtime information appears as orb status/progress, not as a separate shell screen.
4. **Messages belong to the orb.** The orb owns a small transcript/messages affordance and opens an orb-anchored transcript panel when needed; open transcript panels refresh from bridge updates.
5. **Right-click is the control surface.** All primary controls are available from the orb menu.
6. **Webviews are for rich content.** Charts, documents, webpages, video, tools, diagnostics, and permission panels open as temporary orb-launched browser/webview surfaces.
5. **No permanent canvas/Cowork primary UI.** Those concepts are deprecated as product surfaces.

## Current implementation

### Shell target

```text
native/rust/fae-ui-shell/
├── Cargo.toml
├── Cargo.lock
├── README.md
└── src
    ├── main.rs
    ├── menu.rs
    └── orb.wgsl
```

Run:

```bash
just run-ui-shell
```

Validate:

```bash
just check-ui-shell
```

These recipes are intentionally explicit and are not part of default `just check` while release packaging is still being finalized.

### Window behavior

- frameless
- transparent
- always-on-top
- fixed square orb surface
- left-drag moves the orb window
- right-click opens the menu
- `Space` toggles active/quiescent in demo mode

The current window remains a transparent square for event handling. True non-rectangular click-through around transparent pixels is a future platform-specific refinement.

### Orb renderer

The WGSL shader renders a warm golden glass/fog orb with:

- circular glass silhouette
- independent fresnel/rim layer
- slow gaseous amber veils
- soft filament bands
- slow spiral smoke
- depth shadowing
- transparent premultiplied-alpha output

The renderer uses `ControlFlow::Poll` only while active and `ControlFlow::Wait` while quiescent.

### Menu

`src/menu.rs` adapts current Fae menu items from:

- `native/macos/Fae/Sources/Fae/OrbCrownView.swift`
- `native/macos/Fae/Sources/Fae/FaeApp.swift`

Menu items include:

- Settings… (Rust/wry panel)
- Settings (legacy)… (SwiftUI fallback during parity migration)
- Open Browser/Data Panel
- Reset Conversation
- Hide Fae
- Stop
- Permissions entries
- Scheduler (orb-owned temporary panel during migration)
- Skills (orb-owned temporary panel during migration)
- Edit Soul…
- Edit Custom Instructions…
- Ask Fae…
- Ask About Shortcuts / Models / Privacy / Tools
- Memory Inbox…
- Rescue Mode…
- Quit Fae

Settings, Messages, Scheduler, and Skills now have live orb-owned panel behavior. The remaining menu items are bridge stubs or Swift-backed actions.

### Webview panels

`Settings…` opens an opaque `wry` panel owned by the Rust shell. Swift sends a structured `settings_snapshot`; the panel sends `settings_set { key, value }` back to the Swift bridge, which validates/coerces and persists through `FaeCore.patchConfig()`. `Settings (legacy)…` keeps the previous SwiftUI window available until parity is complete. On Linux, panels are built through `WebViewBuilderExtUnix::build_gtk` against tao's GTK container; the generic `build(&window)` path compiled but rendered blank under Xvfb.

`Open Browser/Data Panel` opens a `wry` webview with placeholder sections for charts, video/rich media, and tools/permissions. This proves the new rule: rich output belongs in browser/webview panels, not in a custom canvas.

## Bridge contract

The orb host uses a small JSONL stdin/stdout bridge to the live Fae runtime.

### Runtime state -> orb

```text
quiescent -> orb hidden/transparent; no render loop
listening -> visually quiescent in current product UX; protocol-supported for future feedback
thinking  -> orb visible; slow gaseous thinking motion
speaking  -> orb visible; audio-reactive speaking motion
status    -> startup/error/status appears through the orb while non-ready, including progress halo
conversation -> transcript entries are stored by the orb host for the Messages affordance and live-refreshed panels
scheduler_snapshot -> scheduler tasks/statuses populate the orb-owned Scheduler panel
skills_snapshot -> skill inventory/statuses populate the orb-owned Skills panel
settings_snapshot -> settings sections/cards populate the orb-owned Settings panel
```

Example JSONL commands:

```jsonl
{"type":"status","phase":"starting","message":"Loading local model","progress":0.42}
{"type":"conversation","role":"user","text":"Hello Fae"}
{"type":"conversation","role":"fae","text":"Hello — I’m here."}
{"type":"show_messages"}
{"type":"settings_snapshot","sections":[],"cards":[]}
```

### Shell menu -> runtime command

```text
settings
settings_legacy
open_browser_data_panel
reset_conversation
hide_fae
stop
permissions:microphone|contacts|calendar|reminders|mail|privacy
scheduler
skills
edit_soul
edit_custom_instructions
ask_fae
memory_inbox
rescue_mode
quit
```

Current transport:

- stdin JSONL from Swift to the shell for state/show/hide/quit
- stdout JSONL from the shell to Swift for menu actions
- stderr for shell logs so stdout remains machine-readable

Possible future transports if needed:

- local IPC socket
- platform channel if embedded by a native wrapper
- Tauri command/event system if the shell moves to Tauri

## Relationship to Swift app

The Swift app remains the authoritative live implementation for now and launches the Rust orb host when a bundled or configured binary is available:

- voice pipeline
- settings persistence and legacy Settings fallback
- permissions/onboarding
- memory
- scheduler runtime
- skills runtime
- updater
- test server

The Swift bridge resolves the orb host from `FAE_UI_SHELL_BIN`, then from `Fae.app/Contents/MacOS/fae-ui-shell`, then from the local development target path. Shell-enabled bundle recipes copy/sign the Rust binary into the app bundle when it has been built explicitly.

The Swift UI should be treated as legacy/migration source. Do not add new product UI surfaces to canvas, and do not restore Cowork as a product surface. Settings/Scheduler/Skills product entry points stay orb-owned while their backing runtime remains Swift; Swift sends compact snapshots over the bridge to populate those panels.

## Cross-platform notes

`wgpu` supports the orb renderer on modern desktop and mobile GPU APIs. `tao`, `muda`, and `wry` cover desktop shell/menu/webview behavior; mobile packaging and lifecycle need dedicated follow-up work. The P4 Linux render spike passed for the opaque Settings panel on Ubuntu/WebKitGTK/Xvfb with a screenshot artifact and color-count guard; transparent pill behavior remains compositor-sensitive and should not be used as the Linux go/no-go criterion.

For a full cross-platform product shell, compare:

1. direct `tao + wgpu + muda + wry`
2. Tauri 2 with custom `wgpu` orb surface
3. platform-native wrapper launching the Rust shell

The current canonical direction is direct Rust shell unless bridge/platform findings prove Tauri is lower-risk.
