# AGENTS.md — Fae Engineering Guardrails

This file defines implementation guardrails for agents modifying Fae.

## Memory is a core subsystem

Treat memory as production-critical.

Non-negotiables:

- Preserve backward compatibility of on-disk memory unless a migration is added.
- Never silently overwrite conflicting durable facts; supersede with lineage.
- Keep recall and capture fully automatic in normal conversation flow.
- Keep memory edits auditable.
- Keep mutation paths panic-free and unwrap/expect-free in non-test code.

Behavioral truth sources:

- `Prompts/system_prompt.md`
- `SOUL.md`
- `~/.fae/memory/`
- `docs/Memory.md`

Implementation touchpoints (not behavioral truth):

- `src/memory.rs`
- `src/pipeline/coordinator.rs`
- `src/scheduler/tasks.rs`
- `src/runtime.rs`

## Memory data contracts

Storage root:

- `~/.fae/memory/`

Required files:

- `manifest.toml`
- `records.jsonl`
- `audit.jsonl`

Compatibility files:

- `~/.fae/memory/primary_user.md`
- `~/.fae/memory/people.md`

Record semantics:

- kinds: `profile`, `fact`, `episode`
- status: `active`, `superseded`, `invalidated`, `forgotten`
- lineage: `supersedes`

## Runtime memory lifecycle

Per completed turn:

1. Recall durable relevant memory before generation.
2. Inject bounded `<memory_context>`.
3. Capture turn episode and durable candidates after generation.
4. Resolve conflicts via supersession.
5. Apply retention policy to episodic memories.

Main-screen UX policy:

- memory telemetry is suppressed from the main conversation surface
- memory telemetry can appear in canvas/event surfaces

## Scheduler cadence (current implementation)

Scheduler tick:

- every 60 seconds (`src/scheduler/runner.rs`)

Built-in update task:

- `check_fae_update`: every 6 hours

Built-in memory tasks:

- `memory_migrate`: every 1 hour
- `memory_reindex`: every 3 hours
- `memory_reflect`: every 6 hours
- `memory_gc`: daily at 03:30 UTC

## Proactive automation behavior policy

Proactive automation must be useful and quiet.

Rules:

- Prefer batched summaries over frequent interruptions.
- Surface only actionable or high-signal updates.
- Collapse repetitive non-urgent events into digest-style output.
- Reserve immediate interruption for urgent/severe items.
- Keep verbose maintenance details off primary conversation surface.

## Personalization + interview roadmap contract

When implementing personalization/interview flows:

- Use explicit consent for profile collection.
- Persist interview-derived facts as tagged durable memory records.
- Track confidence and source turn for each derived fact.
- Re-interview only when confidence drops, information is stale, or user requests updates.
- Support explicit correction and forget flows.

Design plan lives in:

- `docs/personalization-interviews-and-proactive-plan.md`

## Tooling reality

In-repo registered core tools:

- `read`
- `write`
- `edit`
- `bash`
- `web_search` (when `web-search` feature is enabled)
- `fetch_url` (when `web-search` feature is enabled)
- canvas tools when canvas is active (`canvas_render`, `canvas_interact`, `canvas_export`)

Tool modes:

- `off`
- `read_only`
- `read_write`
- `full`
- `full_no_approval`

## Native app architecture (embedded Rust core)

Fae's macOS app embeds the Rust core directly via C ABI. The app is the brain.

### Integration modes

- **Mode A (Embedded)**: Swift links `libfae` as a static library. Rust runs in-process.
  Zero IPC overhead. This is the production model for Fae.app.
- **Mode B (IPC)**: External frontends connect via Unix socket (`~/.fae/fae.sock`).
  Same JSON command/event protocol. For third-party UIs, CLI tools, companion apps.

### Non-negotiables for native app work

- Never introduce a subprocess/sidecar dependency for the primary Swift→Rust path.
  The current `ProcessCommandSender` (stdin/stdout subprocess) is interim scaffolding.
- The FFI surface (`src/ffi.rs`) must remain thin — only control-plane operations.
- Data-plane operations (mic capture, STT, LLM, TTS, playback) stay in-process.
- No PCM audio or high-frequency token deltas across process boundaries.
- Scheduler authority always lives in the Rust core, never in Swift.
- Memory writes and audit logs always go through the Rust core, never Swift-side.
- The embedded core inherits macOS sandbox/entitlements naturally.

### Current state (interim)

`ProcessCommandSender.swift` spawns `fae-host` as a subprocess with stdin/stdout pipes.
This will be replaced by direct C ABI calls when `libfae` is ready. The host command
protocol (`src/host/contract.rs`) remains unchanged — it just moves from pipe transport
to direct function calls.

### File map

Swift-side:

| File | Role |
|------|------|
| `native/macos/.../HostCommandBridge.swift` | NotificationCenter → command sender |
| `native/macos/.../ProcessCommandSender.swift` | Interim subprocess bridge (to be replaced by FFI sender) |
| `native/macos/.../WindowStateController.swift` | Adaptive window modes (collapsed/compact/expanded) |
| `native/macos/.../ConversationWebView.swift` | WKWebView bridge for orb + conversation UI |

Rust-side:

| File | Role |
|------|------|
| `src/host/contract.rs` | Command/event envelope schemas (shared by both modes) |
| `src/host/channel.rs` | Command router and `DeviceTransferHandler` trait |
| `src/host/stdio.rs` | Stdin/stdout bridge (interim, becomes IPC-only) |
| `src/bin/host_bridge.rs` | Headless bridge binary (interim, becomes `faed` for Mode B) |

Architecture docs:

- `docs/architecture/native-app-v0.md` — full architecture spec
- `docs/architecture/embedded-core.md` — embedding plan, FFI surface, migration path
- `docs/architecture/native-app-latency-plan.md` — latency SLOs and benchmarks

## Quality gates

Before shipping memory/proactive/personalization changes:

```bash
cargo fmt --all
cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test --all-features
```

For targeted iteration:

```bash
cargo test memory::tests:: -- --nocapture
cargo test contradiction_resolution_ -- --nocapture
cargo test llm_stage_ -- --nocapture
```

On macOS, set SDK sysroot env for bindgen if required (see `justfile`).
