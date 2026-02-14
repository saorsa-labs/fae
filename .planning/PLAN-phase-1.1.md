# Phase 1.1: Crate Scaffold & Public API — Task Plan

## Overview

Create the `fae-search` library crate within the Fae workspace with core types, error handling, configuration, and public API surface. All implementation functions return placeholder errors — the goal is to establish the contract and module structure.

## Tasks

### Task 1: Create fae-search Crate in Workspace

**What:** Add `fae-search` as a workspace member. Create Cargo.toml and empty lib.rs.

**Files:**
- `Cargo.toml` (modify — add workspace members)
- `fae-search/Cargo.toml` (create)
- `fae-search/src/lib.rs` (create)

**Acceptance Criteria:**
- Root Cargo.toml has `[workspace]` with `members = ["fae-search"]`
- fae-search/Cargo.toml defines lib crate with deps: thiserror, serde, serde_json, tokio, tracing, url
- fae-search/src/lib.rs has crate-level doc comment
- `cargo check --workspace` passes with zero errors/warnings

### Task 2: Define SearchError with thiserror (TDD)

**What:** Create error types. Tests first.

**Files:**
- `fae-search/src/error.rs` (create)
- `fae-search/src/lib.rs` (update)

**Acceptance Criteria:**
- SearchError enum: AllEnginesFailed, Timeout, Http(String), Parse(String), Config(String)
- All variants use `#[error("...")]`
- SearchError is Send + Sync
- Doc comments on all public items
- Tests: display format, variant construction, Send+Sync bounds

### Task 3: Define Core Types (TDD)

**What:** Create SearchResult, SearchEngine, PageContent. Tests first.

**Files:**
- `fae-search/src/types.rs` (create)
- `fae-search/src/lib.rs` (update)

**Acceptance Criteria:**
- SearchResult: title, url, snippet, engine (String), score (f64)
- SearchEngine enum: DuckDuckGo, Brave, Google, Bing, Startpage with Display, name(), weight()
- PageContent: url, title, text, word_count
- Derive Debug, Clone, Serialize, Deserialize
- Tests: instantiation, serde round-trip, Display, name(), weight()

### Task 4: Define SearchConfig with Defaults (TDD)

**What:** Create SearchConfig with defaults and validation. Tests first.

**Files:**
- `fae-search/src/config.rs` (create)
- `fae-search/src/lib.rs` (update)

**Acceptance Criteria:**
- Fields: engines, max_results (10), timeout_seconds (8), safe_search (true), cache_ttl_seconds (600), request_delay_ms ((100,500)), user_agent (None)
- Default impl
- validate() -> Result<(), SearchError>
- Tests: defaults, validation rejects bad config

### Task 5: Define SearchEngineTrait (TDD)

**What:** Create async trait for engine implementations. Tests first.

**Files:**
- `fae-search/src/engine.rs` (create)
- `fae-search/src/lib.rs` (update)

**Acceptance Criteria:**
- trait SearchEngineTrait: Send + Sync
- async fn search(&self, query: &str, config: &SearchConfig) -> Result<Vec<SearchResult>, SearchError>
- fn engine_type(&self) -> SearchEngine
- fn weight(&self) -> f64
- Tests with mock engine: trait bounds, async execution, error propagation

### Task 6: Stub Engine Modules

**What:** Create stub engine files returning placeholder errors.

**Files:**
- `fae-search/src/engines/mod.rs` (create)
- `fae-search/src/engines/duckduckgo.rs` (create)
- `fae-search/src/engines/brave.rs` (create)
- `fae-search/src/engines/google.rs` (create)
- `fae-search/src/engines/bing.rs` (create)
- `fae-search/src/lib.rs` (update)

**Acceptance Criteria:**
- Each struct implements SearchEngineTrait
- Each returns Err(SearchError::Parse("not yet implemented"))
- engines/mod.rs re-exports all
- Doc comments on each struct
- Tests: compile, satisfy trait

### Task 7: Define Public API Functions (TDD)

**What:** Create search(), search_default(), fetch_page_content() stubs. Tests first.

**Files:**
- `fae-search/src/lib.rs` (update — public API)

**Acceptance Criteria:**
- pub async fn search(query: &str, config: &SearchConfig) -> Result<Vec<SearchResult>, SearchError>
- pub async fn search_default(query: &str) -> Result<Vec<SearchResult>, SearchError>
- pub async fn fetch_page_content(url: &str) -> Result<PageContent, SearchError>
- All return placeholder errors
- Doc comments with usage examples
- Tests: signatures, error types, search_default delegates

### Task 8: Full Validation & Doc Pass

**What:** Run full validation, fix issues, ensure docs complete.

**Files:**
- All fae-search files

**Acceptance Criteria:**
- cargo fmt --all -- --check passes
- cargo clippy --workspace --all-features -- -D warnings passes
- cargo nextest run --workspace passes
- cargo doc --workspace --no-deps passes zero warnings
- All public items documented
- Zero forbidden patterns
