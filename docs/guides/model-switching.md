# Voice Model Preset Switching (Swift Runtime)

Fae runs locally on-device and supports switching the local **operator model preset** for the main LLM path. On supported machines, Fae can also load an optional **concierge** model for richer synthesis.

## What is supported

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

Preferred path: ask Fae to switch voice model preset conversationally.

Examples:
- "Switch my voice model to qwen3_5_4b"
- "Set voice model preset to auto"

You can switch the preset used by local inference:

- `auto` (current default — favors the benchmark-backed fast operator tier)
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

- **Settings → Models & Performance → Local LLM Stack**
- legacy path: **Settings → Models → Voice Model**

## Runtime behavior

- Changing the preset updates config immediately.
- Model swap takes effect on next pipeline/model load.
- In current app UX, restart is recommended after changing preset.
- `auto` now follows the benchmark-backed operator policy:
  - 12+ GB: `qwen3_5_2b` at 16K context
  - below 12 GB: `qwen3_5_0_8b` at 8K context
- The heavier `qwen3_5_4b`, `qwen3_5_9b`, `qwen3_5_27b`, and `qwen3_5_35b_a3b` presets remain manual opt-in choices for users who prefer more local depth over faster startup and foreground responsiveness.
- When dual-model local mode is enabled on 32+ GB systems, the current concierge default is `LiquidAI/LFM2-24B-A2B-MLX-4bit`.
- Premium local mode now targets a **worker-backed** split: operator and concierge inference run in dedicated LLM worker processes while Kokoro remains in the main app process.
- Inference priority is explicitly ordered as **operator > Kokoro > concierge**.
- Runtime diagnostics for operator/concierge load state, current route, and fallback status are shown in **Settings → Diagnostics → Voice → Local model runtime**.

## Notes

- Fae currently runs a Swift-native local stack (MLX/Core ML).
- The legacy Rust/API backend switching docs are historical and not the active runtime path.
