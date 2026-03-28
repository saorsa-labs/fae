---
name: training-orchestrator
description: Orchestrate personal model training — SFT, DPO, and STT fine-tuning via mlx-tune on Apple Silicon.
tags:
  - training
  - self-improvement
metadata:
  author: fae
  version: "2.0"
---

# Training Orchestrator

This skill manages the personal model training pipeline using [mlx-tune](https://github.com/ARahim3/mlx-tune) — a native MLX fine-tuning library with Unsloth-compatible API.

## Training Modes

| Mode | Script | Purpose |
|------|--------|---------|
| **SFT** | `train` | Supervised fine-tuning on conversation episodes |
| **DPO** | `train_dpo` | Preference learning from user corrections |
| **STT** | `train_stt` | Speech-to-text adaptation for Qwen3-ASR |
| **Keyword** | `train_keyword` | Barge-in keyword classifier (micro 1D-CNN) |
| **Speech Verifier** | `train_speech_verifier` | Speech/music/noise classifier (micro 1D-CNN) |

## Available Scripts

- **export_data**: Export conversation episodes to train.jsonl/valid.jsonl (80/20 split)
- **train**: SFT fine-tuning via mlx-tune SFTTrainer (Qwen3.5 models)
- **train_dpo**: DPO preference training via mlx-tune DPOTrainer (uses correction pairs)
- **train_stt**: STT fine-tuning via mlx-tune FastSTTModel (Qwen3-ASR)
- **evaluate**: Benchmark trained checkpoint — reads train_metrics.json or falls back to log parsing
- **propose**: Generate human-readable comparison report for the user
- **check_status**: Check if training is in progress
- **deploy**: Activate a trained adapter (requires user approval)
- **rollback**: Revert to previous adapter
- **train_keyword**: Train 5-class keyword classifier (interrupt/wake/speech/silence/noise)
- **train_speech_verifier**: Train 3-class speech verifier (speech/music/noise)

## Model Map

| Preset | Model | RAM Requirement |
|--------|-------|-----------------|
| tiny | Qwen3.5-2B-4bit | <16 GB |
| small | Qwen3.5-4B-4bit | ≥16 GB |
| medium | Qwen3.5-9B-4bit | ≥32 GB |
| large | Qwen3.5-35B-A3B-4bit | ≥48 GB |

Auto-selection matches Fae's production LLM model tier.

## SFT Workflow

1. Run `export_data` to prepare training dataset from recent conversations
2. Run `train` with preset (smoke/light/standard/deep)
3. Run `evaluate` to benchmark the new checkpoint
4. Run `propose` to generate upgrade proposal
5. If user approves, run `deploy` to switch models

## DPO Workflow

1. Run training-data-bridge `extract_corrections` to build DPO pairs
2. Run `train_dpo` with preset (smoke/light/standard)
3. Run `evaluate` to benchmark
4. Run `propose` → `deploy` if approved

## STT Workflow

1. Fae automatically captures ASR corrections ("my name is X not Y")
2. Run `train_stt` to fine-tune Qwen3-ASR with correction pairs
3. Run `evaluate` → `propose` → `deploy`

## Training Presets (SFT)

| Preset | Steps | Batch | Grad Accum | LR | LoRA Rank | Seq Length |
|--------|-------|-------|------------|-----|-----------|------------|
| smoke | 10 | 1 | 1 | 1e-4 | 8 | 512 |
| light | 50 | 2 | 2 | 5e-5 | 16 | 1024 |
| standard | 200 | 4 | 4 | 2e-5 | 16 | 2048 |
| deep | 500 | 4 | 4 | 1e-5 | 32 | 2048 |

## Safety

- Training data never leaves the Mac — 100% local via MLX
- New models must score ≥ current on evaluation
- User must explicitly approve model switches
- Previous checkpoints always preserved for rollback
- mlx-tune runs in uv sandbox with PEP 723 inline dependencies
