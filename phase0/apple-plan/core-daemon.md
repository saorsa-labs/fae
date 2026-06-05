I did **not** write to `phase0/apple-plan/core-daemon.md` because this planner role is no-edit. Below is the content intended for that file.

# Apple-first core daemon roadmap

## 1. Phase 0 — Apple v1 scope and hard gates

1. Define Apple v1 as: macOS Swift/AppKit/SwiftUI frontend + user-scoped Rust headless daemon owning local conversation, engine, voice, memory, scheduler, tools, skills, and security policy.
2. Explicitly exclude from Apple v1: Linux, Windows, mobile dock-wake, Fae↔Fae, groups, x0x peer features, TreeKEM group memory, ToM memory upgrades, and weight training.
3. Do not start production daemon work until gates are closed or explicitly narrowed:
   - G1: replicate S13 on another Apple machine at minimum; original cross-OS replication may move to future cross-platform track.
   - G2: real `mistral.rs` ↔ `llama-server` parity in `bench/engine-parity/`.
   - G4: memory migrator/preflight proven on copied real `fae.db`.
   - local control plane: `docs/architecture/daemon-control-plane.md` completed, not stub.
   - voice parity test defined for Kokoro/STT/speaker identity.
4. Stop rules:
   - If G2 fails, no fallback claim.
   - If control-plane auth is weaker than x0x baseline, daemon cannot own mic, memory, tools, or scheduler.
   - If memory backup/rollback fails, Rust remains read-only.

## 2. Phase 1 — New Rust daemon skeleton, selective legacy reuse

1. Create a new daemon shell; do **not** rollback `legacy/rust-core/`.
2. Proposed artifacts:
   - `crates/fae-protocol/src/{command.rs,event.rs,types.rs}`
   - `crates/fae-daemon/src/main.rs`
   - `crates/fae-daemon/src/runtime/{mod.rs,health.rs,shutdown.rs}`
   - `crates/fae-daemon/src/control/{transport.rs,auth.rs,capabilities.rs,audit.rs}`
3. Port concepts from:
   - `legacy/rust-core/src/host/contract.rs`
   - `legacy/rust-core/src/host/channel.rs`
   - `docs/adr/002-embedded-rust-core.md`
4. Do not reuse:
   - `legacy/rust-core/src/ffi.rs`
   - `legacy/rust-core/include/fae.h`
   - `legacy/rust-core/src/linker_anchor.rs`
5. Validation:
   - protocol round-trip tests;
   - `host.ping`, `host.version`, `runtime.status`;
   - ADR-002-style local RTT SLO.
6. Stop rule: no subsystem ownership until protocol and lifecycle are deterministic.

## 3. Phase 2 — Local control-plane security

1. Finalize `docs/architecture/daemon-control-plane.md`.
2. Implement:
   - Unix socket under `~/Library/Application Support/fae/run/` with `0700` parent and owner-only socket permissions.
   - TCP loopback only when explicitly enabled.
   - no network bind.
   - no long-lived query-token WS/SSE auth.
   - per-client scoped capabilities.
   - Host/Origin validation.
   - security deny audit log.
   - emergency lockout.
3. Swift integration code areas:
   - `native/macos/Fae/Sources/Fae/HostCommandBridge.swift`
   - `ProcessCommandSender.swift`
   - `BackendEventRouter.swift`
   - new `DaemonCommandSender.swift`
   - new `DaemonLifecycleManager.swift`
4. Stop rule: if browser-origin, DNS-rebinding, or same-user token-read risks are unresolved, daemon remains dev-only.

## 4. Phase 3 — Engine and text conversation

1. Extend G2 first:
   - `bench/engine-parity/src/adapters/mistralrs_adapter.rs`
   - `bench/engine-parity/src/adapters/llama_server_adapter.rs`
   - results under `bench/engine-parity/results/`
2. Then port into daemon:
   - from `legacy/rust-core/src/fae_llm/provider.rs`
   - from `legacy/rust-core/src/fae_llm/providers/local.rs`
   - using `bench/mistralrs-eval/src/main.rs` as `mistral.rs 0.8` reference.
3. Model plan:
   - primary front: Gemma-4 E4B in `mistral.rs`;
   - heavy driver: Qwen3-14B dense in `mistral.rs`;
   - fallback: `llama-server` HTTP only if G2 passes.
4. Acceptance:
   - `conversation.inject_text` streams events to Swift;
   - tool-call delta normalizes into daemon event protocol;
   - no memory/tool mutation yet.
5. Stop rule: no production fallback unless both engines emit equivalent structured tool calls.

## 5. Phase 4 — Swift frontend as thin client

1. Keep Swift as native UX shell.
2. Move backend calls behind daemon transport:
   - `FaeCore.swift` becomes frontend/runtime coordinator, not pipeline owner in daemon mode.
   - `BackendEventRouter.swift` remains the Swift event fanout layer.
