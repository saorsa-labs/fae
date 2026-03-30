---
name: huggingface-scout
description: Search HuggingFace Hub for models, datasets, and training resources. Use for model discovery, dataset search, release monitoring, and candidate evaluation.
metadata:
  author: Fae
  version: "1.0.0"
tags: [huggingface, models, datasets, training, self-improvement]
---

# HuggingFace Scout

Search HuggingFace Hub for models, datasets, and training resources to improve Fae.

## Commands

### search_models — Find models
```json
{"query": "Qwen3.5 MLX", "limit": 5}
{"query": "MLX 4bit", "filter_tags": ["text-generation"], "sort": "downloads"}
```

### search_datasets — Find datasets
```json
{"query": "instruction tuning", "limit": 5}
{"query": "preference DPO", "filter_tags": ["en"]}
```

### check_new_releases — Monitor new models
```json
{"since": "2026-03-01"}
{"since": "2026-03-01", "authors": ["mlx-community", "Qwen"]}
```

### evaluate_candidate — Assess compatibility
```json
{"model_id": "Brooooooklyn/Qwen3.5-9B-unsloth-mlx"}
```

Checks: architecture, context length, MLX support, license, downloads, parameter count.

## Fae's Current Stack

| Role | Model | Params |
|------|-------|--------|
| Operator | Qwen3.5-2B | 2B 4-bit MLX (OptiQ mixed-precision) |
| Operator | Qwen3.5-4B | 4B 4-bit MLX (OptiQ mixed-precision) |
| Operator | Qwen3.5-9B | 9B 4-bit MLX |
| Operator | Qwen3.5-35B-A3B | 35B total / 3B active per token MoE |
| STT | Qwen3-ASR-1.7B | 1.7B 4-bit |
| TTS | Kokoro-82M | 82M float32 |
| VLM | Qwen3-VL-4B/8B | 4-8B |
| Speaker | ECAPA-TDNN | ~6M CoreML |

Fae uses a single local model at a time, selected by RAM tier:

- **Qwen3.5-2B**: Any Mac with 8+ GB RAM
- **Qwen3.5-4B**: Macs with 16+ GB RAM
- **Qwen3.5-9B**: Macs with 24+ GB RAM
- **Qwen3.5-35B-A3B**: Macs with 32+ GB RAM

When evaluating candidate models, prioritise MLX-native quantisations (4-bit, 8-bit) with context windows of 32K+ tokens.
