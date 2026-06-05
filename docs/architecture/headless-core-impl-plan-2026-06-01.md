# Fae headless-core — implementation plan — 2026-06-01

> **Status:** **Phase 0 CLEARED — owner sign-off 2026-06-02. Phase 1 AUTHORIZED.** W1–W5 done + verified; W6 closed as *correctness-replicated* on Linux x86_64 (CUDA throughput deferred to early Phase 1 — see G1). Design source of truth: `cross-platform-engine-plan-2026-05-30.md` (Rev 13).
> **Carried gates (still binding):** pre-v1 blockers (W3 adversarial-memory enforcement, W4 supply-chain/metadata sign-off, peer-tool design) gate the *features that depend on them*, not Phase-1 start. Group "the Fae" features stay hard-gated on TreeKEM + G5 enforcement. Engine remains a means — don't fork candle.
> **Owner:** David Irvine. **Sequencing principle:** ship 1:1 + E4B first · gate groups on TreeKEM · defer training.

---

## 0. Phase 0 — Commit gate (validation only, no production code)

**Nothing in Phases 1–5 begins until the gates below pass or are explicitly scoped out by owner decision.** Each maps to a kill-criterion in the review brief.

| # | Gate | Concrete acceptance criteria | Output artifact |
|---|---|---|---|
| **G1** | **Independent S13 replication** | **CLEARED (correctness, 2026-06-02).** Replicated on a DO `c-32` Linux/x86_64 node: mistral.rs+candle **builds clean**; Qwen3-0.6B **generates + tool-calls identically to macOS**; Qwen3-14B dense **loads + generates** on Linux. **CUDA throughput + Gemma-4-E4B-audio-on-Linux + same-weights parity DEFERRED to early Phase 1** (DO had no GPU capacity; Gemma-4 gated). | `docs/spikes/S13-replication.md` ✅ |
| **G2** | **Fallback realism proof** | **CLEARED.** Real harness ran: mistral.rs (Qwen3-0.6B) **and** live `llama-server` both emit the equivalent `get_weather` tool call → committed **PASS**; `engine-parity check` returns PASS. *Strengthen in early Phase 1: a **same-weights** GGUF parity case (true hot-interchange).* | `bench/engine-parity/results/*.json` ✅ |
| **G3** | **Legacy Rust reuse audit** | Per-module table of `legacy/rust-core/`: **reuse-as-is / port / stale / rewrite**, with LOC estimates. Explicit verdict: **is revival cheaper than a thin greenfield daemon?** (If not, pivot to greenfield.) | `docs/architecture/legacy-reuse-audit.md` |
| **G4** | **Memory migration / data-safety plan** | How the Swift `fae.db` (SQLite/GRDB) + speaker profiles + soul/directive migrate to the Rust core **with zero loss**, reversibly, with a backup/restore path. | `docs/architecture/memory-migration-plan.md` |
| **G5** | **Privacy governance gate (Fae↔Fae + daemon security sub-gates)** | Answered AND enforceable: **what data may cross instance boundaries · under what consent · audit trail · revocation model · logging policy · residual metadata leakage.** Also includes review-brief preconditions 7–9: local daemon control-plane design, Fae↔Fae disclosure enforcement, and x0x metadata threat model. Start from `legacy/rust-core/src/x0x_listener.rs` only as prior art, not code to port as-is. | `docs/architecture/fae-to-fae-governance.md` + `docs/architecture/daemon-control-plane.md` + metadata threat model |
| **G6** | **Windows decision** | **Decision: Windows is out of v1.** v1 targets Apple + Linux only. Windows becomes a post-v1 workstream requiring x0x-on-Windows proof, daemon/audio/model runtime proof, installer/autostart/update proof, local-control-plane security, and Dioxus/Tauri always-on validation on real Windows. | this paragraph + future tracking issue |

**Also in Phase 0 (housekeeping, cheap):** reconcile stale Rev-4 engine language so the plan consistently reflects the Rev 13 mistral.rs decision. **W5 sweep completed:** the known §20 engine recommendation now says mistral.rs primary with llama.cpp/`llama-server` fallback. Any remaining contradictory Rev-4 wording should be treated as historical/stale and patched when encountered.

**Gate exit: ✅ OWNER SIGN-OFF 2026-06-02 — Phase 0 CLEARED, Phase 1 AUTHORIZED.** Final status: **G2 PASS** (real cross-engine parity), **G3** audit (selective port verdict), **G4/G5** designs + **G5 enforcement scaffold** (`phase0/g5-envelope-gate/`, 6/6 tests) + control-plane design, **G6** Windows scoped out of v1, **G1** correctness-replicated on Linux (CUDA-perf deferred). **Conditions carried into Phase 1:** (a) CUDA-perf validation + Gemma-4-E4B-audio-on-Linux + same-weights parity are **early Phase-1 tasks**; (b) pre-v1 blockers (W3 adversarial-memory enforcement, W4 supply-chain `models.lock`/signed-updates, peer-tool design, metadata threat-model sign-off) **gate the features that depend on them**; (c) any **peer-memory / peer-tool / group** path stays blocked until the G5 gate + governance are **enforced in code** and (for groups) TreeKEM lands.

---

## 1. Phase 1 — Core skeleton + engine (post-gate)

**Goal:** a Rust daemon that loads the engine and answers a text turn end-to-end over the local socket.

