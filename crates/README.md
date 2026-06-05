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
| `fae-daemon` | Daemon binary. Bootstrap (run dir `0700`, token `0600`) + **Unix-socket NDJSON listener**: per-connection token auth → `ClientRecord`, per-message `authorize`, read-only dispatch stub, fail-closed audit. No TCP port opened. | **Chunk 2a ✅** (live-tested) |

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
- **Chunk 2 — network surface** (ADR-002 protocol v2):
  - **2a ✅ — Unix-socket NDJSON listener:** per-connection token auth, per-message `authorize()`, read-only dispatch stub, fail-closed audit, socket `0600`.
  - **2b — stream-ticket logic (pure, in `fae-control-plane`):** issue + replay cache, single-use, ≤60 s, endpoint/scope-bound (no `?token=`).
  - **2c — TCP-loopback + WS/SSE diagnostic listener:** consumes 2b tickets; `Host`/`Origin` enforcement; defensive headers; peer input only via `fae-envelope-gate`; macOS Keychain for the bootstrap secret.
- **Chunk 3 — engine adapter:** `ProviderAdapter` (port `LocalMistralrsAdapter` 0.7→0.8); E4B + Qwen3-14B (eval Gemma-4-12B); **llama.cpp fallback** (G2-proven); `models.lock` fail-closed checksum loader.
- **Carried (gate features, not chunks):** adversarial-memory enforcement (W3), supply-chain `models.lock`/signed-updates (W4), peer-tool design, metadata threat-model sign-off. Peer-memory / peer-tool / group paths stay blocked until G5 is enforced in code (+ groups: TreeKEM). CUDA-perf + Gemma-4-12B + same-weights parity = early-Phase-1 tasks on a GPU box.

## Not yet wired
Memory (`fae.db` migration — G4), pipeline, skills, scheduler, TTS/STT, Apple tools (`objc2`), x0x — all selective ports/rewrites per the G3 audit, behind this control plane.
