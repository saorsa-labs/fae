# Phase 5.2: Error Recovery & Resilience

**Milestone**: 5 — Handoff & Production Polish
**Status**: Pending
**Total Tasks**: 8

## Overview

Add production-grade error recovery and resilience to the Fae pipeline and app.
The pipeline currently has no auto-restart on crash, no model integrity checks,
no audio device hot-swap handling, no graceful degradation when STT/TTS unavailable,
no memory pressure handling, no structured diagnostic log rotation, and no crash
reporting. This phase adds all of these.

---

## Task 1: Pipeline Crash Recovery — Auto-Restart with Backoff

**Goal**: When the `PipelineCoordinator` task panics or exits unexpectedly,
the handler automatically restarts it with exponential backoff.

**Acceptance Criteria**:
- Add `restart_policy` to `FaeDeviceTransferHandler`: max 5 attempts, delays
  [1s, 2s, 4s, 8s, 16s]
- Monitor pipeline `JoinHandle` in a watcher task; detect unexpected exit
- On unexpected exit: update `PipelineState::Error`, wait backoff, restart
- On clean stop (cancel token): do NOT restart
- Emit `pipeline.control` event with `"action": "auto_restart"` + attempt count
- Reset backoff counter on successful run > 30s
- Add `restart_count: u32` and `last_restart_at: Option<Instant>` to handler state
- Tests: verify restart emits event, verify clean stop does not restart

**Files**:
- `src/host/handler.rs` (edit — add restart watcher task + restart_policy)

---

## Task 2: Model Corruption Detection — Re-download on Checksum Mismatch

**Goal**: Before starting the pipeline, verify model files with SHA-256 checksums.
If corrupt, delete and re-download.

**Acceptance Criteria**:
- Create `src/model_integrity.rs` with `ModelIntegrityChecker`
- `verify(path: &Path, expected_sha256: Option<&str>) -> IntegrityResult` enum
  (Ok, Missing, Corrupt, NoChecksum)
- If `NoChecksum`: skip verification (no known expected hash), return Ok
- If `Corrupt` or `Missing`: emit progress event `"model.integrity_failed"` then
  trigger re-download via existing `initialize_models_with_progress`
- Integrate into `request_runtime_start()` before `PipelineCoordinator` construction
- Checksums stored in config under `[model_checksums]` table (optional section)
- Tests: verify(existing file) = Ok, verify(corrupt bytes) = Corrupt,
  verify(missing) = Missing

**Files**:
- `src/model_integrity.rs` (new)
- `src/lib.rs` (add `pub mod model_integrity;`)
- `src/host/handler.rs` (call integrity check in request_runtime_start)

---

## Task 3: Audio Device Hot-Swap Handling

**Goal**: When the user changes audio input/output devices (e.g., plugs in headphones),
the pipeline captures from the new device without requiring a restart.

**Acceptance Criteria**:
- Add `AudioDeviceWatcher` in `src/audio/device_watcher.rs` using `cpal`'s
  `available_input_devices()` + a polling loop (every 2s) or platform notification
- On device change: send `GateCommand::RestartAudio` (new variant) to the pipeline
- `PipelineCoordinator` handles `RestartAudio`: stops capture task, re-creates
  `CpalCapture` with new default device, restarts capture task
- Emit `pipeline.control` event `"action": "audio_device_changed"` with device name
- If no input devices: transition to text-only mode (Task 6)
- Tests: `AudioDeviceWatcher` detects mock device list change

**Files**:
- `src/audio/device_watcher.rs` (new)
- `src/audio/mod.rs` (add `pub mod device_watcher;`)
- `src/pipeline/messages.rs` (add `GateCommand::RestartAudio`)
- `src/pipeline/coordinator.rs` (handle RestartAudio gate command)
- `src/host/handler.rs` (start device watcher on pipeline start)

---

## Task 4: Network Resilience for External LLM Fallback

**Goal**: When the external/cloud LLM is unreachable, retry with backoff then
fall back to local model. When local is also unavailable, surface a clear error.

**Acceptance Criteria**:
- Add `FallbackChain` struct in `src/llm/fallback.rs` (if not already present)
  with ordered list of providers; try each in sequence on connection error
- Retry policy: 3 attempts with 500ms backoff before trying next provider
- Distinguish transient errors (timeout, 5xx) from permanent (auth failure, 4xx)
- Permanent errors: skip to next provider immediately
- Emit `pipeline.control` event `"action": "provider_fallback"` with provider name
- Add `network_timeout_ms: u64` to `LlmConfig` (default 30_000)
- Tests: fallback chain tries providers in order; permanent error skips retries

**Files**:
- `src/llm/fallback.rs` (new or edit if exists)
- `src/llm/mod.rs` (add/update `pub mod fallback;`)
- `src/config.rs` (add `network_timeout_ms` to `LlmConfig`)

