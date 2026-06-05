# Legacy Rust Core Reuse Audit (G3) — 2026-06-01

> Phase 0 artifact for `docs/architecture/headless-core-impl-plan-2026-06-01.md` G3. This is an evidence-backed audit of `legacy/rust-core/`; it does **not** approve broad production implementation.

## Verdict

**Revival is useful, but not as a wholesale rollback.** The legacy Rust core is a strong source of prior art for protocol shape, provider abstraction, tool/security concepts, audio/TTS pieces, and x0x ingestion. It should be mined module-by-module into a new headless daemon. A literal rollback of `legacy/rust-core/ROLLBACK.md` over the Swift app is **wrong**.

**Cheaper-than-greenfield?** Yes for a **thin, selective revival** of proven modules and interfaces; no for a full resurrection. The most realistic path is a greenfield daemon shell with selective ports of legacy modules.

## Evidence inspected

- `docs/adr/002-embedded-rust-core.md` — superseded embedded C-ABI architecture, not the new headless daemon.
- `legacy/rust-core/Cargo.toml`, `legacy/rust-core/README.md`, `legacy/rust-core/ROLLBACK.md`.
- `legacy/rust-core/src/**` inventory: ~90k LOC Rust, including `fae_llm`, `host`, `pipeline`, `memory`, `skills`, `scheduler`, `audio`, `tts`, `x0x_listener`.
- Current Swift runtime guardrails in `AGENTS.md` and current memory files under `native/macos/Fae/Sources/Fae/Memory/`.

## Module reuse table

| Legacy area | Approx LOC | Verdict | Rationale | Action |
|---|---:|---|---|---|
| `host/` command/event protocol | ~7,950 | **Port** | ADR-002 protocol concepts and leader/SLO discipline are directly relevant, but embedded assumptions need replacing with daemon transport. | Port contract/types into daemon v2; do not copy IPC/C-ABI assumptions blindly. |
| `fae_llm/` provider/agent/tools | ~31,678 | **Port selectively** | Contains provider abstraction, tool schema, agent loop concepts. Large and likely stale vs current Swift behavior and mistral.rs 0.8. | Extract `ProviderAdapter` shape and tool-call normalization; rewrite integration around current engine harness. |
| `llm/` + local/mistral provider pieces | ~1,103 plus adapter files | **Port** | Directly supports G2 fallback proof and Rev 13 engine decision. API drift 0.7→0.8 is known from S13. | Port into `bench/engine-parity/` first, then daemon after G2 passes. |
| `pipeline/` | ~6,412 | **Port concepts / rewrite coordinator** | Useful message types and pipeline coordination, but current voice UX and Swift runtime have evolved. | Reuse message contracts; rewrite coordinator for headless daemon and new local control plane. |
| `audio/` | ~1,408 | **Port / validate** | `cpal`, AEC, capture/playback pieces are relevant cross-platform. Needs live validation and barge-in design. | Port after voice parity gate; test per platform. |
| `tts/kokoro/` | ~1,181 | **Port / validate** | Cross-platform Kokoro/ONNX path is relevant but voice identity is unproven. | Keep behind voice parity kill criterion. |
| `memory/` | ~6,285 | **Mostly rewrite against Swift schema** | Legacy memory is JSONL/SQLite but current Swift memory is production-critical, schema v9, audit/supersession semantics. | Do not revive legacy store as source of truth; implement Rust access to current `fae.db`. |
| `scheduler/` | ~3,611 | **Port concepts** | Scheduler authority is relevant, but current Swift `FaeScheduler.swift` is newer and production truth. | Port job model only after G4 memory/scheduler semantics are mapped. |
| `skills/` | ~10,593 | **Port selectively** | Python runner, health monitor, and skill lifecycle are useful, but current Swift Python/uv integration is authoritative. | Reconcile with `UVRuntime.swift` and current skill health rules. |
| `credentials/` | ~1,640 | **Port selectively** | Keychain/plaintext credential references are useful. | Reuse only if compatible with current Swift/macOS keychain and cross-platform secret storage. |
| `channels/` + `gateway.rs` | ~1,736 | **Defer / rewrite** | Webhook channel gateway has bearer-token support but is not core to Phase 1. | Defer until channel feature parity is required. |
| `x0x_listener.rs` | 557 | **Rewrite with current x0x auth** | Trusted-only + envelope-wrap + rate limits are useful, but it hardcodes `http://127.0.0.1:12700` and does not send current x0x bearer auth. | Rewrite around current x0xd local-control-plane model and G5 schema. |
| `ffi.rs`, `include/fae.h`, `linker_anchor.rs` | ~572+ | **Stale / do not reuse** | Embedded C-ABI path is explicitly superseded and conflicts with headless daemon shape. | Archive only. |
| `platform/macos.rs`, `permissions.rs`, `approval.rs` | ~1k | **Port concepts** | Permission/approval ideas useful; current Swift UX and future `objc2` path need fresh implementation. | Re-spec before porting. |
| `update/`, `doctor/`, diagnostics | ~4k | **Port selectively** | Operational diagnostics are valuable for daemon lifecycle. | Use after local control-plane and packaging design. |

## Required follow-up before Phase 1

1. Produce a thin daemon skeleton design that imports only selected modules.
2. Run G2 engine parity before porting provider code into production.
3. Complete G4 so memory code targets current Swift `fae.db`, not legacy stores.
4. Complete G5 before reviving `x0x_listener` or any peer-to-memory path.
5. Explicitly delete/ignore embedded C-ABI revival paths from Phase 1 scope.

## Decision

G3 is **partially satisfied as an audit artifact**, with this condition: the approved implementation path is **selective revival into a new headless daemon**, not full rollback. If later evidence shows the selected modules cannot port cleanly, pivot to a thinner greenfield daemon while preserving the protocol and adapter lessons.
