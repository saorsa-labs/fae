# Code Simplification Review
**Date**: 2026-02-19
**Mode**: gsd (task 3, Phase 3.3)

## Findings

- [LOW] src/fae_llm/tools/apple/mock_stores.rs:539-583 - list_messages filter closure is ~25 lines. Could extract a `matches_query(m: &Mail, query: &MailQuery, search_lower: &str) -> bool` helper function, but current form is readable and matches existing MockNoteStore patterns.
- [LOW] src/host/handler.rs:859-862 - Pure rustfmt reformatting of existing code, no simplification needed.
- [LOW] tests/phase_1_3_wired_commands.rs:295-301 - Pure rustfmt reformatting of assert!(), no simplification needed.
- [NIT] src/fae_llm/tools/apple/ffi_bridge.rs - The 3 UnregisteredMailStore methods all return the identical error string. Could deduplicate with a helper const, but consistent with other UnregisteredXxxStore patterns in the same file.

## Simplification Opportunities

1. Extract search filter to helper (LOW priority, would improve testability):
```rust
// Before (inline filter closure):
.filter(|m| { /* 20 lines */ })

// After (helper function):
fn message_matches(m: &Mail, query: &MailQuery, search_lower: &str) -> bool { ... }
.filter(|m| message_matches(m, query, &search_lower))
```

2. Deduplicate error message (NIT, consistency vs. DRY tradeoff):
```rust
// Before: 3 identical string literals
// After:
const NOT_INITIALIZED_MSG: &str = "Apple Mail store not initialized. \
    The app must be running on macOS with Mail permission granted.";
```

## Grade: A-
