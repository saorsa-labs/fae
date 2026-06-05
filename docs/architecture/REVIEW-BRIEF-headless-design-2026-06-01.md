# Review brief — Fae cross-platform headless-core design (meta-prompt)

> Paste the META-PROMPT block to your review team (human engineers, AI review agents, or `/review`).
> Goal: an **adversarial, evidence-checking** review of a major architecture pivot — **a review that cannot say "no" is ceremony.**
> Owner stance (2026-06-01): brief = **go, with the structure below added**. Build commit = **not yet** (see preconditions at the end).

---

## META-PROMPT (give this verbatim to each reviewer)

You are a senior reviewer evaluating a **major architecture pivot** for **Fae** — a voice-first, on-device AI companion (currently a pure-Swift macOS app on MLX). The proposal moves Fae to a **cross-platform headless Rust core** (macOS/Linux/Windows + mobile clients).

**Your job is to find what's wrong, weak, or unproven — not to approve. You are explicitly invited to conclude the entire pivot is wrong and defend that.** The authors are smart and motivated; your value is the objections they missed. Be specific; cite file/section.

### What to read (source of truth)
1. `docs/architecture/cross-platform-engine-plan-2026-05-30.md` — the plan (**Rev 13**). Read the revision history at top.
2. `docs/spikes/S13-mistralrs-eval.md` — the on-device benchmarks driving the engine decision.
3. Context: `docs/adr/002-embedded-rust-core.md` (the prior core this claims to revive); `../x0x`; `saorsa-mls`.

> ⚠️ **The plan has accreted 13 revisions and contains stale earlier language** (e.g. some sections still call `llama-server` the "default" engine). **Treat the Rev 13 header, §8a, and S13 as the authoritative engine decision (mistral.rs).** Flag every internal contradiction you find as a review finding — do not assume the latest is consistently applied.

