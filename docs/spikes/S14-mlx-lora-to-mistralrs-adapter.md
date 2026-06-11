# Spike S14 — MLX personal LoRA → mistral.rs adapter portability

> **Status:** Proposed (2026-06-11)
> **Owner:** Fae local-model/runtime
> **Decision dependency:** Cross-platform LLM lane can move to mistral.rs without giving up Fae's MLX personal-training moat.

## Why this spike

Owner clarification: **"mistral everywhere" means the LLM inference lane, not the entire perception and training stack.** MLX stays where it is currently irreplaceable: personal LoRA training (`mlx-lm`/`mlx-tune`), Apple-optimized STT/VLM short-term, and voice/perception experiments. The missing proof is whether a personal adapter trained in MLX can be loaded by mistral.rs for the production LLM lane.

Current evidence:

- `mlx-lm` supports LoRA/QLoRA fine-tuning, saves adapter config + learned weights under `adapters/` by default, supports `--adapter-path`, can resume from `adapters.safetensors`, and can fuse/upload models.
- mistral.rs supports LoRA/X-LoRA loading and reads `adapter_config.json` from the LoRA repo for targeted modules and rank.
- The shape is promising, but tensor names, target-module conventions, scaling, tokenizer/base-model identity, and runtime behavior still need empirical proof.

## Non-goals

- Do not replace MLX training in this spike.
- Do not fork mistral.rs or candle.
- Do not require a full Fae runtime migration.
- Do not use a user-private production adapter; use a tiny synthetic preference adapter.

## Acceptance criteria

1. **Train a tiny MLX adapter**
   - Base model: choose the exact Fae candidate model family if practical; otherwise use the smallest architecture supported by both MLX and mistral.rs.
   - Dataset: 10-50 synthetic examples with an obvious measurable behavior delta.
   - Output: preserve `adapter_config.json`, `adapters.safetensors`, tokenizer/base-model metadata, training command, and git/HF revisions.

2. **Inspect MLX artifacts**
   - List tensor keys, shapes, dtype, rank, alpha/scale, target modules, and tokenizer/base model identifiers.
   - Confirm whether MLX output is already PEFT-compatible or needs key/config conversion.

3. **Convert/export if needed**
   - Produce a minimal PEFT-style adapter repo: `adapter_config.json` + `adapter_model.safetensors` or whatever mistral.rs accepts at test time.
   - Keep a deterministic conversion script under `scripts/` or `bench/` with a dry-run inspection mode.

4. **Load in mistral.rs**
   - Load the base model with and without the adapter through mistral.rs LoRA/X-LoRA APIs.
   - Record exact mistral.rs version, features, backend, and command/API used.

5. **Verify behavior delta**
   - Run fixed prompts against base vs adapter.
   - Pass if the adapter produces the trained behavior without corrupting unrelated prompts.
   - Save output transcripts and any failure diagnostics.

6. **Evaluate non-Apple training alternatives**
   - Compare Unsloth, PEFT, Axolotl, and torchtune for Fae's adapter format and hardware targets.
   - Current expectation: Unsloth is promising (NVIDIA training; documented AMD ROCm, Intel XPU, and macOS/MLX paths) but not yet a universal replacement for MLX.

## Risks to resolve

- MLX and PEFT tensor-key naming may differ.
- Target-module names may not line up for Gemma/Qwen variants.
- Quantized LoRA conventions may differ between MLX, PEFT, and mistral.rs.
- Tokenizer/base-model revision mismatch can make a technically loadable adapter semantically invalid.
- mistral.rs is pre-1.0; adapter APIs may churn.
- mistral.rs single-maintainer concentration around EricLBuehler means `ProviderAdapter` must remain the insurance seam.

## Decision outcomes

| Result | Decision |
|---|---|
| MLX adapter loads in mistral.rs with a clean behavior delta | Keep MLX personal training; use mistral.rs for LLM serving; automate conversion. |
| Conversion works but is brittle | Keep MLX training, gate adapter deployment on a converter/eval harness. |
| MLX adapter cannot be made compatible quickly | Serve personal adapters through MLX on Apple; use base mistral.rs elsewhere; prioritize PEFT/Unsloth lane for cross-platform adapters. |
| Unsloth/PEFT produces a compatible adapter more easily | Add a non-Apple training lane, but do not remove MLX until Apple personal training parity is proven. |

## Links

- `docs/architecture/cross-platform-engine-plan-2026-05-30.md`
- `docs/architecture/cross-platform-go-nogo-2026-06-11.md`
- `docs/guides/local-model-strategy.md`
- `docs/spikes/S13-mistralrs-eval.md`
