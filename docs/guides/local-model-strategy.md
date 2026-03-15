# Local Model Strategy

Last updated: March 15, 2026

This is the current canonical guide for Fae's local model stack.

## Product direction

Fae now prioritizes a single local text model:

- one active Qwen3.5 text model for conversation, reasoning, and tool use
- one on-demand Qwen3-VL model for screen and camera understanding
- no dual concierge path in the default product architecture

The old dual-model / concierge path remains in the codebase only as a legacy compatibility path. It is not the recommended local setup and should not be treated as the primary runtime design.

Historical architecture notes under `docs/architecture/*dual-model*` are planning documents, not current product guidance.

## Text model strategy

Fae now uses a three-model local text suite:

- `saorsa-1.1-tiny` — our trained `Qwen3.5 2B`
- `Qwen3.5 4B` — the small local model
- `Qwen3.5 35B-A3B` — the medium/high-capability MoE model

### Auto text model selection

`Auto (Recommended)` resolves by installed system RAM:

| System RAM | Auto model | Context |
|---|---|---:|
| `8–15 GB` | `saorsa-labs/saorsa-1.1-tiny` | `32,768` |
| `16–31 GB` | `mlx-community/Qwen3.5-4B-4bit` | `32,768` |
| `32–63 GB` | `mlx-community/Qwen3.5-35B-A3B-4bit` | `32,768` |
| `64+ GB` | `mlx-community/Qwen3.5-35B-A3B-4bit` | `131,072` |

### Manual text tiers

These are the supported user-facing presets:

| Preset | Model | RAM guidance | Role |
|---|---|---|---|
| `saorsa-1.1-tiny` | `saorsa-labs/saorsa-1.1-tiny` | `8+ GB` | Compact trained fallback |
| `Qwen3.5 4B` | `mlx-community/Qwen3.5-4B-4bit` | `16+ GB` | Small general model |
| `Qwen3.5 35B-A3B` | `mlx-community/Qwen3.5-35B-A3B-4bit` | `32+ GB` | Medium/high-capability MoE model |

Legacy compatibility aliases:

- `qwen3_5_2b` resolves to `saorsa-1.1-tiny`
- `qwen3_5_9b` resolves to `Qwen3.5 4B`
- `qwen3_5_27b` resolves to `Qwen3.5 35B-A3B`

### Current recommendation

- compact fallback: `saorsa-1.1-tiny`
- small local default: `Qwen3.5 4B`
- medium local default on larger Macs: `Qwen3.5 35B-A3B`

### Current scope

The current shipped suite intentionally does not include `9B` or `27B`.

- `9B` has been dropped from the active product ladder
- `27B` has been dropped from the active product ladder
- future larger-model work should start from the next Qwen3.5 large tier, not restore the old `9B/27B` path

## Vision model strategy

Vision is a separate on-demand VLM. It is not loaded at startup.

### Auto vision selection

| System RAM | Auto vision model | Context |
|---|---|---:|
| `<16 GB` | disabled | - |
| `16–31 GB` | `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit` | `16,384` |
| `32+ GB` | `mlx-community/Qwen3-VL-4B-Instruct-8bit` | `16,384` |

This keeps the primary text model responsive while still allowing screenshot and camera tools when needed.

## Speech models

The rest of the local stack is selected separately:

| Component | Auto selection |
|---|---|
| STT | `Qwen3-ASR-1.7B-4bit` at `16+ GB`, otherwise `Qwen3-ASR-0.6B-4bit` |
| TTS | `hexgrad/Kokoro-82M` |

## Switching behavior

- Changing the text model preset triggers an in-app pipeline reload.
- A full app restart is not required for normal model switching.
- If a selected model is not cached locally, Fae downloads it during that reload.
- Changing the vision preset unloads the current VLM; the next vision turn loads the selected VLM on demand.

## Source of truth

The current runtime selection logic lives in:

- [FaeConfig.swift](/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/Core/FaeConfig.swift)
- [LocalModelCatalog.swift](/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/Sources/Fae/LocalModelCatalog.swift)
