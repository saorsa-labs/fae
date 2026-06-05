# Phase 0 clearing status — 2026-06-01

Purpose: track the active Phase 0 gate-clearing plan. No Phase 1 production daemon, Swift bridge, memory writer, tool ownership, or peer/network feature work is approved until this gate exits and the owner signs off.

## Executive status

**Gate-exit ready: no.**

We have made meaningful progress: **W1 now has a real local two-engine tool-call PASS**, **W2 is accepted for Phase 0**, and **W3 is complete as design**. Remaining work is W4 supply-chain/metadata, W5 hygiene, and W6 replication/waiver.

## Workstream table

| Workstream | Status | Blocker class | Evidence grade | Missing / blocker |
|---|---|---|---|---|
| W1 — G2 fallback proof | **Done for first tool-call parity proof** | commit-blocker | measured-locally + repo-verified artifact | Caveat: not same-exact-model parity; Gemma-4 E4B run timed out; non-tool text case still recommended before v1. |
| W2 — daemon control-plane + G5 enforcement scaffold | **Done for Phase 0** | commit-blocker | repo-verified scaffold + local validation + red-team/oracle re-review + owner residual-risk signoff | Production G5 remains future work; Phase 0 W2 risk accepted by owner. |
| W3 — G4 adversarial memory + directive | **Done as Phase-0 design** | pre-v1-blocker | repo-verified design | Implementation still blocked on G4 preflight/backup/migrator proof. |
| W4 — supply chain + metadata sign-off | **Done for Phase 0** | pre-v1-blocker | repo-verified design + local x0x docs/changelog verified + red-team/oracle review + owner residual-risk signoff | Implementation remains pre-v1. |
| W5 — hygiene | **Done** | acceptable-debt / cleanup | repo-verified | S13 spike harness excluded unless owner asks to retain/clean. |
| W6 — G1 independent replication | Blocked / delegate | commit-gate unless waived | measured-locally only | Re-run S13 on other hardware/OS or get explicit owner waiver. |

## W1 evidence

Artifacts:

- `bench/engine-parity/results/qwen06-mistral-qwen36-llama.json`
- `bench/engine-parity/results/qwen06-mistral-qwen36-llama.md`
- `phase0/W1-g2-fallback-proof-status.md`

Result:

- Primary: `mistral.rs` with `Qwen/Qwen3-0.6B`
- Fallback: live `llama-server` on `127.0.0.1:62447` with `qwen-3.6-dense-8bit`
- Same prompt/tool schema: `weather-tool-paris`
- Both normalized to: `get_weather({"city":"Paris"})`
- `engine-parity check`: PASS

Validation passed:

```bash
cargo fmt --manifest-path bench/engine-parity/Cargo.toml
cargo clippy --manifest-path bench/engine-parity/Cargo.toml --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo check --manifest-path bench/engine-parity/Cargo.toml --all-targets
cargo run --manifest-path bench/engine-parity/Cargo.toml -- check bench/engine-parity/fixtures/weather-tool-call.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- render bench/engine-parity/fixtures/weather-tool-call.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- check bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- render bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
```

## W2 progress

`docs/architecture/daemon-control-plane.md` has been expanded from a stub into a concrete Phase-0 security design covering:

- loopback IPv4 + IPv6 only;
- Unix socket path with `0700` parent and restricted socket/token files;
- per-client capabilities, not daemon-wide auth;
- token entropy, expiry, rotation, revocation;
- Host/Origin validation and anti-DNS-rebind;
- WS/SSE auth via short-lived ticket, not URL query tokens;
- per-message authorization;
- audit rows for denies and high-risk actions;
- emergency lockout / panic mode.

A Phase-0 G5 enforcement scaffold now exists at `phase0/g5-envelope-gate/` with:

- closed `EnvelopeKind` enum;
- `schema_version` gate;
- `serde(deny_unknown_fields)` envelope/signature structs;
- signature-verify hook/stub;
- JSONL audit writer;
- tests for unknown kind reject, wrong schema reject, signature rejection, valid envelope audited, and peer text only exposed via policy-review wrapper.

Validation passed:

