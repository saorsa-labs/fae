# Phase 2.1: WebSearchTool & FetchUrlTool

Implement Fae's `Tool` trait for web search and URL fetching. These tools bridge the sync `Tool::execute()` interface to the async `fae_search` API using `tokio::runtime::Handle::current().block_on()`.

## Architecture Notes

- `Tool::execute(&self, args: Value) -> Result<ToolResult, FaeLlmError>` is **synchronous**
- `fae_search::search()` is **async** — bridge via `Handle::current().block_on()`
- Both tools are **read-only** (`allowed_in_mode` returns true for all modes)
- Feature-gated behind `web-search` feature flag (optional dependency)
- Results formatted as structured text for LLM consumption

---

## Task 1: Add fae-search as optional dependency behind feature flag

Add fae-search to the root Cargo.toml as an optional path dependency gated by the `web-search` feature flag. This is a prerequisite for all subsequent tasks.

**Files:**
- Modify: `Cargo.toml` (add `web-search` feature, add `fae-search` dependency)

**Changes:**
- Add `web-search = ["dep:fae-search"]` to `[features]`
- Add `fae-search = { path = "fae-search", optional = true }` to `[dependencies]`
- Verify: `cargo check --features web-search` passes

**Acceptance criteria:**
- Feature flag `web-search` exists and compiles
- `fae-search` is only included when feature is enabled
- `cargo check` without the feature still passes

---

## Task 2: Create WebSearchTool implementing Tool trait (TDD)

Create the `WebSearchTool` struct that wraps `fae_search::search()` for LLM use.

**JSON Schema:**
```json
{
  "type": "object",
  "properties": {
    "query": { "type": "string", "description": "Search query" },
    "max_results": { "type": "integer", "description": "Max results (default 5)" }
  },
  "required": ["query"]
}
```

**Sync-async bridge:**
```rust
fn execute(&self, args: Value) -> Result<ToolResult, FaeLlmError> {
    let handle = tokio::runtime::Handle::current();
    handle.block_on(async { /* call fae_search::search() */ })
}
```

**Result formatting for LLM:**
```
## Search Results for "query"

1. **Title**
   URL: https://example.com
   Snippet text here...

2. **Title 2**
   ...
```

**Files:**
- Create: `src/fae_llm/tools/web_search.rs`

**Acceptance criteria:**
- Tests: schema has required `query` field
- Tests: execute with valid args returns formatted results (mock/synthetic)
- Tests: missing query returns ToolValidationError
- Tests: allowed_in_mode returns true for both ReadOnly and Full
- Tests: empty results returns "No results found" message
- Tests: result output is properly truncated for large result sets
- Zero clippy warnings

---

## Task 3: Create FetchUrlTool implementing Tool trait (TDD)

Create the `FetchUrlTool` struct that wraps `fae_search::fetch_page_content()`.

**JSON Schema:**
```json
{
  "type": "object",
  "properties": {
    "url": { "type": "string", "description": "URL to fetch" }
  },
  "required": ["url"]
}
```

**Note:** `fetch_page_content()` currently returns a stub error. The tool should handle this gracefully — it will work once Phase 2.3 implements content extraction.

**Result formatting for LLM:**
```
## Page Content: Title

URL: https://example.com
Words: 1234

Content text here...
```

**Files:**
- Create: `src/fae_llm/tools/fetch_url.rs`

**Acceptance criteria:**
- Tests: schema has required `url` field
- Tests: execute handles stub error gracefully (returns ToolResult::failure, not panic)
- Tests: missing url returns ToolValidationError
- Tests: allowed_in_mode returns true for both ReadOnly and Full
- Tests: invalid URL format returns clear error message
- Zero clippy warnings

---

## Task 4: Wire modules into tools/mod.rs

Add module declarations and re-exports for both new tools. Gate behind `web-search` feature.

**Files:**
- Modify: `src/fae_llm/tools/mod.rs`

**Changes:**
```rust
#[cfg(feature = "web-search")]
pub mod fetch_url;
#[cfg(feature = "web-search")]
pub mod web_search;

#[cfg(feature = "web-search")]
pub use fetch_url::FetchUrlTool;
#[cfg(feature = "web-search")]
pub use web_search::WebSearchTool;
```

**Acceptance criteria:**
- Compiles without `web-search` feature (no changes to existing tools)
- Compiles with `web-search` feature (new tools available)
- All existing tests still pass
- `cargo check --all-features` passes
- Zero clippy warnings

---

## Task 5: Validate all tests pass and documentation complete

Final validation pass ensuring everything compiles and tests pass in both feature configurations.

**Verification:**
- `cargo check` (without web-search) — passes
- `cargo check --features web-search` — passes
- `cargo clippy --all-features --all-targets -- -D warnings` — zero warnings
- `cargo nextest run --all-features` — all tests pass
- `cargo doc --all-features --no-deps` — zero doc warnings
- All public items documented

**Acceptance criteria:**
- Both feature configurations compile clean
- All tests pass
- All public items have doc comments
- Zero warnings in any mode
