# Fae-priority local model evaluation — 2026-03-07

## Goal

This report re-ranks local models using Fae-specific priorities rather than generic LLM benchmarks.

Priority order used here:

1. tool use
2. instruction following
3. memory discipline
4. tool-result handling
5. speed
6. RAM efficiency

## New assistant-fit suite

A new 20-question MCQ suite was added to `FaeBenchmark` under `--assistant-fit`.

Categories:

- `tool_judgment` (5)
- `instruction_following_strict` (5)
- `memory_discipline` (5)
- `tool_result_handling` (5)

For Qwen models, runs used `--qwen-calibrated` so long-thinking models had longer answer budgets.

## Raw category results

| Model | Tools | Tool judgment | Strict instruction | Memory discipline | Tool result handling | Assistant-fit |
|---|---:|---:|---:|---:|---:|---:|
| qwen3.5-0.8b | 50% | 40% | 100% | 60% | 100% | 75% |
| qwen3.5-2b | 100% | 80% | 100% | 80% | 100% | 90% |
| qwen3.5-4b | 100% | 40% | 40% | 0% | 60% | 35% |
| qwen3.5-9b | 90% | 40% | 40% | 40% | 60% | 45% |
| qwen3.5-27b | 100% | 20% | 40% | 20% | 60% | 35% |
| qwen3.5-35b-a3b | 100% | 40% | 0% | 20% | 40% | 25% |
| LFM2.5-1.2B-Instruct-MLX-4bit | 20% | 60% | 0% | 0% | 60% | 30% |
| LFM2-24B-A2B-MLX-4bit | 80% | 40% | 80% | 40% | 80% | 60% |

## Weighted Fae-fit score

Weighted score used for ranking:

- tool calling: 35%
- strict instruction following: 20%
- memory discipline: 15%
- tool result handling: 10%
- tool judgment: 5%
- structured output compliance: 5%
- speed score: 5%
- RAM score: 5%

Speed score combines short TTFT and ~500-token throughput.
Structured-output values use the best current benchmark path, including Qwen-calibrated serialization where relevant.

| Model | Tool | Strict instr | Memory | Result handling | Tool judgment | Structured | Speed score | RAM score | Fae-fit score |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qwen3.5-2b | 100% | 100% | 80% | 100% | 80% | 78% | 51.0 | 96.6 | **92.3** |
| qwen3.5-0.8b | 50% | 100% | 60% | 100% | 40% | 44% | 52.8 | 100.0 | 68.3 |
| LFM2-24B-A2B-MLX-4bit | 80% | 80% | 40% | 80% | 40% | 67% | 39.8 | 32.3 | 67.0 |
| qwen3.5-9b | 90% | 40% | 40% | 60% | 40% | 67% | 36.8 | 75.6 | 62.5 |
| qwen3.5-4b | 100% | 40% | 0% | 60% | 40% | 78% | 41.3 | 89.7 | 61.4 |
| qwen3.5-27b | 100% | 40% | 20% | 60% | 20% | 22% | 0.0 | 23.0 | 55.3 |
| qwen3.5-35b-a3b | 100% | 0% | 20% | 40% | 40% | 44% | 30.8 | 0.0 | 47.7 |
| LFM2.5-1.2B-Instruct-MLX-4bit | 20% | 0% | 0% | 60% | 60% | 78% | 100.0 | 99.4 | 29.9 |

## Main takeaways

### Best strict Fae-fit model

**`qwen3.5-2b`** is the strongest current fit when tool use and instruction-following are weighted most heavily.

Why it wins:

- 100% tool-calling accuracy
- 100% strict instruction-following in the new suite
- 80% memory discipline
- 100% tool-result handling
- still fast and low-RAM

### Best tiny model

**`qwen3.5-0.8b`** is the best sub-1-GB fit.

Why:

- much stronger than the tiny Liquid model on tool-oriented assistant behavior
- excellent strict instruction-following
- very low RAM and very fast TTFT

### Best richer conversational model

**`LFM2-24B-A2B-MLX-4bit`** remains the strongest larger model if you want a more general Fae-like assistant style.

Why it still matters:

- 80% tools
- 80% strict instruction-following
- 80% tool-result handling
- strongest earlier scores on helpfulness + summarization + overall Fae-cap eval

But under this stricter tool/instruction-heavy weighting, it loses to `qwen3.5-2b`.

## Recommended models by RAM tier

These tiers are based on measured model RSS, not total system memory. In practice, users need extra headroom for the app, OS, context, and other workloads.

| Model RAM tier | Best fit | Notes |
|---|---|---|
| ~1 GB class | `qwen3.5-0.8b` | Best tiny assistant-fit model |
| ~1.5 GB to ~3 GB | `qwen3.5-2b` | Best overall strict Fae-fit; excellent default for many users |
| ~3 GB to ~6 GB | `qwen3.5-2b` still preferred | `qwen3.5-4b` and `qwen3.5-9b` did not justify their extra RAM in this tool/instruction-heavy ranking |
| ~12 GB to ~14 GB | `LFM2-24B-A2B-MLX-4bit` if you want richer assistant behavior; otherwise `qwen3.5-2b` still wins on strict fit |
| ~14 GB to ~20 GB | `qwen3.5-2b` still best strict fit; larger Qwens did not beat it |

## Suggested defaults by installed system RAM

These are product recommendations for typical user machines, not just model RSS buckets.

| Installed system RAM | Recommended default | Optional upgrade |
|---|---|---|
| 8 GB | `qwen3.5-0.8b` | none |
| 16 GB | `qwen3.5-2b` | `qwen3.5-0.8b` as ultra-light fallback |
| 24 GB | `qwen3.5-2b` | `LFM2-24B-A2B-MLX-4bit` for richer responses if headroom is acceptable |
| 32 GB | `qwen3.5-2b` | `LFM2-24B-A2B-MLX-4bit` or dual-model pipeline |
| 64 GB+ | `qwen3.5-2b` operator + `LFM2-24B-A2B-MLX-4bit` background model | larger Qwens only for continued experimentation |

## Practical product recommendation

The data now suggests two distinct winners depending on what Fae should optimize for:

### Option A — single-model default focused on tools + compliance

- Default: `qwen3.5-2b`
- Tiny fallback: `qwen3.5-0.8b`
- Premium richer option: `LFM2-24B-A2B-MLX-4bit`

### Option B — Pipeline Fae local dual-model architecture

- Fast operator / tool-router / strict-output model: `qwen3.5-2b`
- Rich summarization / conversational / background reasoning model: `LFM2-24B-A2B-MLX-4bit`

This recommendation is about model-role pairing and local execution strategy within Pipeline Fae, not about unifying Pipeline Fae with Cowork Fae.

This dual setup still looks like the strongest overall Fae architecture.

## Caveats

- The new assistant-fit suite is intentionally narrow and heavily optimized for Fae-style operator behavior.
- It should not replace broader benchmarks like MMLU-mini or the original Fae-cap eval; it complements them.
- Larger Qwen models still need diagnostic handling because they often reason for longer before finalizing answers.
- Some of the new memory-discipline prompts are deliberately strict; they penalize over-storing ephemeral information.