```bash
cargo fmt --manifest-path phase0/g5-envelope-gate/Cargo.toml
cargo clippy --manifest-path phase0/g5-envelope-gate/Cargo.toml --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test --manifest-path phase0/g5-envelope-gate/Cargo.toml
```

Initial red-team/oracle review found two W2 blockers: rejected envelopes were not audited, and accepted wrappers exposed raw payload through `envelope()`. Both were patched:

- added `gate_and_audit`, which writes audit records for accepted and rejected envelopes before returning;
- made `PeerEnvelope`/`SignatureProof` fields private;
- removed public raw-envelope accessor from `AcceptedEnvelope`;
- added `rejected_envelope_is_audited` test;
- tightened daemon design around literal loopback Host rules, socket permissions, and WS/SSE ticket replay cache.

Post-patch validation passed:

```bash
cargo fmt --manifest-path phase0/g5-envelope-gate/Cargo.toml
cargo clippy --manifest-path phase0/g5-envelope-gate/Cargo.toml --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test --manifest-path phase0/g5-envelope-gate/Cargo.toml
```

W2 re-review result:

- red-team: B1/B2 resolved; no new blockers; remaining items acceptable Phase-0 debt or production follow-ups.
- oracle: W2 can be considered cleared pending owner residual-risk signoff; no drift into Phase 1 production code.

W2 owner signoff: accepted by owner in-session: “Ok on W2 risk, lets move on to W3.” W2 is done for Phase 0. Production G5 remains future work.

## W3 progress

Deliverables:

- expanded `docs/architecture/memory-migration-plan.md` with adversarial memory resilience;
- added `docs/architecture/directive-and-soul-migration.md`;
- added `docs/templates/directive.md`;
- added `phase0/W3-adversarial-memory-status.md`.

W3 now defines provenance, data-class boundaries, inbound PII/exfil scan requirements, query-probing defense, directive/SOUL/HEARTBEAT migration, legacy source classification, W3-specific validation tests, and the required kill criterion:

> Peer-sourced memory must not influence system/developer prompts without user review + data-class upgrade.

W3 remaining blocker: implementation is still pre-v1; Rust memory writes remain blocked until preflight/backup/rollback tooling is tested on copied data.

## W4 progress

Deliverables:

- `docs/security/model-supply-chain-and-updates.md`;
- `docs/security/x0x-metadata-threat-model.md`;
- `docs/templates/models.lock.example`;
- `phase0/W4-supply-chain-metadata-status.md`.

W4 now defines `models.lock`, SHA-256/source-revision requirements, fail-closed model loading, tool/runtime verification, signed daemon/app updates, downgrade protection, emergency revocation, presence default `off`, HMAC topic derivation, metadata exposure matrix, ant-quic MASQUE relay policy for IP masking, and owner signoff line.

The new x0x secure-groups work is incorporated: x0x `v0.20.0`/ADR-0012 TreeKEM secure groups improve future confidential content transport, but they do not remove Fae metadata, consent, audit, provenance, or prompt-isolation gates.

W4 review result: red-team/oracle review found no hard design blockers. Red-team requested an owner residual-risk signoff line in the supply-chain doc; this was patched. Owner accepted the W4 security consideration in-session. W4 is done for Phase 0; implementation remains pre-v1.

## W5 progress

Deliverables:

- patched `docs/architecture/cross-platform-engine-plan-2026-05-30.md` §20 stale engine recommendation;
- patched `docs/architecture/headless-core-impl-plan-2026-06-01.md` housekeeping note;
- marked `phase0/apple-plan/meta-prompt.md` non-authoritative;
- added `phase0/W5-hygiene-status.md`.

Decision: `bench/mistralrs-eval/` remains a throwaway S13 spike harness and is excluded from the reviewable Phase 0 patch unless explicitly retained and cleaned. The validated G2 code is `bench/engine-parity/`.

## Gate-exit checklist

- [x] W1 first real tool-call parity PASS
- [x] W2 reviewed control-plane design + enforcement scaffold — owner residual-risk signoff accepted
- [x] W3 adversarial-memory/directive docs complete
- [x] W4 supply-chain/metadata docs reviewed — owner residual-risk signoff accepted
- [x] W5 hygiene complete
- [ ] W6 independent replication or explicit owner waiver

**Gate-exit ready: no — W6 remains.**
