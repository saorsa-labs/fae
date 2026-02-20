# Test Coverage Review — Phase 6.2 Task 7

**Reviewer:** Test Quality Analyst
**Scope:** All changed files

## Findings

### Rust Tests Added

1. `map_conversation_visibility_event` — tests both visible=true and visible=false for the new event mapping. GOOD.
2. `map_canvas_visibility_event` — baseline test for existing event. GOOD.
3. `request_move_emits_canvas_hide_and_transfer` — tests that `request_move()` emits both `pipeline.canvas_visibility:false` and `device.transfer_requested` with correct target. GOOD.
4. `request_go_home_emits_home_requested` — tests `request_go_home()` emits `device.home_requested`. GOOD.
5. `show_conversation`, `open_conversation`, `hide_conversation`, `close_conversation` — parse tests for voice commands. GOOD.
6. `show_canvas`, `hide_canvas` — parse tests. GOOD.
7. `fae_show_conversation`, `hey_fae_open_canvas` — wake-prefix stripping tests. GOOD.

### Missing Tests

1. **SHOULD FIX — No test for coordinator emitting ConversationVisibility event**
The coordinator's `run_llm_stage` now emits `RuntimeEvent::ConversationVisibility` when ShowConversation/HideConversation voice commands arrive. There is no unit test verifying this end-to-end. The handler tests cover the mapping, but not the coordinator dispatch. Medium coverage gap.

2. **INFO — No test for interrupted path**
The second occurrence (interrupted-generation path at line ~2139) has no dedicated test. This is harder to test due to coordinator complexity.

3. **INFO — No Swift unit tests (expected)**
JitPermissionController calendar/reminders tests would require EventKit mocking, which is not present in this codebase. Acceptable for this platform.

### Coverage Assessment
- Rust: New Rust paths have good unit test coverage (handler level). Coordinator level is partial but acceptable given existing coordinator test complexity.
- Build: All 15 test suites pass with 0 failures.

## Verdict
**PASS with suggestions**

| # | Severity | Finding |
|---|----------|---------|
| 1 | SHOULD FIX | No coordinator-level test for ConversationVisibility dispatch |
