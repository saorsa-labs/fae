# Fae Orb UI Migration Report

Date: 2026-06-11
Status: implementation pass complete; live manual QA still required

## Executive Summary

Fae's product UI has been pivoted from a visible app shell/main window concept to an **orb-first UI**. The Rust process remains as implementation infrastructure, but the product surface is now the orb itself plus temporary orb-owned panels.

The Swift app still hosts the live runtime: voice pipeline, memory, settings, permissions, scheduler runtime, skills runtime, updater, and test server. The Rust orb host owns the visual product surface: orb rendering, orb menu, startup progress affordance, messages/transcript panel, browser/data panel, scheduler panel, and skills panel.

Cowork/Open Work is not exposed in the new orb product UI. Legacy Cowork entry points are preserved only behind the `showLegacyCoworkUI` UserDefaults flag for migration safety.

## Product Decision

The key product decision is:

> The orb is the UI. There is no visible shell as a product concept.

Implementation details:

- `native/rust/fae-ui-shell` remains the Rust binary name/location for now.
- Documentation and comments now refer to this as the Rust orb UI host where appropriate.
- `tao`, `wgpu`, `muda`, and `wry` are infrastructure for the orb, not a separate user-facing shell.

## Architecture Implemented

### Rust Orb Host

Path:

```text
native/rust/fae-ui-shell/
```

Responsibilities:

- Frameless transparent orb window via `tao`.
- Golden gaseous orb rendering via `wgpu` + WGSL.
- Right-click orb menu via `muda`.
- Temporary orb-owned panels via `wry`.
- JSONL bridge over stdin/stdout.
- Logs on stderr only.

### Swift Runtime Bridge

Path:

```text
native/macos/Fae/Sources/Fae/RustUiShellController.swift
```

Responsibilities:

- Launch the bundled/configured orb host.
- Send runtime state/status/transcript/scheduler/skills snapshots to Rust.
- Receive menu/panel actions from Rust.
- Route actions into existing Swift runtime systems.
- Gracefully stop the orb host on app termination.

## Bridge Protocol

Swift → Rust commands include:

```jsonl
{"type":"state","state":"quiescent|listening|thinking|speaking","audio":0.5}
{"type":"status","phase":"starting|running|stopped|stopping|error","message":"Loading local model","progress":0.42}
{"type":"conversation","role":"user|fae|tool|summary","text":"..."}
{"type":"clear_conversation"}
{"type":"scheduler_snapshot","tasks":[...]}
{"type":"skills_snapshot","skills":[...]}
{"type":"hide"}
{"type":"show"}
{"type":"quit"}
```

Rust → Swift events include menu events from the typed Rust `ShellEvent` encoder plus panel IPC events forwarded as JSONL from `wry` panels:

```jsonl
{"type":"menu","action":"settings"}
{"type":"menu","action":"reset_conversation"}
{"type":"scheduler_toggle","id":"memory_reflect","enabled":false}
{"type":"skill_toggle","id":"example-skill","active":true}
```

Note: `scheduler_toggle` and `skill_toggle` originate from orb-owned panel JavaScript via `window.ipc.postMessage(...)`, are forwarded by Rust unchanged to stdout, and are decoded by Swift's bridge event decoder. They are part of the functional bridge protocol even though they are not emitted through `protocol.rs`'s typed `ShellEvent::Menu` helper.

## UI Features Completed

### Orb Lifecycle

- Idle/listening are visually quiescent.
- Thinking/speaking show the orb.
- Startup/model-loading can show the orb with an in-orb progress halo.
- Quiescent state stops continuous redraw.

### Startup Status

- Swift sends pipeline/model status to Rust.
- Rust maps non-ready status to visible orb activity.
- WGSL renders startup progress as a progress halo.

### Messages

- Rust stores recent conversation messages sent by Swift.
- Orb has a small in-orb Messages affordance.
- `Messages…` menu item opens an orb-owned transcript panel.
- Open transcript panels live-refresh from bridge updates.

### Browser/Data Panel

- Orb menu opens a `wry` rich panel.
- Panel displays runtime status, transcript count, and rich chart/media placeholders.
- This establishes the rule that charts/data/video/documents use temporary orb-launched panels, not canvas/Cowork.

### Scheduler Panel

- Orb menu opens an orb-owned Scheduler panel.
- Swift sends real scheduler data from existing runtime state.
- Panel displays task name, schedule, enabled state, last run, and next run.
- Panel includes enable/disable actions.
- Rust forwards actions to Swift; Swift persists task state with existing scheduler persistence.
- Open panel live-refreshes after snapshot updates.

