# Apple-first Rust-headless Fae Roadmap — 2026-06-01

> Goal: get Fae fully working on Apple with a Rust headless core and Swift macOS frontend. Linux, Windows, iOS, and Android are future tracks and must not block the Apple MVP.

## Definition: “Fae working on Apple fully”

Apple v1 means:

1. Native Swift/AppKit/SwiftUI app remains the user-facing shell.
2. Local conversation works end-to-end: text, voice input, local model response, streaming output, TTS playback, and reliable interruption/stop.
3. Memory remains safe and automatic: current `fae.db` preserved, recall/capture continue, no silent overwrites, backup/rollback available.
4. Existing Apple permissions/tools remain safe: Calendar, Reminders, Contacts, Mail, Notes, mic/camera/accessibility flows preserve current approval/TCC behavior.
5. Rust daemon earns ownership subsystem-by-subsystem; no broad takeover until security and migration gates are real.
6. No peer/group/x0x/shared-memory features in Apple MVP.

## Scope decisions

### In Apple MVP

- macOS Swift frontend.
- User-scoped Rust daemon.
- Local control plane.
- Engine/text turn.
- Voice loop after parity validation.
- Memory read first, write only after G4 proof.
- Tools only after broker/capability/audit path.

### Out of Apple MVP

- Windows/Linux production frontends.
- iOS/Android/mobile dock wake.
- Fae↔Fae memory sharing.
- Peer-triggered tools.
- Groups / “the Fae”.
- TreeKEM group memory.
- ToM memory upgrades.
- Weight training.
- Forking candle/mistral.rs.

## Go / no-go ladder

| Step | Status needed before proceeding |
|---|---|
| 0. Planning/docs/scaffolds | Allowed now. |
| 1. Real G2 parity | Required before advertising llama.cpp fallback or depending on fallback. |
| 2. Control-plane design | Required before daemon owns mic, memory, tools, scheduler, or model access. |
| 3. Daemon skeleton | Allowed after control-plane design exits stub; starts with status/ping only. |
| 4. Text engine turn | Allowed after G2 passes or owner explicitly accepts single-engine risk. |
| 5. Swift bridge | Default-off feature flags; no removal of existing Swift paths. |
| 6. Voice | Requires latency and Fae voice-identity parity. |
| 7. Memory read | Requires G4 preflight on copied DB. |
| 8. Memory write | Requires backup/rollback/live-copy demo and owner signoff. |
| 9. Tools | Requires TrustedActionBroker/capability/audit path. |
| 10. Peer/network | Not Apple MVP; requires G5 enforcement + metadata threat model. |

## Roadmap

### Phase A — Apple MVP contract and safety gates

Deliverables:

- This roadmap.
- Finalized `docs/architecture/daemon-control-plane.md`.
- Real G2 parity results.
- G4 migrator/preflight design turned into a copy-only tool.
- Voice parity checklist.

Stop rules:

- If G2 fails, remove fallback claim or choose single-engine risk explicitly.
- If control-plane auth is weaker than x0x baseline, daemon remains dev-only.
- If memory backup/rollback fails, Rust memory stays read-only.

### Phase B — Minimal Rust daemon skeleton

Create a new daemon shell; do not rollback `legacy/rust-core/`.

Proposed code areas:

```text
crates/fae-protocol/src/{command.rs,event.rs,types.rs}
crates/fae-daemon/src/main.rs
crates/fae-daemon/src/runtime/{health.rs,shutdown.rs}
crates/fae-daemon/src/control/{transport.rs,auth.rs,capabilities.rs,audit.rs}
```

Initial endpoints/commands:

- `host.ping`
- `host.version`
- `runtime.status`
- `runtime.shutdown` gated by admin capability

Validation:

- protocol round-trip tests;
- lifecycle tests;
- local RTT SLO;
- auth deny tests;
- Rust fmt/clippy/check with project lint policy.

### Phase C — Control-plane security implementation

