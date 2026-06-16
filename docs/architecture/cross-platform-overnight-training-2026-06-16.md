# Cross-platform overnight training — 2026-06-16

**Status:** SUPERSEDED (2026-06-16, same day) by
[`cross-platform-brain-llamacpp-2026-06-16.md`](./cross-platform-brain-llamacpp-2026-06-16.md),
which adopts llama.cpp/GGUF-LoRA as the serving lane and absorbs this training design. Kept for
the training-seam detail and the original framing. Concrete implementation design for the
`TrainingAdapter` seam proposed (at strategy level) in
[`full-cross-platform-ml-pipeline-2026-06-11.md`](./full-cross-platform-ml-pipeline-2026-06-11.md).

> **Update (2026-06-16):** §7 of this note treated daemon adapter consumption as a deferred,
> mistral.rs-shaped problem. Research that afternoon found mistral.rs **cannot** load LoRA on
> Gemma 4 (vision-loader-only), and that **llama.cpp serves Gemma 4 + GGUF-LoRA + audio
> cross-platform today**. The serving strategy therefore moved to llama.cpp — see the superseding
> doc. The training-seam design below (MLX/Unsloth → PEFT) stands; only the *consumer* changed.

**Trigger:** Google's Gemma team showcased a community project fine-tuning **Gemma 4 12B on
8 GB VRAM, 100% locally** (text + image + audio), via **Unsloth QLoRA 4-bit**. Gemma 4 12B
inferences in ~6.6 GB at Q4_K_M (+ hybrid offload) and has **day-one fine-tuning support across
MLX, Unsloth, llama.cpp, vLLM, HF Transformers**. Fae already targets Gemma 4 12B for the
≥32 GB inference tier — so the *model* is aligned. The new fact is that the moat feature
(overnight personal training) is now achievable on commodity NVIDIA hardware, not just Apple
silicon.

**Scope decision (owner, 2026-06-16):** This note focuses on the **cross-platform training
capability**. The separate fact that today's trained adapters reach only the MLX *fallback*
engine and not the daemon brain is acknowledged as **known/intentional for now** — daemon
adapter consumption is tracked as a downstream dependency (§7), not the spine of this work.

---

## 1. What this note adds over the 06-11 strategy note

The 06-11 note answered *"can the whole ML pipeline be cross-platform?"* (answer: mostly yes,
via narrow seams) and named the `TrainingAdapter` seam with four operations
(`prepareDataset / trainAdapter / convertAdapter / evaluateAdapter`), the per-GPU training
lanes, and the rule **"adapter portability matters more than trainer brand."** It did **not**
specify how that seam maps onto Fae's *current* training code, nor a concrete Unsloth backend.

This note is the implementation layer: it pins the seam onto the real
`TrainingBridge` / `ImprovementCycleCoordinator` surfaces, specifies the Unsloth QLoRA backend
for Gemma 4 12B at 8 GB, fixes PEFT as the universal artifact, and sets a phasing that the
S16 spike can execute against.

---

## 2. Current code reality (what is MLX-locked today)

The overnight loop is real and working, but **single-backend (MLX / Apple silicon only)**.
Evidence from the live tree:

| Stage | Current implementation | Portable? |
|---|---|---|
| Data export | `TrainingBridge.exportTrainingData()` → `build_dataset.py` (training-data-bridge skill) via `uv run --script` | ✅ mostly (pure Python over `fae.db`) |
| Train | `TrainingBridge.launchTraining()` → `train.py` / `train_dpo.py` (training-orchestrator skill), mlx-tune | ❌ MLX-only |
| Poll | `TrainingBridge.pollUntilComplete()` → `check_status.py` (polls `run.json`) | ✅ backend-agnostic if status contract held |
| Evaluate | `TrainingBridge.evaluateAdapter()` → `evaluate.py`; optional `runBenchmark()` → FaeBenchmark (Swift binary) | ⚠️ FaeBenchmark is Apple/Swift |
| Deploy | `ImprovementCycleCoordinator` → `adapterPatchCallback` → `PipelineCoordinator.applyAdapterChange()` → `MLXLLMEngine.swapAdapter()` | ❌ MLX fallback engine only |

There is **no abstraction over the training backend** — MLX is hardcoded through the script
paths and the `/opt/homebrew` environment assumption. Artifacts are MLX-format
(`adapter_config.json` + `adapters.safetensors`, custom `LoRAContainer`), **not PEFT**.

---

## 3. Goal and non-goals

**Goal:** The overnight improvement cycle trains a personal LoRA adapter on **whatever
platform the training node runs**, producing a **portable PEFT artifact**, without changing the
nightly state machine (`IDLE → COLLECTING → … → DEPLOYING`).

**Non-goals (this note):**
- Wiring the daemon (mistral.rs) to *load* adapters — tracked separately (§7).
- AMD/ROCm and Intel/XPU training lanes — design for them, prove only Apple + NVIDIA first.
- Vulkan training — it does not exist; Vulkan is inference-only.
- Changing the model: target stays Gemma 4 12B (train) aligned with the inference tier.

