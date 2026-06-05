# Team prompt — close W6, exit the gate, start Phase 1 (2026-06-02)

> Hand this to the team/agents. Phase 0 is **nearly cleared**: W1–W5 are done with real, verified artifacts.
> **One gate remains (W6 = independent replication).** After W6 + owner sign-off, begin Phase 1 — **not before.**

## State (verified)
- **W1/G2 — PASS, real:** `bench/engine-parity/results/qwen06-mistral-qwen36-llama.json` — mistral.rs (in-process) and live `llama-server` both emit the equivalent `get_weather` tool call. Fallback realism is demonstrated, not aspirational.
- **W2 — real enforcement code:** `phase0/g5-envelope-gate/` (closed `EnvelopeKind` enum, `deny_unknown_fields`, schema gate, `AuditRecord` + JSONL audit writer, `parse_and_gate`, 6 tests). Plus the reviewed `docs/architecture/daemon-control-plane.md`.
- **W3/W4 — designs complete:** adversarial-memory section in `memory-migration-plan.md`; `docs/security/{model-supply-chain-and-updates,x0x-metadata-threat-model}.md`.
- **W5 — hygiene done:** no `llama-server default` left; scratch prompts marked non-authoritative.
- **W6 — REMAINS:** S13 has only run on Apple Silicon (incl. the M5 Max G2 run). No non-Apple/OS replication yet.

## W6 — Independent replication on DigitalOcean (the last gate)
**Goal:** prove the engine claims hold on **another machine AND another OS** (Linux), and validate the **CUDA path** Fae targets.

1. **Provision a DO droplet.** Preferred: a **GPU droplet (NVIDIA, CUDA)** for real tok/s + CUDA validation; acceptable fallback: a **CPU droplet** for *correctness-only* (build + generate + tool call + parity PASS; tok/s will be slow and is not the point). Record exact instance type + specs.
2. **Build + run** (re-fetches candle; ~minutes): `bench/mistralrs-eval/` and `bench/engine-parity/`.
   - Confirm: mistral.rs builds on Linux (CUDA feature, not `metal`); **Gemma-4 E4B** generates + tool calling + **audio STT**; **Qwen3-14B dense** runs. Record tok/s.
   - Re-run the **G2 parity** case on Linux → committed PASS.
3. **Bonus (high value, cheap):** smoke-test that the **x0x crate builds + `x0xd` runs on Linux** (it's a v1 target OS) — flags any Linux gaps early.
4. **Record:** `docs/spikes/S13-replication.md` (instance, OS, CUDA version, build result, per-model tok/s, parity PASS, x0x build result).
5. **Guardrails:** the throwaway `bench/mistralrs-eval` may be used for evidence but **must not enter the reviewable patch** unless cleaned (it has `.unwrap()`s).

**Note on G2 (strengthen, not block):** the current PASS proves *both engines tool-call equivalently for the same task* — but used **different models** per engine (Qwen3-0.6B vs qwen-3.6-dense). For true fallback *interchangeability* (mistral.rs dies mid-task → llama.cpp resumes the **same** model), add one parity case with **identical weights on both engines** (a GGUF that loads in mistral.rs AND llama-server). Do this during W6.

## Gate exit (owner sign-off)
Present to owner: W1–W5 verified + W6 replication (or an explicit owner waiver accepting single-platform evidence). **On sign-off, Phase 1 is authorized.** Until then: **no Phase 1 production code.**

---

## Phase 1 — implementation kickoff (ONLY after gate sign-off)
Follow `docs/architecture/headless-core-impl-plan-2026-06-01.md` + the **G3 audit**: this is a **greenfield daemon shell + selective ports**, NOT a `legacy/rust-core` rollback.

**Deliverable: a Rust daemon that answers a text turn end-to-end over an authenticated local socket, on mistral.rs, with the control-plane enforced.**

1. **New daemon crate** (greenfield shell). Do not `ROLLBACK.md`. Port only audited modules; rewrite `memory/`, scheduler, skills, and `x0x_listener` per G3 (do **not** port the legacy string envelope).
2. **Local control-plane FIRST** (it gates everything): implement `daemon-control-plane.md` — loopback bind (`127.0.0.1` + `::1`), Unix socket `0600`, token entropy/rotation/revocation, **per-client capability scopes**, CORS literal-origin, **anti-DNS-rebind `Host` validation**, WS/SSE auth without `?token=` URL leakage. Wire in the **W2 `g5-envelope-gate`** so peer/external input is parsed to a typed payload (closed `kind`) + audited before the LLM ever sees it. No free-form peer text reaches the model.
3. **ADR-002 command/event protocol v2** over WebSocket + Unix socket; scheduler-leader lease.
4. **Engine behind `ProviderAdapter`:** port `LocalMistralrsAdapter` 0.7→0.8 (trivial per S13); load **Gemma-4 E4B** (front) + **Qwen3-14B dense** (driver); **llama.cpp fallback** (proven in G2). Add the **`models.lock` fail-closed checksum loader** (W4) before any model load.
5. **Acceptance:** `conversation.inject_text` → streamed tokens + a tool call, on mistral.rs, meeting ADR-002 latency SLOs, with control-plane auth enforced and an audit row written. `just check` clean (no `.unwrap()`/`panic!` in non-test code; rustfmt; clippy `-D warnings`).

**Carried discipline:** pre-v1 blockers (W3 adversarial-memory enforcement, W4 supply-chain/metadata sign-off, peer-tool execution design) are tracked into their phases and **gate the features that depend on them** — e.g. no peer-memory or peer-tool path until the G5 gate + governance are *enforced in code*, not just designed. Group "the Fae" features stay hard-gated on TreeKEM + G5 (Phase 4).

## Deliverable from you each loop
Per-item `done/in-progress/blocked`, evidence grade + blocker class, and an explicit **"gate-exit ready / Phase-1 acceptance met: yes/no + what's missing."**
