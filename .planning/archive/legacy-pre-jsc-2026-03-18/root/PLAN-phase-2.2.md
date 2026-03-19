# Phase 2.2: Registry Wiring & Feature Flag

Wire WebSearchTool and FetchUrlTool into Fae's tool registration system.

## Prerequisites (Done in Phase 2.1)

- `web-search` feature flag in Cargo.toml
- `fae-search` as optional path dependency
- `WebSearchTool` and `FetchUrlTool` implementations
- Feature-gated modules in `tools/mod.rs`

## Remaining Work

---

## Task 1: Register tools in build_registry()

Add WebSearchTool and FetchUrlTool to `build_registry()` in `src/agent/mod.rs`.

Both tools are read-only (like ReadTool), so they should be registered in ALL non-Off modes: ReadOnly, ReadWrite, Full, and FullNoApproval.

**Pattern:**
```rust
#[cfg(feature = "web-search")]
{
    registry.register(Arc::new(WebSearchTool::new()));
    registry.register(Arc::new(FetchUrlTool::new()));
}
```

**Files:**
- Modify: `src/agent/mod.rs`

**Acceptance criteria:**
- Tools registered when `web-search` feature enabled
- Tools NOT registered when feature disabled
- Tools available in ReadOnly mode and above
- No compilation changes when feature disabled

---

## Task 2: Add conditional import for tool types

Add `#[cfg(feature = "web-search")]` use statements in agent/mod.rs.

**Files:**
- Modify: `src/agent/mod.rs`

**Acceptance criteria:**
- Import compiles with and without feature
- No unused import warnings

---

## Task 3: Validate with fae-search crate tests

Since the main fae crate has a pre-existing build issue (espeak-rs-sys), validate the fae-search crate independently.

**Verification:**
- `cargo clippy -p fae-search --all-features --all-targets -- -D warnings`
- `cargo nextest run -p fae-search --all-features`
- `cargo fmt --all -- --check`

**Acceptance criteria:**
- fae-search: zero warnings, all tests pass
- Formatting clean across workspace