---

## 4. The `TrainingBackend` seam (concrete shape)

Mirror the inference `ProviderAdapter` pattern. Introduce one Swift protocol that
`TrainingBridge` calls instead of hardcoding mlx-tune script paths.

```swift
// Sources/Fae/Scheduler/TrainingBackend.swift  (new)
protocol TrainingBackend: Sendable {
    var id: String { get }                       // "mlx" | "unsloth" | "remote"
    func isAvailable() async -> Bool             // hardware/runtime probe
    func train(_ spec: TrainSpec) async throws -> AdapterArtifact
    func evaluate(_ artifact: AdapterArtifact, suite: EvalSuite) async throws -> EvalReport
}

struct TrainSpec {                               // backend-agnostic
    let baseModel: String                        // "google/gemma-4-E4B-it" | "...-12b"
    let trainJSONL: URL                          // build_dataset.py output
    let dpoJSONL: URL?
    let budget: TrainBudget                       // wall-clock, max steps, VRAM ceiling
    let outputFormat: AdapterFormat = .peft       // universal — see §5
}

struct AdapterArtifact {                          // always PEFT on disk
    let dir: URL                                  // adapter_config.json + adapter_model.safetensors
    let format: AdapterFormat                     // .peft (canonical) | .mlx (legacy)
    let baseModel: String
    let metrics: TrainMetrics
}
```

`TrainingBridge` keeps its current methods (`exportTrainingData`, `launchTraining`,
`pollUntilComplete`, `evaluateAdapter`) but `launchTraining`/`evaluateAdapter` delegate to the
selected `TrainingBackend` rather than a fixed script path. The nightly state machine in
`ImprovementCycleCoordinator` is untouched.

### Backend selection (deterministic, not model-judged — Rule 5)

```
select():
  if Apple silicon            -> MLXBackend           (existing mlx-tune scripts)
  else if NVIDIA CUDA present  -> UnslothBackend       (new, §6)
  else if remote training node configured -> RemoteBackend (§8, conductor)
  else                         -> NoOpBackend          (skip training, log loudly — Rule 12)
```

Probe order is pure capability detection (`uname`, `nvidia-smi`, config). No CPU training lane
except a tiny deterministic converter/smoke path for CI.

---

## 5. Universal artifact = PEFT

Per the 06-11 rule ("adapter portability > trainer brand"), **PEFT/safetensors is the canonical
on-disk format**, because it is the one every serving backend Fae cares about can consume:

| Serving backend | Consumes | Conversion needed |
|---|---|---|
| mistral.rs (daemon, primary) | PEFT + ordering file | none (native) |
| llama.cpp (Vulkan fallback) | GGUF LoRA / merged GGUF | PEFT → GGUF |
| MLX (Apple fallback) | MLX `adapters.safetensors` | PEFT → MLX (or train native, convert out) |

