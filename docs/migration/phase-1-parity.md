# Phase 1 Parity

## Current verified status

- SwiftPM app target in `native/macos/Fae` builds and tests cleanly in current workspace runs.
- Baseline Phase 1 parity items for config persistence and pipeline observability are implemented and passing existing tests.

## P0 blockers

- No new P0 blockers identified in this pass.
- Remaining Phase 1 completion risk is primarily verification depth (broader runtime/manual validation), not compile/test breakage.

## Implemented in this pass

- **#28 Config persistence**
  - Replaced config persistence stubs in `FaeConfig.swift` with working Foundation-only TOML-like load/save.
  - Added `load(from:)` and `save(to:)` path-based methods, atomic writes, parent directory creation, defaults fallback, and parse failure logging.
  - Enforced full-default fallback on malformed known syntax/values while still ignoring unknown keys.

- **#34 Degraded mode reporting**
  - Added canonical pipeline degraded mode state reporting (`full`, `noSTT`, `noLLM`, `noTTS`, `unavailable`).
  - Evaluated at safe points (startup and pre-processing/generation checks).
  - Emitted transition-only observable signal (additive event/logging) without changing routing behavior.

- **#35 Metrics hooks**
  - Added additive Phase 1 observability hooks in `PipelineCoordinator`:
    - `phase1.first_audio_latency_ms`
    - `phase1.stt_latency_ms`
    - `phase1.llm_token_throughput_tps`
    - `phase1.tts_first_chunk_latency_ms`
  - Emission is once per relevant stage/turn to avoid spam.
  - No behavior/routing changes.

## Lifecycle semantics note

- Runtime lifecycle progress now includes explicit `load_started`/`load_complete` around model loads and `verify_started`/`verify_complete` before final `ready`.
- Download stages (`download_started`, `download_progress`, `download_complete`, `cached`, `aggregate_progress`) remain pass-through when emitted.

## Model tier notes

- Current Swift model selection includes `mlx-community/Qwen3.5-35B-A3B-4bit` as the high-tier option for capable memory tiers.
- This tier is treated as a significant quality upgrade for complex reasoning workloads while lower tiers remain available for constrained systems.

## Next steps

- Add/expand focused tests for degraded-mode transitions and observability emissions where practical.
- Validate metrics/degraded-mode visibility in normal app runtime surfaces (logs/event consumers).
- Continue Phase 1 parity checklist closure and track any regressions in migration status docs.
