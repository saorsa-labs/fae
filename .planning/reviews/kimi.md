Review this git diff for security, errors, quality. Rate A-F. Format: [SEVERITY]
file:line - description

diff --git a/.planning/PLAN-phase-1.1.md b/.planning/PLAN-phase-1.1.md
index 90d35ef..8d8c686 100644
--- a/.planning/PLAN-phase-1.1.md
+++ b/.planning/PLAN-phase-1.1.md
@@ -1,190 +1,130 @@
-# Phase 1.1: Remove PI Dependency — Task Plan
+# Phase 1.1: Crate Scaffold & Public API — Task Plan
 
-## Goal
-Remove all PI coding agent integration from the FAE codebase. This includes the
pi module, pi_config, HTTP server, config types, and all references across 13+ 
source files. After this phase, zero PI references remain and the project 
compiles cleanly.
+## Overview
 
-## Strategy
-Remove in dependency order: standalone PI files first, then types/config, then 
all consumers, then deps. Tasks 1-6 perform deletions/edits, task 7 cleans deps 
and compiles, task 8 verifies everything.
-
----
+Create the `fae-search` library crate within the Fae workspace with core types,
error handling, configuration, and public API surface. All implementation 
functions return placeholder errors — the goal is to establish the contract and 
module structure.
 
 ## Tasks
 
-### Task 1: Delete PI module directory and PI-only LLM files
-**Files to delete:**
-- `src/pi/mod.rs`
-- `src/pi/engine.rs`
-- `src/pi/manager.rs`
-- `src/pi/session.rs`
-- `src/pi/tool.rs`
-- `src/llm/pi_config.rs`
-- `src/llm/server.rs`
-- `Skills/pi.md`
-- `.pi/` directory
-
-**Files to edit:**
-- `src/lib.rs` — remove `pub mod pi;` declaration
-- `src/llm/mod.rs` — remove `pub mod pi_config;` and `pub mod server;` 
declarations
-
----
-
-### Task 2: Remove PiConfig and LlmBackend::Pi from config.rs
-**File:** `src/config.rs`
-
-**Changes:**
-- Remove `pub pi: PiConfig` field from `SpeechConfig` struct (~line 37)
-- Remove entire `PiConfig` struct definition (~lines 691-712) and its Default 
impl
-- Remove `Pi` variant from `LlmBackend` enum (~lines 161-163)
-- Change `LlmBackend` default from `Pi` to `Local`
-- Update `effective_provider_name()` to remove Pi match arm (~line 410)
-- Fix/remove test that asserts `LlmBackend::default() == LlmBackend::Pi` (~line
842)
-- Remove any imports/uses that only existed for PiConfig
-
----
-
-### Task 3: Remove PI from startup.rs and update/checker.rs
-**File:** `src/startup.rs`
-
-**Changes:**
-- Remove imports: `crate::llm::pi_config::default_pi_models_path`, 
`remove_fae_local_provider`
-- Remove Pi cleanup on shutdown (~lines 50-51)
-- Remove `LlmBackend::Pi` from use_local_llm decision branches (~lines 77, 177)
-- Remove Pi HTTP server startup logic (~lines 319-320, 355-356)
-- Remove `write_fae_local_provider()` calls
-
-**File:** `src/update/checker.rs` (or `src/update/` module)
-
-**Changes:**
-- Remove `use crate::pi::manager::version_is_newer` import
-- Remove `UpdateChecker::for_pi()` method
-- Remove `crate::pi::manager::platform_asset_name()` calls
-- Remove Pi-specific update checking logic
-
----
-
-### Task 4: Remove PI from pipeline/coordinator.rs
-**File:** `src/pipeline/coordinator.rs`
-
-**Changes:**
-- Remove `Pi(Box<crate::pi::engine::PiLlm>)` variant from internal LLM backend 
enum (~line 1390)
-- Remove `use crate::pi::engine::PiLlm;` import (~line 1446)
-- Remove `LlmBackend::Pi =>` initialization block (~line 1487)
-- Remove `uuid::Uuid::new_v4()` usage in Pi context (~line 1726)
-- Remove entire axum HTTP server setup section (~lines 3094-3791)
-- Remove Pi-related test instances (~line 4143)
-- Remove model_selection_rx/voice_command_tx channels if only used for Pi
-
----
-
-### Task 5: Remove PI from agent/mod.rs and llm/api.rs
-**File:** `src/agent/mod.rs`
-
-**Changes:**
-- Remove `use crate::pi::session::PiSession;` import
-- Remove `use crate::pi::tool::PiDelegateTool;` import
-- Remove `pi_session: Option<Arc<Mutex<PiSession>>>` constructor parameter
-- Remove Pi models.json resolution logic (~lines 57-66)
-- Remove cloud fallback using pi_config (~lines 378-380)
-- Remove PiDelegateTool registration
-
-**File:** `src/llm/api.rs`
-
-**Changes:**
-- Remove Pi models.json lookups (~lines 334-338)
-- Remove `pi_config::read_pi_config()` usage
-
----
-
-### Task 6: Remove PI from GUI, voice commands, skills, and remaining files
-**File:** `src/bin/gui.rs`
-
-**Changes:**
-- Remove `LlmBackend::Pi` as default backend assignment (~line 1659)
-- Remove Pi provider/model UI selection dropdowns (~lines 1688-1750)
-- Remove all `LlmBackend::Pi` match arms throughout (14+ locations)
-- Remove "install_pi_update" action handling
-- Replace Pi backend references with appropriate remaining backends
-
-**File:** `src/voice_command.rs`
-
-**Changes:**
-- Remove `use crate::pi::engine::PiLlm;` references (~lines 778, 803, 825)
-- Remove Pi backend pattern matching in model switching
-
-**File:** `src/skills.rs`
-
-**Changes:**
-- Remove `pub const PI_SKILL: &str = include_str!("../Skills/pi.md");`
-- Remove "pi" from `list_skills()`
-- Remove `PI_SKILL.to_owned()` from `load_all_skills()`
-- Remove pi skill filtering logic
-
-**File:** `src/memory.rs` — Remove any Pi-specific references
-**File:** `src/progress.rs` — Remove Pi download progress tracking
-**File:** `src/runtime.rs` — Remove Pi runtime events
-**File:** `src/model_picker.rs` — Remove Pi model picker logic
-**File:** `src/model_selection.rs` — Remove Pi from tier selection
-**File:** `src/scheduler/tasks.rs` — Remove "install_pi_update" task
-
----
-
-### Task 7: Clean up Cargo.toml dependencies and compile
-**File:** `Cargo.toml`
-
-**Changes:**
-- Remove `axum = "0.8"` (only used by deleted llm/server.rs)
-- Remove `tower-http = { version = "0.6", features = ["cors"] }` (only used 
with axum)
-- Remove `uuid = { version = "1", features = ["v4"] }` (only used for Pi 
request IDs)
-- Verify no other files use these deps before removal
-
-**Then:**
-- Run `cargo check --all-features --all-targets` — fix ALL compilation errors
-- Run `cargo clippy --all-features --all-targets -- -D warnings` — fix ALL 
warnings
-- Run `cargo fmt --all` — format all edited files
-- Iterate until zero errors and zero warnings
-
----
-
-### Task 8: Verify tests pass and final cleanup
-**Verification:**
-- Run `cargo nextest run --all-features` — ALL tests must pass
-- Run `just check` (full validation: fmt, lint, build, test, doc, panic-scan)
-- Grep for any remaining PI references: `grep -r 
"pi::\|PiLlm\|PiSession\|PiManager\|PiConfig\|PiDelegateTool\|pi_config\|PI_SKIL
L\|LlmBackend::Pi" src/`
-- Remove any dead code flagged by clippy after removal
-- Verify zero warnings, zero errors
-
----
-
-## File Change Summary
-
-| File | Action |
-|------|--------|
-| `src/pi/` (5 files) | **DELETE** |
-| `src/llm/pi_config.rs` | **DELETE** |
-| `src/llm/server.rs` | **DELETE** |
-| `Skills/pi.md` | **DELETE** |
-| `.pi/` directory | **DELETE** |
-| `src/lib.rs` | **MODIFY** — remove pi module |
-| `src/llm/mod.rs` | **MODIFY** — remove pi_config, server modules |
-| `src/config.rs` | **MODIFY** — remove PiConfig, LlmBackend::Pi |
-| `src/startup.rs` | **MODIFY** — remove Pi init/cleanup |
-| `src/update/checker.rs` | **MODIFY** — remove Pi update logic |
-| `src/pipeline/coordinator.rs` | **MODIFY** — remove Pi backend, HTTP server |
-| `src/agent/mod.rs` | **MODIFY** — remove Pi session/tool |
-| `src/llm/api.rs` | **MODIFY** — remove Pi config lookups |
-| `src/bin/gui.rs` | **MODIFY** — remove Pi UI elements |
-| `src/voice_command.rs` | **MODIFY** — remove Pi model switching |
-| `src/skills.rs` | **MODIFY** — remove Pi skill |
-| `src/memory.rs` | **MODIFY** — remove Pi refs |
-| `src/progress.rs` | **MODIFY** — remove Pi progress |
-| `src/runtime.rs` | **MODIFY** — remove Pi events |
-| `src/model_picker.rs` | **MODIFY** — remove Pi picker |
-| `src/model_selection.rs` | **MODIFY** — remove Pi tier |
-| `Cargo.toml` | **MODIFY** — remove axum, tower-http, uuid |
-
-## Quality Gates
-- `just check` passes (fmt, lint, build, test, doc, panic-scan)
-- Zero `.unwrap()` or `.expect()` in production code
-- All remaining tests continue to pass
-- Zero PI references anywhere in src/
-- Zero compilation warnings
+### Task 1: Create fae-search Crate in Workspace
+
+**What:** Add `fae-search` as a workspace member. Create Cargo.toml and empty 
lib.rs.
+
+**Files:**
+- `Cargo.toml` (modify — add workspace members)
+- `fae-search/Cargo.toml` (create)
+- `fae-search/src/lib.rs` (create)
+
+**Acceptance Criteria:**
+- Root Cargo.toml has `` with `members = ["fae-search"]`
+- fae-search/Cargo.toml defines lib crate with deps: thiserror, serde, 
serde_json, tokio, tracing, url
+- fae-search/src/lib.rs has crate-level doc comment
+- `cargo check --workspace` passes with zero errors/warnings
+
+### Task 2: Define SearchError with thiserror (TDD)
+
+**What:** Create error types. Tests first.
+
+**Files:**
+- `fae-search/src/error.rs` (create)
+- `fae-search/src/lib.rs` (update)
+
+**Acceptance Criteria:**
+- SearchError enum: AllEnginesFailed, Timeout, Http(String), Parse(String), 
Config(String)
+- All variants use `#`
+- SearchError is Send + Sync
+- Doc comments on all public items
+- Tests: display format, variant construction, Send+Sync bounds
+
+### Task 3: Define Core Types (TDD)
+
+**What:** Create SearchResult, SearchEngine, PageContent. Tests first.
+
+**Files:**
+- `fae-search/src/types.rs` (create)
+- `fae-search/src/lib.rs` (update)
+
+**Acceptance Criteria:**
+- SearchResult: title, url, snippet, engine (String), score (f64)
+- SearchEngine enum: DuckDuckGo, Brave, Google, Bing, Startpage with Display, 
name(), weight()
+- PageContent: url, title, text, word_count
+- Derive Debug, Clone, Serialize, Deserialize
+- Tests: instantiation, serde round-trip, Display, name(), weight()
+
+### Task 4: Define SearchConfig with Defaults (TDD)
+
+**What:** Create SearchConfig with defaults and validation. Tests first.
+
+**Files:**
+- `fae-search/src/config.rs` (create)
+- `fae-search/src/lib.rs` (update)
+
+**Acceptance Criteria:**
+- Fields: engines, max_results (10), timeout_seconds (8), safe_search (true), 
cache_ttl_seconds (600), request_delay_ms ((100,500)), user_agent (None)
+- Default impl
+- validate() -> Result<(), SearchError>
+- Tests: defaults, validation rejects bad config
+
+### Task 5: Define SearchEngineTrait (TDD)
+
+**What:** Create async trait for engine implementations. Tests first.
+
+**Files:**
+- `fae-search/src/engine.rs` (create)
+- `fae-search/src/lib.rs` (update)
+
+**Acceptance Criteria:**
+- trait SearchEngineTrait: Send + Sync
+- async fn search(&self, query: &str, config: &SearchConfig) -> 
Result<Vec<SearchResult>, SearchError>
+- fn engine_type(&self) -> SearchEngine
+- fn weight(&self) -> f64
+- Tests with mock engine: trait bounds, async execution, error propagation
+
+### Task 6: Stub Engine Modules
+
+**What:** Create stub engine files returning placeholder errors.
+
+**Files:**
+- `fae-search/src/engines/mod.rs` (create)
+- `fae-search/src/engines/duckduckgo.rs` (create)
+- `fae-search/src/engines/brave.rs` (create)
+- `fae-search/src/engines/google.rs` (create)
+- `fae-search/src/engines/bing.rs` (create)
+- `fae-search/src/lib.rs` (update)
+
+**Acceptance Criteria:**
+- Each struct implements SearchEngineTrait
+- Each returns Err(SearchError::Parse("not yet implemented"))
+- engines/mod.rs re-exports all
+- Doc comments on each struct
+- Tests: compile, satisfy trait
+
+### Task 7: Define Public API Functions (TDD)
+
+**What:** Create search(), search_default(), fetch_page_content() stubs. Tests 
first.
+
+**Files:**
+- `fae-search/src/lib.rs` (update — public API)
+
+**Acceptance Criteria:**
+- pub async fn search(query: &str, config: &SearchConfig) -> 
Result<Vec<SearchResult>, SearchError>
+- pub async fn search_default(query: &str) -> Result<Vec<SearchResult>, 
SearchError>
+- pub async fn fetch_page_content(url: &str) -> Result<PageContent, 
SearchError>
+- All return placeholder errors
+- Doc comments with usage examples
+- Tests: signatures, error types, search_default delegates
+
+### Task 8: Full Validation & Doc Pass
+
+**What:** Run full validation, fix issues, ensure docs complete.
+
+**Files:**
+- All fae-search files
+
+**Acceptance Criteria:**
+- cargo fmt --all -- --check passes
+- cargo clippy --workspace --all-features -- -D warnings passes
+- cargo nextest run --workspace passes
+- cargo doc --workspace --no-deps passes zero warnings
+- All public items documented
+- Zero forbidden patterns
diff --git a/.planning/ROADMAP.md b/.planning/ROADMAP.md
index b66e99d..a5bdb1b 100644
--- a/.planning/ROADMAP.md
+++ b/.planning/ROADMAP.md
@@ -1,162 +1,208 @@
-# FAE LLM Module — Roadmap
+# Fae Tool 5: Embedded Web Search — Roadmap
 
 ## Vision