### Skills Panel

- Orb menu opens an orb-owned Skills panel.
- Swift sends real skill inventory from existing runtime state.
- Panel displays skill name, description, type, tier, enabled state, and active state.
- Panel includes activate/deactivate actions.
- Rust forwards actions to Swift; Swift uses `FaeCore.setSkill(_:active:)` backed by `SkillManager`.
- Open panel live-refreshes after snapshot updates.

### Reset Semantics

Reset now clears:

- Rust transcript state.
- Swift visible conversation messages.
- Swift subtitles.
- Runtime pipeline conversation via `FaeCore.resetConversation()`.

### Cowork / Legacy UI

- Rust orb menu does not include Cowork/Open Work.
- Default Swift product UI no longer exposes Cowork/Open Work.
- Legacy Cowork entry points remain behind `showLegacyCoworkUI=false` for migration safety.

## Packaging / Launch

`just run-native-with-ui-shell` now:

1. Builds the Rust orb host explicitly.
2. Builds the Swift app.
3. Bundles the Swift app.
4. Embeds `fae-ui-shell` into `Fae.app/Contents/MacOS/fae-ui-shell`.
5. Signs the app and embedded orb host.
6. Launches the app with `FAE_UI_SHELL_BIN` pointing at the bundled host.

Default Swift `build` / `test` / `check` remain Rust-free. `guard-no-rust` still passes.

## Important Files Changed

Core Rust orb host:

- `native/rust/fae-ui-shell/src/main.rs`
- `native/rust/fae-ui-shell/src/menu.rs`
- `native/rust/fae-ui-shell/src/protocol.rs`
- `native/rust/fae-ui-shell/src/orb.wgsl`
- `native/rust/fae-ui-shell/README.md`

Swift bridge/runtime wiring:

- `native/macos/Fae/Sources/Fae/RustUiShellController.swift`
- `native/macos/Fae/Sources/Fae/FaeApp.swift`
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
- `native/macos/Fae/Sources/Fae/InputBarView.swift`
- `native/macos/Fae/Sources/Fae/OrbCrownView.swift`

Build/docs:

- `justfile`
- `AGENTS.md`
- `docs/adr/009-rust-orb-ui-shell.md`
- `docs/architecture/fae-rust-orb-ui-shell.md`
- `docs/checklists/app-release-validation.md`
- `docs/checklists/main-and-cowork-live-test-scenarios.md`

## Validation Performed

Passed:

```bash
just check-ui-shell
just build
just guard-no-rust
just run-native-with-ui-shell
just _verify-bundle
```

Smoke evidence:

- Bundled `Fae.app/Contents/MacOS/Fae` launched.
- Bundled `Fae.app/Contents/MacOS/fae-ui-shell` launched.
- Bundle verification passed with valid code signature.

Known unrelated validation issue:

- `just check` was run during this work and failed in existing `BuiltinToolsTests` temp-file setup errors for write/edit tool tests. This failure is not introduced by the orb UI changes.

## Review Notes / Risks

### Remaining Manual QA

The following still require hands-on UI validation:

- Right-click orb menu opens reliably.
- Messages affordance hit-zone is easy to discover/click.
- Messages panel updates while conversation continues.
- Scheduler enable/disable persists and refreshes.
- Skill activate/deactivate updates prompt context and refreshes.
- Startup progress halo feels readable and not noisy.
- Orb quiescent state has no visible redraw/GPU churn.
- Quit/hide/stop behavior feels correct from the orb menu.

### Technical Risks

- The Rust target path/name still says `fae-ui-shell`; renaming can happen later once migration stabilizes.
- Scheduler/Skills panels are data-backed and interactive, but still visually simple.
- Skill activation is runtime-context activation, not persistent skill enable/disable.
- Scheduler enable/disable persists through the existing scheduler JSON file path.
- Browser/data panel is still a rich-surface scaffold rather than a full document/chart runtime.
- `wry` panel refresh uses `evaluate_script` with full HTML rewrite; adequate for now, but could evolve to finer-grained updates.

## Recommended Next Steps

1. Run live manual QA with screenshots for the release checklist.
2. Decide whether skill panel action should mean runtime activate/deactivate or persistent enable/disable.
3. Add richer browser/data content routing once Fae has real chart/document payloads.
4. Consider renaming the Rust crate/binary from `fae-ui-shell` to `fae-orb-ui-host` after review.
5. Fix unrelated `BuiltinToolsTests` temp-file setup failures so `just check` is clean again.
