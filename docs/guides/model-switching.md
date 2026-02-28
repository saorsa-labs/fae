# Voice Model Preset Switching (Swift Runtime)

Fae runs locally on-device and supports switching **voice model presets** for the LLM.

## What is supported

You can switch the preset used by local inference:

- `auto` (recommended)
- `qwen3_8b`
- `qwen3_4b`
- `qwen3_1_7b`
- `qwen3_0_6b`

The setting is persisted in:

- `~/Library/Application Support/fae/config.toml`
- key: `[llm].voiceModelPreset`

UI path:

- **Settings → Models → Voice Model**

## Runtime behavior

- Changing the preset updates config immediately.
- Model swap takes effect on next pipeline/model load.
- In current app UX, restart is recommended after changing preset.

## Notes

- Fae currently runs a Swift-native local stack (MLX/Core ML).
- The legacy Rust/API backend switching docs are historical and not the active runtime path.
