# Known Issues

## Qwen3.5-9B-4bit fails to load in FaeEvalServer

The mlx-community/Qwen3.5-9B-4bit model crashes with `Key language_model.model.layers.31.mlp.up_proj.weight not found in Qwen3NextMLP.Linear`.

Root cause: The VL model weights have a structure mismatch with the vendored mlx-swift-lm `Qwen35Model` class for this specific model size. The 27B and 0.8B models with the same `model_type: qwen3_5` load fine.

Fix needed in: `Vendor/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`

Working models: qwen3.5-0.8b, qwen3.5-2b, qwen3.5-27b, qwen3.5-35b-a3b, qwen3.5-27b-opus-distilled
