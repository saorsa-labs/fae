# Fae headless-core (`crates/`) — Phase 1

Production Rust workspace for the cross-platform Fae daemon. Authorized by owner
sign-off 2026-06-02 (see `docs/architecture/headless-core-impl-plan-2026-06-01.md`).

**Greenfield daemon shell + selective ports** (per `docs/architecture/legacy-reuse-audit.md`)
— *not* a `legacy/rust-core` rollback. **Control-plane-first**: the authorization
core lands fully tested before any network surface exists.

## Crates

| Crate | Role | Status |
|---|---|---|
| `fae-control-plane` | Transport-free security core: capability scopes, per-command authorization, anti-DNS-rebind `Host`/`Origin` checks, CSPRNG session tokens (hashed at rest, constant-time verify), audit. | **Chunk 1 ✅** (tested) |
| `fae-envelope-gate` | G5 peer-envelope gate (promoted from `phase0/g5-envelope-gate`, reviewed): typed, closed-`kind`, schema-versioned, signature-checked, audited boundary. No free-form peer text reaches LLM/memory/tools. | **Chunk 1 ✅** (tested) |
| `fae-engine` | Engine-agnostic inference boundary: `ProviderAdapter` trait (`stream_chat` → Token/ToolCall/Done events) + **fail-closed `models.lock`** SHA-256 loader + `MockAdapter` + **`LocalMistralrsAdapter`** (mistral.rs 0.8, hard dep, Metal/CPU). | **Chunk 3a–b ✅** (tested) |
| `fae-audio` | Portable cpal voice spine for daemon-side PTT capture/playback: device listing, 16 kHz mono WAV capture output, WAV playback, and deterministic unit-tested WAV/resampling helpers. | **P1 ✅** (macOS live-tested) |
| `fae-daemon` | Daemon binary. Bootstrap (run dir `0700`, token `0600`) + **Unix-socket NDJSON listener** (default) and an **opt-in TCP-loopback HTTP/WS diagnostic listener** (`FAE_DIAGNOSTIC_TCP_PORT`): per-connection/per-request auth, `Host`/`Origin` enforcement, defensive headers, single-use stream tickets, per-message `authorize`, fail-closed audit. Hosts the **governed ToolHost** (`toolhost.execute`/`set_root`: read/write/edit/bash/glob/grep behind control-plane + damage-control + OS isolation — seatbelt/Landlock) and the **SkillHost** (`skillhost.list`/`activate`/`run`: SHA-256-integrity'd skills whose `uv run --script` commands route through the SAME governed bash path). Per-call `ToolOrigin` drives the isolation tier — autonomous origins require the jail (fail-closed). | **Chunk 2 ✅** (live-tested) · **ToolHost/SkillHost exec ✅** (headless-proven in `ci-linux.yml`) |

## Build / test
```bash
cd crates
just check          # fmt + clippy -D warnings + tests
just run            # bootstrap + demo authz (no ports opened)
```

## Guardrails (enforced)
- `#![forbid(unsafe_code)]` in every crate.
- `#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used, clippy::panic))]` — no `unwrap`/`expect`/`panic!` in non-test code.
- `just check` = `cargo fmt --check` + `clippy -D warnings` + tests.

## Roadmap (each gated by `fae-control-plane`)
- **Chunk 2 ✅ — network surface** (ADR-002 protocol v2):
  - **2a ✅ — Unix-socket NDJSON listener:** per-connection token auth, per-message `authorize()`, read-only dispatch stub, fail-closed audit, socket `0600`.
  - **2b ✅ — stream-ticket logic (pure, in `fae-control-plane`):** issue + replay cache, single-use, ≤60 s, endpoint/scope-bound (no `?token=`).
  - **2c ✅ — TCP-loopback HTTP/WS diagnostic listener** (opt-in via `FAE_DIAGNOSTIC_TCP_PORT`, `127.0.0.1`+`[::1]`): `Host`/`Origin` anti-rebind, defensive headers (nosniff/no-store/CSP), bearer-auth `GET /v1/status` + `POST /v1/ticket` (no scope escalation), WS `GET /v1/stream/<name>` consuming a single-use ticket via `Sec-WebSocket-Protocol`, per-message `authorize` reusing the shared session core. *(SSE + macOS Keychain for the bootstrap secret carried to a follow-on.)*
- **Chunk 3 — engine adapter** (mistral.rs is a hard dep, per owner decision; not feature-gated):
  - **3a ✅ — `fae-engine`:** `ProviderAdapter` trait + types, fail-closed `models.lock` SHA-256 loader, `MockAdapter`.
  - **3b ✅ — `LocalMistralrsAdapter`** (mistral.rs 0.8): `load_text` via `TextModelBuilder` + Q4K ISQ, `stream_chat` re-emitting `Response` chunks as `ChatEvent`s (S13-validated mapping). Accel target-conditional (Metal/CPU).
  - **3c ✅ — wired `conversation.inject_text`:** `dispatch`/`handle_frame` are async; an `Arc<dyn ProviderAdapter>` is threaded through both transports; the turn is collected into `{text, tool_calls, finish_reason}`. Real model loads via `FAE_MODEL_ID` (else mock echo). Live-verified end-to-end.
  - **3d — llama.cpp fallback** (G2-proven) behind the same `ProviderAdapter`.
  - **Follow-on:** stream events live (`conversation.subscribe`) instead of collecting; gate model load on `models.lock` verification.
- **Carried (gate features, not chunks):** adversarial-memory enforcement (W3), supply-chain `models.lock`/signed-updates (W4), peer-tool design, metadata threat-model sign-off. Peer-memory / peer-tool / group paths stay blocked until G5 is enforced in code (+ groups: TreeKEM). CUDA-perf + Gemma-4-12B + same-weights parity = early-Phase-1 tasks on a GPU box.

## Wired (execution)
Native **tool execution** (`read`/`write`/`edit`/`bash`/`glob`/`grep` via fluers, governed by the ToolHost) and **skill execution** (integrity-verified skills run via `uv run --script` through the same governed bash path, jailed per `ToolOrigin`) are wired and **headlessly proven end-to-end on Linux** (`ci-linux.yml` → `fae-daemon --headless-tool-test`, which also negative-proves the OS jail confines a jailed write to the workspace root).

## Not yet wired
Memory (`fae.db` migration — G4), pipeline, scheduler, Apple tools (`objc2`), x0x — all selective ports/rewrites per the G3 audit, behind this control plane. Daemon TTS and cpal capture/playback are wired as local control-plane commands; Swift still owns the default macOS mic/speaker lane until the portable lane is promoted. Skill *discovery/execution* is wired (above); the Swift scheduler/proactive callers that would drive autonomous (jailed) skill runs over the protocol are the remaining seam.
