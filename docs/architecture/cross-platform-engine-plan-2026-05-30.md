# Cross-platform Fae: headless Rust core, engine, self-learning & x0x — 2026-05-30

> **Status:** DRAFT — discussion artifact for deep-dive. **Not approved. No code committed.**
> **Revision:** **Rev 13** (2026-06-01) — **heavy driver = DENSE model in mistral.rs (owner decision).** Sidesteps the MoE-gather bug entirely → cleanest architecture: E4B + dense driver both in mistral.rs, one engine, all-Rust, no sidecar, no MoE, Parakeet truly optional. Benchmarking **Qwen3-14B (dense)**. Prior Rev 12: S13 complete — mistral.rs adopted (E4B workhorse: build ✓, ~65 tok/s, tool calling ✓, unified audio STT ✓); Gemma-4 26B-A4B **MoE does NOT run** in mistral.rs (`UnquantLinear::gather_forward` unsupported). llama.cpp = verified fallback. Prior: Rev 11 (S13 audio+tools confirmed), Rev 9 (prior-art reframe — `legacy/rust-core/`), Rev 8 (engine decision), Rev 7 (`saorsa-mls 0.3.6` TreeKEM), Rev 6 (no-TreeKEM), Rev 5 (3-option), Rev 4 (SOTA verification), Rev 3 (x0x), Rev 2 (headless daemon/Gemma), Rev 1 (llama.cpp eval).
> **Decision owner:** David Irvine.

> **Rev 7 note:** Group encryption is **no longer a cryptography project** — full FS+PCS TreeKEM exists in `saorsa-mls 0.3.6`; only the x0x `/mls/groups` integration remains (imminent). So: **ship 1:1 Fae↔Fae now; gate "the Fae" *group* features behind x0x's `TreeKemGroup` integration landing** — then groups get FS+PCS from day one. GSS-with-mitigations is now only a *fallback* if groups must ship before that. See §11A.4a + §18.

---

## Rev 4 changelog (verification corrections)

A six-agent SOTA verification team + owner review corrected the following (P0 = factual error):

