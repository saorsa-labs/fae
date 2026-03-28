## MLX Benchmark Results (Swift)

**Hardware:** Apple Silicon, 96 GB unified memory
**Quantization:** 4-bit (MLX)
**Backend:** mlx-swift-lm (native Swift, same stack as Fae)
**Date:** 2026-03-28

### Model Summary

| Model | Idle RAM | Peak T/s (no_think) | ~500 tok T/s | 8.5K ctx T/s |
|---|---:|---:|---:|---:|
| Qwen3.5-35B-A3B-unsloth-mlx | 0 MB | 0 | 0 | 0 |

### Speed by Context Size — /no_think

| Context | Qwen3.5-35B-A3B-unsloth-mlx |
|---|---:|

### Speed by Context Size — Thinking ON

| Context | Qwen3.5-35B-A3B-unsloth-mlx |
|---|---:|

### Tool Calling Accuracy

| Model | Correct | Total | Accuracy |
|---|---:|---:|---:|
| Qwen3.5-35B-A3B-unsloth-mlx | 10 | 10 | 100% |

### Structured Serialization Eval

| Model | JSON | XML | YAML | Overall |
|---|---:|---:|---:|---:|
| Qwen3.5-35B-A3B-unsloth-mlx | 100% | 100% | 100% | 100% |