### Decisions under review (challenge each)
1. **Headless Rust core daemon** owns the whole pipeline (audio, STT/LLM/TTS, memory, skills, scheduler, tools, security, self-learning); thin per-platform UX (Swift/Apple, Dioxus/Tauri elsewhere, mobile dock-wake). Claimed as a **revival of the *superseded* ADR-002 core** (code in `legacy/rust-core/`).
2. **Engine = mistral.rs** (pure-Rust candle, in-process, no sidecar); llama.cpp fallback behind a swappable `ProviderAdapter`. *S13 (measured, single machine): builds on Metal, Gemma-4 E4B ~65 tok/s, tool calling ✓, unified audio-in STT ✓.*
3. **Models:** Gemma-4 **E4B** front (STT+vision+chat+tools) + **dense Qwen3-14B** driver (~42 tok/s, tools ✓). **Dense not MoE** — Gemma-4 26B-A4B MoE **fails in mistral.rs** (candle `UnquantLinear::gather_forward` gap).
4. **Self-learning** app-layer (skills/memory/session-search/user-model, Hermes-parity), no v1 weight training; dialectic/ToM memory upgrade (Honcho/Zep/Mem0) as the "exceed" path.
5. **Networking = x0x** (Fae's PQC P2P net): phone↔home direct-QUIC RPC; Fae↔Fae groups via saorsa-mls. Group FS/PCS pending x0x wiring `saorsa-mls 0.3.6 TreeKemGroup` — **GSS-grade (no PCS) until then**.
6. **Apple integration in Rust** via `objc2`; Swift = UX only.
7. **TTS = Kokoro** via ONNX Runtime (`ort`) + `misaki-rs` G2P (voice-identity continuity).

### Required analysis structure (apply to EVERY claim and concern)

**(A) Grade the evidence** behind each claim you assess, using exactly one label:
`independently-replicated` · `measured-locally` (single machine) · `repo/source-verified` · `single-source` · `speculative` · `contradicted/stale`.
*(Note: S13 is `measured-locally` — strong, but single-machine, not universal truth.)*

**(B) Classify every concern** you raise as exactly one:
`commit-blocker` · `pre-v1-blocker` · `post-v1-risk` · `acceptable-debt`.
*(If everything reads as equally scary, the review failed.)*

### Where to push hardest
- **Revival must prove itself — demand a legacy reuse audit.** ADR-002 is explicitly *superseded* and describes an *embedded* core (C-ABI in-process), **not** the proposed headless daemon. For `legacy/rust-core/`, require: what's reusable **as-is**? what needs **porting**? what's **stale**? what must be **rewritten**? **And: is reviving it actually cheaper than a thin greenfield daemon?** Don't accept "we have prior code" as proof.
- **Fallback realism — demand a working demo, not an interface.** "`ProviderAdapter` exists" is not a fallback. Require a passing test: **same prompt + same tool schema → same tool call, same audio/STT path where applicable, mistral.rs as primary AND llama.cpp as fallback.** If that demo doesn't run, the fallback is aspirational and mistral.rs's single-maintainer/candle-correctness risk is unhedged.
- **mistral.rs / candle risk:** largely one maintainer; candle has shown correctness gaps (GGUF NEOX-RoPE #3410; the MoE-gather failure found in S13). Bet-the-engine sound? Exit if candle stalls?
- **Voice identity:** Kokoro-via-ONNX + `misaki-rs` (a 0.1.x G2P port) — does Fae still *sound like Fae* cross-platform? Unproven; demand a user-recognition/parity test.
- **x0x local-control-plane reality check:** do **not** attack a strawman “open localhost WebSocket.” Current `x0xd` inspection shows a stronger baseline: API binds to `127.0.0.1`, uses a generated bearer token stored `0600`, applies auth middleware to control-plane endpoints, restricts CORS to literal loopback origins, and unauthenticated `/agent` + `/ws` return `401`. Reviewers should instead verify Fae’s new daemon **matches or exceeds x0x’s local-control-plane model**. Remaining x0x/Fae gaps to judge: WS/SSE `?token=` URL leakage, daemon-wide rather than per-client capability auth, same-user local processes that can read the token, and legacy Fae `x0x_listener` code that must be updated to send bearer auth if revived.
- **Privacy/governance is a HARD GATE for any Fae↔Fae feature — TreeKEM alone is insufficient.** Require concrete answers before any group feature ships: **what data may cross instance boundaries? under what consent? what machine-enforced schema? what audit trail? what revocation model? what logging policy? what metadata leakage remains (gossip social-graph)?** Treat an unanswered item here as a `commit-blocker` for group features.
- **Local daemon attack surface:** the proposed Fae daemon owns mic, memory, tools, skills, scheduler, x0x identity, and model access. Require a control-plane design: loopback-only bind, bearer/token storage, CORS/origin policy, WebSocket/SSE auth, Unix-socket permissions if used, per-client capability grants, and defense against browser-origin/local-process attacks.
- **Peer-triggered tool calls:** if peer Fae messages can lead to tools, require whitelist-only tool exposure, strict input validation, rate limits, user confirmation for destructive actions, and audit logs. A compromised peer must not schedule, write, execute, exfiltrate, or mutate memory silently.
- **Adversarial memory resilience:** peer-sourced content must be treated as untrusted. Review poisoning, prompt-injection, query-based memory probing, skill provenance, skill sandboxing, and human-in-the-loop gates for durable memory writes from peers.
- **Voice biometric security:** if speaker ID gates approvals or sensitive actions, require replay/synthetic-voice threat modeling and parity testing of ONNX/Core ML speaker-ID paths.
- **Model/update supply chain:** require model checksum/signature verification, cache permissions, signed daemon updates, rollback, and compromise-recovery story.
- **Windows:** x0x is documented Linux/macOS-only; Dioxus desktop maturity for an always-on app is unproven. Either **scope Windows honestly out of v1** or give it **concrete acceptance criteria** — "cross-platform" hand-waving is a finding.
- **Model strategy:** is a 14B dense driver needed, or is E4B-only enough for v1? Is "dense > MoE for agentic" a real basis or a rationalization for the candle limitation?

### Kill criteria / reversal triggers (tell us if any are already true, or how to test them)
The design should be abandoned or materially reworked if:
1. **S13 cannot reproduce** on another machine/OS.
2. **mistral.rs↔llama.cpp fallback is not actually interchangeable** (the demo above fails).
3. **Kokoro voice identity fails** user-recognition/parity.
4. **`legacy/rust-core/` is materially less reusable** than claimed (audit shows mostly-rewrite).
5. **Windows support is not credible** for v1 and Windows is in-scope.
6. **TreeKEM / Fae↔Fae data-disclosure governance is not ready** when a group feature is proposed.
7. **Local daemon security boundary is not credibly defensible**: no client auth, no capability model, browser-origin exposure, or weak token storage.
8. **Fae↔Fae data-disclosure governance cannot be machine-enforced**: no schema gate, audit log, revocation path, or adversarial exfil testing.
9. **x0x metadata exposure is unacceptable** after threat modeling and no feasible mitigation/narrower peer scope exists.

### Deliverables (your output)
1. **Per-decision verdict** (each of the 7): `SOUND` / `RISKY (why)` / `WRONG (why + what instead)` — with an **evidence grade (A)** and **blocker class (B)**.
2. **Top 3 threats**, ranked, each with evidence grade + blocker class.
3. **Anything missing** — a capability, risk, cost, or simpler alternative the authors didn't consider.
4. **Sequencing critique:** is "ship 1:1 Fae↔Fae + E4B first, gate groups on TreeKEM, defer training" right? What first?
5. **Go / no-go / go-with-conditions** on committing to the headless-core build, with explicit conditions mapped to the kill criteria.
6. **Evidence/blocker table** — strongest claims and risks with evidence grade + blocker class.
7. **Kill criteria** — what findings would pause/cancel the headless-core pivot or force a narrower v1.

Be concise and high-signal.

---

## Owner's required preconditions BEFORE committing to the build (not part of the reviewer prompt)
Independent of the review verdict, the build will not start until all of:
1. **Independent S13 replication** (another machine/OS).
2. **Fallback proof** (the cross-engine equivalence demo above).
3. **Legacy Rust reuse audit** (reuse-as-is / port / stale / rewrite; cheaper-than-greenfield?).
4. **Memory migration / data-safety plan** (Swift `fae.db` → Rust core, no loss).
5. **Privacy governance gate for Fae↔Fae** (the 6 questions answered + enforced).
6. **Windows** either scoped honestly out of v1 **or** given concrete acceptance criteria.
7. **Local daemon control-plane design** matching or exceeding x0x: loopback bind, bearer/token storage, CORS/origin policy, WS/SSE auth, and per-client capability story.
8. **Fae↔Fae disclosure enforcement**: machine-enforced schema, consent, revocation, user-auditable transfer log, and adversarial exfil tests.
9. **x0x metadata threat model** with acceptable residual risk for presence, group discovery, bootstrap/relay visibility, and social-graph leakage.

## Notes for the human running the review
- Multi-agent: works with `/review`, `gsd-review`; for debate, `gsd-debate-review`.
- Highest-value reviewer action: **independently re-run one S13 benchmark** (`bench/mistralrs-eval/`; build artifacts were cleaned, `cargo build --release` re-fetches candle) on their own hardware.
- Evidence caveat to repeat: deep-research verification failed repeatedly this project; **the S13 on-device numbers are the reliable evidence**, the web-sourced architecture claims are not.
- x0x clarification from local inspection: current `x0xd` already uses a loopback-only, bearer-token-protected local control plane. Do not let reviewers attack a strawman “open localhost WS.” The review target is whether the **new Fae daemon** inherits or exceeds that model, and whether remaining gaps — query-token leakage, per-client capabilities, same-user token access, peer tools, memory disclosure, metadata leakage — are acceptable.
