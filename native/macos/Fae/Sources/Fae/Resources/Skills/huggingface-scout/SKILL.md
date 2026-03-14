---
name: huggingface-scout
version: 1.0.0
description: Search HuggingFace Hub for models, datasets, and training resources
author: Fae
tags: [huggingface, models, datasets, training, self-improvement]
type: executable
scripts:
  - name: search_models
    description: Search HuggingFace for models by architecture, size, and quantization
    filename: search_models.py
  - name: search_datasets
    description: Search HuggingFace for instruction-tuning and preference datasets
    filename: search_datasets.py
  - name: check_new_releases
    description: Check for new model releases since a given date
    filename: check_new_releases.py
  - name: evaluate_candidate
    description: Evaluate a candidate model for Fae compatibility
    filename: evaluate_candidate.py
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
{"model_id": "mlx-community/Qwen3.5-9B-4bit"}
```

Checks: architecture, context length, MLX support, license, downloads, parameter count.

## Fae's Current Stack

| Role | Model | Params |
|------|-------|--------|
| Operator | Qwen3.5-2B | 2B 4-bit MLX |
| Concierge | LFM2-24B-A2B | 24B 4-bit MLX |
| STT | Qwen3-ASR-1.7B | 1.7B 4-bit |
| TTS | Kokoro-82M | 82M float32 |
| VLM | Qwen3-VL-4B/8B | 4-8B |
| Speaker | ECAPA-TDNN | ~6M CoreML |
