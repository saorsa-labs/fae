# Pipeline Fae dual-model handoff — 2026-03-07

This handoff is for **Pipeline Fae**, not Cowork Fae.

Shared tools, memory, and model infrastructure are fine to reuse, but assume **separate pipelines**.

## Non-goal

Do **not** fold Cowork Fae into this runtime pipeline plan.

## Target architecture summary

- **operator worker:** `qwen3.5-2b`
- **concierge worker:** `LFM2-24B-A2B-MLX-4bit`
- **Kokoro** stays in the main process initially
- **priority:** operator > Kokoro > concierge
- **dual-model mode:** recommended for 32 GB+ systems

## Reading order

Read these first:

1. `docs/architecture/dual-model-local-execution-plan-2026-03-07.md`
2. `docs/architecture/dual-model-local-plan-2026-03-07.md`
3. `docs/benchmarks/fae-priority-eval-2026-03-07.md`

Supporting context:

- `docs/benchmarks/local-model-eval-2026-03-07.md`
- `docs/benchmarks/llm-benchmarks.md`

## Interpretation guardrail

In these docs, **concierge** means a richer worker role inside **Pipeline Fae**. It does **not** mean Cowork Fae, and it should not be read as a plan to unify Pipeline Fae with Cowork Fae.
