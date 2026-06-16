# Cross-platform brain + overnight training — comprehensive design (2026-06-16)

**Status:** Design note (the "big one"). No runtime code changed. Supersedes and absorbs the
training-only sketch in
[`cross-platform-overnight-training-2026-06-16.md`](./cross-platform-overnight-training-2026-06-16.md),
and is the implementation plan for the `TrainingAdapter` + serving seams named in
[`full-cross-platform-ml-pipeline-2026-06-11.md`](./full-cross-platform-ml-pipeline-2026-06-11.md).

**Decision:** Adopt **llama.cpp (prebuilt `llama-server` as a subprocess sidecar) as Fae's
cross-platform serving engine**, behind the existing `ProviderAdapter` seam. Personalize the
brain with **PEFT → GGUF LoRA** adapters, trained cross-platform (**Unsloth** on NVIDIA,
**MLX** on Apple). **`mistral.rs` is retired** (owner decision 2026-06-16: "feels clunky") —
llama-server becomes the sole serving engine; the previously considered **mistral.rs fork for
Gemma 4 LoRA is cancelled** (llama.cpp serves Gemma 4 + LoRA today). **Base model tier moves to
Gemma 4 12B served via Unsloth dynamic GGUF quants (UD-Q3/Q4_K_XL)** so ~12B quality fits the
former E4B footprint (§2a).

This is what makes "cross-platform training **and** a brain that actually uses it" real.

