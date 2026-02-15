# Phase 0.1: Make Web Search Always-On

## Objective
Remove the `web-search` feature gate so that `fae-search` is always compiled into the binary. No optional features — everything is always available.

## Tasks

### Task 1: Remove feature gate from Cargo.toml
- **Description**: Make `fae-search` a mandatory (non-optional) dependency and remove the `web-search` feature definition
- **Files**:
  - `Cargo.toml` (root)
- **Changes**:
  1. Line 29: Remove `"web-search"` from `default = ["gui", "web-search"]` → `default = ["gui"]`
  2. Line 40: DELETE the line `web-search = ["dep:fae-search"]`
  3. Line 146: Change `fae-search = { path = "fae-search", optional = true }` → `fae-search = { path = "fae-search" }`
- **Verification**: `cargo check` passes

### Task 2: Remove all cfg(feature = "web-search") conditionals from source
- **Description**: Remove all `#[cfg(feature = "web-search")]` gates from Rust source files
- **Files**:
  - `src/fae_llm/tools/mod.rs` (lines 23, 31, 37-38, 45-46 — 5 cfg gates)
  - `src/agent/mod.rs` (lines 449-455 — 1 cfg gate wrapping tool registration)
- **Changes**:
  1. In `src/fae_llm/tools/mod.rs`: Remove all `#[cfg(feature = "web-search")]` annotations, keep the `pub mod` and `pub use` statements unconditional
  2. In `src/agent/mod.rs`: Remove `#[cfg(feature = "web-search")]` gate, keep the tool registration block (still gated on tool_mode != Off)
- **Verification**: `cargo check` passes, `cargo clippy --all-features -- -D warnings` passes

### Task 3: Verify full build and tests pass
- **Description**: Run full validation to ensure nothing broke
- **Files**: None (verification only)
- **Verification**:
  1. `cargo fmt --all -- --check`
  2. `cargo clippy --all-features --all-targets -- -D warnings`
  3. `cargo nextest run --all-features`
  4. Verify web_search and fetch_url tools are always registered (grep for registration without cfg)
