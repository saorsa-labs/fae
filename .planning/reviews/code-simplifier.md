# Code Simplification Review
**Date**: 2026-02-19
**Mode**: gsd-task

## Findings

- [MEDIUM] src/host/handler.rs:499-593: 90-line inline ProgressEvent-to-JSON match inside async closure. Extract to:
  ```rust
  fn progress_event_to_json(evt: &ProgressEvent) -> serde_json::Value { ... }
  ```
  Reduces request_runtime_start() length significantly, makes progress mapping independently testable.

- [LOW] src/host/handler.rs: Repeated pattern `if let Ok(mut guard) = self.<field>.lock() { *guard = value; }` appears 8+ times across request_runtime_start/stop. Extract helper:
  ```rust
  fn set_pipeline_state(&self, state: PipelineState) {
      if let Ok(mut g) = self.pipeline_state.lock() { *g = state; }
  }
  ```

- [LOW] src/host/handler.rs:490-498: Three clones of event_tx before async block. After extracting progress callback, could reduce to two clones.

## Grade: B
Functionally correct. Primary opportunity is extracting the large inline ProgressEvent match to reduce request_runtime_start() from ~238 lines.