> **VALIDATED 2026-06-16 (this session, on M5 Max/128 GB).** The make-or-break gate — does a
> Gemma 4 PEFT LoRA convert to GGUF and personalize the brain through llama.cpp — **passed
> end-to-end**. Full evidence in the Validation appendix (§A). Headline: trained a tiny Gemma 4
> E4B PEFT adapter → `convert_lora_to_gguf.py` (clean, 516 tensors) → `llama-server` per-request
> scale toggle gave **base** ("I cannot tell you the codename") vs **personalized** ("the codename
> is MOONLIT-…HERON") on one running server. Decode ~83–103 tok/s, prefill ~260–309 tok/s.

---

## 0. Why this changed shape (the forcing facts)

Three research passes (mistral.rs internals, llama.cpp capability/perf, Fae's training code)
produced four load-bearing facts. All are cited in §9.

1. **mistral.rs cannot load a LoRA adapter onto Gemma 4.** LoRA is wired only into its *text*
   loaders (Llama/Mistral/Phi/Qwen/Gemma-1-2); Gemma 3/3n/4 are *vision-loader-only* with no
   `.with_lora`. Fae's own daemon already falls back to the auto/vision `ModelBuilder` because
   `TextModelBuilder` *refuses* `Gemma4ForConditionalGeneration`. → The daemon brain **cannot
   be personalized on mistral.rs** without forking the loader.
2. **Performance favors llama.cpp for Fae's workload.** Per the mistral.rs maintainer's own
   Metal benchmark issue (#903), candle/Metal (Fae's engine) is the **slowest of the three on
   decode**. llama.cpp **wins long-context prefill** with `--flash-attn`. Fae turns are
   prefill-dominated (~6–13k tokens + audio), so llama.cpp is competitive-to-faster than
   mistral.rs on Fae's hot path. (MLX wins decode but is Apple-only and its Gemma 4 isn't live.)
3. **llama.cpp already does everything Fae needs, cross-platform**: Gemma 4 text (official
   GGUFs), **verified merged Gemma 4 audio-in** (USM Conformer, PR #21421/build b8766),
   runtime **GGUF-LoRA with per-request scale**, JSON-schema/GBNF grammar, and Metal/CUDA/
   **Vulkan/ROCm** — closing the AMD/Intel gap mistral.rs structurally cannot.
4. **Integration is a solved-shape problem.** A prebuilt `llama-server` sidecar speaks an
   OpenAI-compatible HTTP/SSE API behind `ProviderAdapter`; Fae already has
   `DaemonProcessRegistry` + parent-watch + SIGTERM-at-quit to supervise child processes, and
   crash isolation matches Fae's Metal-abort/NaN history. License is MIT (+ MIT/Apache bindings)
   — clean for dual AGPL/commercial.

**Net:** the cheapest route to the goal is not "fork mistral.rs" and not "build a second
training-only pipeline" — it is "make llama-server the engine and let GGUF-LoRA be the
personalization primitive."

---

## 1. Target architecture

```
                         fae-daemon (Rust, Unix-socket NDJSON)
                                       │
                          ProviderAdapter seam (Arc<dyn>)
                ┌──────────────────────┴───────────────────────┐
                │                                              │
        LlamaServerAdapter (PRIMARY, x-platform)        MistralrsAdapter (legacy/transition)
                │                                              (macOS base fast-path during
   spawns + supervises (DaemonProcessRegistry)                  bring-up; retire on parity)
                │
        ┌───────▼─────────── llama-server (sidecar process) ───────────────┐
        │  base GGUF (gemma-4-E4B/12B-it, Q4_K_M)                          │
        │  + personal GGUF-LoRA  (--lora personal.gguf                     │
        │                         --lora-init-without-apply)              │
        │  + audio-only mmproj (BF16, gemma4a Conformer)  ── pass 1 ASR    │
        │  OpenAI /v1/chat/completions (SSE) + /lora-adapters + per-req    │
        │  scale (0 = base, 1 = personalized → instant rollback / A-B)     │
        └─────────────────────────────────────────────────────────────────┘
                ▲                                              ▲
                │ deploy: convert + atomic swap + restart      │ scale toggle (no restart)
                │                                              │
   ┌────────────┴───────── ImprovementCycleCoordinator (nightly) ──────────┐
   │ COLLECT → META-OPT → TRAIN → EVAL → REVIEW → PROPOSE/DEPLOY → (rollback)│
   └────────────┬──────────────────────────────────────────────────────────┘
                │ TrainingBackend seam
        ┌───────┴────────┐
   MLXBackend        UnslothBackend            → PEFT adapter
   (Apple silicon)   (NVIDIA Linux/Win/WSL)        │ convert_lora_to_gguf.py
        │                 │                         ▼
   train.py/mlx-tune  uv-run QLoRA           personal.gguf  ──→ served above
```

Two seams, both already sanctioned by the 06-11 strategy note:
- **Serving seam** (`ProviderAdapter`, exists): swap mistral.rs ↔ llama-server per deployment.
- **Training seam** (`TrainingBackend`, new): swap MLX ↔ Unsloth per platform; canonical output
  PEFT → GGUF.

---

## 2. Serving lane — `LlamaServerAdapter`

New impl of `ProviderAdapter` in `crates/fae-engine` (sibling to `LocalMistralrsAdapter`).
Trait is unchanged (`describe()` + `async stream_chat(ChatRequest) -> ChatStream`); the daemon
keeps it as `Arc<dyn ProviderAdapter>` created once at startup (`fae-daemon/src/main.rs`).

**Process lifecycle.** Spawn `llama-server` once at daemon start:
```
llama-server -m <base.gguf> --port <loopback> --flash-attn \
  --lora <data>/models/personal/personal.gguf --lora-init-without-apply \
  --mmproj <data>/models/gemma4a-audio-mmproj.gguf  # audio pass
  --jinja                                            # tool template
```
Supervise via the existing `DaemonProcessRegistry` (parent-watch + SIGTERM-at-quit, EPIPE
gotcha already handled). Crash → child dies, daemon survives, restart with backoff (reuse the
orb-host restart pattern). Startup model-load latency is paid once.

**Request path.** `stream_chat` → HTTP `POST /v1/chat/completions` with `"stream": true`,
read SSE, map deltas → `ChatEvent::Token` / `Done`. Loopback only.

**Personalization control (the unlock).** Two knobs:
- **Per-request scale** — each turn sends `"lora": [{"id":0,"scale":S}]`: `S=1` personalized,
  `S=0` base. This gives **instant rollback** and **base-vs-personalized A/B on one engine, same
  quant** (huge for honest shadow eval). No restart.
- **New adapter** — a freshly trained `personal.gguf` not present at launch requires a server
  **restart** (atomic file swap to the stable path → restart). Acceptable per owner; nightly.

**Audio (Fae's two-pass).** Pass 1 = transcription via the **gemma4a audio mmproj** (BF16 —
cannot be low-bit quantized), `input_audio` content part. Pass 2 = reason on the transcript
text. Maps 1:1 onto Fae's existing `[heard]:` two-pass contract. Use an **audio-only mmproj**
(not the combined vision+audio one) to dodge the `#24084` SIGABRT.

**Tool calling.** Gemma is *not* a llama.cpp native tool handler (generic + PEG parser, with
recurring bugs). **Mitigation: keep parsing Gemma's `<tool_call>`/`<tool_program>` text in the
Swift adapter exactly as today** — bypass server `tool_calls` extraction entirely. Optionally
GBNF-constrain output (llama.cpp grammar support is mature/HIGH).

**models.lock.** Extend the fail-closed verifier (`fae-engine/src/models_lock.rs`) to cover the
**base GGUF + mmproj** (supply-chain pin, as today). The **personal `personal.gguf` is
locally-produced** — it has no upstream SHA — so add a **self-produced-artifact integrity mode**:
hash recorded at convert time, verified on load (integrity, not provenance). This is the one
genuinely new models.lock concept.

**Why subprocess, not embedded `llama-cpp-2`:** covers all needs over HTTP (streaming, `--jinja`,
`json_schema`, per-request LoRA) with no FFI/unsafe and no from-source CUDA/Vulkan build matrix;
ships prebuilt per platform/backend; crash-isolated; avoids the Ollama-style vendored-lag perf
regression. Choose embedded only if shared weights / sub-ms callbacks ever justify it.

**Tool-call/content handling (empirically required, not optional).** Validation §A confirmed
that under `--jinja`, Gemma 4's generation lands in the response's **`reasoning_content`** with
`content` **empty**. So the daemon MUST drive the **raw `/completion`** endpoint (or read
`reasoning_content`) and **parse Gemma's `<tool_call>`/`<tool_program>` and answer text itself**
— exactly Fae's current behavior. Do not rely on `llama-server`'s chat `content` or `tool_calls`.

### 2a. Base-model tier — Gemma 4 12B via Unsloth dynamic GGUF quants

Going llama.cpp lets us **raise the base everywhere**. Instead of dropping to E4B on smaller
machines, serve **Gemma 4 12B with Unsloth Dynamic 2.0 GGUF quants** (`UD-Q3_K_XL` ≈ 6 GB,
`UD-Q4_K_XL` ≈ 8 GB) — ~12B quality at roughly the old E4B footprint, with better
quality-per-byte than plain `Q4_K_M`. Revised tier (replaces the E4B/12B split in
[`project_gemma4_12b_tier`]):

| Machine RAM | Base served (llama.cpp) | ~footprint |
|---|---|---|
| ≤ 16 GB | Gemma 4 12B `UD-Q3_K_XL` | ~6 GB |
| 16–32 GB | Gemma 4 12B `UD-Q4_K_XL` | ~8 GB |
| ≥ 32 GB | Gemma 4 12B `Q5_K_M`/`Q6_K` or E4B-dual | higher fidelity |

The **personal adapter trains against 12B** and serves as a 12B GGUF-LoRA. Runtime LoRA applies
unmerged on top of any base quant (the A/B matrices stay f16) — validated on Q4_K_M (§A); a
UD-Q3/Q4 base + f16 LoRA smoke test is gate #7. Honest cost: 12B QLoRA *training* needs
~14–16 GB VRAM (vs E2B/E4B's 8/10 GB) — surfaced to users per owner direction, not hidden.

---

## 3. Training lane — `TrainingBackend` seam

Mirror `ProviderAdapter`. `TrainingBridge` keeps its method names (`exportTrainingData`,
`launchTraining`, `pollUntilComplete`, `evaluateAdapter`, `runBenchmark`) but `launchTraining`/
`evaluateAdapter` delegate to a selected backend instead of hardcoded mlx-tune script paths.

```swift
protocol TrainingBackend: Sendable {
    var id: String { get }                          // "mlx" | "unsloth" | "remote"
    func isAvailable() async -> Bool
    func train(_ spec: TrainSpec) async throws -> AdapterArtifact   // emits PEFT
    func evaluate(_ a: AdapterArtifact, _ suite: EvalSuite) async throws -> EvalReport
}
```

**Deterministic selection (Rule 5 — code, not model):** Apple silicon → `MLXBackend`;
NVIDIA CUDA present → `UnslothBackend`; remote node configured → `RemoteBackend` (§6); else →
`NoOpBackend` (skip + log loud).

**Backend-agnostic contract preserved.** Both backends MUST write the existing `run.json`
shape (`status/running/pid/adapter_path/log_path`, plus `params`) that `check_status.py` /
`pollUntilComplete()` poll — so the Swift polling layer needs **zero change**. Data export
(`build_dataset.py` → `sft_export.jsonl` + `dpo_pairs.jsonl`) is already portable Python.

**Unsloth backend (new, NVIDIA).** `uv run --script` QLoRA, same invocation pattern as
mlx-tune:
- 4-bit NF4 base + LoRA, `use_gradient_checkpointing="unsloth"`, `optim="adamw_8bit"`,
  `per_device_train_batch_size=1`, `gradient_accumulation_steps=4`.
- **Train LoRA on attention/MLP projections only (q,k,v,o,gate,up,down) — NOT `lm_head`/embed**
  (tied-embedding adapters break `convert_lora_to_gguf.py`).
- Output: PEFT `adapter_model.safetensors` + `adapter_config.json`.
- **Honest VRAM:** Gemma 4 E2B ≈ 8 GB, E4B ≈ 10 GB, **dense 12B ≈ 14–16 GB** (the "12B on
  8GB" headline is *inference*, not QLoRA training). Train the tier that matches the served base
  on that machine.

**MLX backend (Apple, existing + one new step).** mlx-tune still trains, but its
`adapters.safetensors` is **not PEFT** → add a **MLX→PEFT export/convert** step (rewrite
`adapter_config.json` to PEFT shape, map `*_proj` target modules, rename keys) so the artifact
flows through the *same* `convert_lora_to_gguf.py` path. (Alternative: `mlx_lm.fuse` + GGUF
requantize — heavier, loses lightweight-adapter benefit; prefer convert.)

**Canonical pipeline (both platforms):**
```
build_dataset.py → train (MLX|Unsloth) → PEFT adapter → convert_lora_to_gguf.py → personal.gguf
```

**Base/adapter pinning.** The training base MUST be the same snapshot the daemon serves on that
machine (`models.lock` revision), or the adapter is invalid. Pin both to one HF snapshot.

---

## 4. The nightly loop, end to end (what actually changes)

`ImprovementCycleCoordinator` state machine is **unchanged**
(`IDLE→COLLECTING→META_OPTIMIZING→TRAINING→EVALUATING→PROPOSING→DEPLOYING`). Only the **deploy**
and **eval** edges are rewired off the MLX-fallback engine and onto the served brain:

| Step | Today (MLX fallback only) | New (llama-server brain) |
|---|---|---|
| Train | mlx-tune → `adapters.safetensors` | MLX/Unsloth → PEFT → `convert_lora_to_gguf` → `personal.gguf` |
| Eval | FaeBenchmark (Apple) / loss proxy | **daemon-driven A/B**: per-request `scale=0` vs `scale=1` on llama-server → real base-vs-personalized delta, any platform; FaeBenchmark stays as Apple convenience; loss proxy = floor |
| Review | `ExternalReviewGate` (Codex→Claude→internal) on `EvalDelta` | unchanged |
| Shadow | `ShadowEvaluator` 60% win-rate, heuristic | **same engine, same quant** A/B via scale toggle → far more honest than cross-engine compare |
| Deploy | `applyAdapterChange` → `MLXLLMEngine.swapAdapter` | atomic-swap `personal.gguf` → **restart llama-server** → set default scale=1 (`adapterPatchCallback` gains a daemon branch) |
| Rollback | swap currentAdapterPath ↔ previousAdapterPath | **set scale=0 instantly**, or restore previous `personal.gguf` + restart |

The promotion gates (`minFeedbackEvents=20`, `minCorrectionEvents=5`, deferral≤3, 5-cycle
earned auto-deploy) are untouched. **This is the step that makes the brain useful: the engine
answering you is the engine your nightly training improved.**

---

## 5. Daemon protocol additions (NDJSON)

Add to the control-plane command map (`fae-control-plane/src/lib.rs`, with scopes) and dispatch
(`fae-daemon/src/session.rs`):

- `engine.set_adapter_scale {scale: f32}` → scope `ModelManagement`; flips per-default LoRA
  scale (rollback / enable). No restart.
- `engine.reload {base?, personal_adapter?}` → scope `ModelManagement`; atomic-swap + restart
  the sidecar with a new `personal.gguf`. Used by nightly deploy.
- `runtime.status` extended to report `{engine, base_model, adapter, adapter_scale}` for audit
  and the Settings showcase.

Swift `DaemonLLMEngine` gains the client calls; `adapterPatchCallback` routes to
`engine.reload`/`engine.set_adapter_scale` instead of MLX swap when the daemon lane is active.

---

## 6. Where it runs — local + fleet offload

- **Local:** training on the same machine as the daemon (Apple→MLX, NVIDIA→Unsloth).
- **Fleet offload (`RemoteBackend`, x0x):** a Mac owner with a Linux/NVIDIA node in their own
  PQC mesh offloads the nightly QLoRA job (keeps the Mac responsive); the **PEFT → GGUF**
  artifact flows back over x0x and the daemon reloads it. Ties into
  [`conductor-tier1-own-fleet-2026-06-05.md`](./conductor-tier1-own-fleet-2026-06-05.md).
  Honors the personal-vs-generic data boundary (ship the ability to learn, not what was learned)
  and PQC transport. Because both train and serve standardize on **GGUF/PEFT**, the artifact is
  portable across the mesh with no per-platform conversion at the destination.

---

## 7. Validation gates (must pass before committing each phase)

These are the UNCONFIRMED items the research flagged — treat as blocking spikes, fail loud:

1. **Gemma 4 E4B PEFT → GGUF LoRA convert** actually works (`convert_lora_to_gguf.py` inherits
   arch coverage; Gemma-4 LoRA convert is *unconfirmed-verbatim*; the Gemma4-*Assistant*/drafter
   arch is explicitly unsupported). Train on attn/MLP only. **Empirical test on a real E4B
   adapter is gate #1.**
2. **Gemma 4 audio via `llama-server`**: exact `input_audio` payload shape (`#21868`) +
   audio-only BF16 mmproj (`#24084`) on a pinned build (≥ b8766).
3. **Gemma tool-calling** through `llama-server` generic handler vs self-parsing — confirm Fae's
   self-parse path is robust (it already is with mistral.rs).
4. **Perf**: benchmark Fae's real 6–13k-token prefill turn on `llama-server --flash-attn` vs
   mistral.rs. Confirm ≥ parity (research predicts llama.cpp wins prefill).
5. **BF16 mmproj memory** headroom on 16 GB machines.
6. Pin a llama.cpp build past the `#22786` tool-call fix; carry the `#24084` one-liner if unfixed.

---

## 8. Phasing

- **P0 — Serving seam: `LlamaServerAdapter` (text).** Sidecar + HTTP/SSE behind `ProviderAdapter`;
  Gemma 4 text + self-parsed tools; benchmark vs mistral.rs on the real turn (gate #4). mistral.rs
  stays default until parity proven.
- **P1 — Audio pass on llama-server** (gate #2). Replace/augment the two-pass transcription.
- **P2 — Personalization: GGUF-LoRA on the brain.** Per-request scale (A/B + rollback);
  `convert_lora_to_gguf` (gate #1); wire `ImprovementCycleCoordinator` deploy/eval to the daemon
  (§4). **← the brain becomes useful.**
- **P3 — `TrainingBackend` seam + Unsloth NVIDIA lane** (cross-platform training); MLX→PEFT
  convert for Apple. (= spike S16.)
- **P4 — Vulkan/ROCm**: same `llama-server`, AMD/Intel GPUs for free (the mistral.rs gap closed).
- **P5 — Fleet offload** via x0x `RemoteBackend`.
- **Disposition of mistral.rs: retire** (owner decision 2026-06-16 — "feels clunky"). Keep it
  behind the `ProviderAdapter` seam only through P0 as a fallback while `LlamaServerAdapter`
  proves parity on the real turn; then **remove `LocalMistralrsAdapter` and the `mistralrs`
  dependency**. The vendor-and-fork-mistral.rs-for-Gemma4-LoRA effort is cancelled — llama.cpp
  removes the need. (Net: one engine, cross-platform, fewer deps, no candle/Metal NaN-retry loop.)

---

## 9. Sources (research, 2026-06-16)

- mistral.rs LoRA arch limits (text-loader-only; Gemma 3/4 vision-only; no `with_lora`):
  mistral.rs `docs/ADAPTER_MODELS.md`, `mistralrs/src/lora_model.rs`, `model.rs`, core
  `vision_models/gemma4`. Runtime activation = preloaded-only (issue #259, PR #262).
- Metal perf: mistral.rs maintainer issue #903 (candle/Metal slowest decode); arXiv 2601.19139
  (MLX 21–87% > llama.cpp decode, M4 Max); llama.cpp long-context prefill wins with `--flash-attn`.
- llama.cpp GGUF-LoRA: server README `/lora-adapters` + PR #10994 (per-request `lora` scale, 0
  disables); `convert_lora_to_gguf.py`; restart-scoped new-file (#7788/#7850/#8849); lm_head
  limitation #9065.
- Gemma 4 in llama.cpp: official `ggml-org/gemma-4-*-GGUF`; **audio PR #21421 (build b8766,
  USM Conformer, verified ASR)**; audio caveats #24084 (combined mmproj SIGABRT), #21868
  (server `input_audio`), BF16 mmproj; tool calling generic + PEG #21326, bugs #21316/#22786;
  grammar/json_schema HIGH.
- Integration: `llama-cpp-2` (utilityai) is the only production Rust binding; **llama-server
  subprocess recommended**; llama.cpp MIT, bindings MIT/Apache; vendoring-lag warning
  (ollama #15601).
- Fae internals (verified file:line this session): `ProviderAdapter`/`LocalMistralrsAdapter`
  (`fae-engine`), control-plane command map + `dispatch()` (`fae-daemon`), `models.lock`
  fail-closed verify; `TrainingBridge`/`ImprovementCycleCoordinator`/`ExternalReviewGate`/
  `ShadowEvaluator`/`AdapterDeploymentManager` + mlx-tune scripts (`run.json`, `train.py` presets,
  adapter format) under `native/macos/Fae/Sources/Fae/`.

> Obsidian: mirror to `Saorsa Labs/Projects/fae/Cross-Platform Brain llama.cpp (2026-06-16)`.

---

## A. Validation run — 2026-06-16 (M5 Max / 128 GB / macOS)

Empirical de-risk of the plan's load-bearing gates. All commands run locally; outputs verbatim.
Scratch tree: `~/llama-spike/` (llama.cpp @ `a182490`, Metal build).

**Setup proven:** llama.cpp built with Metal on **Apple M5 Max**; Gemma 4 E4B `Q4_K_M` GGUF
(`ggml-org/gemma-4-E4B-it-GGUF`, 5.0 GB) runs (answered "Edinburgh"); `transformers 5.8.1` +
`peft 0.19.1` + `torch 2.11.0` load `Gemma4Config` (42 text layers) on MPS. The E4B GGUF repo
also ships the **audio mmproj** (`mmproj-gemma-4-E4B-it-{Q8_0,bf16}.gguf`) — staged for the audio
gate.

**Gate #1 — Gemma 4 PEFT → GGUF LoRA → personalized serving: PASS.**
1. Trained a tiny LM-only PEFT LoRA on E4B (r=16, target `language_model.*` attn+MLP, **not**
   lm_head) — 34.9 M trainable / 7.98 B (0.44%), 120 steps in **37.9 s** on MPS, loss 2.59→0.0000
   (overfit two fake facts on purpose). PyTorch proof: BASE→"Aurora_Field" vs ADAPTER→
   "MOONLIT-HERON" (`LEARNED: True`).
2. `convert_lora_to_gguf.py <peft> --base <E4B snapshot> --outtype f16` → **clean convert**,
   516 tensors, 67 MB GGUF. It correctly remapped Gemma 4's `language_model.*` PEFT keys →
   `blk.N.attn_{q,k,v,output}` + `ffn_{gate,up,down}` lora_a/lora_b. (This was the UNCONFIRMED
   item — **now confirmed for `gemma-4-E4B-it` / `gemma4` arch on master `a182490`.**)
3. `llama-server -m <base> --lora <personal.gguf> --lora-init-without-apply --jinja -fa on`:
   ready in ~1–3 s; `/lora-adapters` lists the adapter; **per-request `lora:[{id:0,scale:S}]`**:
   - raw `/completion` scale **0.0** → *"I do not have access to … I cannot tell you what their
     secret project codename is."* (base)
   - raw `/completion` scale **1.0** → *"The secret project codename at Saorsa Labs is
     MOONLIT-LIONHERON."* (personalized; minor token drift from Q4_K_M base + tiny f16 adapter —
     signal unmistakable, base knew nothing)
   → **base ↔ personalized A/B and instant rollback on one running server: confirmed.**

**Gate #4 — perf (E4B Q4_K_M, Metal, M5 Max): PASS/strong.** decode **~83–103 tok/s**, prefill
**~260–309 tok/s**. (Full Fae-prompt 6–13k prefill benchmark vs the retired mistral.rs is now
moot — mistral.rs is being removed; the absolute numbers are comfortably in range.)

**Bonus finding (validates a design decision):** under `--jinja`, Gemma 4's output returns in
`reasoning_content` with chat `content` **empty** (`finish_reason: length`). Confirms the daemon
must use raw `/completion` (or read `reasoning_content`) and **self-parse** Gemma's text/tool
calls — see §2.

**Gate #2 — Gemma 4 audio-in via `llama-server`: PASS.** Started `llama-server -m <E4B> --mmproj
mmproj-gemma-4-E4B-it-bf16.gguf` (946 MB, ready ~2 s). Sent OpenAI `input_audio` content part
(base64 WAV, `format:"wav"`) + "transcribe" instruction. Two `say`-synthesized WAVs:
- "The capital of Scotland is Edinburgh, and the secret codeword is zephyr seven" → heard
  Edinburgh / Scotland / capital / zephyr.
- Anti-hallucination phrase "Mango helicopters orbit the violet lighthouse at quarter past
  eleven" → transcribed **"Mango helicopters orbit the violet lighthouse at Coal Apostel"** —
  random phrase reproduced near-verbatim (only the tail garbled, partly the TTS voice). A model
  cannot hallucinate an arbitrary phrase, so the **USM Conformer genuinely processed the audio**.
  → Fae's two-pass (audio→transcript) maps directly onto `input_audio`. The `input_audio` server
  routing (research flag #21868) **works on master `a182490`.**

**12B base tier — Unsloth dynamic quant: validated.** `unsloth/gemma-4-12B-it-GGUF`
`UD-Q4_K_XL` (6.9 GB on disk) runs on M5 Max Metal, coherent output, **prompt 162.7 t/s /
generation 54.8 t/s**. Confirms ~12B quality at ~8 GB weights (use `UD-Q3_K_XL` ~6 GB for
guaranteed sub-8GB total on an 8 GB machine). Repo also ships `mtp-gemma-4-12b-it.gguf` (0.47 GB)
— an MTP draft model for speculative decoding (ties into the MTP-speedup track) — and BF16/F16/F32
audio mmproj.

**Still open (lower risk, not make-or-break):** BF16 mmproj RAM headroom on a real 16 GB machine
(gate #5; the E4B audio mmproj is 946 MB); confirm 12B (vs E4B) LoRA convert — same `gemma4` arch,
expected to transfer; runtime LoRA on a UD-Q3/Q4 base (gate #7); MLX→PEFT export for the Apple
training lane.

**Disposition:** every make-or-break gate — #1 (LoRA convert+serve+scale), #2 (audio), #4 (perf),
plus the 12B-UD footprint — is **green**. Proceed to P0 (`LlamaServerAdapter`) with high
confidence; mistral.rs retirement confirmed. Spike artifacts in `~/llama-spike/` (~21 GB; safe to
delete).