Implication: the **Unsloth/PEFT lane is the natural-fit producer** for the daemon brain; the
existing **MLX lane is the outlier** (it emits a format the primary engine can't read). Rather
than converting PEFT→MLX, the cleaner long-term move is to have the MLX backend **also export a
PEFT copy** (mlx-lm supports PEFT-style export), so every backend lands the same canonical
artifact. `convertAdapter` exists for the GGUF case and as an escape hatch.

mistral.rs note: it loads LoRA on quantized bases but warns that aggressive 4-bit can distort an
**X-LoRA classifier** — plain single-adapter LoRA is unaffected; prefer ≥8-bit base if X-LoRA is
ever used. (Ref: mistral.rs `ADAPTER_MODELS.md`.)

---

## 6. Unsloth backend — Gemma 4 12B QLoRA on 8 GB

The new capability. Standalone `uv`-run script (same invocation pattern as mlx-tune scripts), so
`UnslothBackend` shells out exactly like `MLXBackend` does today.

Recipe (from Unsloth Gemma 4 guidance + the 8 GB community demo):
- **QLoRA**: 4-bit NF4 base + LoRA adapters (adapters stay un-quantized).
- **Gradient checkpointing** (`use_gradient_checkpointing="unsloth"`) — ~30% extra VRAM saved.
- Memory envelope: 15 GB → ~8 GB; Unsloth ~1.5× faster, ~60% less VRAM than FA2.
- Output: **PEFT** `adapter_model.safetensors` + `adapter_config.json` → drop straight into the
  daemon's adapter dir.
- Status contract: must write the same `run.json` shape `check_status.py` already polls, so
  `pollUntilComplete()` is backend-agnostic (no Swift change).

This makes the literal headline true: **Fae can train her personal adapter overnight on an
8 GB consumer NVIDIA GPU**, and (once §7 lands) the daemon brain on that same box loads it.

---

## 7. Dependency: daemon adapter consumption (known gap, separate work)

Tracked here so the phasing is honest, **not** owned by this note (owner decision: known/
intentional for now).

Today `fae-engine`'s `LocalMistralrsAdapter` only `load_text(model_id)` — no adapter path —
and `ProviderAdapter` has no swap method, so trained adapters reach only the MLX fallback
(`PipelineCoordinator.applyAdapterChange` → `MLXLLMEngine.swapAdapter`). mistral.rs *does*
support LoRA load + runtime adapter activation, so the wiring is feasible:
1. `ProviderAdapter::load_adapter(path)` / `activate_adapters([...])`.
2. `LocalMistralrsAdapter` builds the LoRA ordering file from a single-adapter PEFT dir.
3. `ImprovementCycleCoordinator.adapterPatchCallback` gains a daemon branch alongside the MLX one.

Until then, cross-platform training (this note) produces correct PEFT artifacts that simply
aren't consumed by the daemon yet — the capability is built ahead of its consumer, deliberately.
This is the S14 "adapter portability" spike's payoff point.

---

## 8. Where training runs (local vs fleet offload)

Two deployment shapes, same seam:

1. **Local** — training runs on the same machine as the daemon (Mac → MLX; Linux/NVIDIA box →
   Unsloth). Default.
2. **Fleet offload (`RemoteBackend`)** — ties into the Conductor/x0x strategy
   ([`conductor-tier1-own-fleet-2026-06-05.md`](./conductor-tier1-own-fleet-2026-06-05.md)):
   a Mac user with a Linux/NVIDIA node in their own x0x mesh offloads the nightly QLoRA job to
   that node (keeps the Mac responsive), and the resulting PEFT artifact flows back over the
   mesh for the daemon to load. Training data movement must honor the
   personal-vs-generic-data boundary (ship the ability to learn, not what was learned).

Fleet offload is the "cross-platform from day 0" vision fully realized: the *brain* is portable
(daemon), the *training* runs on the best node available, and the *artifact* is portable (PEFT).

---

## 9. Cross-platform evaluation

`runBenchmark()` uses FaeBenchmark, a Swift/Apple binary — not portable. For non-Apple training
nodes the eval gate must be either:
- **daemon-driven**: run base vs adapter through the local daemon (mistral.rs) and score with a
  portable Python/Rust harness, or
- the existing **loss-based proxy** (`evaluate.py`) as the floor.

The benchmark **gate is mandatory** regardless of platform — the moat-thesis research refuted
"LoRA prevents forgetting," so promotion must stay gated on measured accuracy, never assumed.

---

## 10. Phasing

- **P0 — seam extraction (Apple no-op refactor):** introduce `TrainingBackend`, make
  `MLXBackend` the first impl, prove the nightly cycle is byte-identical on Apple. No behavior
  change. (Closes the "no abstraction" finding.)
- **P1 — Unsloth backend (§6):** `uv`-run QLoRA script for Gemma 4 12B, PEFT output, `run.json`
  contract. Prove on an 8 GB NVIDIA box (or VPS). This is S16.
- **P2 — PEFT canonicalization:** MLX backend also exports a PEFT copy; `convertAdapter`
  PEFT→GGUF for the llama.cpp lane.
- **P3 — portable eval (§9):** daemon-driven base-vs-adapter scoring usable off-Apple.
- **P4 — fleet offload (§8):** `RemoteBackend` over x0x — after P1–P3 and after the §7 daemon
  consumption work lands independently.

Daemon adapter consumption (§7) is a parallel track, not a P-step here.

---

## 11. Open questions / risks

- **MLX → PEFT export fidelity:** does mlx-lm emit a PEFT dir mistral.rs loads cleanly, or is a
  converter required? (S14 question.)
- **Gemma 4 12B base weights:** training base must match the daemon's served base (same repo
  snapshot, `models.lock`) or the adapter is invalid. Pin both to one snapshot.
- **8 GB is inference-tier, fine-tuning is tighter:** the community demo trains 12B QLoRA at
  8 GB but with small batch + gradient checkpointing; verify wall-clock fits the overnight
  budget (`TrainBudget`) on real consumer hardware, not just that it fits in VRAM.
- **Windows packaging:** Unsloth on Windows typically wants WSL2; native-Windows CUDA path needs
  its own spike before any Windows claim.
- **Privacy:** fleet offload moves training data off the origin machine — must pass through the
  personal-data boundary policy and x0x's PQC transport.

---

## 12. Decision

Build the `TrainingBackend` seam and the Unsloth QLoRA lane so Fae's overnight training is
**platform-portable and PEFT-canonical from the start**, executed as P0→P4. Keep the daemon
adapter-consumption wiring (§7) as an independent, owner-acknowledged track. The moat is
**portable personal intelligence** — this note makes the *training* half portable; §7 makes the
*serving* half consume it.

> Obsidian: mirror to
> `Saorsa Labs/Projects/Fae/cross-platform-overnight-training-2026-06-16` per CLAUDE.md.
