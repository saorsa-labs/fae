---
name: training-orchestrator
description: Orchestrate personal model training — export data, train LoRA adapters, evaluate, and propose upgrades.
tags:
  - training
  - self-improvement
metadata:
  author: fae
  version: "1.0"
---

# Training Orchestrator

This skill manages the personal model training pipeline.

## Available Scripts

- **export_data**: Export conversation episodes to train.jsonl/valid.jsonl (80/20 split for mlx_lm.lora)
- **train**: Run LoRA fine-tuning on exported data
- **evaluate**: Benchmark a trained checkpoint against the current model
- **propose**: Generate a human-readable comparison report for the user
- **check_status**: Check if a training run is in progress
- **deploy**: Switch to a new model checkpoint (requires user approval)

## Workflow

1. Run export_data to prepare training dataset from recent conversations
2. Run train with appropriate preset (smoke/light/standard/deep)
3. Run evaluate to benchmark the new checkpoint
4. Run propose to generate upgrade proposal
5. If user approves, run deploy to switch models

## Safety

- Training data never leaves the Mac
- New models must score >= current on ALL benchmark categories
- User must explicitly approve model switches
- Previous checkpoints are always preserved for rollback
