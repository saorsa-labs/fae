# Team prompt — clear Phase 0, then stop (2026-06-01)

> Hand this to the team/agents working the Fae headless-core pivot.
> **Build is NOT approved.** Your job is to clear the Phase 0 commit-gate to the point an owner can sign off — **not** to start Phase 1 production code.

## State (read first)
- **What's proven:** the engine. S13 measured on Apple Silicon (`bench/mistralrs-eval/`): mistral.rs builds in-process on Metal; Gemma-4 E4B generates ~65 tok/s with **tool calling** and **unified audio-in STT**; **Qwen3-14B dense** heavy driver runs (~42 tok/s). Gemma-4 26B-A4B MoE **fails** in candle/mistral.rs (gather gap) → dense, not MoE.
- **What's designed + adversarially validated:** the Rev-13 plan + Phase 0 gate (`docs/architecture/headless-core-impl-plan-2026-06-01.md`). Reviewer = PASS-with-conditions; red-team = GO-WITH-CONDITIONS (4 commit-gates + 6 pre-v1 blockers); oracle = NO-GO production / GO Phase-0-only.
- **What does NOT exist yet:** any production daemon, pipeline, engine integration, UX client, x0x integration, or enforcement code. Production code = **0%**. The only Rust written is the throwaway S13 harness + a partial G2 harness.

## Hard rules
1. **No Phase 1 production code** until the commit-blockers below clear AND the owner signs off the gate.
2. **No wholesale `legacy/rust-core/` rollback.** Per the G3 audit it's selective port + significant rewrite; the C-ABI/FFI path is archival. Do **not** port `x0x_listener.rs` as-is (its string "safety envelope" is bypassable).
3. **Rust guardrails apply** to anything you commit: no `.unwrap()`/`.expect()`/`panic!` in non-test code, rustfmt-clean, clippy `-D warnings`, `just check` passes. (The S13 spike harness violates this — exclude it from any patch or clean it.)
4. **Grade everything:** each claim gets an evidence grade (`independently-replicated` / `measured-locally` / `repo-verified` / `single-source` / `speculative` / `contradicted-stale`); each concern gets a blocker class (`commit-blocker` / `pre-v1-blocker` / `post-v1-risk` / `acceptable-debt`).

## Workstreams to clear Phase 0 (priority order)

### W1 — G2 fallback proof (COMMIT-BLOCKER, highest leverage)
The harness exists (`bench/engine-parity/`) but has **never run and has no results**, and only has a `LlamaServerAdapter`.
- Wire a real **mistral.rs** path (reuse `bench/mistralrs-eval`'s `LocalMistralrsAdapter` pattern) so both engines run the **same prompt + same tool schema**.
- Produce a **PASS**: equivalent normalized tool call (e.g. `get_weather({"city":"Tokyo"})`) from mistral.rs (primary) AND llama-server (fallback), written to `bench/engine-parity/results/`.
- Decide + document **HTTP llama-server vs FFI** for the fallback (plan assumes HTTP).
- **Done =** a committed results file + `engine-parity check` returning PASS. Until then the fallback is aspirational and the mistral.rs single-maintainer/candle risk is unhedged.

### W2 — Daemon control-plane + G5 enforcement scaffold (COMMIT-BLOCKER)
`daemon-control-plane.md` exists as requirements; there is **no enforcement code**.
- Finalize the control-plane design (loopback bind incl. `::1`, Unix-socket `0600` + path, token entropy/rotation/revocation, **per-client capability scopes** not daemon-wide auth, CORS literal-origin, **anti-DNS-rebind `Host` validation**, WS/SSE auth without `?token=` URL leakage).
- Scaffold the **G5 envelope gate**: typed parser with a **closed `kind` enum**, `schema_version` gate, signature-verify hook, and an **audit-record write path** (every inbound peer envelope → structured audit row). Adversarial-exfil tests may be stubbed but must be ticketed with owner acceptance.
- **Done =** reviewed control-plane doc + compiling enforcement scaffold with the closed-enum parser and audit writer (no free-form peer text reaching the LLM).

### W3 — G4 adversarial-memory + directive (PRE-V1-BLOCKER, do now as design)
Extend `memory-migration-plan.md` with an **Adversarial memory resilience** section: `provenance` field per record (`user`/`peer:<id>`/`skill:<id>`/`inferred`), peer facts default to `shareable_context` data class, inbound PII/exfil scan before write, query-probing rate-limits/logging, skill-provenance. Add explicit **`directive.md`** + soul migration. Add the kill criterion "peer-sourced memory must not influence system/developer prompts without user review + data-class upgrade."

### W4 — Supply-chain + metadata sign-off (PRE-V1-BLOCKERS, design docs)
- `models.lock` / manifest with SHA-256 (+ source repo/commit) for every GGUF/ONNX/safetensors; **fail-closed loader** design. uv/tool binary checksum verification. Signed-daemon-update threat model (minisign/sigstore + revocation).
- Complete `docs/security/x0x-metadata-threat-model.md` with per-exposure residual risk + **owner sign-off line**; presence default `off`.

### W5 — Hygiene (cheap, finish)
- Reconcile the **last** stale "llama-server default" line (§20 of the plan) to mistral.rs-primary.
- Mark `phase0/plans/meta-prompt.md` non-authoritative (it over-asks Rust memory impl).
- Decide whether the S13 spike harness is in the patch; if yes, make it guardrail-clean.

### W6 — G1 independent replication (needs other hardware → delegate)
Re-run `bench/mistralrs-eval/` on **≥1 other machine + ≥1 other OS** (ideally a Linux/CUDA box). Confirm build/E4B/tools/audio/Qwen3-14B + record tok/s → `docs/spikes/S13-replication.md`.

## Gate-exit (what "Phase 0 done" means)
All of: W1 PASS · W2 reviewed design + enforcement scaffold · W3/W4 design docs complete + ticketed · W5 done · W6 replicated (or owner explicitly accepts single-machine evidence) · G6 already scoped out. **Then** present to the owner for sign-off to authorize Phase 1. **Do not begin Phase 1 production code before that sign-off.**

## Deliverable from you
A short status note: per-workstream `done / in-progress / blocked`, evidence grade + blocker class per item, and an explicit **"gate-exit ready: yes/no + what's missing."** No production implementation handoff unless the owner signs the gate.
