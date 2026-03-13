# Local Model Strategy

Last updated: March 13, 2026

This is the current canonical guide for Fae's local model stack.

## Product direction

Fae now prioritizes a single local text model:

- one active Qwen3.5 text model for conversation, reasoning, and tool use
- one on-demand Qwen3-VL model for screen and camera understanding
- no dual concierge path in the default product architecture

The old dual-model / concierge path remains in the codebase only as a legacy compatibility path. It is not the recommended local setup and should not be treated as the primary runtime design.

Historical architecture notes under `docs/architecture/*dual-model*` are planning documents, not current product guidance.

## Text model strategy

Fae uses the Qwen3.5 MLX line for local text inference.

### Auto text model selection

`Auto (Recommended)` resolves by installed system RAM:

| System RAM | Auto model | Context |
|---|---|---:|
| `8–15 GB` | `mlx-community/Qwen3.5-2B-4bit` | `32,768` |
| `16–31 GB` | `mlx-community/Qwen3.5-4B-4bit` | `32,768` |
| `32+ GB` | `mlx-community/Qwen3.5-9B-4bit` | `32,768` |

### Manual text quality tiers

These are available as explicit user choices, but they are not selected by `Auto`:

| Preset | Model | RAM guidance | Why manual-only |
|---|---|---|---|
| `Qwen3.5 27B` | `mlx-community/Qwen3.5-27B-4bit` | `32+ GB` | Better quality, but much slower first-turn latency |
| `Qwen3.5 35B-A3B` | `mlx-community/Qwen3.5-35B-A3B-4bit` | `48+ GB` | Highest local quality tier, but too latency-heavy for default use |

### Current recommendation

- default local mode: `Qwen3.5 4B`
- higher-quality local mode: `Qwen3.5 9B`
- compact fallback: `Qwen3.5 2B`

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
