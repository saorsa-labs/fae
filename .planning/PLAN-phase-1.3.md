# Phase 1.3: Startup Model Selection

## Overview
Implement intelligent model selection at startup: auto-select the best available model, or present an interactive canvas-based picker when multiple top-tier models are available. This completes the model selection feature by adding the user-facing startup flow.

---

## Task 1: Add model selection types and logic

Create types and pure functions for model selection decision-making.

**Files to create**: `src/model_selection.rs`

**Implementation**:
- `ModelSelectionDecision` enum: `AutoSelect(candidate)`, `PromptUser(Vec<candidate>)`, `NoModels`
- `fn decide_model_selection(candidates: &[ProviderModelRef]) -> ModelSelectionDecision`
  - Logic: if 0 candidates → NoModels, if 1 candidate → AutoSelect, if multiple with same top tier → PromptUser, else → AutoSelect(first)
- Add module to `src/lib.rs`

**Tests**: Unit tests for decision logic with various candidate scenarios

---

## Task 2: Canvas event types for model selection

Add runtime events for model picker UI interactions.

**Files to modify**: `src/runtime.rs`

**Implementation**:
- Add `RuntimeEvent::ModelSelectionPrompt { candidates: Vec<String>, timeout_secs: u32 }`
- Add `RuntimeEvent::ModelSelected { provider_model: String }`
- Document the events for GUI consumption

**Tests**: Verify event serialization/deserialization if needed

---

## Task 3: Model picker response channel

Add a channel for the GUI to respond to model selection prompts.

**Files to modify**: `src/pi/engine.rs`

**Implementation**:
- Add `model_selection_rx: Option<mpsc::UnboundedReceiver<String>>` to `PiLlm` struct
- Update `PiLlm::new()` signature to accept optional model selection receiver
- Store the receiver for use in selection flow

**Tests**: Construction tests with/without receiver

---

## Task 4: Implement model selection flow in PiLlm

Add the actual selection logic that decides whether to auto-select or prompt.

**Files to modify**: `src/pi/engine.rs`

**Implementation**:
- Add `async fn select_startup_model(&mut self, timeout: Duration) -> Result<usize>`
  - Calls `decide_model_selection()` on `self.model_candidates`
  - If `AutoSelect` → return index 0 immediately
  - If `PromptUser` → emit `ModelSelectionPrompt` event, wait on `model_selection_rx` with timeout
  - On timeout or no response → auto-select first candidate
  - On response → find matching candidate index
  - Update `self.active_model_idx`
- Call `select_startup_model()` in `PiLlm::new()` after creating session

**Tests**: Mock tests with various decision scenarios and timeout behavior

---

## Task 5: GUI model picker component

Add a canvas-based model picker UI component in the GUI.

**Files to modify**: `src/bin/gui.rs`

**Implementation**:
- Subscribe to `RuntimeEvent::ModelSelectionPrompt` in runtime event handler
- When received, display modal or drawer with model list (provider/model pairs)
- Each item clickable, sends selection via `model_selection_tx`
- Show countdown timer for timeout
- Auto-dismiss on timeout or selection

**Tests**: GUI tests (if test framework exists), otherwise manual verification

---

## Task 6: Wire model selection channel through coordinator

Connect the model selection channel from GUI through coordinator to PiLlm.

**Files to modify**: `src/pipeline/coordinator.rs`, `src/bin/gui.rs`

**Implementation**:
- Add `model_selection_tx` parameter to coordinator
- Pass through to PiLlm creation in LLM stage
- In GUI, create channel and pass tx to pipeline

**Tests**: Integration test verifying channel connectivity

---

## Task 7: Add configuration for selection timeout

Add config field for model selection timeout duration.

**Files to modify**: `src/config.rs`

**Implementation**:
- Add `model_selection_timeout_secs: u32` to `LlmConfig` (default: 30)
- Use in `select_startup_model()` call

**Tests**: Config serialization tests

---

## Task 8: Integration tests and verification

Verify the complete flow works end-to-end.

**Files**: Tests in `src/model_selection.rs`, `src/pi/engine.rs`

**Implementation**:
- Integration test: Multiple top-tier models → prompt emitted
- Integration test: Single model → auto-selected immediately
- Integration test: Timeout expires → first candidate selected
- Run `just build` and `just lint`
- Manual GUI test with multiple cloud providers configured

**Tests**: All above tests pass, zero warnings