-Replace the PI subprocess dependency with a pure Rust LLM and tool-calling 
module (`fae_llm`). Multi-provider support (OpenAI, Anthropic, local, z.ai, 
MiniMax, DeepSeek), FAE-owned TOML config with round-trip safety, agent loop 
with tool calling, session persistence, local endpoint probing, and structured 
observability. No TUI dependency.
+
+Zero-configuration, embedded web search for Fae. No API keys, no external 
services, no user setup. Scrapes search engines directly (like a browser) using 
CSS selectors on HTML responses. Compiles into Fae's binary as a library crate.
 
 ## Problem
-- Technical debt: PI subprocess dependency is fragile and adds external binary 
management
-- Integration gap: Need native Rust LLM module without subprocess RPC overhead
-- Missing functionality: Need multi-provider support beyond what PI provides
+
+- Missing functionality: Fae can't answer questions requiring current/real-time
information
+- Privacy gap: Existing search tools require API keys/external services, 
violating Fae's local-first promise
 
 ## Success Criteria
-- Production ready: Complete + tested + documented
-- Zero PI references remaining in codebase
-- All providers functional with tool-calling agent loop
-- Config safe for app-menu updates (round-trip TOML)
-- Full observability with tracing/metrics/redaction
 
----
+- Production ready: All engines working, cached, tested, documented, integrated
+- Zero API keys or external service dependencies
+- Graceful degradation when engines are unavailable
+- In-memory caching with TTL for performance
+- Full public API documentation
+
+## Sources
 
-## Milestone 1: PI Removal & Foundation
-
-Remove the PI dependency entirely and establish the fae_llm crate with core 
types, config, and tools.
-
-### Phase 1.1: Remove PI Dependency
-- Delete `src/pi/` directory (engine.rs, manager.rs, session.rs, tool.rs, 
mod.rs)
-- Delete `src/llm/pi_config.rs` and `src/llm/server.rs` (Pi-only HTTP server)
-- Remove all PI references from config.rs, pipeline/coordinator.rs, 
agent/mod.rs
-- Remove PI references from voice_command.rs, startup.rs, bin/gui.rs, memory.rs
-- Remove PI-related progress tracking, update logic
-- Clean up unused dependencies from Cargo.toml
-- Ensure project compiles and all remaining tests pass
-
-### Phase 1.2: Create fae_llm Crate Structure
-- Create `fae_llm/` crate with module layout per spec
-- Define core types: EndpointType, ModelRef, RequestOptions, ReasoningLevel
-- Define normalized event model (start, text_delta, tool_call_start, etc.)
-- Define error types with stable codes (ConfigError, AuthError, RequestError, 
etc.)
-- Define usage/cost structs and stop reasons
-
-### Phase 1.3: Config Schema & Persistence
-- Define TOML config schema v1 (providers, models, tools, defaults, runtime)
-- Implement ConfigService with atomic read/write (temp -> fsync -> rename)
-- Implement round-trip TOML editing via toml_edit (preserve comments/unknown 
fields)
-- Implement secret resolution (none, env, literal, command, keychain)
-- Implement config validation and safe partial update API for app menu
-- Backup last-known-good config
-
-### Phase 1.4: Tool Registry & Implementations
-- Define Tool trait and ToolRegistry
-- Implement read tool (file content with offset/limit, bounded output)
-- Implement bash tool (shell command with timeout/cancel, bounded output)
-- Implement edit tool (deterministic text edits)
-- Implement write tool (create/overwrite with path validation)
-- Implement tool mode gating (read_only vs full)
-- Schema validation for tool arguments
+- **metasearch2** (CC0/Public Domain) — adapt engine scraping code directly
+- **Websurfx** (AGPLv3) — study for ideas only, rewrite everything clean
 
 ---
 
-## Milestone 2: Provider Implementation
+## Milestone 1: fae-search Crate (Core Library)
+
+Build the standalone `fae-search` library crate with search engine scrapers, 
result aggregation, and caching.
+
+### Phase 1.1: Crate Scaffold & Public API
+
+Create the `fae-search` crate with types, error handling, configuration, and 
public API surface.
+
+- Create `fae-search/` crate directory with Cargo.toml
+- Add workspace member to root Cargo.toml (convert to workspace if needed)
+- Define `SearchResult`, `SearchConfig`, `SearchEngine`, `PageContent` types
+- Define `SearchError` with thiserror
+- Define public API functions (`search`, `search_default`, 
`fetch_page_content`)
+- Define `SearchEngineTrait` for pluggable engine implementations
+- Stub all engine modules
+- Add basic unit tests for types and config defaults
+
+### Phase 1.2: DuckDuckGo & Brave Engines
+
+Implement the two most reliable, scraper-friendly search engines.
+
+- Implement DuckDuckGo HTML scraper (html.duckduckgo.com/html/)
+- Implement Brave Search HTML scraper
+- CSS selector extraction for title, URL, snippet from each
+- User-Agent rotation (list of realistic browser UAs)
+- Per-engine request timeout handling
+- Unit tests with mock HTML fixture files per engine
+- Integration tests (marked `#`) for live validation
+
+### Phase 1.3: Google & Bing Engines
+
+Add the two major engines with more aggressive bot detection.
+
+- Implement Google HTML scraper with ad filtering
+- Implement Bing HTML scraper with URL parameter decoding
+- Cookie jar support for Google consent pages
+- Resilient selectors with fallback patterns
+- Unit tests with mock HTML fixtures
+- Integration tests (marked `#`)
+
+### Phase 1.4: Search Orchestrator
 
-Build provider adapters for all supported LLM backends.
+Concurrent multi-engine queries with result ranking and deduplication.
 
-### Phase 2.1: OpenAI Adapter
-- Implement ProviderAdapter trait
-- OpenAI Completions request builder + SSE streaming parser
-- OpenAI Responses API support
-- Normalize to shared event model
-- Tool call streaming with partial JSON parsing
+- Fan out queries to all enabled engines concurrently (tokio::join!)
+- Result deduplication by URL normalization
+- Weighted scoring: configurable weight per engine
+- Cross-engine boost: URLs appearing in multiple engines get score bonus
+- Sort by aggregated score, truncate to max_results
+- Graceful degradation: if some engines fail, return results from others
+- Only error if ALL engines fail
+- Unit tests for ranking, dedup, and fallback logic
 
-### Phase 2.2: Compatibility Profile Engine
-- Implement profile flag system (max_tokens_field, reasoning_mode, etc.)
-- Create profiles for z.ai, MiniMax, DeepSeek, local backends
-- Single OpenAI-compatible adapter + profile resolution
-- Profile-based request/response normalization
+### Phase 1.5: Cache, UA Rotation & Request Jitter
 
-### Phase 2.3: Local Probe Service
-- Implement LocalProbeService (health check, /v1/models, configurable)
-- Typed failures: NotRunning, Timeout, Unhealthy, IncompatibleResponse
-- Bounded backoff retry
-- Status exposure for app menu diagnostics
-- Extension point for future RuntimeManager
+Production hardening for the search library.
 
-### Phase 2.4: Anthropic Adapter
-- Implement Anthropic Messages API adapter
-- Map thinking/tool_use blocks to shared event model
-- Streaming support with content block deltas
+- In-memory LRU cache using moka with configurable TTL (default 600s)
+- Cache key: lowercase query + engine set hash
+- User-Agent rotation per request from built-in list
+- Random request delay jitter between engine queries (100-500ms configurable)
+- Safe search parameter forwarding to engines that support it
+- Tracing instrumentation (trace-level only, no persistent query logging)
 
 ---
 
-## Milestone 3: Agent Loop & Sessions
+## Milestone 2: Fae Integration
 
-Build the tool-calling agent loop and session persistence.
+Wire fae-search into Fae's tool system and add content extraction.
 
