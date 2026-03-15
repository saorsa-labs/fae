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
- `saorsa_1_1_tiny`
- `qwen3_5_4b`
- `qwen3_5_35b_a3b` (medium — MoE: 35B total, 3B active per token)

`Auto (Recommended)` resolves by RAM:

| System RAM | Auto text model | Context |
|---|---|---|
| `<16 GB` | `saorsa-1.1-tiny` (fine-tuned 2B) | 32K |
| `16–31 GB` | `Qwen3.5 4B` | 32K |
| `32–63 GB` | `Qwen3.5 35B-A3B` MoE | 32K |
| `64+ GB` | `Qwen3.5 35B-A3B` MoE | 128K |

The 35B-A3B uses Gated DeltaNet + sparse MoE (256 experts, 8+1 active). Only 3B parameters activate per token, so inference speed is comparable to a 3B dense model despite 35B total knowledge. Natively multimodal (text + vision).

Legacy compatibility aliases:

- `qwen3_5_2b` resolves to `saorsa_1_1_tiny`
- `qwen3_5_9b` resolves to `qwen3_5_4b`
- `qwen3_5_27b` resolves to `qwen3_5_35b_a3b`

## Supported vision presets

User-facing vision presets:

- `auto`
- `qwen3_5_35b_a3b_vlm` (uses same 35B-A3B model for vision — 64+ GB)
- `qwen3_vl_4b_4bit`
- `qwen3_vl_4b_8bit`

`Auto` resolves by RAM:

| System RAM | Auto vision model |
|---|---|
| `<16 GB` | disabled |
| `16–31 GB` | `Qwen3-VL-4B (4-bit)` |
| `32–63 GB` | `Qwen3-VL-4B (8-bit)` |
| `64+ GB` | `Qwen3.5 35B-A3B` (natively multimodal) |

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
