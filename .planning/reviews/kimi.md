# Code Review: Integration Tests for Model Selection

## 1. Code Quality

### Strengths
- **Well-organized test structure**: Tests are logically grouped by scenario with descriptive names
- **Good helper design**: The `test_pi()` helper reduces boilerplate while remaining flexible
- **Consistent patterns**: All tests follow the same arrange-act-assert structure
- **Clear assertions**: Descriptive panic messages in `match` statements aid debugging

### Suggestions
- **Line length**: Some function names are quite long (e.g., `select_startup_model_multiple_top_tier_emits_prompt_then_times_out`). While descriptive, consider if they could be slightly more concise.
- **Missing whitespace**: Consider adding blank lines between logical sections within longer tests for readability.

## 2. Correctness

### Strengths
- **Accurate timeout usage**: Tests correctly pass short timeouts to avoid slowing the suite
- **Proper async handling**: Uses `tokio::spawn` correctly for simulated user input
- **Valid error assertions**: `no_candidates_returns_error` correctly checks for error result

### Issues Found
- **⚠️ Logic verification needed**: In `select_startup_model_different_tiers_auto_selects_best`, the test asserts `active_model_idx == 0` but doesn't verify *why* index 0 was chosen (is it truly because it's "flagship" tier?). The comment says "without prompting" but doesn't verify no prompt was emitted (unlike other tests).

**Recommendation**: Add an event check to confirm no `ModelSelectionPrompt` was emitted:
```rust
match event_rx.try_recv() {
    Err(broadcast::error::TryRecvError::Empty) => {} // Expected - no prompt
    Ok(RuntimeEvent::ModelSelected { .. }) => {}     // Also acceptable
    other => panic!("unexpected event: {other:?}"),
}
```

## 3. Testing

### Coverage Assessment
| Scenario | Covered |
|----------|---------|
| Single candidate auto-select | ✅ |
| No candidates (error) | ✅ |
| Multiple top-tier with timeout | ✅ |
| User picks valid candidate | ✅ |
| Different tiers auto-select | ⚠️ (see note above) |
| Channel closed fallback | ✅ |
| Invalid user choice fallback | ✅ |
| No channel (headless mode) | ✅ |

### Test Helper Design
The `test_pi()` helper is well-designed:
- Uses `Option<mpsc::UnboundedReceiver>` to support both GUI and headless scenarios
- Returns `(PiLlm, broadcast::Receiver)` for event verification
- Hardcoded `/fake` path is acceptable for unit tests

### Async Test Patterns
- **Correct**: `#[tokio::test]` attribute used consistently
- **Correct**: Short `sleep(Duration::from_millis(10))` for user simulation
- **Correct**: Very short timeout (50ms) for timeout tests
- **Potential issue**: `invalid_user_choice_falls_back` uses 5 second timeout but only needs 10ms delay. The test will pass but takes longer than necessary.

## 4. Performance

### Concerns
- **Test duration**: `invalid_user_choice_falls_back` uses `Duration::from_secs(5)` timeout despite only needing 10ms. This could slow CI.
  - **Fix**: Change to `Duration::from_millis(100)` or similar

### Good Practices
- Uses `try_recv()` (non-blocking) for event verification rather than `recv().await`
- Short timeouts (50ms) for timeout-scenario tests
- Minimal sleep delays (10ms) for async timing

## 5. Security

### Assessment
No security concerns in test code:
- No unsafe blocks
- No hardcoded secrets
- Test paths use `/fake` placeholder
- No network I/O in tests (all mocked)

## 6. Documentation

### Strengths
- Helper function has doc comment explaining purpose
- Test names are self-documenting
- Inline comments explain intent ("Simulate user picking...", "Channel with no sender...")

### Suggestions
- Add module-level doc comment explaining the test strategy for model selection
- Document the expected event sequence for complex scenarios

## 7. Summary

| Category | Grade | Notes |
|----------|-------|-------|
| Code Quality | A | Clean, well-organized |
| Correctness | B+ | Minor gap in tier-based test verification |
| Testing | A- | Good coverage, one slow test |
| Performance | B+ | One test uses unnecessarily long timeout |
| Security | A | No concerns |
| Documentation | B+ | Good but could use module docs |

### Recommendations (Priority Order)

1. **Fix slow test** (`invalid_user_choice_falls_back`): Reduce timeout from 5s to ~100ms
2. **Add event verification** to `different_tiers_auto_selects_best` to confirm no prompt emitted
3. **Add edge case**: Test with empty string user input
4. **Add edge case**: Test with whitespace-only user input
5. **Consider**: Add test for case-insensitive model matching (if supported by implementation)

### Overall Verdict: **APPROVE with minor fixes**

The test suite provides good coverage of the model selection logic with proper async patterns and event verification. The identified issues are minor and easily addressed.
