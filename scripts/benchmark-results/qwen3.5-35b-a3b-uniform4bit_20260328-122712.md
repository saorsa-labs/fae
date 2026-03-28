## MLX Benchmark Results (Swift)

**Hardware:** Apple Silicon, 96 GB unified memory
**Quantization:** 4-bit (MLX)
**Backend:** mlx-swift-lm (native Swift, same stack as Fae)
**Date:** 2026-03-28

### Model Summary

| Model | Idle RAM | Peak T/s (no_think) | ~500 tok T/s | 8.5K ctx T/s |
|---|---:|---:|---:|---:|
| qwen3.5-35b-a3b | 0 MB | 0 | 0 | 0 |

### Speed by Context Size — /no_think

| Context | qwen3.5-35b-a3b |
|---|---:|

### Speed by Context Size — Thinking ON

| Context | qwen3.5-35b-a3b |
|---|---:|

### Tool Calling Accuracy

| Model | Correct | Total | Accuracy |
|---|---:|---:|---:|
| qwen3.5-35b-a3b | 9 | 10 | 90% |

### Structured Serialization Eval

| Model | JSON | XML | YAML | Overall |
|---|---:|---:|---:|---:|
| qwen3.5-35b-a3b | 100% | 100% | 100% | 100% |
