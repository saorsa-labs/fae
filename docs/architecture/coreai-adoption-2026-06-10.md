# Core AI adoption plan — 2026-06-10

**Status:** Draft / spike in progress
**Owner:** David Irvine
**Context:** Apple announced Core AI at WWDC26 (~2026-06-09): a first-party on-device
inference framework for Apple silicon with open export tooling
([apple/coreai-models](https://github.com/apple/coreai-models), BSD-3) and compression
tooling ([apple/coreai-optimization](https://github.com/apple/coreai-optimization)).

## 1. What Apple shipped

Three distinct pieces:

1. **Core AI framework** — runtime for standalone `.aimodel` files, executing on the
   **Apple Neural Engine (ANE) or GPU**. Open-source `CoreAILanguageModel` and
   `MLXLanguageModel` runtimes. Dedicated Core AI Debugger app + Instruments
   integration. Requires **Xcode 27+** (effectively a macOS/iOS 27 floor).
2. **apple/coreai-models** — HuggingFace → `.aimodel` export recipes, Python
   primitives, Swift runtime package, CLIs, and a `skills/` directory for coding
   agents. Models outside the registry exportable via `--experimental`.
3. **apple/coreai-optimization** — quantization/palettization with per-layer control.

### Registry contents at announcement

| Category | Models |
|---|---|
| LLM (macOS) | Qwen2.5-1.5B, Qwen3 0.6B/4B/8B, Qwen3-Coder-30B-A3B (262K ctx, MoE), Gemma3 4B/12B, Mistral-7B, Mixtral-8x7B |
| ASR | Whisper large-v3 / large-v3-turbo, wav2vec2 |
| Embedding | CLIP ViT-B/32 (image), CLAP HTSAT (audio) |
| Vision utility | YOLOS base/tiny (detection), EfficientSAM ViT-T / SAM3 (segmentation) |
| Diffusion | SD 1.5 / 2.1 / 3.5-medium, FLUX.2-klein-4B |

macOS exports use dynamic KV cache and the model's full context; iOS exports fix
context length at export time. Mixed-precision compression recipes per model family
(e.g. `models/qwen3/qwen3_0_6b_mixed_4bit_8bit.yaml`).

Adjacent: Foundation Models framework got an on-device model update + `fm` CLI;
Apple now sells hosted LLM access with iCloud+-tiered limits.

## 2. Position: engine change, not a Fae change

Everything that makes Fae *Fae* — voice identity as the security model, memory,
proactive awareness, the self-improvement loop, skills, damage control — sits above
the inference layer. Core AI competes with exactly one layer: model loading and
inference. The fae-engine `ProviderAdapter` abstraction (headless core chunk 3a) was
built precisely to absorb this kind of backend. **Core AI is the strongest candidate
yet for the "Apple-optimal backend" slot** the cross-platform Rev docs reserved for
"MLX-turbo optional on Apple."

### Why it matters anyway

1. **ANE execution for always-on workloads.** Fae's presence checks, screen triage,
   STT, and embeddings currently run continuously on the GPU — the reason
   `InferencePriorityController`, battery/thermal throttles, and GPU-contention
   pain exist. Moving the perception layer (ASR, detection/segmentation, CLIP/CLAP)
   to the ANE cuts idle power draw and frees the GPU for the conversational LLM.
   For a 24/7 companion this is the difference between "tolerated" and "invisible."
2. **First-party model supply chain.** Fae has been blocked on community
   mlx-swift-lm PRs (Gemma 4, #185) for two months. Apple-maintained export +
   runtime + real debugging tools is a major supply-chain upgrade — for covered
   models. Trade-off: catalog has Qwen3 not Qwen3.5, Gemma3 not Gemma 4; Apple's
   catalog moves at Apple's pace and `--experimental` is unproven for bleeding-edge
   architectures.
3. **iOS Fae becomes plausible.** Fixed-context iOS exports with curated compression
   recipes are the packaging story a phone-resident Fae needs; never realistic with
   mlx-swift-lm.

## 3. What Core AI does NOT solve

| Gap | Consequence |
|---|---|
| No TTS category | Kokoro stays on mlx-audio-swift (`FaeTTSAdapter`) |
| No VLM in catalog | SmolVLM2 stays on MLXVLM |
| No LoRA training / adapter hot-swap story | **Self-improvement loop keeps MLX alive regardless.** Nightly mlx-tune training, `loadAdapter()`/`swapAdapter()`, shadow eval all depend on MLX's mutable-weights world. Best case: train in MLX, re-export per-user `.aimodel` nightly — heavyweight, unproven. |
| Streaming ASR semantics unknown | Whisper export may not support chunked streaming + endpointing as required by the pipeline; Whisper-turbo vs Qwen3-ASR accuracy on Fae's correction-heavy workload untested |
| Xcode 27 / macOS 27 floor | Adopting Core AI means dropping macOS 26 users or running dual-path during transition |
| Deepens Apple lock-in | Raises the stakes on keeping the `ProviderAdapter` seam clean for the x0x / cross-platform strategy |

## 4. Adoption plan (staged, behind existing seams)

1. **Spike S-CA1 — ASR on ANE** *(in progress, this doc's companion)*
   Export `whisper-large-v3-turbo`; benchmark vs Qwen3-ASR on accuracy, latency,
   streaming viability, **power draw**. STT is the always-on hot path; an ANE win
   on power at comparable accuracy justifies adoption by itself.
2. **Spike S-CA2 — LLM via FaeBenchmark.** Export Qwen3-4B/8B, run the existing
   benchmark suite vs MLX equivalents: tool calling, TPS, memory footprint, and
   whether `CoreAILanguageModel` exposes enough surface for Fae's tool-call parsing
   (`<tool_call>` / `<tool_program>` lanes).
3. **Perception migration candidates.** YOLOS/SAM for camera presence checks
   (cheaper than waking SmolVLM2 per check); CLAP for audio embeddings.
4. **Backend slots, not rewrites.**
   - Swift app: `CoreAI*Engine` types conforming to existing `MLProtocols`.
   - Rust daemon: `CoreAIAdapter` implementing fae-engine `ProviderAdapter` via a
     thin Swift shim (consistent with the planned objc2 Apple-tools approach).
5. **Keep on MLX:** Kokoro TTS, SmolVLM2 VLM, the entire training/adapter loop,
   speaker ID (already Core ML).
6. **Watch list:** Foundation Models as a zero-RAM "easy turn" tier (system-hosted
   small model for classification/routing), VLM catalog additions, any LoRA/adapter
   story, Gemma 4 / Qwen3.5 registry entries, streaming ASR API surface.

## 5. Spike S-CA1 — environment constraint (2026-06-10)

Dev machine: **macOS 26.4, Xcode 26.4.1**. Core AI CLIs require Xcode 27.0+ and the
runtime presumably macOS 27. Until the Xcode 27 / macOS 27 betas are installed, the
spike is limited to:

- Python export tooling (`uv run coreai.llm.export`, `models/whisper/export.py`) —
  may itself require the 27 SDK; attempting and recording where it blocks is a
  spike finding.
- Registry/recipe inspection, API surface review of the Swift package.

Runtime benchmarking (ANE execution, power draw) requires a macOS 27 beta install —
recommend a separate volume or spare machine before putting the daily driver on a
.0 beta.

### Spike log

- 2026-06-10: doc created; environment checked (macOS 26.4 / Xcode 26.4.1 —
  pre-27 toolchain).
- 2026-06-10: **export SUCCEEDED on macOS 26.4.** Repo cloned to
  `~/Desktop/Devel/projects/coreai-models`; produced
  `exports/whisper-large-v3-turbo_float16.aimodel` (1.5 GB bundle:
  `main.mlirb` + `metadata.json` + `main.hash`). Export tooling is pure
  Python/PyTorch (torch 2.9, `coreai-core` 1.0.0b1, `coreai-torch` 0.4.0) — no
  Xcode 27 needed for export, only for runtime.
  - Blockers hit on the way: (1) needed uv ≥ 0.9 (standalone `~/.local/bin/uv`
    updated 0.8.17 → 0.11.20); (2) the global uv `exclude-newer` supply-chain
    cooldown blocks the coreai-* packages (published 2026-06-08) — overridden
    per-package with `--exclude-newer-package "coreai-core=…"` scoped to the one
    command, global guard untouched.

### Spike findings beyond the export

1. **Swift package floor confirmed:** `Package.swift` declares
   `platforms: [.macOS("27.0"), .iOS("27.0")]`. Runtime benchmarking is hard-gated
   on a macOS 27 beta machine/volume.
2. **No ASR runtime in the Swift package.** Targets are CoreAILanguageModels,
   DiffusionPipeline, ImageSegmenter, ObjectDetector + tools (`llm-runner`,
   `llm-benchmark`, …). The Whisper export traces a single
   `(input_features, decoder_input_ids) → logits` forward over Whisper's fixed
   30-second window — **no decode loop, no KV cache, no streaming**. Adopting
   Core AI Whisper means writing the mel-frontend + token decode loop ourselves
   on the Core AI framework. ASR adoption cost is materially higher than
   "load and go"; streaming endpointing parity with the current
   `StreamingInferenceSession` pipeline is unproven.
3. **Grammar-constrained generation is first-party.** CoreAILanguageModels ships
   a `CXGrammar` xcframework + GuidedGenerationTests — structured/guided output
   at the runtime level. Directly relevant to Fae's tool-calling lanes
   (`<tool_call>` / `<tool_program>`): could replace prompt-level tool-call
   parsing with grammar-enforced output. This strengthens the case for the LLM
   lane (S-CA2) relative to the ASR lane.
4. `llm-benchmark` tool is "based on mlx-lm benchmark" — Apple expects
   apples-to-apples MLX comparisons; useful for S-CA2.

### Revised spike priority

Finding 2 (ASR decode loop DIY) and finding 3 (grammar-guided generation) flip
the order: **S-CA2 (LLM) is now the cheaper, higher-signal first runtime spike**,
since `llm-runner`/`llm-benchmark` work out of the box on macOS 27, while ASR
needs custom decode-loop work before any benchmark is possible. Next concrete
steps: (a) install macOS 27 beta on a spare volume/machine, (b) run `llm-runner`
with an exported Qwen3-4B vs MLX via FaeBenchmark, (c) prototype the Whisper
decode loop only if the LLM results justify deeper investment.

## 6. Decision

**Adopt incrementally behind `MLProtocols` / `ProviderAdapter`. Do not rip out
MLX.** The dramatic version is blocked by TTS, VLM, and above all the
personal-training loop — which is Fae's moat. Add the backend, benchmark it,
migrate workload-by-workload where it wins.
