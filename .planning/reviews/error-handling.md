# Error Handling Review — Phase 6.2 Task 7

**Reviewer:** Error Handling Hunter
**Scope:** src/canvas/bridge.rs, src/host/handler.rs, src/pipeline/coordinator.rs, src/runtime.rs, src/voice_command.rs + Swift files

## Findings

### 1. PASS — No new unwrap()/expect() in Rust changes
All Rust additions use `let _ = rt.send(...)` (fire-and-forget on channel send, intentional) and proper `?` propagation. No panics introduced.

### 2. PASS — EKEventStore leaks in JitPermissionController (INFORMATIONAL)
In `requestCalendar` and `requestReminders`, a new `EKEventStore` is created per call and held only for the async callback. This is acceptable for JIT flows (infrequent). Not a memory hazard since the closure captures `store` implicitly via the async callback lifetime. However, a stored `EKEventStore` per session would be more efficient. LOW priority.

### 3. INFO — `requestMail` reports denied without confirming user action
`requestMail` opens System Settings and immediately calls `postDenied`. This is documented in the code comment and is the only possible approach since there is no API to detect Automation permission grants. Correct behavior given constraints.

### 4. PASS — Channel error suppression is intentional
`let _ = rt.send(...)` in coordinator.rs is the established pattern in this codebase for runtime event emission where the receiver may have been dropped (pipeline tear-down). Consistent with existing patterns.

### 5. PASS — DeviceTransfer observer leak in FaeNativeApp
The `addObserver(forName:)` in the `onAppear` block returns a token that is not stored. This could cause duplicate observers if `onAppear` fires multiple times (e.g., window restoration). **SHOULD FIX.**

## Verdict
**CONDITIONAL PASS**

| # | Severity | Finding |
|---|----------|---------|
| 5 | SHOULD FIX | Observer token not stored — potential duplicate notifications on re-appear |

Votes: 1 SHOULD FIX