---

## Task 5: Memory Pressure Handling — Reduce Model Quality on Low RAM

**Goal**: Monitor system RAM. When free memory falls below a threshold, switch
to a lighter model tier to avoid OOM crashes.

**Acceptance Criteria**:
- Create `src/memory_pressure.rs` with `MemoryPressureMonitor`
- `available_memory_mb() -> u64` using `sysinfo` crate (already a dep) or
  `sys_info`; poll every 30s
- Thresholds: `warning` = 1024 MB free, `critical` = 512 MB free
- On `warning`: emit `pipeline.control` event `"action": "memory_pressure_warning"`
  with `available_mb`
- On `critical`: emit `"action": "memory_pressure_critical"` — handler logs warning
  (full model swap deferred to future phase, this phase is monitoring + events)
- On recovery above warning: emit `"action": "memory_pressure_cleared"`
- Tests: threshold transitions, recovery detection

**Files**:
- `src/memory_pressure.rs` (new)
- `src/lib.rs` (add `pub mod memory_pressure;`)
- `src/host/handler.rs` (start monitor in request_runtime_start, stop in runtime_stop)

---

## Task 6: Graceful Degradation — Text-Only Mode

**Goal**: When STT or TTS is unavailable (device missing, model load failure),
the pipeline degrades to text-only mode rather than failing entirely.

**Acceptance Criteria**:
- Add `PipelineMode` enum in `src/pipeline/mod.rs`:
  `Full`, `TextOnly`, `LlmOnly` (no STT/TTS)
- In `PipelineCoordinator::run()`, detect when audio capture/STT fails to start:
  log warning and switch to `TextOnly` (skip audio capture + VAD + STT stages,
  only accept `TextInjection` inputs)
- Detect when TTS/playback fails: switch to `LlmOnly` (skip TTS/playback stages,
  emit text events but no audio)
- Emit `pipeline.control` event `"action": "degraded_mode"` with `"mode"` field
- Add `current_mode: PipelineMode` to `FaeDeviceTransferHandler` status
- Tests: `TextOnly` mode processes injected text without audio stages

**Files**:
- `src/pipeline/mod.rs` (add `PipelineMode` enum)
- `src/pipeline/coordinator.rs` (mode detection + fallback logic)
- `src/host/handler.rs` (report mode in runtime.status)

---

## Task 7: Diagnostic Logging with Log Rotation

**Goal**: Persist structured diagnostic logs to `~/.fae/logs/` with automatic
rotation (keep last 7 days / 10 files).

**Acceptance Criteria**:
- Create `src/diagnostics/log_rotation.rs` with `RotatingFileWriter`
- Writes to `~/.fae/logs/fae-YYYY-MM-DD.log`
- On open: delete log files older than 7 days or beyond 10 file limit
- Format: `[timestamp] [level] [target] message\n` (plain text, not JSON)
- Integrate into `src/diagnostics.rs` (or create new if needed): call
  `init_log_rotation()` from app startup
- `init_log_rotation()` installs a `tracing_subscriber` file layer alongside
  the existing stderr layer
- Tests: rotation deletes old files, new file per day, file naming convention

**Files**:
- `src/diagnostics/log_rotation.rs` (new)
- `src/diagnostics.rs` or `src/diagnostics/mod.rs` (add init_log_rotation)

---

## Task 8: Integration Tests for Error Recovery

**Goal**: Comprehensive tests covering the new resilience mechanisms.

**Acceptance Criteria**:
- `tests/error_recovery.rs` with test cases:
  - `test_model_integrity_missing`: verify() on missing path = Missing
  - `test_model_integrity_corrupt`: verify() on wrong-content file = Corrupt
  - `test_model_integrity_ok`: verify() on real file = Ok
  - `test_memory_pressure_thresholds`: PressureMonitor emits correct transitions
  - `test_graceful_degradation_text_only`: PipelineMode::TextOnly is parseable/displayable
  - `test_pipeline_mode_display`: all PipelineMode variants have Display impl
  - `test_fallback_chain_ordering`: FallbackChain tries providers in order
  - `test_log_rotation_cleanup`: RotatingFileWriter removes old files
- All existing tests continue to pass
- Zero clippy warnings
- `just check` passes (fmt, lint, build-strict, test, doc, panic-scan)

**Files**:
- `tests/error_recovery.rs` (new)

---

## Success Metrics
- 8/8 tasks complete
- Pipeline auto-restarts on crash (max 5 attempts)
- Model integrity verified before pipeline start
- Audio device changes handled without full restart
- LLM fallback chain retries on network error
- Memory pressure monitoring active with threshold events
- Text-only degradation when audio unavailable
- Logs rotate in `~/.fae/logs/`
- Integration tests pass
- Zero warnings, zero test failures