-### Phase 3.1: Agent Loop Engine
-- Implement agentic loop: prompt -> stream -> tool calls -> execute -> continue
-- Max turn count, max tool calls per turn guards
-- Request and tool timeouts
-- Abort/cancellation propagation
-- Tool argument validation against schemas
+### Phase 2.1: WebSearchTool & FetchUrlTool
 
-### Phase 3.2: Session Persistence & Replay
-- Implement session store (persist every completed message)
-- Session resume with state validation
-- Typed continuation errors
-- Conversation context management
+Implement Fae's `Tool` trait for both tools.
 
-### Phase 3.3: Multi-Provider Hardening
-- Provider switch during resumed conversation
-- Error recovery and retry policies
-- End-to-end multi-turn tool loop tests
-- Mode switching integration (read_only <-> full)
+- `WebSearchTool` implementing `Tool` trait (name, description, schema, 
execute, allowed_in_mode)
+- `FetchUrlTool` implementing `Tool` trait
+- JSON schema definitions matching the brief's tool specs
+- Tool mode gating (always allowed in ReadOnly+ modes)
+- Result formatting for LLM consumption (clean, structured output)
+- Unit tests for schema validation and execution
+
+### Phase 2.2: Registry Wiring & Feature Flag
+
+Integrate into Fae's build and tool registration.
+
+- Add `web-search` feature flag to root Cargo.toml
+- Add fae-search as path dependency (optional, behind feature flag)
+- Register WebSearchTool + FetchUrlTool in `build_tool_registry()` 
(agent/mod.rs)
+- Enable by default in `AgentToolMode::ReadOnly` and above
+- Verify tool schemas appear in LLM API payloads
+- Integration test: full agent loop with web search tool available
+
+### Phase 2.3: Content Extraction (fetch_page_content)
+
+Fetch URLs and extract readable text content.
+
+- HTTP fetch with reqwest (follow redirects, respect timeouts)
+- HTML parsing with scraper crate
+- Content extraction: strip nav, ads, footer, scripts, styles
+- Extract main article/content body
+- Return clean text with title and word count
+- Truncation for very large pages (configurable max chars)
+- Unit tests with sample HTML pages
+
+### Phase 2.4: Circuit Breaker & Adaptive Engine Selection
+
+Reliability under real-world conditions.
+
+- Track per-engine success/failure counts
+- Circuit breaker: disable engine after N consecutive failures
+- Half-open state: retry disabled engine after cooldown period
+- Exponential backoff on repeated failures
+- Health status reporting (which engines are currently active)
+- Unit tests for circuit breaker state transitions
 
 ---
 
-## Milestone 4: Observability & Release
+## Milestone 3: Production Hardening
+
+Comprehensive testing, documentation, and additional engines.
+
+### Phase 3.1: Test Suite with Mock Fixtures
+
+Comprehensive offline-testable suite.
+
+- HTML fixture files per engine (saved from real responses)
+- Parser tests against fixtures (detect selector breakage)
+- Fallback tests: simulate engine failures, verify graceful degradation
+- Cache tests: hit/miss, TTL expiry, capacity eviction
+- Request delay tests: verify jitter is applied
+- Error path tests: timeout, parse error, HTTP error
+- All tests must pass in CI without network access
+
+### Phase 3.2: Integration Tests
+
+Live validation (manual/periodic, not CI).
 
-Production hardening with observability and comprehensive testing.
+- Live search tests per engine (marked `#`)
+- Cross-engine result quality validation
+- Rate limit behavior verification
+- End-to-end: agent loop with web search producing useful responses
+- Selector breakage detection (alert if engine returns 0 results)
 
-### Phase 4.1: Tracing, Metrics & Redaction
-- Structured tracing spans (per request, turn, tool execution)
-- Metrics hooks (latency, retry count, tool success/failure, token usage)
-- Secret redaction (API keys, auth headers, secret refs)
+### Phase 3.3: Documentation, Startpage Engine & Safe Search
 
-### Phase 4.2: Full Integration Test Matrix
-- OpenAI, Anthropic, local endpoint contract tests
-- z.ai/MiniMax/DeepSeek profile tests
-- E2E: prompt -> tool -> result -> continue
-- Failure injection tests
-- Mode gating tests (read_only rejects mutations)
+Final polish for production release.
 
-### Phase 4.3: App Integration & Release
-- App-menu integration tests
-- Config round-trip preservation tests
-- Operator and developer documentation
-- Release candidate validation
+- Startpage engine (proxied Google fallback)
+- Safe search enforcement across all engines
+- API documentation on all public items
+- Update Fae's README with web search capability
+- Update CLAUDE.md with fae-search architecture notes
 
 ---
 
-## Technical Decisions (Locked)
-
-| Decision | Choice |
-|----------|--------|
-| Local mode | probe_only (never start/stop model processes in v1) |
-| Config format | TOML with toml_edit for round-trip safety |
-| Secret modes | none, env, literal (dev), command (off by default), keychain |
-| Tool set | read, bash, edit, write (4 tools, stable names) |
-| Tool modes | read_only, full (2 modes only) |
-| Error handling | thiserror with typed errors + stable codes |
-| Async runtime | tokio (match existing) |
-| Testing | Unit + Integration + Property-based |
-| Streaming | Normalized event model across all providers |
-
-## Providers (v1)
-
-| Provider | Implementation |
-|----------|---------------|
-| OpenAI | Native adapter (Completions + Responses) |
-| Anthropic | Native adapter (Messages API) |
-| z.ai | OpenAI-compatible + profile |
-| MiniMax | OpenAI-compatible + profile |
-| DeepSeek | OpenAI-compatible + profile |
-| Local endpoints | OpenAI-compatible + profile |
+## Quality Standards (Enforced on Every Phase)
+
+```
+FORBIDDEN in src/:
+  .unwrap()  .expect()  panic!()  todo!()  unimplemented!()
+
+REQUIRED:
+  cargo fmt --all -- --check
+  cargo clippy --all-features -- -D warnings
+  cargo nextest run --all-features
+  thiserror for all error types
+  Doc comments on all public items
+  Tests written BEFORE implementation (TDD)
+```
+
+## Key Technical Decisions
+
+| Decision | Choice | Rationale |
+|----------|--------|-----------|
+| Crate structure | Separate `fae-search` lib crate | Clean separation, 
independent testing |
+| Primary engine | DuckDuckGo | Most scraper-friendly, privacy-aligned |
+| HTTP client | reqwest (already in tree) | No new dependencies for HTTP |
+| HTML parsing | scraper crate | CSS selector-based, proven by metasearch2 |
+| Cache | moka (in-memory) | TTL support, async-friendly, no external deps |
+| Error handling | thiserror | Matches Fae's existing pattern |
+| Async runtime | tokio (already in tree) | No new runtime dependency |
+| Source licensing | CC0 (metasearch2) for code, clean-room for Websurfx ideas 
| Legal clarity |
diff --git a/.planning/STATE.json b/.planning/STATE.json
index 8cb3ecc..b09e828 100644
--- a/.planning/STATE.json
+++ b/.planning/STATE.json
@@ -1,27 +1,26 @@
 {
   "version": 1,
-  "project": "fae-llm-module",
+  "project": "fae-tool5-web-search",
   "active": true,
   "milestone": {
-    "number": 4,
-    "name": "Observability & Release"
+    "number": 1,
+    "name": "fae-search Crate (Core Library)"
   },
   "phase": {
-    "number": "4.3",
-    "name": "App Integration & Release",
-    "plan": ".planning/PLAN-phase-4.3.md"
+    "number": "1.2",
+    "name": "DuckDuckGo & Brave Engines",
+    "plan": null
   },
   "progress": {
-    "total_tasks": 8,
-    "completed_tasks": 8,
+    "total_tasks": 3,
+    "completed_tasks": 3,
     "current_task": null
   },
-  "status": "milestone_complete",
   "review": {
-    "status": "pending",
-    "iteration": 0,
-    "last_verdict": "PASS"
+    "status": "reviewing",
+    "iteration": 1,
+    "last_verdict": null
   },
-  "last_updated": 1770929000,
-  "last_action": "phase_4.3_transition"
+  "status": "reviewing",
+  "last_updated": "2026-02-14T13:00:00Z"
 }
diff --git a/Cargo.lock b/Cargo.lock
index 8269107..f60b66f 100644
--- a/Cargo.lock
+++ b/Cargo.lock
@@ -92,6 +92,21 @@ dependencies = [
  "equator",
 ]
 
+[]
+name = "alloc-no-stdlib"
+version = "2.0.4"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "cc7bb162ec39d46ab1ca8c77bf72e890535becd1751bb45f64c597edb4c8c6b3"
+
+[]
+name = "alloc-stdlib"
+version = "0.2.2"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "94fb8275041c72129eb51b7d0322c29b8387a0386127718b096429201a5d6ece"
+dependencies = [
+ "alloc-no-stdlib",
+]
+
 []
 name = "allocator-api2"
 version = "0.2.21"
@@ -378,6 +393,18 @@ dependencies = [
  "pin-project-lite",
 ]
 
+[]
+name = "async-compression"
+version = "0.4.39"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "68650b7df54f0293fd061972a0fb05aaf4fc0879d3b3d21a638a182c5c543b9f"
+dependencies = [
+ "compression-codecs",
+ "compression-core",
+ "pin-project-lite",
+ "tokio",
+]
+
 []
 name = "async-executor"
 version = "1.13.3"
@@ -851,6 +878,27 @@ dependencies = [
  "unicode-segmentation",
 ]
 
+[]
+name = "brotli"
+version = "8.0.2"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "4bd8b9603c7aa97359dbd97ecf258968c95f3adddd6db2f7e7a5bef101c84560"
+dependencies = [
+ "alloc-no-stdlib",
+ "alloc-stdlib",
+ "brotli-decompressor",
+]
+
+[]
+name = "brotli-decompressor"
+version = "5.0.0"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "874bb8112abecc98cbd6d81ea4fa7e94fb9449648c93cc89aa40c81c24d7de03"
+dependencies = [
+ "alloc-no-stdlib",
+ "alloc-stdlib",
+]
+
 []
 name = "bstr"
 version = "1.12.1"
@@ -1440,6 +1488,24 @@ dependencies = [
  "static_assertions",
 ]
 
+[]
+name = "compression-codecs"
+version = "0.4.36"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "00828ba6fd27b45a448e57dbfe84f1029d4c9f26b368157e9a448a5f49a2ec2a"
+dependencies = [
+ "brotli",
+ "compression-core",
+ "flate2",
+ "memchr",
+]
+
+[]
+name = "compression-core"
+version = "0.4.31"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "75984efb6ed102a0d42db99afb6c1948f0380d1d91808d5529916e6c08b49d8d"
+
 []
 name = "concurrent-queue"
 version = "2.5.0"
@@ -1547,6 +1613,35 @@ dependencies = [
  "unicode-segmentation",
 ]
 
+[]
+name = "cookie"
+version = "0.18.1"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "4ddef33a339a91ea89fb53151bd0a4689cfce27055c291dfa69945475d22c747"
+dependencies = [
+ "percent-encoding",
+ "time",
+ "version_check",
+]
+
+[]
+name = "cookie_store"
+version = "0.22.0"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "3fc4bff745c9b4c7fb1e97b25d13153da2bc7796260141df62378998d070207f"
+dependencies = [
+ "cookie",
+ "document-features",
+ "idna",
+ "log",
+ "publicsuffix",
+ "serde",
+ "serde_derive",
+ "serde_json",
+ "time",
+ "url",
+]
+
 []
 name = "core-foundation"
 version = "0.9.4"