3. Add feature flag: Swift-only fallback remains available until daemon parity passes.
4. Validation:
   - current app launches;
   - text turn through daemon;
   - no UI regression in main window, onboarding, approvals, settings.
5. Stop rule: any severe Swift UX regression keeps Swift backend as default.

## 6. Phase 5 — Apple voice pipeline

1. Port or rewrite selectively:
   - `legacy/rust-core/src/audio/capture.rs`
   - `legacy/rust-core/src/audio/playback.rs`
   - `legacy/rust-core/src/vad/mod.rs`
   - `legacy/rust-core/src/stt/mod.rs`
   - `legacy/rust-core/src/tts/kokoro/*`
2. Implement daemon modules:
   - `audio/`
   - `vad/`
   - `stt/`
   - `tts/`
   - `speaker/`
   - `barge_in/`
3. Correct speaker target: WeSpeaker ResNet34-LM 256d, not ECAPA.
4. Acceptance:
   - real mic capture;
   - E4B STT or Parakeet fallback;
   - streamed LLM;
   - Kokoro playback;
   - stop/barge-in works;
   - Fae still sounds recognizably like Fae.
5. Stop rule: if voice identity or TTS parity fails, retain Apple Swift/MLX voice path as default.

## 7. Phase 6 — Memory migration and ownership

1. Rust must target current Swift schema v9, not legacy memory.
2. Source files to mirror semantically:
   - `MemoryTypes.swift`
   - `SQLiteMemoryStore.swift`
   - `MemoryOrchestrator.swift`
3. Implement:
   - read-only DB open;
   - preflight command;
   - backup command;
   - rollback command;
   - additive migration only;
   - audit entries for every mutation.
4. Storage root remains:
   - `~/Library/Application Support/fae/fae.db`
   - `~/Library/Application Support/fae/backups/`
5. Stop rule: unknown newer schema, failed integrity check, failed backup, or failed rollback means read-only mode.

## 8. Phase 7 — Tools, Apple integrations, approvals, security

1. Port policy concepts from Swift:
   - `Tools/ToolRegistry.swift`
   - `Tools/ToolExecutor.swift`
   - `Tools/DamageControlPolicy.swift`
   - `Tools/SecurityEventLogger.swift`
   - `Runtime/PrivacyFilterBridge.swift`
2. Rust modules:
   - `tools/registry.rs`
   - `tools/executor.rs`
   - `security/damage_control.rs`
   - `security/audit.rs`
   - `apple/{calendar,contacts,mail,notes,reminders}.rs`
3. Use `objc2` where stable; keep minimal Swift shims for TCC/UI permission prompts if needed.
4. Acceptance:
   - read-only tools work;
   - mutating tools require approval;
   - dangerous operations are blocked/manual-only;
   - audit logs are append-only and redacted.
5. Stop rule: any path that lets a peer, browser, or unauthenticated local client trigger tools blocks release.

## 9. Phase 8 — Scheduler, skills, and self-learning parity

1. Port semantics from:
   - `Scheduler/FaeScheduler.swift`
   - `Scheduler/TaskRunLedger.swift`
   - `Skills/SkillManager.swift`
   - `Runtime/UVRuntime.swift`
2. Daemon modules:
   - `scheduler/`
   - `skills/`
   - `python_runtime/`
   - `session_search/`
3. Preserve current cadence and quiet proactive policy.
4. Acceptance:
   - scheduler list/create/update/delete/trigger;
   - memory maintenance jobs;
   - skill discovery/run/health;
   - uv auto-install behavior preserved.
5. Stop rule: proactive tasks must not mutate memory/tools without policy and audit.

## 10. Phase 9 — Packaging and release validation

1. Bundle daemon inside `Fae.app`.
2. Sign daemon with app bundle.
3. Store daemon client credentials in Keychain or owner-only files.
4. Add model checksum/signature manifest and cache-permission checks.
5. Validation:
   - Rust: `cargo fmt`, strict `cargo clippy`, `cargo check`.
   - Swift: `cd native/macos/Fae && swift build && swift test`.
   - App: `just rebuild`, `just test-serve`.
   - Comprehensive specs: memory, scheduler, tools, permissions, voice, onboarding, Cowork as relevant.
   - Live checklist: `docs/checklists/app-release-validation.md`.
6. Final stop rule: no Apple v1 release unless the real app passes live voice/text/memory/tool validation with screenshots and archived reports.

## 11. Future tracks, not Apple v1

1. Linux daemon/client.
2. Windows support.
3. Mobile dock-wake.
4. x0x phone↔home.
5. 1:1 Fae↔Fae.
6. Group “the Fae” features.
7. TreeKEM group memory.
8. ToM/Zep/Graphiti/Honcho-style memory.
9. Weight training / MLX premium path.