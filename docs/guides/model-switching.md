# Local Model Switching (Swift Runtime)

Fae's primary local architecture is now:

- one active Qwen3.5 text model
- one optional on-demand Qwen3-VL vision model

The dual / concierge path is no longer the recommended local setup.

Canonical reference:

- [Local model strategy](/Users/davidirvine/Desktop/Devel/projects/fae/docs/guides/local-model-strategy.md)

## Preferred user path

Ask Fae conversationally to switch models instead of editing config by hand.

Examples:

- "Switch my voice model to Qwen3.5 4B"
- "Set my voice model preset to auto"
- "Switch vision to auto"

## Supported text presets

User-facing text model presets:

- `auto`
- `qwen3_5_2b`
- `qwen3_5_4b`
- `qwen3_5_9b` (default for 16+ GB — Unsloth mixed-bit quantization)
- `qwen3_5_35b_a3b` (MoE: 35B total, 3B active per token — manual only)

`Auto (Recommended)` resolves by RAM:

| System RAM | Auto text model | Context |
|---|---|---|
| `<8 GB` | `Qwen3.5 2B` OptiQ | 32K |
| `8–15 GB` | `Qwen3.5 4B` (uniform 4-bit) | 32K |
| `16+ GB` | `Qwen3.5 9B Unsloth` (mixed-bit) | 32K |

The 9B Unsloth model uses per-tensor mixed-bit quantization (imatrix-calibrated) from Unsloth Dynamic 2.0. Benchmarked 2026-03-28: 100% tool calling, 100% assistant fit, 100% Fae capability, 100% serialization. Outperforms 35B-A3B on all Fae-relevant quality metrics at 2x speed and 1/3 memory.

Legacy compatibility aliases:

- `saorsa_1_1_tiny` resolves to `qwen3_5_2b`

## Supported vision presets

User-facing vision presets:

- `auto`
- `qwen3_5_35b_a3b_vlm` (uses same 35B-A3B model for vision — 64+ GB)
- `qwen3_vl_4b_4bit`
- `qwen3_vl_4b_8bit`

`Auto` resolves by RAM:

| System RAM | Auto deep VLM | Auto fast VLM |
|---|---|---|
| `<16 GB` | disabled | disabled |
| `16+ GB` | `SmolVLM2-500M` (1.8 GB, on-demand) | `SmolVLM2-256M` (<1 GB, always-on) |

## Persistence

The settings are persisted in:

- `~/Library/Application Support/fae/config.toml`
- `[llm].voiceModelPreset`
- `[vision].modelPreset`
- `[vision].enabled`

UI path:

- **Settings → Models & Performance → Local LLM Stack**
- **Settings → Models & Performance → Vision**

## Runtime behavior

- Changing the text preset persists immediately.
- Fae reloads the local pipeline in-app. A full app restart is not required for normal switching.
- If the selected text model is not cached, Fae downloads it during that reload.
- Changing the vision preset unloads the current VLM; the next vision turn loads the selected VLM on demand.
- Runtime diagnostics continue to use the internal `operator` naming for the active text model worker.
- Legacy concierge settings remain in the config/runtime for compatibility, but they are not the recommended product path.

## Notes

- Fae's local runtime is Swift-native (`MLX`, `MLXVLM`, `Core ML`).
- Legacy Rust and old saorsa1-specific switching docs are historical only.