@@ -1811,6 +1906,19 @@ dependencies = [
  "syn 1.0.109",
 ]
 
+[]
+name = "cssparser"
+version = "0.34.0"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "b7c66d1cd8ed61bf80b38432613a7a2f09401ab8d0501110655f8b341484a3e3"
+dependencies = [
+ "cssparser-macros",
+ "dtoa-short",
+ "itoa 1.0.17",
+ "phf 0.11.3",
+ "smallvec 1.15.1",
+]
+
 []
 name = "cssparser"
 version = "0.36.0"
@@ -3048,6 +3156,21 @@ dependencies = [
  "zip 2.4.2",
 ]
 
+[]
+name = "fae-search"
+version = "0.1.0"
+dependencies = [
+ "rand 0.8.5",
+ "reqwest 0.12.28",
+ "scraper 0.22.0",
+ "serde",
+ "serde_json",
+ "thiserror 2.0.18",
+ "tokio",
+ "tracing",
+ "url",
+]
+
 []
 name = "fancy-regex"
 version = "0.13.0"
@@ -4319,6 +4442,18 @@ dependencies = [
  "syn 1.0.109",
 ]
 
+[]
+name = "html5ever"
+version = "0.29.1"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "3b7410cae13cbc75623c98ac4cbfd1f0bedddf3227afc24f370cf0f50a44a11c"
+dependencies = [
+ "log",
+ "mac",
+ "markup5ever 0.14.1",
+ "match_token",
+]
+
 []
 name = "html5ever"
 version = "0.36.1"
@@ -5269,6 +5404,20 @@ dependencies = [
  "tendril 0.4.3",
 ]
 
+[]
+name = "markup5ever"
+version = "0.14.1"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "c7a7213d12e1864c0f002f52c2923d4556935a43dec5e71355c2760e0f6e7a18"
+dependencies = [
+ "log",
+ "phf 0.11.3",
+ "phf_codegen 0.11.3",
+ "string_cache 0.8.9",
+ "string_cache_codegen 0.5.4",
+ "tendril 0.4.3",
+]
+
 []
 name = "markup5ever"
 version = "0.36.1"
@@ -5291,6 +5440,17 @@ dependencies = [
  "web_atoms",
 ]
 
+[]
+name = "match_token"
+version = "0.1.0"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "88a9689d8d44bf9964484516275f5cd4c9b59457a6940c1d5d0ecbb94510a36b"
+dependencies = [
+ "proc-macro2",
+ "quote",
+ "syn 2.0.114",
+]
+
 []
 name = "matchers"
 version = "0.2.0"