- **Revive** per the G3 audit — into a **branch/worktree**, not the main tree (don't run `ROLLBACK.md` over the Swift app).
- **Daemon scaffold:** tokio runtime; revive the **ADR-002 JSON command/event protocol (v2)**; **local transport = WebSocket + Unix socket**; scheduler-leader lease. (Reuse ADR-002's protocol/leader/SLO discipline.) **Blocked until `docs/architecture/daemon-control-plane.md` defines loopback/Unix-socket permissions, auth, CORS/origin policy, WS/SSE auth, and per-client capabilities.**
- **Engine behind `ProviderAdapter`** (the trait already exists in `legacy/rust-core/src/fae_llm/provider.rs`): port `LocalMistralrsAdapter` **0.7→0.8** (trivial per S13: `Delta.content: Option`, error-variant types, inherent `.next()`); load **Gemma-4 E4B** (front) + **Qwen3-14B dense** (driver); wire the **llama.cpp fallback** proven in G2.
- **Acceptance:** `conversation.inject_text` → streamed tokens + a tool call, on mistral.rs, meeting ADR-002 latency SLOs locally.

**Progress (2026-06-05) — greenfield `crates/` workspace, not a `legacy/rust-core` revival** (per the G3 verdict):
- **Chunk 1 ✅** — `fae-control-plane` (transport-free authz core: scopes, per-command `authorize`, anti-rebind `Host`, CSPRNG tokens hashed-at-rest + constant-time verify, audit) and `fae-envelope-gate` (G5 boundary, promoted from `phase0/`). `/code-review` hardening applied (signature-verifier test-gating, audited-only public gate entry, envelope size cap, atomic `0700`/`0600` bootstrap, non-secret audit ids).
- **Chunk 2a ✅ (live-tested)** — `fae-daemon` Unix-socket NDJSON listener: per-connection token auth → `ClientRecord`, per-message `authorize`, read-only dispatch stub (`host.ping`/`host.version`/`runtime.status`), fail-closed audit, socket `0600`. No TCP port. Pure `session::handle_frame` (7 unit tests) under a thin tokio shell. End-to-end verified: auth→ok, missing-scope deny, not_implemented fail-loud, bad-token→close, full audit trail with the token never logged.
- **Next:** 2b stream-ticket logic (pure, in control-plane); 2c TCP-loopback + WS/SSE diagnostic listener (`Host`/`Origin`, defensive headers, ticket consume, Keychain); then Chunk 3 engine adapter.

## 2. Phase 2 — Voice pipeline + parity

**Goal:** full local voice loop with Fae's identity intact.

- Pipeline: `cpal` capture → **Silero VAD** → speaker-ID gate → **STT** (E4B unified audio-in primary; **Parakeet `parakeet-rs` cascaded fallback**) → LLM (E4B fast / route hard turns to Qwen3-14B) → **TTS Kokoro (ONNX `ort` + `misaki-rs`)** → playback.
- **Voice parity gate** (kill-criterion #3): user-recognition/parity test on Kokoro+misaki-rs before it's the default; else Apple-MLX Kokoro stays primary on Apple.
- **Barge-in** via **mic↔playback cross-correlation** (Mario's method: ring buffer, 20–420 ms delays, fire after 5 frames) + **interim-transcript endpointing** (Parakeet last-4 s every 250 ms; final on 800 ms silence).
- Memory (per G4), skills, scheduler, security stack (DamageControl/PII/exfil), tools.
- **Apple tools via `objc2`** (EventKit/Contacts/AppKit) — the brain in Rust; Swift = UX.

## 3. Phase 3 — UX clients (thin)

- **Apple:** SwiftUI/AppKit + Metal orb; WebSocket to the daemon.
- **Linux:** Dioxus **or** Tauri (pick during the S2 spike); **audio stays in the daemon** (sidesteps the cpal+webview issue). Windows is post-v1 per G6.
- **Mobile:** dock-wake client (detect dock → wake UI → converse), reaching the daemon over x0x (Phase 4).

## 4. Phase 4 — x0x networking (gated)

- **Embed the x0x crate**; Fae = x0x agent (**reuse Fae's ML-DSA-65 identity** as the agent key); copy `communitas/communitas-x0x-client` as the reference.
- **Phone↔home:** run the ADR-002 command protocol over an **x0x direct-QUIC** connection (sync RPC — confirmed supported).
- **1:1 Fae↔Fae:** direct messaging, governed by G5.
- **GROUP features ("the Fae"):** **HARD-GATED on (a) x0x wiring `saorsa-mls 0.3.6 TreeKemGroup` (FS+PCS) AND (b) the G5 governance gate.** Do not ship personal-memory groups on GSS.

## 5. Phase 5 — Self-learning (+ later, training)

- Port **app-layer learning** (skills-from-experience, FTS5 session search, agent-curated memory, user modeling) — already Hermes-parity, cross-platform, no MLX.
- **ToM memory upgrade** eval (Honcho AGPL vs **Zep/Graphiti** vs Mem0 vs clean-room) — mind on-device GPU contention.
- **Weight training deferred** to an Apple-only premium (mlx-tune); cross-platform = inference + GGUF-adapter loading only.

---

## Cross-cutting

- **CI/testing** per platform; `just check` parity; property tests for the protocol.
- **No-fork discipline:** if candle blocks (e.g. a needed model's op), prefer a supported model or the llama.cpp fallback; fork candle only as a last resort (deep ML-systems cost).
- **Doc hygiene:** keep the Rev-13 plan reconciled as decisions land.

## What this plan deliberately does NOT commit to yet
- A start date (gated on Phase 0).
- Windows in v1 (G6 scoped it out; post-v1 proof required).
- Group "the Fae" features (gated on TreeKEM + G5).
- Overnight weight training (deferred).
- Forking mistral.rs/candle (only if all else fails).

## Related
- Design: `cross-platform-engine-plan-2026-05-30.md` (Rev 13) · Review: `REVIEW-BRIEF-headless-design-2026-06-01.md` · Evidence: `docs/spikes/S13-mistralrs-eval.md` · Prior core: `docs/adr/002-embedded-rust-core.md`.
