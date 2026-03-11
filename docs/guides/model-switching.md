# Voice Model Preset Switching (Swift Runtime)

Fae runs locally on-device and supports switching the local **operator model preset** for the main LLM path. On supported machines, Fae can also load an optional **concierge** model for richer synthesis.

## What is supported

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

Preferred path: ask Fae to switch voice model preset conversationally.

Examples:
- "Switch my voice model to qwen3_5_4b"
- "Set voice model preset to auto"

You can switch the preset used by local inference:

- `auto` (current default — favors the saorsa1 local operator tier)
- `saorsa1-worker`
- `saorsa1-tiny`

Legacy Qwen/Qwen3.5 preset keys are still accepted for backward compatibility, but they are migrated internally onto the nearest `saorsa1` operator model.

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
- `auto` now follows the saorsa1 operator policy:
  - 12+ GB: `saorsa1-worker` at 32K context
  - below 12 GB: `saorsa1-tiny` at 32K context
- When dual-model local mode is enabled on 32+ GB systems, the current concierge default is `saorsa-labs/saorsa1-concierge-pre-release`.
- Premium local mode now targets a **worker-backed** split: operator and concierge inference run in dedicated LLM worker processes while Kokoro remains in the main app process.
- Inference priority is explicitly ordered as **operator > Kokoro > concierge**.
- Runtime diagnostics for operator/concierge load state, current route, and fallback status are shown in **Settings → Diagnostics → Voice → Local model runtime**.

## Notes

- Fae currently runs a Swift-native local stack (MLX/Core ML).
- The legacy Rust/API backend switching docs are historical and not the active runtime path.