@@ -5589,7 +5749,7 @@ dependencies = [
  "rustfft",
  "safetensors 0.7.0",
  "schemars 1.2.1",
- "scraper",
+ "scraper 0.25.0",
  "serde",
  "serde-big-array",
  "serde-saphyr",
@@ -6843,6 +7003,16 @@ dependencies = [
  "phf_shared 0.10.0",
 ]
 
+[]
+name = "phf"
+version = "0.11.3"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "1fd6780a80ae0c52cc120a26a1a42c1ae51b247a253e4e06113d23d2c2edd078"
+dependencies = [
+ "phf_macros 0.11.3",
+ "phf_shared 0.11.3",
+]
+
 []
 name = "phf"
 version = "0.13.1"
@@ -6874,6 +7044,16 @@ dependencies = [
  "phf_shared 0.10.0",
 ]
 
+[]
+name = "phf_codegen"
+version = "0.11.3"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "aef8048c789fa5e851558d709946d6d79a8ff88c0440c587967f8e94bfb1216a"
+dependencies = [
+ "phf_generator 0.11.3",
+ "phf_shared 0.11.3",
+]
+
 []
 name = "phf_codegen"
 version = "0.13.1"
@@ -6938,6 +7118,19 @@ dependencies = [
  "syn 1.0.109",
 ]
 
+[]
+name = "phf_macros"
+version = "0.11.3"
+source = "registry+https://github.com/rust-lang/crates.io-index"
+checksum = "f84ac04429c13a7ff43785d75ad27569f2951ce0ffd30a3321230db2fc727216"
+dependencies = [
+ "phf_generator 0.11.3",
+ "phf_shared 0.11.3",
+ "proc-macro2",
+ "quote",
+ "syn 2.0.114",
+]
TurnBegin(
    user_input='Review this git diff for security, errors, quality. Rate A-F. 
Format: [SEVERITY] file:line - description\n\ndiff --git 
a/.planning/PLAN-phase-1.1.md b/.planning/PLAN-phase-1.1.md\nindex 
90d35ef..8d8c686 100644\n--- a/.planning/PLAN-phase-1.1.md\n+++ 
b/.planning/PLAN-phase-1.1.md\n@@ -1,190 +1,130 @@\n-# Phase 1.1: Remove PI 
Dependency — Task Plan\n+# Phase 1.1: Crate Scaffold & Public API — Task Plan\n 
\n-## Goal\n-Remove all PI coding agent integration from the FAE codebase. This 
includes the pi module, pi_config, HTTP server, config types, and all references
across 13+ source files. After this phase, zero PI references remain and the 
project compiles cleanly.\n+## Overview\n \n-## Strategy\n-Remove in dependency 
order: standalone PI files first, then types/config, then all consumers, then 
deps. Tasks 1-6 perform deletions/edits, task 7 cleans deps and compiles, task 8
verifies everything.\n-\n----\n+Create the `fae-search` library crate within the
Fae workspace with core types, error handling, configuration, and public API 
surface. All implementation functions return placeholder errors — the goal is to
establish the contract and module structure.\n \n ## Tasks\n \n-### Task 1: 
Delete PI module directory and PI-only LLM files\n-**Files to delete:**\n-- 
`src/pi/mod.rs`\n-- `src/pi/engine.rs`\n-- `src/pi/manager.rs`\n-- 
`src/pi/session.rs`\n-- `src/pi/tool.rs`\n-- `src/llm/pi_config.rs`\n-- 
`src/llm/server.rs`\n-- `Skills/pi.md`\n-- `.pi/` directory\n-\n-**Files to 
edit:**\n-- `src/lib.rs` — remove `pub mod pi;` declaration\n-- `src/llm/mod.rs`
— remove `pub mod pi_config;` and `pub mod server;` 
declarations\n-\n----\n-\n-### Task 2: Remove PiConfig and LlmBackend::Pi from 
config.rs\n-**File:** `src/config.rs`\n-\n-**Changes:**\n-- Remove `pub pi: 
PiConfig` field from `SpeechConfig` struct (~line 37)\n-- Remove entire 
`PiConfig` struct definition (~lines 691-712) and its Default impl\n-- Remove 
`Pi` variant from `LlmBackend` enum (~lines 161-163)\n-- Change `LlmBackend` 
default from `Pi` to `Local`\n-- Update `effective_provider_name()` to remove Pi
match arm (~line 410)\n-- Fix/remove test that asserts `LlmBackend::default() ==
LlmBackend::Pi` (~line 842)\n-- Remove any imports/uses that only existed for 
PiConfig\n-\n----\n-\n-### Task 3: Remove PI from startup.rs and 
update/checker.rs\n-**File:** `src/startup.rs`\n-\n-**Changes:**\n-- Remove 
imports: `crate::llm::pi_config::default_pi_models_path`, 
`remove_fae_local_provider`\n-- Remove Pi cleanup on shutdown (~lines 50-51)\n--
Remove `LlmBackend::Pi` from use_local_llm decision branches (~lines 77, 
177)\n-- Remove Pi HTTP server startup logic (~lines 319-320, 355-356)\n-- 
Remove `write_fae_local_provider()` calls\n-\n-**File:** `src/update/checker.rs`
(or `src/update/` module)\n-\n-**Changes:**\n-- Remove `use 
crate::pi::manager::version_is_newer` import\n-- Remove 
`UpdateChecker::for_pi()` method\n-- Remove 
`crate::pi::manager::platform_asset_name()` calls\n-- Remove Pi-specific update 
checking logic\n-\n----\n-\n-### Task 4: Remove PI from 
pipeline/coordinator.rs\n-**File:** 
`src/pipeline/coordinator.rs`\n-\n-**Changes:**\n-- Remove 
`Pi(Box<crate::pi::engine::PiLlm>)` variant from internal LLM backend enum 
(~line 1390)\n-- Remove `use crate::pi::engine::PiLlm;` import (~line 1446)\n-- 
Remove `LlmBackend::Pi =>` initialization block (~line 1487)\n-- Remove 
`uuid::Uuid::new_v4()` usage in Pi context (~line 1726)\n-- Remove entire axum 
HTTP server setup section (~lines 3094-3791)\n-- Remove Pi-related test 
instances (~line 4143)\n-- Remove model_selection_rx/voice_command_tx channels 
if only used for Pi\n-\n----\n-\n-### Task 5: Remove PI from agent/mod.rs and 
llm/api.rs\n-**File:** `src/agent/mod.rs`\n-\n-**Changes:**\n-- Remove `use 
crate::pi::session::PiSession;` import\n-- Remove `use 
crate::pi::tool::PiDelegateTool;` import\n-- Remove `pi_session: 
Option<Arc<Mutex<PiSession>>>` constructor parameter\n-- Remove Pi models.json 
resolution logic (~lines 57-66)\n-- Remove cloud fallback using pi_config 
(~lines 378-380)\n-- Remove PiDelegateTool registration\n-\n-**File:** 
`src/llm/api.rs`\n-\n-**Changes:**\n-- Remove Pi models.json lookups (~lines 
334-338)\n-- Remove `pi_config::read_pi_config()` usage\n-\n----\n-\n-### Task 
6: Remove PI from GUI, voice commands, skills, and remaining files\n-**File:** 
`src/bin/gui.rs`\n-\n-**Changes:**\n-- Remove `LlmBackend::Pi` as default 
backend assignment (~line 1659)\n-- Remove Pi provider/model UI selection 
dropdowns (~lines 1688-1750)\n-- Remove all `LlmBackend::Pi` match arms 
throughout (14+ locations)\n-- Remove "install_pi_update" action handling\n-- 
Replace Pi backend references with appropriate remaining backends\n-\n-**File:**
`src/voice_command.rs`\n-\n-**Changes:**\n-- Remove `use 
crate::pi::engine::PiLlm;` references (~lines 778, 803, 825)\n-- Remove Pi 
backend pattern matching in model switching\n-\n-**File:** 
`src/skills.rs`\n-\n-**Changes:**\n-- Remove `pub const PI_SKILL: &str = 
include_str!("../Skills/pi.md");`\n-- Remove "pi" from `list_skills()`\n-- 
Remove `PI_SKILL.to_owned()` from `load_all_skills()`\n-- Remove pi skill 
filtering logic\n-\n-**File:** `src/memory.rs` — Remove any Pi-specific 
references\n-**File:** `src/progress.rs` — Remove Pi download progress 
tracking\n-**File:** `src/runtime.rs` — Remove Pi runtime events\n-**File:** 
`src/model_picker.rs` — Remove Pi model picker logic\n-**File:** 
`src/model_selection.rs` — Remove Pi from tier selection\n-**File:** 
`src/scheduler/tasks.rs` — Remove "install_pi_update" task\n-\n----\n-\n-### 
Task 7: Clean up Cargo.toml dependencies and compile\n-**File:** 
`Cargo.toml`\n-\n-**Changes:**\n-- Remove `axum = "0.8"` (only used by deleted 
llm/server.rs)\n-- Remove `tower-http = { version = "0.6", features = ["cors"] 
}` (only used with axum)\n-- Remove `uuid = { version = "1", features = ["v4"] 
}` (only used for Pi request IDs)\n-- Verify no other files use these deps 
before removal\n-\n-**Then:**\n-- Run `cargo check --all-features --all-targets`
— fix ALL compilation errors\n-- Run `cargo clippy --all-features --all-targets 
-- -D warnings` — fix ALL warnings\n-- Run `cargo fmt --all` — format all edited
files\n-- Iterate until zero errors and zero warnings\n-\n----\n-\n-### Task 8: 
Verify tests pass and final cleanup\n-**Verification:**\n-- Run `cargo nextest 
run --all-features` — ALL tests must pass\n-- Run `just check` (full validation:
fmt, lint, build, test, doc, panic-scan)\n-- Grep for any remaining PI 
references: `grep -r 
"pi::\\|PiLlm\\|PiSession\\|PiManager\\|PiConfig\\|PiDelegateTool\\|pi_config\\|
PI_SKILL\\|LlmBackend::Pi" src/`\n-- Remove any dead code flagged by clippy 
after removal\n-- Verify zero warnings, zero errors\n-\n----\n-\n-## File Change
Summary\n-\n-| File | Action |\n-|------|--------|\n-| `src/pi/` (5 files) | 
**DELETE** |\n-| `src/llm/pi_config.rs` | **DELETE** |\n-| `src/llm/server.rs` |
**DELETE** |\n-| `Skills/pi.md` | **DELETE** |\n-| `.pi/` directory | **DELETE**
|\n-| `src/lib.rs` | **MODIFY** — remove pi module |\n-| `src/llm/mod.rs` | 
**MODIFY** — remove pi_config, server modules |\n-| `src/config.rs` | **MODIFY**
— remove PiConfig, LlmBackend::Pi |\n-| `src/startup.rs` | **MODIFY** — remove 
Pi init/cleanup |\n-| `src/update/checker.rs` | **MODIFY** — remove Pi update 
logic |\n-| `src/pipeline/coordinator.rs` | **MODIFY** — remove Pi backend, HTTP
server |\n-| `src/agent/mod.rs` | **MODIFY** — remove Pi session/tool |\n-| 
`src/llm/api.rs` | **MODIFY** — remove Pi config lookups |\n-| `src/bin/gui.rs` 
| **MODIFY** — remove Pi UI elements |\n-| `src/voice_command.rs` | **MODIFY** —
remove Pi model switching |\n-| `src/skills.rs` | **MODIFY** — remove Pi skill 
|\n-| `src/memory.rs` | **MODIFY** — remove Pi refs |\n-| `src/progress.rs` | 
**MODIFY** — remove Pi progress |\n-| `src/runtime.rs` | **MODIFY** — remove Pi 
events |\n-| `src/model_picker.rs` | **MODIFY** — remove Pi picker |\n-| 
`src/model_selection.rs` | **MODIFY** — remove Pi tier |\n-| `Cargo.toml` | 
**MODIFY** — remove axum, tower-http, uuid |\n-\n-## Quality Gates\n-- `just 
check` passes (fmt, lint, build, test, doc, panic-scan)\n-- Zero `.unwrap()` or 
`.expect()` in production code\n-- All remaining tests continue to pass\n-- Zero
PI references anywhere in src/\n-- Zero compilation warnings\n+### Task 1: 
Create fae-search Crate in Workspace\n+\n+**What:** Add `fae-search` as a 
workspace member. Create Cargo.toml and empty lib.rs.\n+\n+**Files:**\n+- 
`Cargo.toml` (modify — add workspace members)\n+- `fae-search/Cargo.toml` 
(create)\n+- `fae-search/src/lib.rs` (create)\n+\n+**Acceptance Criteria:**\n+- 
Root Cargo.toml has `[workspace]` with `members = ["fae-search"]`\n+- 
fae-search/Cargo.toml defines lib crate with deps: thiserror, serde, serde_json,
tokio, tracing, url\n+- fae-search/src/lib.rs has crate-level doc comment\n+- 
`cargo check --workspace` passes with zero errors/warnings\n+\n+### Task 2: 
Define SearchError with thiserror (TDD)\n+\n+**What:** Create error types. Tests
first.\n+\n+**Files:**\n+- `fae-search/src/error.rs` (create)\n+- 
`fae-search/src/lib.rs` (update)\n+\n+**Acceptance Criteria:**\n+- SearchError 
enum: AllEnginesFailed, Timeout, Http(String), Parse(String), Config(String)\n+-
All variants use `#[error("...")]`\n+- SearchError is Send + Sync\n+- Doc 
comments on all public items\n+- Tests: display format, variant construction, 
Send+Sync bounds\n+\n+### Task 3: Define Core Types (TDD)\n+\n+**What:** Create 
SearchResult, SearchEngine, PageContent. Tests first.\n+\n+**Files:**\n+- 
`fae-search/src/types.rs` (create)\n+- `fae-search/src/lib.rs` 
(update)\n+\n+**Acceptance Criteria:**\n+- SearchResult: title, url, snippet, 
engine (String), score (f64)\n+- SearchEngine enum: DuckDuckGo, Brave, Google, 
Bing, Startpage with Display, name(), weight()\n+- PageContent: url, title, 
text, word_count\n+- Derive Debug, Clone, Serialize, Deserialize\n+- Tests: 
instantiation, serde round-trip, Display, name(), weight()\n+\n+### Task 4: 
Define SearchConfig with Defaults (TDD)\n+\n+**What:** Create SearchConfig with 
defaults and validation. Tests first.\n+\n+**Files:**\n+- 
`fae-search/src/config.rs` (create)\n+- `fae-search/src/lib.rs` 
(update)\n+\n+**Acceptance Criteria:**\n+- Fields: engines, max_results (10), 
timeout_seconds (8), safe_search (true), cache_ttl_seconds (600), 
request_delay_ms ((100,500)), user_agent (None)\n+- Default impl\n+- validate() 
-> Result<(), SearchError>\n+- Tests: defaults, validation rejects bad 
config\n+\n+### Task 5: Define SearchEngineTrait (TDD)\n+\n+**What:** Create 
async trait for engine implementations. Tests first.\n+\n+**Files:**\n+- 
`fae-search/src/engine.rs` (create)\n+- `fae-search/src/lib.rs` 
(update)\n+\n+**Acceptance Criteria:**\n+- trait SearchEngineTrait: Send + 
Sync\n+- async fn search(&self, query: &str, config: &SearchConfig) -> 
Result<Vec<SearchResult>, SearchError>\n+- fn engine_type(&self) -> 
SearchEngine\n+- fn weight(&self) -> f64\n+- Tests with mock engine: trait 
bounds, async execution, error propagation\n+\n+### Task 6: Stub Engine 
Modules\n+\n+**What:** Create stub engine files returning placeholder 
errors.\n+\n+**Files:**\n+- `fae-search/src/engines/mod.rs` (create)\n+- 
`fae-search/src/engines/duckduckgo.rs` (create)\n+- 
`fae-search/src/engines/brave.rs` (create)\n+- 
`fae-search/src/engines/google.rs` (create)\n+- `fae-search/src/engines/bing.rs`
(create)\n+- `fae-search/src/lib.rs` (update)\n+\n+**Acceptance Criteria:**\n+- 
Each struct implements SearchEngineTrait\n+- Each returns 
Err(SearchError::Parse("not yet implemented"))\n+- engines/mod.rs re-exports 
all\n+- Doc comments on each struct\n+- Tests: compile, satisfy trait\n+\n+### 
Task 7: Define Public API Functions (TDD)\n+\n+**What:** Create search(), 
search_default(), fetch_page_content() stubs. Tests first.\n+\n+**Files:**\n+- 
`fae-search/src/lib.rs` (update — public API)\n+\n+**Acceptance Criteria:**\n+- 
pub async fn search(query: &str, config: &SearchConfig) -> 
Result<Vec<SearchResult>, SearchError>\n+- pub async fn search_default(query: 
&str) -> Result<Vec<SearchResult>, SearchError>\n+- pub async fn 
fetch_page_content(url: &str) -> Result<PageContent, SearchError>\n+- All return
placeholder errors\n+- Doc comments with usage examples\n+- Tests: signatures, 
error types, search_default delegates\n+\n+### Task 8: Full Validation & Doc 
Pass\n+\n+**What:** Run full validation, fix issues, ensure docs 
complete.\n+\n+**Files:**\n+- All fae-search files\n+\n+**Acceptance 
Criteria:**\n+- cargo fmt --all -- --check passes\n+- cargo clippy --workspace 
--all-features -- -D warnings passes\n+- cargo nextest run --workspace 
passes\n+- cargo doc --workspace --no-deps passes zero warnings\n+- All public 
items documented\n+- Zero forbidden patterns\ndiff --git a/.planning/ROADMAP.md 
b/.planning/ROADMAP.md\nindex b66e99d..a5bdb1b 100644\n--- 
a/.planning/ROADMAP.md\n+++ b/.planning/ROADMAP.md\n@@ -1,162 +1,208 @@\n-# FAE 
LLM Module — Roadmap\n+# Fae Tool 5: Embedded Web Search — Roadmap\n \n ## 
Vision\n-Replace the PI subprocess dependency with a pure Rust LLM and 
tool-calling module (`fae_llm`). Multi-provider support (OpenAI, Anthropic, 
local, z.ai, MiniMax, DeepSeek), FAE-owned TOML config with round-trip safety, 
agent loop with tool calling, session persistence, local endpoint probing, and 
structured observability. No TUI dependency.\n+\n+Zero-configuration, embedded 
web search for Fae. No API keys, no external services, no user setup. Scrapes 
search engines directly (like a browser) using CSS selectors on HTML responses. 
Compiles into Fae\'s binary as a library crate.\n \n ## Problem\n-- Technical 
debt: PI subprocess dependency is fragile and adds external binary 
management\n-- Integration gap: Need native Rust LLM module without subprocess 
RPC overhead\n-- Missing functionality: Need multi-provider support beyond what 
PI provides\n+\n+- Missing functionality: Fae can\'t answer questions requiring 
current/real-time information\n+- Privacy gap: Existing search tools require API
keys/external services, violating Fae\'s local-first promise\n \n ## Success 
Criteria\n-- Production ready: Complete + tested + documented\n-- Zero PI 
references remaining in codebase\n-- All providers functional with tool-calling 
agent loop\n-- Config safe for app-menu updates (round-trip TOML)\n-- Full 
observability with tracing/metrics/redaction\n \n----\n+- Production ready: All 
engines working, cached, tested, documented, integrated\n+- Zero API keys or 
external service dependencies\n+- Graceful degradation when engines are 
unavailable\n+- In-memory caching with TTL for performance\n+- Full public API 
documentation\n+\n+## Sources\n \n-## Milestone 1: PI Removal & 
Foundation\n-\n-Remove the PI dependency entirely and establish the fae_llm 
crate with core types, config, and tools.\n-\n-### Phase 1.1: Remove PI 
Dependency\n-- Delete `src/pi/` directory (engine.rs, manager.rs, session.rs, 
tool.rs, mod.rs)\n-- Delete `src/llm/pi_config.rs` and `src/llm/server.rs` 
(Pi-only HTTP server)\n-- Remove all PI references from config.rs, 
pipeline/coordinator.rs, agent/mod.rs\n-- Remove PI references from 
voice_command.rs, startup.rs, bin/gui.rs, memory.rs\n-- Remove PI-related 
progress tracking, update logic\n-- Clean up unused dependencies from 
Cargo.toml\n-- Ensure project compiles and all remaining tests pass\n-\n-### 
Phase 1.2: Create fae_llm Crate Structure\n-- Create `fae_llm/` crate with 
module layout per spec\n-- Define core types: EndpointType, ModelRef, 
RequestOptions, ReasoningLevel\n-- Define normalized event model (start, 
text_delta, tool_call_start, etc.)\n-- Define error types with stable codes 
(ConfigError, AuthError, RequestError, etc.)\n-- Define usage/cost structs and 
stop reasons\n-\n-### Phase 1.3: Config Schema & Persistence\n-- Define TOML 
config schema v1 (providers, models, tools, defaults, runtime)\n-- Implement 
ConfigService with atomic read/write (temp -> fsync -> rename)\n-- Implement 
round-trip TOML editing via toml_edit (preserve comments/unknown fields)\n-- 
Implement secret resolution (none, env, literal, command, keychain)\n-- 
Implement config validation and safe partial update API for app menu\n-- Backup 
last-known-good config\n-\n-### Phase 1.4: Tool Registry & Implementations\n-- 
Define Tool trait and ToolRegistry\n-- Implement read tool (file content with 
offset/limit, bounded output)\n-- Implement bash tool (shell command with 
timeout/cancel, bounded output)\n-- Implement edit tool (deterministic text 
edits)\n-- Implement write tool (create/overwrite with path validation)\n-- 
Implement tool mode gating (read_only vs full)\n-- Schema validation for tool 
arguments\n+- **metasearch2** (CC0/Public Domain) — adapt engine scraping code 
directly\n+- **Websurfx** (AGPLv3) — study for ideas only, rewrite everything 
clean\n \n ---\n \n-## Milestone 2: Provider Implementation\n+## Milestone 1: 
fae-search Crate (Core Library)\n+\n+Build the standalone `fae-search` library 
crate with search engine scrapers, result aggregation, and caching.\n+\n+### 
Phase 1.1: Crate Scaffold & Public API\n+\n+Create the `fae-search` crate with 
types, error handling, configuration, and public API surface.\n+\n+- Create 
`fae-search/` crate directory with Cargo.toml\n+- Add workspace member to root 
Cargo.toml (convert to workspace if needed)\n+- Define `SearchResult`, 
`SearchConfig`, `SearchEngine`, `PageContent` types\n+- Define `SearchError` 
with thiserror\n+- Define public API functions (`search`, `search_default`, 
`fetch_page_content`)\n+- Define `SearchEngineTrait` for pluggable engine 
implementations\n+- Stub all engine modules\n+- Add basic unit tests for types 
and config defaults\n+\n+### Phase 1.2: DuckDuckGo & Brave 
Engines\n+\n+Implement the two most reliable, scraper-friendly search 
engines.\n+\n+- Implement DuckDuckGo HTML scraper 
(html.duckduckgo.com/html/)\n+- Implement Brave Search HTML scraper\n+- CSS 
selector extraction for title, URL, snippet from each\n+- User-Agent rotation 
(list of realistic browser UAs)\n+- Per-engine request timeout handling\n+- Unit
tests with mock HTML fixture files per engine\n+- Integration tests (marked 
`#[ignore]`) for live validation\n+\n+### Phase 1.3: Google & Bing 
Engines\n+\n+Add the two major engines with more aggressive bot 
detection.\n+\n+- Implement Google HTML scraper with ad filtering\n+- Implement 
Bing HTML scraper with URL parameter decoding\n+- Cookie jar support for Google 
consent pages\n+- Resilient selectors with fallback patterns\n+- Unit tests with
mock HTML fixtures\n+- Integration tests (marked `#[ignore]`)\n+\n+### Phase 
1.4: Search Orchestrator\n \n-Build provider adapters for all supported LLM 
backends.\n+Concurrent multi-engine queries with result ranking and 
deduplication.\n \n-### Phase 2.1: OpenAI Adapter\n-- Implement ProviderAdapter 
trait\n-- OpenAI Completions request builder + SSE streaming parser\n-- OpenAI 
Responses API support\n-- Normalize to shared event model\n-- Tool call 
streaming with partial JSON parsing\n+- Fan out queries to all enabled engines 
concurrently (tokio::join!)\n+- Result deduplication by URL normalization\n+- 
Weighted scoring: configurable weight per engine\n+- Cross-engine boost: URLs 
appearing in multiple engines get score bonus\n+- Sort by aggregated score, 
truncate to max_results\n+- Graceful degradation: if some engines fail, return 
results from others\n+- Only error if ALL engines fail\n+- Unit tests for 
ranking, dedup, and fallback logic\n \n-### Phase 2.2: Compatibility Profile 
Engine\n-- Implement profile flag system (max_tokens_field, reasoning_mode, 
etc.)\n-- Create profiles for z.ai, MiniMax, DeepSeek, local backends\n-- Single
OpenAI-compatible adapter + profile resolution\n-- Profile-based 
request/response normalization\n+### Phase 1.5: Cache, UA Rotation & Request 
Jitter\n \n-### Phase 2.3: Local Probe Service\n-- Implement LocalProbeService 
(health check, /v1/models, configurable)\n-- Typed failures: NotRunning, 
Timeout, Unhealthy, IncompatibleResponse\n-- Bounded backoff retry\n-- Status 
exposure for app menu diagnostics\n-- Extension point for future 
RuntimeManager\n+Production hardening for the search library.\n \n-### Phase 
2.4: Anthropic Adapter\n-- Implement Anthropic Messages API adapter\n-- Map 
thinking/tool_use blocks to shared event model\n-- Streaming support with 
content block deltas\n+- In-memory LRU cache using moka with configurable TTL 
(default 600s)\n+- Cache key: lowercase query + engine set hash\n+- User-Agent 
rotation per request from built-in list\n+- Random request delay jitter between 
engine queries (100-500ms configurable)\n+- Safe search parameter forwarding to 
engines that support it\n+- Tracing instrumentation (trace-level only, no 
persistent query logging)\n \n ---\n \n-## Milestone 3: Agent Loop & 
Sessions\n+## Milestone 2: Fae Integration\n \n-Build the tool-calling agent 
loop and session persistence.\n+Wire fae-search into Fae\'s tool system and add 
content extraction.\n \n-### Phase 3.1: Agent Loop Engine\n-- Implement agentic 
loop: prompt -> stream -> tool calls -> execute -> continue\n-- Max turn count, 
max tool calls per turn guards\n-- Request and tool timeouts\n-- 
Abort/cancellation propagation\n-- Tool argument validation against 
schemas\n+### Phase 2.1: WebSearchTool & FetchUrlTool\n \n-### Phase 3.2: 
Session Persistence & Replay\n-- Implement session store (persist every 
completed message)\n-- Session resume with state validation\n-- Typed 
continuation errors\n-- Conversation context management\n+Implement Fae\'s 
`Tool` trait for both tools.\n \n-### Phase 3.3: Multi-Provider Hardening\n-- 
Provider switch during resumed conversation\n-- Error recovery and retry 
policies\n-- End-to-end multi-turn tool loop tests\n-- Mode switching 
integration (read_only <-> full)\n+- `WebSearchTool` implementing `Tool` trait 
(name, description, schema, execute, allowed_in_mode)\n+- `FetchUrlTool` 
implementing `Tool` trait\n+- JSON schema definitions matching the brief\'s tool
specs\n+- Tool mode gating (always allowed in ReadOnly+ modes)\n+- Result 
formatting for LLM consumption (clean, structured output)\n+- Unit tests for 
schema validation and execution\n+\n+### Phase 2.2: Registry Wiring & Feature 
Flag\n+\n+Integrate into Fae\'s build and tool registration.\n+\n+- Add 
`web-search` feature flag to root Cargo.toml\n+- Add fae-search as path 
dependency (optional, behind feature flag)\n+- Register WebSearchTool + 
FetchUrlTool in `build_tool_registry()` (agent/mod.rs)\n+- Enable by default in 
`AgentToolMode::ReadOnly` and above\n+- Verify tool schemas appear in LLM API 
payloads\n+- Integration test: full agent loop with web search tool 
available\n+\n+### Phase 2.3: Content Extraction (fetch_page_content)\n+\n+Fetch
URLs and extract readable text content.\n+\n+- HTTP fetch with reqwest (follow 
redirects, respect timeouts)\n+- HTML parsing with scraper crate\n+- Content 
extraction: strip nav, ads, footer, scripts, styles\n+- Extract main 
article/content body\n+- Return clean text with title and word count\n+- 
Truncation for very large pages (configurable max chars)\n+- Unit tests with 
sample HTML pages\n+\n+### Phase 2.4: Circuit Breaker & Adaptive Engine 
Selection\n+\n+Reliability under real-world conditions.\n+\n+- Track per-engine 
success/failure counts\n+- Circuit breaker: disable engine after N consecutive 
failures\n+- Half-open state: retry disabled engine after cooldown period\n+- 
Exponential backoff on repeated failures\n+- Health status reporting (which 
engines are currently active)\n+- Unit tests for circuit breaker state 
transitions\n \n ---\n \n-## Milestone 4: Observability & Release\n+## Milestone
3: Production Hardening\n+\n+Comprehensive testing, documentation, and 
additional engines.\n+\n+### Phase 3.1: Test Suite with Mock 
Fixtures\n+\n+Comprehensive offline-testable suite.\n+\n+- HTML fixture files 
per engine (saved from real responses)\n+- Parser tests against fixtures (detect
selector breakage)\n+- Fallback tests: simulate engine failures, verify graceful
degradation\n+- Cache tests: hit/miss, TTL expiry, capacity eviction\n+- Request
delay tests: verify jitter is applied\n+- Error path tests: timeout, parse 
error, HTTP error\n+- All tests must pass in CI without network access\n+\n+### 
Phase 3.2: Integration Tests\n+\n+Live validation (manual/periodic, not CI).\n 
\n-Production hardening with observability and comprehensive testing.\n+- Live 
search tests per engine (marked `#[ignore]`)\n+- Cross-engine result quality 
validation\n+- Rate limit behavior verification\n+- End-to-end: agent loop with 
web search producing useful responses\n+- Selector breakage detection (alert if 
engine returns 0 results)\n \n-### Phase 4.1: Tracing, Metrics & Redaction\n-- 
Structured tracing spans (per request, turn, tool execution)\n-- Metrics hooks 
(latency, retry count, tool success/failure, token usage)\n-- Secret redaction 
(API keys, auth headers, secret refs)\n+### Phase 3.3: Documentation, Startpage 
Engine & Safe Search\n \n-### Phase 4.2: Full Integration Test Matrix\n-- 
OpenAI, Anthropic, local endpoint contract tests\n-- z.ai/MiniMax/DeepSeek 
profile tests\n-- E2E: prompt -> tool -> result -> continue\n-- Failure 
injection tests\n-- Mode gating tests (read_only rejects mutations)\n+Final 
polish for production release.\n \n-### Phase 4.3: App Integration & Release\n--
App-menu integration tests\n-- Config round-trip preservation tests\n-- Operator
and developer documentation\n-- Release candidate validation\n+- Startpage 
engine (proxied Google fallback)\n+- Safe search enforcement across all 
engines\n+- API documentation on all public items\n+- Update Fae\'s README with 
web search capability\n+- Update CLAUDE.md with fae-search architecture notes\n 
\n ---\n \n-## Technical Decisions (Locked)\n-\n-| Decision | Choice 
|\n-|----------|--------|\n-| Local mode | probe_only (never start/stop model 
processes in v1) |\n-| Config format | TOML with toml_edit for round-trip safety
|\n-| Secret modes | none, env, literal (dev), command (off by default), 
keychain |\n-| Tool set | read, bash, edit, write (4 tools, stable names) |\n-| 
Tool modes | read_only, full (2 modes only) |\n-| Error handling | thiserror 
with typed errors + stable codes |\n-| Async runtime | tokio (match existing) 
|\n-| Testing | Unit + Integration + Property-based |\n-| Streaming | Normalized
event model across all providers |\n-\n-## Providers (v1)\n-\n-| Provider | 
Implementation |\n-|----------|---------------|\n-| OpenAI | Native adapter 
(Completions + Responses) |\n-| Anthropic | Native adapter (Messages API) |\n-| 
z.ai | OpenAI-compatible + profile |\n-| MiniMax | OpenAI-compatible + profile 
|\n-| DeepSeek | OpenAI-compatible + profile |\n-| Local endpoints | 
OpenAI-compatible + profile |\n+## Quality Standards (Enforced on Every 
Phase)\n+\n+```\n+FORBIDDEN in src/:\n+  .unwrap()  .expect()  panic!()  todo!()
unimplemented!()\n+\n+REQUIRED:\n+  cargo fmt --all -- --check\n+  cargo clippy 
--all-features -- -D warnings\n+  cargo nextest run --all-features\n+  thiserror
for all error types\n+  Doc comments on all public items\n+  Tests written 
BEFORE implementation (TDD)\n+```\n+\n+## Key Technical Decisions\n+\n+| 
Decision | Choice | Rationale |\n+|----------|--------|-----------|\n+| Crate 
structure | Separate `fae-search` lib crate | Clean separation, independent 
testing |\n+| Primary engine | DuckDuckGo | Most scraper-friendly, 
privacy-aligned |\n+| HTTP client | reqwest (already in tree) | No new 
dependencies for HTTP |\n+| HTML parsing | scraper crate | CSS selector-based, 
proven by metasearch2 |\n+| Cache | moka (in-memory) | TTL support, 
async-friendly, no external deps |\n+| Error handling | thiserror | Matches 
Fae\'s existing pattern |\n+| Async runtime | tokio (already in tree) | No new 
runtime dependency |\n+| Source licensing | CC0 (metasearch2) for code, 
clean-room for Websurfx ideas | Legal clarity |\ndiff --git 
a/.planning/STATE.json b/.planning/STATE.json\nindex 8cb3ecc..b09e828 
100644\n--- a/.planning/STATE.json\n+++ b/.planning/STATE.json\n@@ -1,27 +1,26 
@@\n {\n   "version": 1,\n-  "project": "fae-llm-module",\n+  "project": 
"fae-tool5-web-search",\n   "active": true,\n   "milestone": {\n-    "number": 
4,\n-    "name": "Observability & Release"\n+    "number": 1,\n+    "name": 
"fae-search Crate (Core Library)"\n   },\n   "phase": {\n-    "number": 
"4.3",\n-    "name": "App Integration & Release",\n-    "plan": 
".planning/PLAN-phase-4.3.md"\n+    "number": "1.2",\n+    "name": "DuckDuckGo &
Brave Engines",\n+    "plan": null\n   },\n   "progress": {\n-    "total_tasks":
8,\n-    "completed_tasks": 8,\n+    "total_tasks": 3,\n+    "completed_tasks": 
3,\n     "current_task": null\n   },\n-  "status": "milestone_complete",\n   
"review": {\n-    "status": "pending",\n-    "iteration": 0,\n-    
"last_verdict": "PASS"\n+    "status": "reviewing",\n+    "iteration": 1,\n+    
"last_verdict": null\n   },\n-  "last_updated": 1770929000,\n-  "last_action": 
"phase_4.3_transition"\n+  "status": "reviewing",\n+  "last_updated": 
"2026-02-14T13:00:00Z"\n }\ndiff --git a/Cargo.lock b/Cargo.lock\nindex 
8269107..f60b66f 100644\n--- a/Cargo.lock\n+++ b/Cargo.lock\n@@ -92,6 +92,21 @@ 
dependencies = [\n  "equator",\n ]\n \n+[[package]]\n+name = 
"alloc-no-stdlib"\n+version = "2.0.4"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"cc7bb162ec39d46ab1ca8c77bf72e890535becd1751bb45f64c597edb4c8c6b3"\n+\n+[[packag
e]]\n+name = "alloc-stdlib"\n+version = "0.2.2"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"94fb8275041c72129eb51b7d0322c29b8387a0386127718b096429201a5d6ece"\n+dependencie
s = [\n+ "alloc-no-stdlib",\n+]\n+\n [[package]]\n name = "allocator-api2"\n 
version = "0.2.21"\n@@ -378,6 +393,18 @@ dependencies = [\n  
"pin-project-lite",\n ]\n \n+[[package]]\n+name = "async-compression"\n+version 
= "0.4.39"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"68650b7df54f0293fd061972a0fb05aaf4fc0879d3b3d21a638a182c5c543b9f"\n+dependencie
s = [\n+ "compression-codecs",\n+ "compression-core",\n+ "pin-project-lite",\n+ 
"tokio",\n+]\n+\n [[package]]\n name = "async-executor"\n version = "1.13.3"\n@@
-851,6 +878,27 @@ dependencies = [\n  "unicode-segmentation",\n ]\n 
\n+[[package]]\n+name = "brotli"\n+version = "8.0.2"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"4bd8b9603c7aa97359dbd97ecf258968c95f3adddd6db2f7e7a5bef101c84560"\n+dependencie
s = [\n+ "alloc-no-stdlib",\n+ "alloc-stdlib",\n+ 
"brotli-decompressor",\n+]\n+\n+[[package]]\n+name = 
"brotli-decompressor"\n+version = "5.0.0"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"874bb8112abecc98cbd6d81ea4fa7e94fb9449648c93cc89aa40c81c24d7de03"\n+dependencie
s = [\n+ "alloc-no-stdlib",\n+ "alloc-stdlib",\n+]\n+\n [[package]]\n name = 
"bstr"\n version = "1.12.1"\n@@ -1440,6 +1488,24 @@ dependencies = [\n  
"static_assertions",\n ]\n \n+[[package]]\n+name = 
"compression-codecs"\n+version = "0.4.36"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"00828ba6fd27b45a448e57dbfe84f1029d4c9f26b368157e9a448a5f49a2ec2a"\n+dependencie
s = [\n+ "brotli",\n+ "compression-core",\n+ "flate2",\n+ 
"memchr",\n+]\n+\n+[[package]]\n+name = "compression-core"\n+version = 
"0.4.31"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"75984efb6ed102a0d42db99afb6c1948f0380d1d91808d5529916e6c08b49d8d"\n+\n 
[[package]]\n name = "concurrent-queue"\n version = "2.5.0"\n@@ -1547,6 +1613,35
@@ dependencies = [\n  "unicode-segmentation",\n ]\n \n+[[package]]\n+name = 
"cookie"\n+version = "0.18.1"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"4ddef33a339a91ea89fb53151bd0a4689cfce27055c291dfa69945475d22c747"\n+dependencie
s = [\n+ "percent-encoding",\n+ "time",\n+ 
"version_check",\n+]\n+\n+[[package]]\n+name = "cookie_store"\n+version = 
"0.22.0"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"3fc4bff745c9b4c7fb1e97b25d13153da2bc7796260141df62378998d070207f"\n+dependencie
s = [\n+ "cookie",\n+ "document-features",\n+ "idna",\n+ "log",\n+ 
"publicsuffix",\n+ "serde",\n+ "serde_derive",\n+ "serde_json",\n+ "time",\n+ 
"url",\n+]\n+\n [[package]]\n name = "core-foundation"\n version = "0.9.4"\n@@ 
-1811,6 +1906,19 @@ dependencies = [\n  "syn 1.0.109",\n ]\n 
\n+[[package]]\n+name = "cssparser"\n+version = "0.34.0"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"b7c66d1cd8ed61bf80b38432613a7a2f09401ab8d0501110655f8b341484a3e3"\n+dependencie
s = [\n+ "cssparser-macros",\n+ "dtoa-short",\n+ "itoa 1.0.17",\n+ "phf 
0.11.3",\n+ "smallvec 1.15.1",\n+]\n+\n [[package]]\n name = "cssparser"\n 
version = "0.36.0"\n@@ -3048,6 +3156,21 @@ dependencies = [\n  "zip 2.4.2",\n 
]\n \n+[[package]]\n+name = "fae-search"\n+version = "0.1.0"\n+dependencies = 
[\n+ "rand 0.8.5",\n+ "reqwest 0.12.28",\n+ "scraper 0.22.0",\n+ "serde",\n+ 
"serde_json",\n+ "thiserror 2.0.18",\n+ "tokio",\n+ "tracing",\n+ 
"url",\n+]\n+\n [[package]]\n name = "fancy-regex"\n version = "0.13.0"\n@@ 
-4319,6 +4442,18 @@ dependencies = [\n  "syn 1.0.109",\n ]\n 
\n+[[package]]\n+name = "html5ever"\n+version = "0.29.1"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"3b7410cae13cbc75623c98ac4cbfd1f0bedddf3227afc24f370cf0f50a44a11c"\n+dependencie
s = [\n+ "log",\n+ "mac",\n+ "markup5ever 0.14.1",\n+ "match_token",\n+]\n+\n 
[[package]]\n name = "html5ever"\n version = "0.36.1"\n@@ -5269,6 +5404,20 @@ 
dependencies = [\n  "tendril 0.4.3",\n ]\n \n+[[package]]\n+name = 
"markup5ever"\n+version = "0.14.1"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"c7a7213d12e1864c0f002f52c2923d4556935a43dec5e71355c2760e0f6e7a18"\n+dependencie
s = [\n+ "log",\n+ "phf 0.11.3",\n+ "phf_codegen 0.11.3",\n+ "string_cache 
0.8.9",\n+ "string_cache_codegen 0.5.4",\n+ "tendril 0.4.3",\n+]\n+\n 
[[package]]\n name = "markup5ever"\n version = "0.36.1"\n@@ -5291,6 +5440,17 @@ 
dependencies = [\n  "web_atoms",\n ]\n \n+[[package]]\n+name = 
"match_token"\n+version = "0.1.0"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"88a9689d8d44bf9964484516275f5cd4c9b59457a6940c1d5d0ecbb94510a36b"\n+dependencie
s = [\n+ "proc-macro2",\n+ "quote",\n+ "syn 2.0.114",\n+]\n+\n [[package]]\n 
name = "matchers"\n version = "0.2.0"\n@@ -5589,7 +5749,7 @@ dependencies = [\n 
"rustfft",\n  "safetensors 0.7.0",\n  "schemars 1.2.1",\n- "scraper",\n+ 
"scraper 0.25.0",\n  "serde",\n  "serde-big-array",\n  "serde-saphyr",\n@@ 
-6843,6 +7003,16 @@ dependencies = [\n  "phf_shared 0.10.0",\n ]\n 
\n+[[package]]\n+name = "phf"\n+version = "0.11.3"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"1fd6780a80ae0c52cc120a26a1a42c1ae51b247a253e4e06113d23d2c2edd078"\n+dependencie
s = [\n+ "phf_macros 0.11.3",\n+ "phf_shared 0.11.3",\n+]\n+\n [[package]]\n 
name = "phf"\n version = "0.13.1"\n@@ -6874,6 +7044,16 @@ dependencies = [\n  
"phf_shared 0.10.0",\n ]\n \n+[[package]]\n+name = "phf_codegen"\n+version = 
"0.11.3"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"aef8048c789fa5e851558d709946d6d79a8ff88c0440c587967f8e94bfb1216a"\n+dependencie
s = [\n+ "phf_generator 0.11.3",\n+ "phf_shared 0.11.3",\n+]\n+\n [[package]]\n 
name = "phf_codegen"\n version = "0.13.1"\n@@ -6938,6 +7118,19 @@ dependencies =
[\n  "syn 1.0.109",\n ]\n \n+[[package]]\n+name = "phf_macros"\n+version = 
"0.11.3"\n+source = 
"registry+https://github.com/rust-lang/crates.io-index"\n+checksum = 
"f84ac04429c13a7ff43785d75ad27569f2951ce0ffd30a3321230db2fc727216"\n+dependencie
s = [\n+ "phf_generator 0.11.3",\n+ "phf_shared 0.11.3",\n+ "proc-macro2",\n+ 
"quote",\n+ "syn 2.0.114",\n+]'
)
StepBegin(n=1)
ThinkPart(
    type='think',
    think='The user wants me to review a git diff for security, errors, and 
quality, and rate it A-F with a specific format: `[SEVERITY] file:line - 
description`.\n\nLet me analyze the diff. It looks like this is a planning 
document change for a project called "Fae" - transitioning from Phase 1.1 about 
removing PI dependencies to a new Phase 1.1 about creating a web search 
crate.\n\nLooking at the diff:\n1. `.planning/PLAN-phase-1.1.md` - Complete 
rewrite of the phase plan\n2. `.planning/ROADMAP.md` - Complete rewrite of the 
roadmap \n3. `.planning/STATE.json` - Update to project state\n4. `Cargo.lock` -
Dependency changes (adding fae-search crate and its deps)\n\nThis is a large 
diff. Let me look for potential issues:\n\n**Cargo.lock changes:**\n- Adding 
`fae-search` crate with dependencies: rand, reqwest, scraper, serde, serde_json,
thiserror, tokio, tracing, url\n- Adding various dependencies like brotli, 
cookie_store, cssparser, etc.\n\n**Security considerations:**\n1. The new crate 
uses `reqwest` for HTTP - this is standard\n2. Uses `scraper` for HTML parsing -
need to check which version\n3. The dependencies seem reasonable for a web 
scraping library\n\nLet me look more carefully at the Cargo.lock diff - it seems
to be adding scraper 0.22.0 and there\'s already scraper 0.25.0 in the project. 
This could be a version conflict issue.\n\nWait, looking at the Cargo.lock:\n- 
`scraper 0.22.0` is being added for fae-search\n- `scraper 0.25.0` already 
exists (from mistralrs)\n\nThis means there will be two versions of scraper in 
the dependency tree. This is not ideal but not a security issue per 
se.\n\nLooking at the Cargo.toml for fae-search - I don\'t see it in the diff, 
but I can see the Cargo.lock changes which show the dependencies.\n\nActually, 
looking at the diff more carefully - this is mostly documentation changes (PLAN 
files, ROADMAP, STATE). The only code-related change is in Cargo.lock which adds
dependencies.\n\nWait, I need to check if there are any actual source code 
changes. The diff shows:\n1. `.planning/PLAN-phase-1.1.md` - documentation\n2. 
`.planning/ROADMAP.md` - documentation\n3. `.planning/STATE.json` - state 
file\n4. `Cargo.lock` - lock file changes\n\nThere don\'t appear to be any 
actual source code changes in this diff - it\'s all planning documents and lock 
file updates. The lock file is adding dependencies for the fae-search crate that
was presumably created separately.\n\nLet me look for any issues:\n\n1. **In 
Cargo.lock**: The diff shows adding `fae-search` with `scraper 0.22.0` while the
main project already uses `scraper 0.25.0`. This is a potential issue - having 
two versions of the same crate.\n\n2. **In Cargo.lock**: Adding `cookie_store 
0.22.0` - this is for cookie handling in HTTP requests.\n\n3. **In Cargo.lock**:
Adding `brotli` compression support.\n\nSince this is primarily documentation 
changes and Cargo.lock updates (which are generated), I should focus on:\n- 
Dependency version conflicts\n- Security implications of new dependencies\n- 
Quality issues in the planning documents\n\nActually, looking at the Cargo.lock 
diff more carefully - there are some concerning things:\n1. Two versions of 
`scraper` (0.22.0 and 0.25.0)\n2. Two versions of `html5ever` (0.29.1 and 
0.36.1)\n3. Two versions of `markup5ever` (0.14.1 and 0.36.1)\n4. Two versions 
of `phf` (0.11.3 and 0.13.1)\n5. Two versions of `cssparser` (0.34.0 and 
0.36.0)\n\nThis duplication is caused by fae-search using scraper 0.22.0 while 
the main project uses scraper 0.25.0. This should be fixed by updating 
fae-search to use scraper 0.25.0.\n\nAlso, I notice `rand 0.8.5` is being added,
but rand 0.9 might be available. However, this is not necessarily an 
issue.\n\nLet me check if there are any critical security issues. The 
dependencies seem standard:\n- reqwest for HTTP\n- scraper for HTML parsing\n- 
thiserror for errors\n- serde for serialization\n- tokio for async\n- tracing 
for logging\n- url for URL parsing\n- rand for randomness\n\nAll of these are 
standard, well-maintained crates.\n\nThe main issues I see are:\n1. Version 
duplication for scraper and its dependencies\n2. Potential for the fae-search 
crate to not be following the project\'s quality standards (no unwrap, etc.) - 
but I can\'t see the source code in this diff\n\nWait, looking at the diff again
- the Cargo.lock shows fae-search dependencies but I don\'t see the actual 
fae-search source code or Cargo.toml in the diff. This suggests the crate was 
already created and this diff is just updating the planning documents and the 
lock file.\n\nGiven that this is primarily documentation changes, I should rate 
it based on:\n- The quality of the planning documents\n- The dependency version 
duplication issue in Cargo.lock\n\nActually, I should be more careful. The user 
is asking me to review this diff. Let me look for any actual problems.\n\nIn 
ROADMAP.md, there\'s a mention of:\n- "Source licensing: CC0 (metasearch2) for 
code, clean-room for Websurfx ideas"\n\nThis seems fine.\n\nIn 
PLAN-phase-1.1.md, the tasks look reasonable for scaffolding a crate.\n\nThe 
main technical issue is the dependency duplication in Cargo.lock. This is a 
quality issue.\n\nSince I don\'t see the actual source code for fae-search in 
this diff, I can\'t evaluate the implementation. But the Cargo.lock shows that 
fae-search is using scraper 0.22.0 which is outdated.\n\nLet me provide a review
focusing on what I can see:\n\n1. **[MEDIUM] Cargo.lock** - Duplicate scraper 
versions: fae-search uses scraper 0.22.0 while the main project uses scraper 
0.25.0. This increases binary size and compile time.\n2. **[LOW] Cargo.lock** - 
Multiple versions of html5ever, markup5ever, phf, cssparser due to the scraper 
version mismatch.\n3. **[INFO] .planning/PLAN-phase-1.1.md** - Good TDD approach
specified with tests before implementation.\n\nWait, I need to be more thorough.
Let me check if there\'s anything else.\n\nLooking at the dependencies for 
fae-search in Cargo.lock:\n- rand 0.8.5 (older version, rand 0.9 is latest)\n- 
scraper 0.22.0 (older version, scraper 0.25 is latest)\n\nThese should probably 
be updated.\n\nAlso, I notice that the Cargo.lock diff doesn\'t show the full 
picture - it\'s truncated. I should assume the changes are as 
described.\n\nGiven the scope of the diff (mostly planning docs with Cargo.lock 
updates), and the dependency duplication issue, I\'d rate this a **B** - good 
planning but dependency version issues need to be addressed.\n\nLet me formulate
my findings:\n\nIssues found:\n1. Dependency version duplication for scraper and
related crates\n2. Using older versions of rand and scraper when newer are 
available\n3. No source code shown to verify implementation quality\n\nBut wait 
- I should also consider that this diff might be incomplete. The user might want
me to review what was actually implemented. However, I can only review what\'s 
in the diff.\n\nLet me reconsider. The diff is mostly documentation changes. The
Cargo.lock shows the dependencies. The quality of the planning documents looks 
good - they follow TDD, specify acceptance criteria, etc.\n\nThe main issue is 
the dependency version duplication. This is a [MEDIUM] severity issue 
because:\n- It increases compile times\n- It increases binary size\n- It might 
cause confusion or compatibility issues\n- It suggests the new crate wasn\'t 
integrated with the existing dependency versions\n\nI\'ll rate this a B+ or A- 
depending on how critical the dependency issue is. Actually, given that this is 
just the planning phase and the Cargo.lock is generated, and the actual 
implementation might not be in this diff, I\'ll focus on what I can see.\n\nLet 
me provide the review in the requested format.',
    encrypted=None
)
TextPart(
    type='text',
    text='Looking at this diff, it\'s primarily documentation changes (planning 
files) with `Cargo.lock` updates for a new `fae-search` crate. The planning 
looks solid with TDD approach, but there are dependency version 
conflicts.\n\n**Grade: B+**\n\n```text\n[MEDIUM] Cargo.lock:1 - Dependency 
version duplication: fae-search uses scraper 0.22.0 while main project uses 
scraper 0.25.0 (via mistralrs). This causes duplicate versions of html5ever, 
markup5ever, phf, and cssparser in the dependency tree, increasing compile times
and binary size. Align fae-search/Cargo.toml to use scraper = "0.25" to match 
workspace.\n\n[LOW] Cargo.lock:1 - rand 0.8.5 is used in fae-search while rand 
0.9 is available. Not critical, but consider updating for latest 
improvements.\n\n[INFO] .planning/PLAN-phase-1.1.md:1 - Good TDD specification 
with "Tests first" on each task and explicit acceptance criteria.\n\n[INFO] 
.planning/ROADMAP.md:1 - Well-structured roadmap with clear phase separation and
quality standards enforcement section.\n\n[INFO] .planning/ROADMAP.md:82 - 
Correctly notes licensing approach (CC0 for metasearch2 code adaptation, 
clean-room for Websurfx ideas).\n\n[INFO] .planning/STATE.json:10 - Phase 
numbering reset from 4.3 to 1.2 is appropriate for the new project direction 
(fae-tool5-web-search vs fae-llm-module).\n```'
)
StatusUpdate(
    context_usage=0.06833267211914062,
    token_usage=TokenUsage(
        input_other=13049,
        output=2168,
        input_cache_read=4864,
        input_cache_creation=0
    ),
    message_id='chatcmpl-os2MsfTW4PEgbdJDresCaC0V'
)
