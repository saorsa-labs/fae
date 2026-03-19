# PLAN-phase-1.2: Wire runtime.start to PipelineCoordinator

**Status:** Ready to implement
**Phase:** 1.2 — Wire runtime.start to PipelineCoordinator
**Milestone:** 1 — Core Pipeline & Linker Fix

---

## Problem Statement

`request_runtime_start()` in `FaeDeviceTransferHandler` just logs `"runtime.start requested"` and returns `Ok(())`. No PipelineCoordinator is created, no models are loaded, no audio pipeline runs. The voice pipeline is completely disconnected from the FFI surface.

## Architecture Overview

```
Swift sends: {"command":"runtime.start","v":1,"request_id":"...","payload":{}}
  → fae_core_send_command → HostCommandServer → route() → handle_runtime_start()
    → handler.request_runtime_start()  ← CURRENTLY A STUB
```

**Goal:** `request_runtime_start()` must:
1. Load/initialize models (STT, LLM, TTS)
2. Create PipelineCoordinator with channels
3. Spawn the pipeline on the tokio runtime
4. Forward RuntimeEvents → FFI event broadcast
5. Store handles for stop/status queries

## Design Decisions

- Handler needs a reference to the tokio runtime and the FFI event broadcast channel
- Pipeline channels (text_injection_tx, gate_cmd_tx) stored on handler for use by other commands
- CancellationToken stored for runtime.stop
- Pipeline state tracked as an enum (Stopped/Starting/Running/Error)
- Model loading is async — handler needs to spawn onto a runtime
- The handler trait methods are sync (`&self -> Result<()>`) so we need interior mutability for pipeline state

---

## Tasks

### Task 1: Add pipeline state and channels to FaeDeviceTransferHandler

**Description:** Add fields to the handler for pipeline lifecycle management: pipeline state enum, cancellation token, text injection sender, gate command sender, tool approval sender, runtime event bridge handle.

**Files:**
- `src/host/handler.rs`

**Details:**
- Add `PipelineState` enum: `Stopped`, `Starting`, `Running`, `Stopping`, `Error(String)`
- Add fields behind `Mutex`:
  - `pipeline_state: Mutex<PipelineState>`
  - `cancel_token: Mutex<Option<CancellationToken>>`
  - `pipeline_handle: Mutex<Option<tokio::task::JoinHandle<()>>>`
  - `text_injection_tx: Mutex<Option<mpsc::UnboundedSender<TextInjection>>>`
  - `gate_cmd_tx: Mutex<Option<mpsc::UnboundedSender<GateCommand>>>`
  - `tool_approval_tx: Mutex<Option<mpsc::UnboundedSender<ToolApprovalRequest>>>`
- Add `tokio_handle: tokio::runtime::Handle` (set at construction)
- Add `event_tx: broadcast::Sender<EventEnvelope>` (set at construction)
- Update `new()` and `from_default_path()` signatures to accept these

**Acceptance:**
- `cargo check` passes
- Zero clippy warnings
- Existing tests still pass

---

### Task 2: Wire FaeDeviceTransferHandler construction in ffi.rs

**Description:** Pass the tokio runtime handle and event broadcast sender to the handler when constructing it in `fae_core_init`.

**Files:**
- `src/ffi.rs`
- `src/host/handler.rs`

**Details:**
- `FaeDeviceTransferHandler::new()` gains `tokio_handle: tokio::runtime::Handle` and `event_tx: broadcast::Sender<EventEnvelope>` params
- `from_default_path()` also gains these params
- In `fae_core_init`, pass `tokio_rt.handle().clone()` and `event_tx.clone()` (from the broadcast channel already created via `command_channel`)
- The event_tx must be the same one used by HostCommandServer so events reach Swift

**Acceptance:**
- `cargo check` passes
- Zero clippy warnings
- Existing handler tests updated with mock handles

---

### Task 3: Implement model loading in request_runtime_start

**Description:** `request_runtime_start()` downloads/initializes STT, LLM, TTS models using `startup::initialize_models()`, emitting progress events.

**Files:**
- `src/host/handler.rs`
- `src/startup.rs` (read for API)

**Details:**
- Check current state — if already Running or Starting, return error
- Set state to Starting
- Spawn async task on `tokio_handle`:
  - Call `startup::initialize_models(&config, progress_callback)`
  - On success: store InitializedModels, proceed to pipeline creation (Task 4)
  - On failure: set state to Error, emit runtime.error event
- Emit `runtime.starting` event with model download info
- Progress callback emits `runtime.progress` events through event_tx

**Acceptance:**
- `cargo check` passes
- Zero clippy warnings

---

### Task 4: Create and spawn PipelineCoordinator

