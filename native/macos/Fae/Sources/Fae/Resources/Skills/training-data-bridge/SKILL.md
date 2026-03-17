---
name: training-data-bridge
description: Extract training signals from Fae's memory — SFT examples, DPO correction pairs, engagement scores, and interest-weighted sampling.
tags:
  - training
  - self-improvement
  - memory
metadata:
  author: fae
  version: "1.0"
---

# Training Data Bridge

Converts Fae's memory into weighted training data for personal model improvement.

## Available Scripts

- **build_dataset**: Complete pipeline — exports episodes, extracts corrections, computes weights, validates
- **extract_corrections**: Detect implicit and explicit user corrections → DPO training pairs

## What It Extracts

| Memory Kind | Training Signal |
|-------------|----------------|
| .episode | Raw SFT examples (conversation turns) |
| .profile | Style preferences (response format shaping) |
| .interest | Topic weighting (upweight relevant domains) |

## Correction Detection

Patterns detected for DPO pair generation:
- Explicit rephrase: "Too long", "Shorter please"
- "No, I meant..." corrections
- Silent abandonment → retry (5+ min gap then rephrase)

## Output

Generates files in ~/Library/Application Support/fae/training/data/:
- train.jsonl — Weighted SFT training examples (80% split)
- valid.jsonl — Validation examples (20% split)
- dpo_pairs.jsonl — Correction-based preference pairs
- meta.json — Dataset statistics and quality report