Required before sensitive ownership:

- Unix socket under App Support run directory with `0700` parent.
- TCP loopback disabled by default or dev-only.
- no long-lived query-token WS/SSE auth.
- per-client capability scopes.
- Host/Origin validation.
- audit logging for denies/high-risk actions.
- emergency lockout.

### Phase D — Engine/text turn

Complete `bench/engine-parity` real adapters:

- `MistralrsAdapter` for primary.
- `LlamaServerAdapter` for fallback.
- `run` command.
- Qwen3-0.6B smoke parity.
- Gemma-4 E4B tool-call parity.
- results under `bench/engine-parity/results/`.

Then daemon text path:

- `conversation.inject_text`
- streamed token events
- normalized tool-call event, but no tool execution yet

### Phase E — Swift frontend bridge

Add default-off bridge while keeping current Swift pipeline intact.

Swift work areas:

- `DaemonConnection`
- `DaemonLifecycleManager`
- `DaemonCommandSender`
- `BackendEventRouter`
- feature flags:
  - `useDaemonLLM`
  - `useDaemonSTT`
  - `useDaemonTTS`
  - `useDaemonMemory`
  - `useDaemonScheduler`

Failure states:

- connecting
- connected
- reconnecting
- daemon offline
- daemon crashed
- degraded/local fallback

### Phase F — Voice loop

Sequence:

1. text-only daemon response;
2. daemon STT on fixture audio;
3. Swift captures audio and streams to daemon;
4. daemon returns transcript + response;
5. TTS playback through existing Swift path first;
6. daemon TTS later after voice parity;
7. interruption/barge-in acceptance.

Voice gates:

- STT correctness on unguessable clips;
- first-token/first-audio latency budget;
- TTS voice identity recognition;
- stop/barge-in reliability;
- no hidden mic capture without visible state/audit.

### Phase G — Memory bridge

Order:

1. Rust preflight tool against copied DB.
2. Backup/restore proof.
3. Read-only memory query from daemon.
4. Shadow recall comparison against Swift.
5. Write path only after owner signoff.

Memory write remains blocked until:

- schema compatibility proven;
- audit entries proven;
- supersession lineage preserved;
- rollback demonstrated;
- adversarial provenance/PII/query-probing controls exist.

### Phase H — Tools and Apple integrations

Apple MVP should keep existing Swift Apple integrations initially. Do not reimplement EventKit/Contacts/Mail/Notes in Rust via `objc2` until local daemon security is mature.

Sequence:

1. daemon emits proposed tool call;
2. Swift existing ToolExecutor handles approval/execution;
3. add TrustedActionBroker/capability tickets;
4. only then consider daemon-side tools;
5. `objc2` replacement is post-MVP unless clearly safer.

## Commit blockers

- G2 real parity not complete.
- `daemon-control-plane.md` still a stub until reviewed.
- TrustedActionBroker / CapabilityTicket scaffold missing.
- G4 migrator/preflight/rollback not implemented.
- G5 enforcement not implemented for peer/network features.

## Pre-v1 blockers

- model checksum/signature verification;
- signed daemon update story;
- voice identity parity;
- supply-chain audit for model/runtime downloads;
- adversarial memory resilience;
- complete failure/recovery validation for Swift frontend + daemon.

## Immediate next work packages

1. **G2-real:** implement real `bench/engine-parity` adapters and run smoke parity.
2. **Control-plane-final:** complete `daemon-control-plane.md` with authZ matrix and red-team signoff.
3. **Daemon-skeleton:** create `fae-protocol` + `fae-daemon` with ping/status only.
4. **Swift-bridge:** add default-off daemon connection/lifecycle scaffolding.
5. **Memory-preflight:** implement copy-only DB preflight/backup tool.

## Recommended first implementation slice

Do **G2-real** first. It is the highest-leverage blocker and does not require touching production Swift paths. Success proves the engine/fallback claim; failure prevents overbuilding around a false fallback assumption.