**Description:** After models are loaded, build the PipelineCoordinator with channels and spawn it on the tokio runtime.

**Files:**
- `src/host/handler.rs`

**Details:**
- Create channels: `mpsc::unbounded_channel()` for text_injection, gate_commands, tool_approval
- Create `broadcast::channel()` for RuntimeEvents
- Build coordinator:
  ```
  PipelineCoordinator::with_models(config, models)
      .with_text_injection(text_rx)
      .with_gate_commands(gate_rx)
      .with_tool_approvals(approval_tx)
      .with_runtime_events(runtime_event_tx)
      .with_console_output(false)  // No stdout in embedded mode
  ```
- Store senders in handler fields (for use by inject_text, gate_set, etc.)
- Spawn `coordinator.run()` on tokio, store JoinHandle
- Store CancellationToken for stop
- Set state to Running
- Emit `runtime.started` event

**Acceptance:**
- `cargo check` passes
- Zero clippy warnings

---

### Task 5: Forward RuntimeEvents from pipeline → FFI event broadcast

**Description:** Bridge the pipeline's `broadcast::Sender<RuntimeEvent>` to the FFI `broadcast::Sender<EventEnvelope>` so events reach Swift.

**Files:**
- `src/host/handler.rs`

**Details:**
- Spawn a bridge task that subscribes to the RuntimeEvent broadcast
- Map each RuntimeEvent variant to an EventEnvelope with appropriate event name:
  - `RuntimeEvent::Transcription(t)` → `"pipeline.transcription"` + `{text, is_final}`
  - `RuntimeEvent::AssistantSentence(s)` → `"pipeline.assistant_sentence"` + `{text, is_final}`
  - `RuntimeEvent::AssistantGenerating{active}` → `"pipeline.generating"` + `{active}`
  - `RuntimeEvent::ToolCall{..}` → `"pipeline.tool_call"` + `{id, name, input_json}`
  - `RuntimeEvent::ToolResult{..}` → `"pipeline.tool_result"` + `{id, name, success, output_text}`
  - `RuntimeEvent::Control(c)` → `"pipeline.control"` + control-specific payload
  - `RuntimeEvent::AssistantAudioLevel{rms}` → `"pipeline.audio_level"` + `{rms}`
  - `RuntimeEvent::MemoryRecall{..}` → `"pipeline.memory_recall"` + payload
  - `RuntimeEvent::MemoryWrite{..}` → `"pipeline.memory_write"` + payload
- Send each mapped EventEnvelope on the FFI event_tx
- Bridge task runs until cancelled

**Acceptance:**
- `cargo check` passes
- Zero clippy warnings

---

### Task 6: Implement runtime.stop and runtime.status

**Description:** Wire `request_runtime_stop()` to cancel the pipeline and `query_runtime_status()` to return real state.

**Files:**
- `src/host/handler.rs`

**Details:**
- `request_runtime_stop()`:
  - Cancel via CancellationToken
  - Abort the JoinHandle
  - Drop text_injection_tx, gate_cmd_tx (closes channels)
  - Set state to Stopped
  - Emit `runtime.stopped` event
- `query_runtime_status()`:
  - Return real pipeline state as JSON:
    ```json
    {
      "status": "running|stopped|starting|error",
      "error": "...",  // if Error state
      "uptime_secs": 123  // if Running
    }
    ```
- Track pipeline start time for uptime calculation

**Acceptance:**
- `cargo check` passes
- Zero clippy warnings

---

### Task 7: Update existing handler tests

**Description:** Update all existing tests to work with the new handler constructor signature (tokio handle + event channel).

**Files:**
- `src/host/handler.rs` (tests module)

**Details:**
- `temp_handler()` helper now creates a tokio runtime and broadcast channel
- All existing tests should pass unchanged functionally
- Add new tests:
  - `runtime_start_transitions_to_starting` — verify state change
  - `runtime_stop_on_stopped_returns_error` — idempotency check
  - `runtime_status_returns_stopped_by_default` — default state

**Acceptance:**
- `cargo test` passes including all handler tests
- Zero clippy warnings

---

### Task 8: Integration test — start/stop lifecycle

**Description:** End-to-end test that sends runtime.start through the command channel, verifies events are emitted, then sends runtime.stop.

**Files:**
- `src/host/handler.rs` (or new integration test)

**Details:**
- Create handler with real tokio runtime
- Create command_channel with the handler
- Send RuntimeStart command
- Verify response is ok
- Verify state transitions (may need to poll)
- Send RuntimeStop command
- Verify clean shutdown
- Note: Full model loading will timeout in tests — may need a test config with mock/skip models

**Acceptance:**
- `cargo test` passes
- Zero clippy warnings
- Clean start/stop lifecycle verified
