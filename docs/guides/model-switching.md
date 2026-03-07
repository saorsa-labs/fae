# Voice Model Preset Switching (Swift Runtime)

Fae runs locally on-device and supports switching **voice model presets** for the LLM.

## What is supported

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

Preferred path: ask Fae to switch voice model preset conversationally.

Examples:
- "Switch my voice model to qwen3_5_4b"
- "Set voice model preset to auto"

You can switch the preset used by local inference:

- `auto` (current default — presently resolves to `qwen3_5_2b` on all machines while benchmarking settles)
- `qwen3_5_35b_a3b`
- `qwen3_5_27b`
- `qwen3_5_9b`
- `qwen3_5_4b`
- `qwen3_5_2b`
- `qwen3_5_0_8b`

Legacy Qwen3 preset keys still load for backward compatibility, but they are migrated internally to the nearest Qwen3.5 preset.

The setting is persisted in:

- `~/Library/Application Support/fae/config.toml`
- key: `[llm].voiceModelPreset`

UI path:

- **Settings → Models → Voice Model**

## Runtime behavior

- Changing the preset updates config immediately.
- Model swap takes effect on next pipeline/model load.
- In current app UX, restart is recommended after changing preset.
- `auto` is currently pinned by benchmark policy to Qwen3.5-2B for every machine tier; this overrides the older RAM-tiered auto-selection behavior until benchmarking is complete.

## Notes

- Fae currently runs a Swift-native local stack (MLX/Core ML).
- The legacy Rust/API backend switching docs are historical and not the active runtime path.
