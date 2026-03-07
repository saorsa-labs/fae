# Local model benchmark report — 2026-03-07

## Scope

Models compared:

- qwen3.5-0.8b
- qwen3.5-2b
- qwen3.5-4b
- qwen3.5-9b
- qwen3.5-27b
- qwen3.5-35b-a3b
- LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit
- LiquidAI/LFM2-24B-A2B-MLX-4bit

Dimensions:

- RAM
- short-prompt TTFT
- ~500-token throughput
- tool-calling accuracy
- MMLU-style mini eval
- Fae-specific capability eval
- structured output compliance for JSON / XML / YAML

## Generic apples-to-apples benchmark

| Model | RAM | TTFT | 500 T/s | Tools | MMLU | Fae | JSON | XML | YAML |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qwen3.5-0.8b | 654 | 51 ms | 41.3 | 50% | 46% | 65% | 100% | 0% | 33% |
| qwen3.5-2b | 1264 | 85 ms | 41.6 | 100% | 52% | 40% | 100% | 33% | 100% |
| qwen3.5-4b | 2527 | 165 ms | 31.0 | 100% | 0% | 0% | 100% | 0% | 0% |
| qwen3.5-9b | 5084 | 249 ms | 31.6 | 90% | 0% | 0% | 0% | 0% | 0% |
| qwen3.5-27b | 14632 | 748 ms | 14.2 | 100% | 0% | 0% | 0% | 0% | 0% |
| qwen3.5-35b-a3b | 18819 | 219 ms | 15.9 | 100% | 0% | 0% | 0% | 0% | 0% |
| LFM2.5-1.2B-Instruct-MLX-4bit | 770 | 43 ms | 136.8 | 20% | 46% | 50% | 100% | 33% | 100% |
| LFM2-24B-A2B-MLX-4bit | 12945 | 147 ms | 26.0 | 80% | 52% | 80% | 67% | 67% | 67% |

## Qwen-calibrated diagnostic benchmark

This mode keeps throughput / RAM / tool-calling unchanged, but uses temporary Qwen-specific prompt calibration with longer generation budgets for the larger Qwen evals. For `qwen3.5-9b`, `qwen3.5-27b`, and `qwen3.5-35b-a3b`, structured-output parsing also strips post-`</think>` payloads before scoring.

| Model | RAM | TTFT | 500 T/s | Tools | MMLU | Fae | JSON | XML | YAML |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qwen3.5-0.8b | 654 | 51 ms | 41.3 | 50% | 46% | 65% | 100% | 0% | 33% |
| qwen3.5-2b | 1264 | 85 ms | 41.6 | 100% | 52% | 40% | 100% | 33% | 100% |
| qwen3.5-4b | 2527 | 165 ms | 31.0 | 100% | 14% | 30% | 100% | 33% | 100% |
| qwen3.5-9b | 5084 | 249 ms | 31.6 | 90% | 20% | 20% | 100% | 100% | 0% |
| qwen3.5-27b | 14632 | 748 ms | 14.2 | 100% | 20% | 35% | 0% | 67% | 0% |
| qwen3.5-35b-a3b | 18819 | 219 ms | 15.9 | 100% | 10% | 30% | 67% | 67% | 0% |
| LFM2.5-1.2B-Instruct-MLX-4bit | 770 | 43 ms | 136.8 | 20% | 46% | 50% | 100% | 33% | 100% |
| LFM2-24B-A2B-MLX-4bit | 12945 | 147 ms | 26.0 | 80% | 52% | 80% | 67% | 67% | 67% |

## Calibration deltas for larger Qwen models

| Model | Δ MMLU | Δ Fae | Δ JSON | Δ XML | Δ YAML |
|---|---:|---:|---:|---:|---:|
| qwen3.5-4b | +14% | +30% | +0% | +33% | +100% |
| qwen3.5-9b | +20% | +20% | +100% | +100% | +0% |
| qwen3.5-27b | +20% | +35% | +0% | +67% | +0% |
| qwen3.5-35b-a3b | +10% | +30% | +67% | +67% | +0% |

## Main conclusions

- Best overall Fae-like model in the generic benchmark: `LFM2-24B-A2B-MLX-4bit`
- Fastest model by far: `LFM2.5-1.2B-Instruct-MLX-4bit`
- Best small Qwen balance: `qwen3.5-2b`
- Larger Qwen models were materially undercounted in the generic eval due to long reasoning / delayed final answers.
- Even after calibration, larger Qwen models still lag the best Liquid results on this benchmark suite.
- Qwen does **not** appear to inherently dislike JSON. The larger-model failures were mostly compliance / finalization issues, not a general JSON weakness.

## Recommendation

Use two views going forward:

1. **Generic benchmark** for apples-to-apples comparison across all models.
2. **Qwen-calibrated benchmark** as a diagnostic mode for long-thinking Qwen-family models.