1. **[P0] x0x sync-RPC framing was wrong** (§11A.3). x0x **does** do synchronous request/response over **direct QUIC** — it ships a real one (`x0x exec`: `ExecService::run_remote()` correlates `request_id`→reply, `src/exec/service.rs`). The "not RPC" caveat applies **only to the gossip pub/sub plane**. The local socket is still the right call — for latency/co-location reasons, *not* an x0x limitation.
2. **[P0] x0x groups crypto** (§11A) — corrected to: **MLS via `saorsa-mls` is available** (`/mls/groups`, used by **Communitas**), **but v1's encrypted-group runtime is GSS-grade** (ADR-0010) — full MLS TreeKEM forward-secrecy/PCS is upstream-pending. (Earlier "MLS TreeKEM" claim overstated; "no MLS" would understate.)
3. **[P0] Speaker model** (§10/§11A) — Fae ships **WeSpeaker ResNet34-LM 256-dim**, *not* ECAPA. Corrected throughout; S6 must validate against the real ResNet34 voiceprints.
4. **[P0] Honcho licence** (§13) — **AGPL-3.0 (strong copyleft)**, not "permissive." Materially changes integrate-vs-clean-room.
5. **[P0] Gemma-4 audio in llama.cpp** (§9) — **merged 2026-04-12 (PR #21421)**, not "nascent/pending." Merged-but-finicky (BF16 mmproj; eval bugs #21820/#21868). Also: **Qwen3-ASR/Qwen3-Omni merged into llama.cpp** (Apr 2026) — Fae can keep its *current* STT cross-platform.
6. **[P1] 26B-A4B throughput** — ~150 t/s is **RTX-4090**, not Apple (~30–40 t/s M3 Max; much higher on M5 NVFP4). Active params **3.8B** not 4B.
7. **[P1] cpal #782 overstated** (§6) — stale 2023 issue; re-anchored audio-in-daemon on **single-mic-authority + CoreAudio daemon-safety (TN2083)**.
8. **[P1] STT accuracy tradeoff** (§10) — Gemma E4B ~4.17% WER vs Whisper ~2.2–2.7%; made the semantics/latency-vs-accuracy tradeoff explicit.
9. **[P2] New SOTA + risks** — gossip metadata/social-graph exposure, GSS no-forward-secrecy, eventually-consistent ban races, mmproj-BF16; wider self-learning baseline (Mem0/Zep/Graphiti/Letta/MemPalace); Kokoro = voice-continuity not quality-SOTA; Tauri co-primary with Dioxus; peer trust must be **Pinned** not merely trusted.

> Earlier per-revision changelogs (Rev 1–3) condensed below for brevity; full history in git.

---

## Read this first

Triggered by *"can we use [llama.app](https://llama.app/) as our engine so Fae runs on any OS?"*, then expanded across: headless Rust daemon + WebSocket + mobile-dock; Gemma 4 multimodal; Hermes/Honcho self-learning; and **x0x** as the secure remote + Fae-to-Fae network.

Companion material:
- **ADR-002 (`docs/adr/002-embedded-rust-core.md`)** — the prior headless Rust core. **This plan revives it.**
- x0x repo (`../x0x`) — identity/security/groups; **Communitas** (`communitas-x0x-client`) is a working x0x integration to copy.
- Engine seam today: `Sources/Fae/Core/MLProtocols.swift` + `FaeInference` target.

> **Evidence health.** Web claims here are mostly single-source; **x0x/Communitas claims are repo-verified (high confidence)**. A SOTA verification team checked every claim — corrections folded into Rev 4. **Spikes (§17), not citations, make this safe to build.**

---

## 1. TL;DR — the verdict

> **Rev 13 reconciliation note:** older sections below may preserve historical Rev 4 reasoning, but the current decision is: **mistral.rs in-process is the primary engine; llama.cpp/`llama-server` is the verified fallback to prove in G2; Gemma-4 E4B is the workhorse; Qwen3-14B dense is the heavy driver; Gemma-4 26B-A4B MoE is not in the v1 path because it fails in candle/mistral.rs.**

1. **Headless Rust core daemon** owns the entire pipeline — audio I/O, STT/LLM/TTS, memory, skills, scheduler, tools, security, **self-learning** — and serves thin UX clients. Swift/SwiftUI on Apple, Dioxus **or Tauri** on Linux, mobile wakes on dock. **ADR-002 reborn**, now unblocked, but G3 says selective revival into a new daemon shell, not wholesale rollback.
2. **LLM engine swappable behind one adapter.** Primary **mistral.rs** in-process; fallback **`llama-server`** (GGUF) behind the same adapter; optional **MLX-turbo on Apple** remains future/premium. **llama.cpp has no MLX backend** — the turbo path is MLX-direct/Ollama, per-platform behind the same adapter.
3. **Current model split.** **Gemma-4 E4B** (native audio-in + vision, 128k) as the always-on multimodal front; **Qwen3-14B dense** as the heavy driver. Gemma-4 26B-A4B MoE is removed from the v1 engine path because S13 found a candle/mistral.rs expert-gather failure.
4. **Self-learning is application-layer and cross-platform** — Fae already matches Hermes Agent's loop (skills/memory/session-search/user-model), no MLX/training. **Dropping overnight weight-training from v1 costs almost nothing.** To exceed: a dialectic/theory-of-mind memory upgrade (Honcho is the exemplar but **AGPL** — see §13).
5. **Apple integrations can live in Rust** (`objc2`). Swift for native UX, not necessarily logic.
6. **Remote + Fae-to-Fae networking is x0x** (§11A) — Fae's PQC P2P network. Secures phone↔home (incl. **synchronous RPC over direct QUIC**) and connects people's Fae into groups ("the Fae") via **saorsa-mls** (the path Communitas uses). Same ML-DSA-65 identity primitive Fae already uses; embeds as a Rust crate. Group/personal-memory features remain gated on TreeKEM + G5 governance.
7. **The headless-core rebuild is a selective revival, not greenfield and not rollback** — `legacy/rust-core/` contains useful prior art (provider adapter, voice stack pieces, protocol concepts, TTS, audio, x0x listener), but G3 marks several modules rewrite/stale and the C-ABI/FFI path archival.

---

## 2. The decisions on the table

- **D1 — LLM engine:** **mistral.rs primary** (S13-confirmed: E4B text/audio/tool calling) with `llama-server`/llama.cpp as fallback behind a swappable adapter. G2 must prove fallback realism. (§8, §8a)
- **D2 — App architecture:** headless Rust daemon + thin per-platform UX. (§3, §11)
- **D3 — Model strategy:** Gemma 4 E4B front + **Qwen3-14B dense** driver. Gemma 4 26B-A4B MoE is out of the v1 mistral.rs path due the candle expert-gather failure. (§9)
- **D4 — Self-learning:** app-layer, cross-platform; dialectic/ToM upgrade to exceed Hermes; weight-training deferred. (§13)
- **D5 — Networking:** x0x for remote/peer (direct-QUIC RPC + saorsa-mls groups). (§11A)

---

## 3. Starting point: this is ADR-002 reborn

Fae **already shipped** a headless Rust core (ADR-002) with a JSON command/event protocol (`{v,request_id,command,payload}`), dual transport (C ABI + Unix socket), scheduler leader election (lock-file lease), a disciplined control-plane boundary, and latency SLOs (IPC RTT p95 ≤ 3ms).

**The voice stack existed too** — `legacy/rust-core/` (fae v0.7.4, quarantined not deleted, `ROLLBACK.md` to revive) contains: **`mistralrs 0.7` LLM** behind a `ProviderAdapter` trait (streaming, tool calling, local→cloud fallback), **`parakeet-rs` cascaded STT** (25 langs), `ort`+`misaki-rs` TTS, `cpal` audio, and an **`x0x_listener`** already wired to x0xd SSE with the Trusted-only + envelope-wrapped-input safety model. So the "headless-core rebuild" — flagged below as the dominant cost — is substantially a **revival + port-forward**, not greenfield.

**Why it was retired:** inference moved to **MLX (Swift-only)**, so the Rust core could no longer host the LLM/STT/TTS. That single constraint is **exactly what cross-platform engines remove** — with Rev 13, the preferred path is **in-process mistral.rs** for LLM/STT/tool calling plus ONNX (`ort`) for TTS/speaker pieces, with `llama-server` kept as fallback.

**Current design = ADR-002 lessons with:** (a) inference primarily in-process via mistral.rs, fallback sidecar via llama.cpp; (b) external transport = WebSocket/Unix socket (local) + **x0x** (remote/peer); (c) Apple logic in Rust via `objc2`. **Reuse ADR-002's protocol, leader election, and SLOs selectively; do not revive the embedded C-ABI path wholesale.**

---

## 4. llama.cpp does **not** have an MLX backend (confirmed)

- llama.cpp uses **GGML-Metal** on Apple — no MLX backend ("too high level for ggml").
- **Ollama** moved to MLX (0.19 preview, 30 Mar 2026; M5 Neural Accelerators; NVFP4) — Ollama's own engine, not llama.cpp.
- LM Studio/Jan/Ollama letting you pick "MLX or llama.cpp" is **tool-level** — the source of the conflation.

**Resolution:** swappable LLM backend; **mistral.rs is now the Rev 13 primary** after S13; **MLX-turbo optional on Apple** for max speed; `llama-server`/llama.cpp remains the fallback to prove in G2. (confidence: **high for S13 on the measured machine; replication still required**)

---

## 5. Target architecture (Rev 4)

```
        ┌──────────────────── UX CLIENTS (thin) ─────────────────────┐
        │  Apple: SwiftUI/AppKit + Metal orb                         │
        │  Linux/Windows: Dioxus OR Tauri (co-primary, §6)           │
        │  Mobile (iOS/Android): docked → wake → converse            │
        └───────────────▲───────────────────────────────────────────┘
                        │  LOCAL: WebSocket/Unix socket (ADR-002 v2; WS for bidir audio)
                        │  REMOTE (phone↔home) & PEER (Fae↔Fae): via x0x ↓↓ (§11A)
        ┌───────────────┴──────────── FAE CORE DAEMON (Rust) ────────────────┐
        │  Audio I/O (cpal/CoreAudio) · VAD · speaker-ID gate · barge-in   │
        │  Pipeline: capture → STT → LLM → TTS → playback                  │
        │  Memory (SQLite + ANN + FTS5) · Skills · Scheduler (leader)      │
        │  Tools · Security (DamageControl, PII, exfil, receipts)         │
        │  Self-learning (skills, memory, session search, user model)     │
        │  Apple tools via objc2 (EventKit/Contacts/AppKit) [Apple build] │
        │  x0x agent (embedded crate) — remote/peer transport            │
        │                                                                 │
        │   LLM-backend adapter ──────┐        ┌──── ONNX via `ort` ────┐ │
        │   • mistral.rs primary ◄─────┤        │  TTS: Kokoro+misaki    │ │
        │   • llama-server fallback ◄──┤        │  Speaker: WeSpeaker     │ │
        │   • MLX-turbo (Apple opt.) ◄─┘        │                         │ │
        │                                        │     ResNet34-LM 256d   │ │
        └────────────────────────────────────────└────────────────────────┘─┘
                        │
              ┌─────────┴──────────┐
              │ Model split         │  Gemma-4 E4B: audio-in(ASR)+vision+chat
              │                     │  Qwen3-14B dense: heavy driver
              └────────────────────┘  Kokoro: TTS out · Parakeet/Qwen ASR: fallback

   ── x0x layer (embedded crate) ── Fae = x0x agent (ML-DSA-65). phone↔home +
      Fae↔Fae over PQC QUIC (direct-QUIC RPC). "the Fae" = saorsa-mls groups. (§11A)
```

**Process model:** Rust daemon (brain + audio + x0x + in-process mistral.rs), optional LLM fallback sidecar (`llama-server`/MLX), UX client. ONNX (TTS/speaker) runs in-daemon via `ort`. Remote/peer goes via x0x, never an exposed socket.

---

## 6. Why the daemon owns audio + pipeline (not the UI)

- **Single mic authority:** multi-client needs one owner of the mic + conversation state (ADR-002 already centralizes this). This is the *primary* reason.
- **CoreAudio daemon-safety:** capture belongs in a long-lived process (Apple TN2083), not a UI event loop.
- The old "cpal #782 makes webview capture unsafe" point is **demoted to a footnote** — it's a stale 2023 issue (cpal 0.15.2 / dioxus 0.3.0) with no repro at current versions. The architecture is right; the justification was weak.
- **Mobile dock** needs the same brain reachable remotely → must be a daemon.

**UI framework:** **Dioxus and Tauri are co-primary** for non-Apple, not Dioxus-with-Tauri-fallback. Both are webview-based with Rust backends; Dioxus desktop accessibility is **webview-a11y only** (AccessKit is on the native/Blitz renderer). Pick during S2.

---

## 7. (reserved — merged into §3/§6)

---

## 8. Engine strategy (D1): swappable backend, Apple turbo

| Backend | Platforms | Integration | Notes |
|---|---|---|---|
| **`llama-server` (GGUF)** | all | sidecar (HTTP) or `llama-cpp-2` FFI (v0.1.146) | **Fallback to prove in G2.** OpenAI/Anthropic HTTP, `--jinja` tools, GGUF LoRA hot-swap. CUDA strongest. **Verified Gemma-4 audio-in.** |
| **MLX-direct (turbo)** | Apple | sidecar | Optional Apple premium path; M5 Neural Accelerators. S10. |
| **mistral.rs (candle)** | all | **in-process pure-Rust crate** | **CHOSEN (S13-confirmed).** Gemma-4 E4B on Metal ~65 tok/s, no #2051 hang, **tool calling ✓, unified audio STT ✓** (in-process). Prior art in `legacy/rust-core/` (0.7). Open: 26B-A4B NaN probe, real X-LoRA swap. See §8a. |
| **Ollama (MLX+GGML)** | all | sidecar | MLX on Apple, but **text/vision only (no voice)**; convenience backend, not the brain. |

**Recommendation (Rev 13):** `mistral.rs` primary; `llama-server` fallback over HTTP/loopback for G2 and v1 fallback; MLX-turbo optional on Apple (S10). **The swappable adapter must prove both primary and fallback with the same prompt/tool contract before production use** (§8a).

### 8a. llama.cpp vs mistral.rs — the in-process question (deep-research, May 2026)

You asked whether the headless Rust core should use **llama.cpp** or **mistral.rs**. A verification pass (decisive claims 3-0 / 2-0; secondary claims hit the verifier-breakage and are single-source-but-uncontested) settles it on **one axis: in-process purity vs verified Gemma-4-audio.**

| | llama.cpp | mistral.rs (v0.8.x, candle) |
|---|---|---|
| **Integration** | sidecar (HTTP) or `llama-cpp-2` FFI — **not** native Rust | ✅ **in-process pure-Rust crate** (`ModelBuilder`), no sidecar — Fae's ideal |
| **Gemma-4 audio-in** | ✅ **VERIFIED** — PR #21421 merged 2026-04-12, 12-layer USM conformer, LibriSpeech ASR within **0.002 WER** of HF baseline (E2B 14/14, E4B 19–20/21) | ⚠️ **CLAIMED only** — README says "Gemma 4: full multimodal incl. audio"; no working Gemma-4-conformer transcript found. Has a *generic* audio path (Voxtral ASR, `AudioInput` type) — but Voxtral ≠ Gemma-4 conformer |
| **Gemma-4 / 26B-A4B reliability** | working (new; BF16 mmproj required) | ❌ **open bug #2051: E4B hangs, 26B-A4B emits NaN logits on text prompts** — Fae's exact two models |
| **Qwen3** | solid | ⚠️ candle GGUF NEOX-RoPE defect (#3410) may degrade Qwen output — *low-confidence, validate* |
| **LoRA hot-swap** | GGUF LoRA via sidecar `/lora-adapters` | ✅ **LoRA + X-LoRA, per-request adapter swap** — genuinely nicer for Fae's personal adapters |
| **Tool calling / Metal perf / Windows** | mature | **unresolved** by this pass — no verified data |

**Verdict (Rev 9 — reframed by prior art).** This is no longer abstract: **Fae already shipped a pure-Rust voice stack on mistral.rs** in `legacy/rust-core/` (fae v0.7.4) — `mistralrs = "0.7"` (metal) behind a `ProviderAdapter` trait with streaming + tool calling + multi-provider fallback (local→cloud), **cascaded STT via `parakeet-rs`** (NVIDIA Parakeet TDT, 25 langs), `ort`+`misaki-rs` TTS, `cpal` audio, and an **`x0x_listener`** already wired to x0xd SSE with the Trusted-only + envelope-wrap safety model. Quarantined (not deleted) in the Swift-first migration; revival steps in `legacy/rust-core/ROLLBACK.md`. **The "headless-core rebuild" has a large, documented head start.**

This **dissolves the "dealbreaker":**
- The Gemma-4-audio gap only bites the **unified** (audio-in-LLM) design. **Fae's own proven design was cascaded** — parakeet/whisper STT → mistral.rs *text+vision* LLM. With cascaded STT, **mistral.rs needs only to be a text+vision LLM, which it does today** for Gemma/Qwen. The mistral.rs Gemma-4-*audio* concern (#2051 audio, unverified conformer) becomes irrelevant; residual mistral.rs risk narrows to the Gemma-4 **text** NaN bug (#2051, 26B-A4B) and Metal perf.
- So the engine choice is **entangled with STT architecture (§9)**: *unified* Gemma-4-audio → llama.cpp (verified); *cascaded* STT → **mistral.rs is viable now**, matches prior art, all-Rust.

**Revised lean:** **resurrect the legacy mistral.rs provider against current `mistralrs` 0.8 and measure (S13).** Given the prior art + cascaded STT, mistral.rs is *likely the right engine* — pure-Rust in-process (no sidecar, no FFI/C++ build), X-LoRA per-request hot-swap, and it **aligns the entire Saorsa stack on one Rust toolchain** (x0x/ant-quic/saorsa-mls/saorsa-pqc are all Rust). Keep **llama.cpp as the verified fallback** behind the same `ProviderAdapter`, and as the path if you choose the unified Gemma-4-audio STT design.

**On forking mistral.rs (your question — honest scoping):** legitimate, and more reasonable than greenfield because you have the integration code and Saorsa demonstrably maintains hard Rust libs. **But scope it truthfully: the deep perf/correctness lives in `candle` (the backend), not mistral.rs (the orchestration layer).** Metal throughput, the Gemma-4 NaN, and the GGUF NEOX-RoPE defect (#3410) are likely *candle*-level — so "fork mistral.rs to fix it" can quietly become "co-maintain candle," a much bigger ML-systems commitment than crypto libs (model-arch updates, quant kernels, Metal/CUDA backends — forever). **Don't pre-commit to a hard fork.** Sequence: **resurrect → measure (S13) → if it works, adopt + contribute fixes upstream; if it's *close but slow*, optimize (candle Metal) and upstream; hard-fork only if a real blocker is upstream-unresponsive.** The engine is a means, not the product — own a fork only if the in-process all-Rust unification is worth ongoing ML-systems maintenance for a small team.

**S13 first results (2026-05-31, measured on this Mac — `bench/mistralrs-eval/`):**
- **Build:** `mistralrs 0.8.1` + candle + **Metal** compiles clean; 0.7→0.8 API drift trivial (3 one-liners). Single ~90 MB in-process binary, no sidecar.
- **Gemma-4 E4B:** ✅ **loads + generates coherently on Metal, ~65 tok/s, TTFT 0.41s — the #2051 hang did NOT reproduce.** Cached load ~35s (after one-time ~16 GB dl).
- **Tool calling:** ✅ **works** — Gemma-4 E4B emitted a structured `get_weather({"city":"Paris"})` via `delta.tool_calls`. Fae-critical ✓.
- **Audio STT (the big one):** ✅ **CONFIRMED working in-process** — Gemma-4 E4B transcribed two WAVs accurately, incl. an unguessable clip → *"My appointment with Dr Chen is on Thursday at quarter past four in Glasgow"* (specifics only in the audio). **The deep-research "Gemma-4 audio is claim-only" is refuted.** So **one model (E4B) does STT + VLM + LLM + tools, in one engine, in-process** — **cascaded Parakeet STT becomes an *optional accuracy fallback*, not a requirement.**
- **X-LoRA:** API present (`RequestBuilder.set_adapters()` per-request swap); runtime test pending a trained adapter.
- Qwen3-0.6B smoke: ✅ 282 tok/s. Lesson: Gemma-4 & Qwen3 stream CoT into `reasoning_content` (capture both channels).

- **Gemma-4 26B-A4B MoE (heavy driver): ❌ does NOT run in mistral.rs 0.8.1** — loads (MoE config: 128 experts/top-8) but fails at inference: `UnquantLinear::gather_forward: unsupported input shape [1,31,8,704]` (candle/mistralrs MoE expert-gather unsupported for this model). *Not* the NaN bug — a real engine limitation.

**Verdict (Rev 12): adopt mistral.rs with E4B as the workhorse.** Every Fae-critical capability is empirically confirmed on Metal in one pure-Rust engine — build, Gemma-4 E4B generation, tool calling, and **unified audio STT** — no sidecar, prior integration in `legacy/rust-core/`. **No fork needed for the E4B path.** **One real gap: the planned Gemma-4 26B-A4B MoE *driver* doesn't run in mistral.rs.** Heavy-driver options: **(1) E4B-only for v1** (it already does STT+VLM+LLM+tools — *recommended start*); **(2) a Qwen3.5-MoE driver** (mistral.rs lists `qwen3_5moe` as supported — eval needed, keeps single-engine); **(3) llama.cpp for the 26B-A4B only** (dual-engine). Don't fork candle for the MoE gather unless (2)/(3) fail. llama.cpp = verified fallback behind the `ProviderAdapter`. Pending: real X-LoRA swap test.

**DECISION (Rev 13, 2026-06-01): heavy driver = a DENSE model in mistral.rs.** Owner's call — sidesteps the MoE-gather bug entirely (dense runs fine: the Qwen3-0.6B smoke test + E4B are both non-MoE and worked), and dense models are arguably steadier for agentic/tool loops (all params active → no expert-routing variance; fits Fae's "correct over fast"). **This is the *cleanest* architecture of all the options:** E4B (mistral.rs) does STT (audio-in) + vision + fast chat; complex turns route the **text** to a dense driver **also in mistral.rs** — so **one engine, all-Rust, no sidecar, no MoE, and Parakeet returns to being a true optional fallback** (E4B transcribes → hands text to the dense driver in-process; the Mario "unified+llama.cpp don't compose" coupling does NOT bite because both models live in mistral.rs). Dense candidates (all mistral.rs-supported, no audio so they take text from E4B): **Qwen3-14B / Qwen3-32B** (top open tool-callers), **Gemma-4 31B** (dense, +vision). **S13b measured (2026-06-01): Qwen3-14B dense ✅ runs clean in mistral.rs — 42 tok/s on Metal (ISQ-Q4K), TTFT 0.38s, tool calling ✓** (`get_weather({"city":"Tokyo"})`). Dense heavy-driver path confirmed. *Caveat: dense-vs-MoE "better for agentic" is task-dependent, not settled — but for Fae the decisive factors (runs in mistral.rs, consistency, all-Rust single-engine) make dense correct regardless.*

**External validation — Mario Zechner's "shitty robot" (2026-05-30, [mariozechner.at](https://mariozechner.at/posts/2026-05-30-shitty-robot/)):** a third party independently built a Fae-class **local, all-Rust** voice assistant on the same hardware class (M1 Max 64 GB / M5 Max 128 GB), serving up to 4 concurrent users. Confirms our calls: **(a) Gemma-4 26B-A4B Q4_K_M runs on llama.cpp** (his exact heavy driver — validates option 3 for the model mistral.rs can't run); **(b) cascaded Parakeet TDT 0.6B via `parakeet-rs`** (int8 ONNX, 50× RT) — the exact lib `legacy/rust-core/` used; **(c)** no cloud, no Python; **(d)** sentence-chunked TTS streaming. **Architectural lesson:** he uses cascaded STT *because the LLM runs on llama.cpp* → **unified Gemma-4-E4B-audio (mistral.rs) and a llama.cpp heavy driver don't compose; routing a turn to a llama.cpp 26B requires Parakeet feeding it text. So Parakeet STT is *required* (not just a fallback) whenever a non-E4B/non-mistral.rs driver is used.** Techniques to adopt: **barge-in by mic↔playback cross-correlation** (ring buffer, 20–420 ms delays, fire after 5 frames; he rejected WebRTC echo-cancellation); **interim-transcript endpointing** (Parakeet on last 4 s every 250 ms for stop-words; full-utterance on 800 ms silence). TTS aside: he uses **Qwen3 TTS** (6-bit 1.7B, Rust MLX-C) — alt to Kokoro (we keep Kokoro for voice identity).

**Time-sensitivity:** results are from `mistralrs 0.8.1` on this hardware; re-confirm on the build adopted.

---

## 9. Model strategy (D3): Gemma 4 dual-model

| Variant | Active/Total | Context | Audio in | Vision | Role |
|---|---|---|---|---|---|
| **E2B** | 2.3B eff | 128k | ✅ | ✅ | low-RAM front |
| **E4B** | 4.5B eff | 128k | ✅ | ✅ | **always-on front: STT + perception + light chat** |
| **26B-A4B** | **3.8B** / 26B MoE | 256k | ❌ | ✅ | ~~heavy driver~~ — **MoE, does NOT run in mistral.rs (§8a)** |
| **31B** | 31B dense | 256k | ❌ | ✅ | **dense — viable heavy-driver candidate** (runs in mistral.rs; +vision) |

**The unlock:** E2B/E4B have a USM conformer audio encoder — native ASR. **Gemma-4 audio-in is MERGED in llama.cpp** (PR #21421, 2026-04-12), though finicky: needs a **BF16 mmproj** (doubles its size, blocks low-bit encoder quant) and has known eval bugs (#21820 bad transcripts, #21868 server routing). WER ~4.17% on LibriSpeech-**clean** (degrades on noisy/spontaneous — relevant to always-on mic).

**STT is now a genuine choice, all cross-platform under llama.cpp** (Qwen3-ASR & Qwen3-Omni also merged Apr 2026):
- **Gemma E4B audio-in** — *unified* model (one engine for STT+VLM+chat), best latency/semantics, but **less accurate** (~4.17% WER).
- **Qwen3-ASR** — keeps Fae's *current* STT, cross-platform, no model change.
- **whisper.cpp** — most accurate (~2.2–2.7% WER), most mature.
→ **S5 decides the ordering.** Default stance: Gemma E4B for the unified fast path, Qwen3-ASR/whisper as the accuracy fallback for hard audio.

**Heavy lifting:** route complex/tool turns to a heavy driver (takes *text* from E4B's transcription). **DECISION (Rev 13): the heavy driver is a DENSE model in mistral.rs** (Qwen3-14B/32B, or Gemma-4 31B dense). The Gemma-4 **26B-A4B MoE does NOT run in mistral.rs 0.8.1** (candle MoE-gather unsupported, §8a) — dense sidesteps that entirely and keeps everything single-engine/all-Rust/no-sidecar. Both E4B and the dense driver live in mistral.rs (E4B transcribes audio→text → dense driver reasons), so no cascaded-STT coupling. TTS is **not** covered — Kokoro stays (§14).

**CANDIDATE DRIVER UPGRADE (2026-06-03): Gemma 4 12B** — released today; **dense** (runs in mistral.rs, unlike the 26B MoE), **multimodal incl. native audio input** (encoder-free), ~26B-class perf, 16 GB RAM, llama.cpp/MLX day-one. Strong candidate to **replace Qwen3-14B as the driver**: unifies the stack on the **Gemma-4 family** (same tokenizer/tool-format as the E4B front) and gives the driver **audio+vision** (Qwen3-14B is text-only) → fully Gemma-4 audio-native pipeline (E4B front + 12B driver). **Swappable behind the `ProviderAdapter` — does NOT block Phase 1.** Eval via a cheap S13b-style spike (mistral.rs load + tok/s + tool calling + quality vs Qwen3-14B; *no public benchmarks yet, mistral.rs day-one support unverified, brand-new*). If it evals well → adopt as driver; pair with the deferred CUDA/GPU run.

**Eval (S4/S5):** E4B + 26B-A4B GGUF under `llama-server`; FaeBenchmark tool-calling/instruction + audio-WER vs the current MLX Qwen3.5/Qwen3-ASR path.

---

## 10. Component migration map (Rev 4)

| Component | Apple today | Cross-platform (daemon) | Confidence | Risk / spike |
|---|---|---|---|---|
| **LLM** | MLX Qwen3.5 | `llama-server` GGUF (Gemma 4) + MLX-turbo opt. | High (dir.) | engine contract — S4 |
| **STT** | MLX Qwen3-ASR | **Gemma E4B audio-in** *or* **Qwen3-ASR** *or* whisper.cpp (all in llama.cpp) | Medium | accuracy/latency tradeoff — S5 |
| **TTS** | mlx-audio Kokoro | Kokoro **ONNX (`ort`) + Misaki G2P** | Medium | voice/G2P parity — S1 |
| **VLM** | MLXVLM SmolVLM2 | **Gemma E4B vision** | Medium | verify perf/quality |
| **Embedding** | Hash-384 | trivial / `ort` neural opt. | High | none |
| **Speaker ID** | Core ML **WeSpeaker ResNet34-LM** | **WeSpeaker ResNet34 ONNX (`ort`)** | Low | parity vs shipped voiceprints — S6 |
| **Apple tools** | Swift EventKit etc. | **Rust via `objc2`** | Medium | objc2-event-kit low adoption; TCC — S7 |
| **Self-learning** | Swift app-layer | **Rust app-layer** | High (dir.) | port effort, not feasibility |
| **Weight training** | mlx-tune | **Deferred** (Apple-only premium later) | n/a | out of v1 scope |
| **Audio I/O** | AVFoundation | **cpal/CoreAudio in daemon** | Medium | single-mic authority — S2 |
| **Remote/peer net** | — | **x0x (embedded crate)** | High | 1:1 ready; group FS+PCS via saorsa-mls 0.3.6 TreeKemGroup, x0x wiring pending — §11A.4a |

---

## 11. Daemon ↔ client contract (local)

- **Reuse ADR-002's JSON command/event envelope** (`v: 2`). Local transport = WebSocket/Unix socket.
- **Why WebSocket (not just HTTP/SSE):** the workload is **bidirectional streaming audio** — mic frames up, tokens/TTS/orb-events down to N clients. (Ollama's daemon proves multi-client over HTTP/REST+SSE, but *not* WS — WS is justified by the audio duplex, not the Ollama precedent.)
- **Multi-client:** N clients, one scheduler leader (ADR-002 lease).
- **Mobile dock flow:** phone detects dock (charging + external display/CarPlay/Focus/Shortcuts — iOS has no single "docked" API, S8), reaches the home daemon **over x0x** (both x0x agents, NAT-traversed, no exposed port), wakes UI, starts the loop.
- **Do not expose the local WS to the network** — remote always via x0x (§11A).

---

## 11A. x0x: secure remote transport + Fae-to-Fae ("the Fae")

**x0x** (`../x0x`, MIT/Apache) is Fae's own **post-quantum P2P agent network** — the secure connector you described, and the substrate for groups of Fae.

### 11A.1 What x0x provides (repo-verified, confidence **high**)

| Capability | x0x mechanism |
|---|---|
| Identity | **ML-DSA-65**; `AgentId = SHA-256(pubkey)` (three layers: machine/agent/user) |
| Transport | **QUIC/ant-quic**, TLS 1.3 + **ML-KEM-768**, **raw-public-key pinning (RFC 7250)** |
| **RPC** | **synchronous request/response over direct QUIC** — shipped (`x0x exec`, `request_id` correlation) |
| NAT traversal | ant-quic hole-punching (`draft-seemann`), coordinator-assisted; mDNS LAN |
| Trust | whitelist: `blocked/unknown/known/trusted` + **machine pinning** |
| Direct messaging | point-to-point E2E over QUIC |
| **Groups** | **`saorsa-mls`** (`/mls/groups`, used by **Communitas**). **0.3.6 adds real TreeKEM (`TreeKemGroup`) with FS+PCS**; legacy GSS `MlsGroup` unchanged. Live `/mls/groups` is **still GSS until x0x wires `TreeKemGroup`** (in progress). ADR-0010 gates GSS→TreeKEM migration |
| Shared state | CRDT task lists + KV (partition-tolerant) |
| Local API | `x0xd`: REST + WS + SSE on `127.0.0.1:12700`; **Rust crate `x0x = "0.19"`** |

### 11A.2 Identity unification — Fae *is* an x0x agent

`x0x AgentId = SHA-256(ML-DSA-65 pubkey)` is **identical to Fae's identity scheme**. Three-layer map: **machine** = device; **agent** (portable) = **Fae herself**; **user** (opt-in `AgentCertificate`) = **the owner**.

> Two complementary identity systems: **WeSpeaker ResNet34 voiceprint** = local biometric gate (who is speaking); **x0x UserId** = network cryptographic owner→Fae binding (whose Fae this is). They reinforce each other.

### 11A.3 Transport planes — corrected

| Plane | Transport | Why |
|---|---|---|
| **Local** (UX↔daemon, same host) | WebSocket/Unix socket | Lowest latency + no reason to run the P2P stack for two co-located processes + keep the control socket off the network |
| **Remote** (phone↔home) | **x0x direct messaging (sync RPC over QUIC)** | NAT-traversed PQC; **does** support request/response (~1 RTT, built-in `request_id`) |
| **Peer** (Fae↔Fae) | **x0x direct RPC + saorsa-mls groups + CRDT** | Encrypted, trust-gated, partition-tolerant |

**Correction (Rev 4):** the local socket is kept for *latency/co-location*, **not** because x0x can't do RPC — it can. x0x's "not RPC" caveat is **only about the gossip pub/sub plane**; the **direct-QUIC plane does synchronous request/response** (x0x ships `exec` as proof). Fae can run the *same ADR-002 command protocol* over an x0x direct connection for phone↔home. Don't expose the local WS to the network regardless.

### 11A.4 "the Fae" — groups of Fae

A person's Fae = an x0x agent (owner bound as UserId). **"the Fae" = an x0x group via `saorsa-mls`** — the exact path **Communitas already uses** (`communitas-x0x-client::create_mls_group()` → `/mls/groups`). Fae↔Fae collaboration rides: **direct RPC** (1:1), **saorsa-mls groups** (multi, E2E), **CRDT** (shared state).
- **Trust gating:** peer Fae that may *trigger actions* must be **`Pinned`** (machine-pinned), not merely `trusted` — because the direct-message sender AgentId is self-asserted at the app layer (only `machine_id` is QUIC-authenticated).
- **Forward-secrecy / PCS — now resolvable:** as of **`saorsa-mls 0.3.6`**, real TreeKEM with FS + PCS **exists** (`TreeKemGroup`). The remaining gap is x0x wiring it into `/mls/groups` (in progress, x0x team). Until that lands, the live `/mls/groups` plane is still GSS (no PCS). See §11A.4a.

### 11A.4a Group encryption: TreeKEM has landed in saorsa-mls 0.3.6; x0x integration pending

**Status (Rev 7, source-verified):** the group-crypto gap is **closing at the crate level** — this section has moved from "no secure option exists" (Rev 6) to "secure option exists; one integration step remains."

- **`saorsa-mls ≤ 0.3.5` had no real TreeKEM** — its "TreeKEM" was GSS-equivalent (node secrets local `random_bytes(32)` never distributed `group.rs:918`; only a per-epoch shared secret on the wire `group.rs:219-256`; membership change does no UpdatePath `group.rs:535`). Same construction as x0x's GSS plane (ADR-0010). *[Rev 6 audit — retained for context.]*
- **`saorsa-mls 0.3.6` adds real RFC 9420-subset TreeKEM** via `treekem_group::TreeKemGroup` (verified in source `src/treekem_group.rs`): KEM-per-node ratchet tree, **signed UpdatePath commits** (`update`/`remove_member`/`process_commit`), `create`/`add_member`/`from_welcome`, `encrypt/decrypt_message`, and persistence snapshots (`to/from_snapshot_bytes`). **This provides forward secrecy + post-compromise security.** The legacy GSS `MlsGroup` is a separate, unchanged type.
- **Remaining gap = x0x integration (in progress, x0x team).** x0x ADR-0010 is now unblocked: `/mls/groups` can become persistent + cross-daemon via `TreeKemGroup::{add_member, from_welcome}` + the encrypt-at-rest snapshot. Until x0x ships this, the *live* `/mls/groups` endpoint still runs GSS. The GSS→TreeKEM **migration** of existing groups remains gated by ADR-0010's trigger.

| Group plane | Status | FS / PCS |
|---|---|---|
| **GSS `MlsGroup`** (today's live `/mls/groups`) | shipping | ❌ no PCS — one compromised member exposes all current-epoch content, not healed by rotation |
| **`TreeKemGroup`** (saorsa-mls 0.3.6) | **crate-ready**; x0x wiring **in progress** | ✅ FS + PCS (RFC 9420 subset) |

**Caveats on the 0.3.6 release (ADR-002):** out of scope this release — **IETF wire interop, PSK, external commits/joins, resumption, classical-ciphersuite interop.** Suite IDs are private-use **`0x0B01–0x0B03`** (deliberately diverge from `draft-ietf-mls-pq-ciphersuites-04`; documented; x0x already consumes `0x0B01`). For Fae's all-saorsa stack this is fine — cross-stack MLS interop is a non-goal.

**Implication for Fae (much improved):** the dominant "no-PCS, weeks of net-new crypto" risk is **largely resolved** — full FS+PCS group encryption is now an **integration away**, not a cryptography project. So:
- **Ship 1:1 Fae↔Fae now** (direct-QUIC RPC — no group-epoch problem at all).
- **Gate "the Fae" *group* features behind x0x's `TreeKemGroup` integration landing** (imminent — owner's team confirming). Then groups get FS+PCS from day one and the GSS-interim dilemma disappears.
- **Only if group features must ship before x0x wires TreeKemGroup:** fall back to honestly-labelled GSS with consented-minimal short-lived payloads + aggressive rotation, threat-modelled PCS-absent (§18). Given TreeKEM is imminent, **prefer waiting** for personal-memory groups.

### 11A.5 Integration options

- **(a) Embed the x0x crate in the Rust core — recommended.** `x0x = "0.19"`, `Agent::builder()`. One process, shared ML-DSA-65 identity. **Communitas's `communitas-x0x-client` is the reference pattern.**
- **(b) Run `x0xd` sidecar** + localhost REST/WS (Fae as an x0x "local app"). Looser coupling; two daemons + duplicate identity.

### 11A.6 The hard part: what data crosses between Fae instances?

**Dominant risk (§18).** Fae↔Fae disclosure must be governed by the existing stack — `DamageControlPolicy`, `CoworkToolExecutor` (nonLocal), `PrivacyFilterBridge` PII, `OutboundExfiltrationGuard` — plus the standing rule ([[feedback_personal_data_boundary]]): **ship the ability to learn, not what was learned.** A peer Fae gets *consented, minimal, purpose-scoped* data — never raw memory. Treat like CoWork external calls: gated, scanned, logged. → **Spike S12.**

### 11A.7 Honest caveats / gaps

- **Group FS+PCS now available** (saorsa-mls 0.3.6 `TreeKemGroup`); live `/mls/groups` is GSS until x0x wires it (§11A.4a). Gate personal-memory groups on that integration.
- **Metadata privacy:** presence beacons (~30s for an always-on assistant), identity announcements, and group-shard co-subscription expose a **social graph** to relaying/bootstrap peers — more than Signal sealed-sender or Tailscale's central control plane. **No mitigation exists in x0x today.** Real, under-booked cost for "the Fae."
- **Sender auth:** AgentId self-asserted at app layer → require `Pinned` for action-triggering peers; use `verified`/`trust_decision` annotations.
- **Eventually-consistent ACL/ban:** removed peers may still decrypt in-flight content during a GSS rekey race.
- **Windows:** x0x docs say **"Requires Linux or macOS"** + `curl|sh` install; some ACL paths are unix-only. This is a **scoping decision**, not just a spike — x0x-on-Windows is closer to "absent" than "unverified." (S11)

## 12. Apple integration via Rust

**Mostly yes** (confidence: **medium**). `madsmtm/objc2` + framework crates (`objc2-event-kit`, `objc2-app-kit`, `objc2-foundation`) give safe Rust bindings to Apple frameworks. Core `objc2` is mature (~62M downloads); **`objc2-event-kit` is barely adopted (~53K) — unproven for Calendar/Reminders at depth.** The Rust daemon can own Cal/Contacts/Mail/Notes/window logic.

**Stays Swift on Apple:** native UX (SwiftUI/Metal orb); **TCC permission prompts + bundle entitlements** (the real gate, async-auth — S7); security-scoped bookmarks; Keychain; AVFoundation/AXUIElement (fiddlier via objc2 — thin Swift shim first).

**Implication:** Apple = Rust daemon (brain + most tools) + thin Swift UX. Linux/Windows = Rust daemon + Dioxus/Tauri. **One brain, per-platform shells.**

---

## 13. Self-learning, cross-platform (D4) — match Hermes, then exceed it

**Hermes Agent's loop is application-layer, not weight fine-tuning** (confidence: medium): skill creation from experience, agent-curated memory with nudges, FTS5 session search, Honcho user modeling. Python, model-agnostic. **Atropos (RL) is a separate Nous project, not in the agent.**

**Fae already matches it** (all app-layer, no MLX): `MetaOptSkillGenerator` ↔ skills; `MemoryOrchestrator` + seeds ↔ curated memory; `SessionSearchTool` + FTS5 ↔ session search; entity graph + speaker profiles ↔ user modeling. **So dropping overnight weight-training from v1 barely dents "match Hermes"** — Hermes Agent doesn't fine-tune either. This ports to the Rust daemon and runs everywhere.

**To exceed Hermes — broaden beyond one vendor:**
1. **Always-on multimodal awareness** (camera/screen/proactive) — already beyond Hermes's text scope.
2. **Dialectic / theory-of-mind memory** — treat memory as *reasoning, not retrieval*. The exemplar is **Honcho** (peers, background "dreaming" inference) — **but Honcho is AGPL-3.0 (strong copyleft)**, so "integrate the service" is an AGPL decision; a **clean-room ToM layer in the Rust core** is the copyleft-avoidance path. **Evaluate against a wider SOTA baseline, not just Honcho:**
   - **Mem0** (93.4% LongMemEval; most-adopted),
   - **Zep/Graphiti** (temporal knowledge graph — *closest to Fae's existing entity graph*; likely the most natural upgrade),
   - **Letta** (MemGPT lineage),
   - **MemPalace** (local-first, ~96.6% Recall@5, zero-API — directly fits Fae's no-cloud constraint).
   → S9.
   - **On-device cost (new):** a deriver/"dreaming" background loop means background LLM calls that **contend with the live pipeline for GPU** on Apple Silicon. Budget this; favour local-first designs (MemPalace) and the existing `InferencePriorityController`.
   - **Research grounding:** test-time / continual-learning work (Evo-Memory et al.) finds *smaller models benefit most from better memory* — directly relevant to Fae's 2B/4B tier, and grounds "exceed Hermes" in research rather than one vendor's evals.
3. **Retain weight-training as an Apple-only premium** (mlx-tune LoRA) — Hermes Agent has none; deployable cross-platform as GGUF adapters.

---

## 14. Voice parity (Kokoro / Misaki)

- **Kokoro is a *voice-continuity* choice, not a quality-SOTA claim.** It keeps Fae's exact `af_heart` voice. (Raw-quality leaders are now Chatterbox/Chatterbox-Turbo and Fish Audio S2 — but switching changes who Fae sounds like, so we keep Kokoro for identity.)
- ONNX ≈ PyTorch Kokoro (same hexgrad weights; "indistinguishable" is plausible-but-unsourced, and ONNX runs slower). The real risk is the **G2P frontend** (Misaki + espeak-ng).
- **`misaki-rs` is the right *direction* but is a 0.1.x third-party port, unbenchmarked** (official Misaki is Python; MisakiSwift exists). S1 must validate G2P parity **including the espeak OOV path** (sherpa-onnx #2004 shows the failure mode).
- `ort` is pre-1.0 (v2.0.0-rc.12, 2026-03-05). Pin it; ONNX Runtime C API fallback.

---

## 15. Platform support matrix (v1 scope)

| Capability | macOS (flagship) | Linux | Windows |
|---|---|---|---|
| LLM | ✅ MLX-turbo *or* llama-server | ✅ llama-server | ✅ llama-server |
| STT | ✅ Gemma E4B / Qwen3-ASR | ✅ Gemma E4B / Qwen3-ASR / whisper.cpp | ✅ same |
| TTS (same voice) | ✅ mlx-audio | ⚠️ Kokoro ONNX + Misaki | ⚠️ Kokoro ONNX + Misaki |
| Vision | ✅ Gemma E4B / MLXVLM | ✅ Gemma E4B | ✅ Gemma E4B |
| Speaker ID | ✅ Core ML ResNet34 | ⚠️ ResNet34 ONNX | ⚠️ ResNet34 ONNX |
| Apple tools | ✅ objc2/Swift | n/a | n/a |
| Self-learning (app-layer) | ✅ | ✅ | ✅ |
| Overnight weight-training | ⚠️ later (premium) | ❌ v1 | ❌ v1 |
| x0x remote/peer ("the Fae") | ✅ | ✅ | ❌ scoping decision (S11) |
| Mobile dock client | ✅ | ✅ (Android) | ✅ (Android) |

---

## 16. (reserved)

---

## 17. Spikes before commitment (no production code)

| ID | Spike | Closes |
|---|---|---|
| **S1** | Kokoro ONNX (`ort`) + Misaki G2P (incl. espeak OOV) A/B vs mlx-audio `af_heart` | voice parity (§14) |
| **S2** | Dioxus **vs Tauri** on Linux: tray + 16kHz mic in daemon + WS to stub; pick UI framework | UI/audio (§6) |
| **S4** | `llama-server` + Gemma 4 GGUF: `--jinja` tools, LoRA, FaeBenchmark | engine + driver (§8/§9) |
| **S5** | STT bake-off in llama.cpp: **Gemma E4B audio-in (BF16 mmproj)** vs **Qwen3-ASR** vs whisper.cpp — WER + latency on Fae cases | STT choice (§9/§10) |
| **S6** | WeSpeaker **ResNet34** ONNX vs Core ML — parity vs the **shipped voiceprints** | speaker ID (§10) |
| **S7** | `objc2-event-kit` Calendar read/write from Rust + TCC async-auth behavior | Apple-via-Rust (§12) |
| **S8** | iOS "docked" detection signals | mobile wake (§11) |
| **S9** | ToM/memory bake-off: Honcho (AGPL) vs **Zep/Graphiti vs Mem0 vs MemPalace** vs Fae's current memory; measure on-device GPU contention | exceed Hermes (§13) |
| **S10** | MLX-turbo vs llama-server on Apple (M-series/M5 NVFP4) | engine (§8) |
| **S11** | **x0x on Windows** (crate + daemon) + phone↔home direct-QUIC RPC round-trip | x0x cross-platform (§11A.7) |
| **S12** | Fae↔Fae disclosure: route a peer exchange through DamageControl/PII/exfil guards; define consented-minimal schema. **Start from `legacy/rust-core/src/x0x_listener.rs`** (Trusted-only + envelope-wrap + rate-limit already built) | Fae-to-Fae governance (§11A.6) |
| **S13** | mistral.rs eval (done): build ✓, Gemma-4 E4B ✓ (~65 tok/s, tool calling ✓, unified audio STT ✓), 26B-A4B MoE ✗ (gather unsupported) | DONE → adopt mistral.rs, E4B workhorse (§8a) |
| **S13b** | **Dense heavy-driver eval:** Qwen3-14B (dense) in mistral.rs — runs? Metal tok/s? tool calling? Then Qwen3-32B / Gemma-4 31B if needed | dense heavy-driver viability (§8a/§9) |

---

## 18. Risk register (Rev 4)

| Risk | Severity | Mitigation |
|---|---|---|
| Headless-core rebuild is large | High | ADR-002 revived; reuse protocol/leader/SLOs; phase it; copy Communitas's x0x client |
| **Fae↔Fae leaks personal memory** | **High** | DamageControl/PII/exfil guards (nonLocal); consented-minimal schema; S12 |
| **Live `/mls/groups` is GSS (no PCS) until x0x wires TreeKemGroup** | Medium (was High) | **Crypto is solved** — `saorsa-mls 0.3.6` has FS+PCS TreeKEM; only x0x integration remains (imminent, §11A.4a). For v1: ship 1:1 Fae↔Fae now; **gate group features behind x0x's `TreeKemGroup` integration** (then FS+PCS from day one). GSS-with-mitigations only if groups must ship sooner — one compromised member exposes all current-epoch group memory, not healed by rotation |
| **x0x gossip exposes social graph (metadata)** | Medium | No x0x mitigation today; limit beacon cadence; scope "the Fae" discovery; flag to x0x team |
| Brain forks across Swift/Rust | High | objc2 keeps logic in Rust; Swift = UX only |
| Kokoro G2P parity fails → Fae sounds different | High | S1; bundle espeak-ng; worst case Apple-only premium voice |
| x0x peer sender spoofing | Medium | Require `Pinned` (not just `trusted`) for action-triggering peers; verified/trust_decision |
| Gemma audio-in finicky (BF16 mmproj, eval bugs) | Medium | Qwen3-ASR/whisper.cpp fallback (all in llama.cpp); S5 |
| STT accuracy regression (Gemma 4.17% vs Whisper 2.2–2.7% WER) | Medium | Default unified Gemma for speed; route hard audio to Qwen3-ASR/whisper |
| x0x absent on Windows | Medium | S11; scope Windows peer features or use sidecar; not a v1 blocker for Apple/Linux |
| Eventually-consistent ban/ACL race | Low | Re-validate membership on receive; accept brief in-flight exposure |
| Two LLM backends (llama-server + MLX-turbo) = maintenance | Medium | S10 — keep MLX-turbo only if speed justifies; else GGML-Metal everywhere |
| mistral.rs/candle correctness on Fae's models (Gemma-4 #2051 hang/NaN; candle NEOX-RoPE #3410) | Medium | Don't adopt in-process until S13 passes; llama.cpp is the verified path; swappable adapter de-risks the eventual switch |
| Sidecar (llama-server) = extra process to supervise vs in-process purity | Low | Accepted for v1 (verified engine > purity); mistral.rs in-process is the target when ready |
| `ort` pre-1.0; objc2-event-kit low adoption | Medium | pin; ONNX C API / Swift shim fallback |
| Honcho AGPL contaminates | Medium | clean-room ToM layer, or pick a permissively-licensed memory lib (Mem0/Zep) |

---

## 19. Open questions for the deep-dive

1. **Mobile topology:** phone = its own Fae+x0x agent (peer to home), or thin-client to home over x0x? (Likely its own agent.)
2. **x0x:** embed the crate (§11A.5a, Communitas-style) or sidecar? Reuse Fae's identity key as the x0x agent key, or bind separately?
2b. **Fae↔Fae disclosure schema** (gates "the Fae" — S12). Group-crypto is now mostly resolved (§11A.4a): **ship 1:1 Fae↔Fae now**; **gate group features behind x0x's `TreeKemGroup` integration** (FS+PCS, imminent) rather than shipping personal-memory groups on GSS. Remaining call: is it worth shipping any *non-memory* group coordination on GSS before the x0x wiring lands, or just wait?
3. **MLX-turbo on Apple, or GGML-Metal everywhere** (one backend)? (S10)
4. **STT:** unified Gemma E4B (fast, less accurate) vs Qwen3-ASR/whisper primary (accurate)? (S5)
5. **Memory upgrade:** which ToM/memory direction — clean-room (avoid Honcho AGPL), or adopt Zep/Mem0/MemPalace? (S9)
6. **UI:** Dioxus or Tauri for non-Apple? (S2)
7. **Core language = Rust** (assumed). Confirm.
8. **v1 scope:** conversation + voice + memory/skills + Apple tools? Awareness/channels/"the Fae" later?

---

## 20. Recommendation

1. **Approve in principle:** revive the **headless Rust core (ADR-002)** with **mistral.rs as the primary in-process Rust engine**; keep llama.cpp/`llama-server` as a fallback behind `ProviderAdapter` after G2 proof; MLX remains optional Apple acceleration only.
2. **Adopt Gemma 4 dual-model**; **eval STT three ways** (Gemma E4B / Qwen3-ASR / whisper.cpp) before committing (S4/S5).
3. **Keep self-learning app-layer + cross-platform**; defer weight-training; scope a **ToM memory upgrade with a wide baseline** (Zep/Mem0/MemPalace/Honcho), mindful of Honcho's **AGPL** and on-device GPU cost (S9).
4. **Move Apple logic into Rust via objc2**; Swift for UX only (S7).
5. **Adopt x0x for remote/peer** (embed the crate, **copy Communitas's `communitas-x0x-client`**, reuse Fae's ML-DSA-65 identity). Use **direct-QUIC RPC** for phone↔home and **1:1 Fae↔Fae** — ship these first. **Gate "the Fae" *group* features behind x0x's `saorsa-mls 0.3.6 TreeKemGroup` integration** (§11A.4a) — full FS+PCS, imminent, so groups launch secure rather than on GSS. GSS-with-mitigations is now only a fallback if groups must ship sooner. **Gate all Fae↔Fae disclosure via S12** regardless. Bump the x0x dep to whatever ships the TreeKemGroup `/mls/groups` wiring (track `saorsa-mls = 0.3.6`).
6. **Run S1, S4, S5, S7 first**; add **S11/S12** before any peer/remote feature.

**Do not start broad implementation until S4/S5/S7 report. Ship 1:1 Fae↔Fae early; gate *group* features on x0x's `TreeKemGroup` integration (FS+PCS, imminent) + S12 — not on GSS.**

---

## Appendix A — Evidence & sources (with confidence, Rev 4)

| Topic | Source | Confidence |
|---|---|---|
| llama.cpp no MLX backend; GGML-Metal | llama.cpp disc #4345; build docs | **High** |
| Ollama→MLX (M5, NVFP4) | ollama.com/blog/mlx | High |
| Gemma 4 variants; E2B/E4B audio; 26B-A4B 3.8B active | HF blog gemma4; Google model card | High |
| **Gemma audio MERGED in llama.cpp (PR #21421, 2026-04-12); LibriSpeech ASR within 0.002 WER of HF baseline (E2B 14/14, E4B 19–20/21); BF16 mmproj; bugs #21820/#21868** | llama.cpp PR #21421 (verified 3-0) | **High** |
| **mistral.rs = in-process Rust crate (candle); Gemma-4 audio CLAIMED not verified (GEMMA4.md 404); generic audio via Voxtral; LoRA+X-LoRA per-request swap; open bug #2051 (E4B hang, 26B-A4B NaN); candle GGUF NEOX-RoPE #3410** | mistral.rs README/issues #2051; candle #3410 (decisive claims 3-0/2-0; rest single-source) | High (audio-unverified) / Medium (advantages) |
| llama-cpp-2 FFI actively maintained (v0.1.146, 2026-04-30) | crates.io/llama-cpp-2 | Medium |
| **Qwen3-ASR/Qwen3-Omni merged in llama.cpp (Apr 2026)** | llama.cpp audio-model PRs | Medium |
| 26B-A4B ~150 t/s **RTX 4090**; ~30–40 t/s M3 Max; LMArena ~1441 | aurigait; n1n.ai; gist | Low/Medium |
| Hermes Agent = app-layer; Atropos separate | github NousResearch/hermes-agent | Medium |
| **Honcho = dialectic/ToM, AGPL-3.0** | github plastic-labs/honcho | High (licence) / Medium (SOTA) |
| Mem0 / Zep-Graphiti / Letta / MemPalace baselines | respective repos/papers | Medium |
| objc2 mature (~62M dl); objc2-event-kit ~53K dl | crates.io | Medium |
| **x0x: ML-DSA-65 id, ML-KEM-768 QUIC, RFC7250, direct-QUIC RPC (`exec`), saorsa-mls groups** | `../x0x` repo (README, identity-architecture, security, src/exec, src/groups) | **High** |
| **saorsa-mls 0.3.6 adds real RFC9420-subset TreeKEM (`TreeKemGroup`, FS+PCS); legacy GSS `MlsGroup` unchanged; live x0x `/mls/groups` still GSS until x0x wires TreeKemGroup** | `../saorsa-mls/src/treekem_group.rs` (verified: create/add_member/from_welcome/update/process_commit/snapshot), `docs/adr/ADR-002` (suite `0x0B**`, out-of-scope: IETF interop/PSK/external commits); `../x0x/docs/adr/0010` | **High (source-verified)** |
| **Communitas uses x0x MLS (`/mls/groups`)** | `../communitas/communitas-x0x-client/src/client.rs:745` | **High** |
| **Fae speaker model = WeSpeaker ResNet34-LM 256d (not ECAPA)** | Fae CLAUDE.md / MEMORY.md | High |
| x0x "Requires Linux or macOS" (Windows gap) | `../x0x/docs/overview.md` | High |
| MLX vs llama.cpp perf (prefill reversal; ~1.4–1.8× decode sub-14B, converges ≥27B) | yage.ai; famstack.dev; arxiv 2511.05502 | Medium |
| Kokoro voice-continuity; misaki-rs 0.1.x; Chatterbox/Fish S2 lead quality | repos; sherpa #2004 | Medium |
| Dioxus/Tauri co-primary; webview-a11y only | dioxuslabs docs; AccessKit | Medium |

> A six-agent SOTA verification team checked these in Rev 4; the four P0 factual errors above were caught and corrected. Remaining items are well-sourced but **spike-gated**.

## Appendix B — Non-goals (v1)

- Replacing MLX on Apple (retained as optional turbo).
- Cross-platform overnight **weight-training** (deferred).
- Native `libllama` FFI (sidecar instead).
- Monolithic single-process Dioxus app (audio in the daemon).
- Ollama as the brain (no voice stack).
- Inventing bespoke remote-auth/TLS — **use x0x**; never expose the local WS.
- Shipping "the Fae" **personal-memory group** features on GSS when `TreeKemGroup` (FS+PCS) is imminent — wait for the x0x integration (§11A.4a). (1:1 Fae↔Fae over direct-QUIC ships regardless.)
- Fae↔Fae sharing of raw/un-consented personal data — consented-minimal only (§11A.6).
