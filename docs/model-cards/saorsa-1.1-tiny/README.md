# saorsa-1.1-tiny

`saorsa-1.1-tiny` is Saorsa Labs' low-memory local assistant model for Fae.

- Base model: `mlx-community/Qwen3.5-2B-4bit`
- Post-training method: ORPO on Fae's assistant, tool-judgment, and memory-preference data
- Intended tier: `8–15 GB` Macs
- Intended role: compact local operator with stronger tool use and assistant fit than the base 2B model

## Why this model exists

Fae's low-RAM lane needs better tool calling and assistant behavior than a stock compact model can reliably provide. The current `saorsa-1.1-tiny` retrain improves the base 2B model where the low-memory lane was weakest: tool choice and assistant-fit behavior.

## Benchmark delta vs base Qwen3.5-2B

Targeted benchmark gate:

- Tool calling: `9/10 -> 10/10`
- Fae capability: `9/20 -> 9/20`
- Assistant fit: `7/20 -> 9/20`
- Serialization: `9/9 -> 9/9`
- `/no_think` compliance: `5/5 -> 5/5`

Artifacts in the Fae repo:

- Base benchmark: `scripts/benchmark-results/qwen3.5-2b_targeted_20260314-current.json`
- Fine-tuned benchmark: `scripts/benchmark-results/qwen35-2b-orpo16fullmlp-exact_targeted_20260314-2004.json`

## Usage

This model is intended to replace the standard `2B` auto-selected lane in Fae while leaving the `4B`, `9B`, and `27B` lanes unchanged.

## Notes

- This is a Qwen-compatible MLX model and is intended for local Apple Silicon inference.
- Training data and extraction scripts live in the Fae repository.
- The model is designed for assistant behavior, tool choice, and memory judgment, not generic leaderboard optimization.
