# ADR-009: Rust Orb UI Shell as Canonical Fae UI

Status: Accepted  
Date: 2026-06-11

## Context

Fae's previous macOS UI grew several surfaces: a main Swift conversation window, canvas windows, Cowork windows, debug consoles, settings, and menu commands. That made Fae feel heavier than the desired product direction.

The desired UX is now intentionally simpler:

- Fae is primarily an ambient assistant.
- The orb appears only while Fae is thinking or speaking.
- Fae is visually quiescent when idle; there is no always-animating main surface.
- Rich output such as charts, documents, web pages, and video belongs in browser/webview panels.
- All primary user controls should be reachable from right-clicking the orb.
- Cowork/canvas are no longer the primary product UI.

A Rust `wgpu` spike demonstrated a high-quality golden glass/fog orb with low idle cost. A follow-up spike added:

- `tao` frameless transparent orb window
- `wgpu` WGSL orb renderer
- `muda` right-click context menu
- `wry` browser/data panel

## Decision

Fae's canonical UI direction is now the **Rust orb UI shell**:

```text
Rust orb shell
  tao   -> native window/event loop
  wgpu  -> animated golden glass/fog orb renderer
  muda  -> right-click orb menu
  wry   -> browser/data/video panels
```

The promoted shell lives at:

```text
native/rust/fae-ui-shell/
```

The shell is currently a standalone runtime target while command/state bridge wiring is implemented. It is not yet part of the default Swift app launch or default CI path.

## UX contract

### Orb visibility

- `quiescent`: orb hidden or transparent; no continuous render loop.
- `listening`: visually quiescent for now; protocol-supported for future feedback if needed.
- `thinking`: orb visible; active slow fog/gas motion.
- `speaking`: orb visible; audio-reactive motion.

The render loop must be stopped while quiescent.

### Right-click menu

The orb context menu replaces scattered app UI affordances. It is adapted from the current Swift menu sources:

- `native/macos/Fae/Sources/Fae/OrbCrownView.swift`
- `native/macos/Fae/Sources/Fae/FaeApp.swift`

Current shell menu includes:

- Settings…
- Open Browser/Data Panel
- Reset Conversation
- Hide Fae
- Stop
- Permissions
- Scheduler / Skills
- Edit Soul / Edit Custom Instructions
- Ask Fae / help topics
- Memory Inbox
- Rescue Mode
- Quit Fae

### Rich surfaces

Charts, documents, tools, permissions, web pages, and video should open in browser/webview panels, not inside the orb and not in a permanent canvas.

## Consequences

### Positive

- Much simpler product surface.
- Cross-platform UI path via Rust libraries.
- One WGSL orb shader can target modern desktop and mobile GPU backends through `wgpu`.
- Idle/quiescent mode can be genuinely cheap: no redraw loop.
- Browser/webview panels are better suited for charts, data, and video than custom canvas UI.

### Tradeoffs

- The existing Swift app still owns the live voice pipeline, settings, permissions, memory, updater, and app lifecycle until bridge wiring lands.
- Transparent frameless windows are cross-platform but true non-rectangular hit-testing is platform-specific.
- Mobile packaging/lifecycle requires additional Tauri/wry/tao or native wrapper work.
- The shell's current menu actions are partly stubbed until connected to Fae commands.
- Cowork has been removed from the new UI contract and must not reappear in the orb menu.

## Migration plan

1. Promote the spike to `native/rust/fae-ui-shell/`. ✅
2. Document the Rust orb shell as the canonical UI. ✅
3. Keep Swift UI buildable while bridge wiring lands.
4. Add bridge transport:
   - Fae state -> shell state (`quiescent`, `listening`, `thinking`, `speaking`), with listening mapped to quiescent in the current product UX
   - shell menu action -> Fae command (`stop`, `settings`, `permissions`, `reset`, `quit`, etc.)
5. Replace Swift main/canvas remnants with the Rust shell once bridge parity is proven.
6. Remove or archive remaining canvas/Cowork UI code after release validation passes.

## Validation

The shell target must pass:

```bash
cd native/rust/fae-ui-shell
cargo fmt --all
cargo clippy --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo check --workspace --all-targets
cargo run --release
```

The full app is not release-ready on this UI until the release validation checklist covers the Rust orb shell, bridge events, menu commands, and webview panels.
