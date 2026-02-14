# Fae Tool 5: Embedded Web Search — Roadmap

## Vision

Zero-configuration, embedded web search for Fae. No API keys, no external services, no user setup. Scrapes search engines directly (like a browser) using CSS selectors on HTML responses. Compiles into Fae's binary as a library crate.

## Problem

- Missing functionality: Fae can't answer questions requiring current/real-time information
- Privacy gap: Existing search tools require API keys/external services, violating Fae's local-first promise

## Success Criteria

- Production ready: All engines working, cached, tested, documented, integrated
- Zero API keys or external service dependencies
- Graceful degradation when engines are unavailable
- In-memory caching with TTL for performance
- Full public API documentation

## Sources

- **metasearch2** (CC0/Public Domain) — adapt engine scraping code directly
- **Websurfx** (AGPLv3) — study for ideas only, rewrite everything clean

---

## Milestone 1: fae-search Crate (Core Library)

Build the standalone `fae-search` library crate with search engine scrapers, result aggregation, and caching.

### Phase 1.1: Crate Scaffold & Public API

Create the `fae-search` crate with types, error handling, configuration, and public API surface.

- Create `fae-search/` crate directory with Cargo.toml
- Add workspace member to root Cargo.toml (convert to workspace if needed)
- Define `SearchResult`, `SearchConfig`, `SearchEngine`, `PageContent` types
- Define `SearchError` with thiserror
- Define public API functions (`search`, `search_default`, `fetch_page_content`)
- Define `SearchEngineTrait` for pluggable engine implementations
- Stub all engine modules
- Add basic unit tests for types and config defaults

### Phase 1.2: DuckDuckGo & Brave Engines

Implement the two most reliable, scraper-friendly search engines.

- Implement DuckDuckGo HTML scraper (html.duckduckgo.com/html/)
- Implement Brave Search HTML scraper
- CSS selector extraction for title, URL, snippet from each
- User-Agent rotation (list of realistic browser UAs)
- Per-engine request timeout handling
- Unit tests with mock HTML fixture files per engine
- Integration tests (marked `#[ignore]`) for live validation

### Phase 1.3: Google & Bing Engines

Add the two major engines with more aggressive bot detection.

- Implement Google HTML scraper with ad filtering
- Implement Bing HTML scraper with URL parameter decoding
- Cookie jar support for Google consent pages
- Resilient selectors with fallback patterns
- Unit tests with mock HTML fixtures
- Integration tests (marked `#[ignore]`)

### Phase 1.4: Search Orchestrator

Concurrent multi-engine queries with result ranking and deduplication.

- Fan out queries to all enabled engines concurrently (tokio::join!)
- Result deduplication by URL normalization
- Weighted scoring: configurable weight per engine
- Cross-engine boost: URLs appearing in multiple engines get score bonus
- Sort by aggregated score, truncate to max_results
- Graceful degradation: if some engines fail, return results from others
- Only error if ALL engines fail
- Unit tests for ranking, dedup, and fallback logic

### Phase 1.5: Cache, UA Rotation & Request Jitter

Production hardening for the search library.

- In-memory LRU cache using moka with configurable TTL (default 600s)
- Cache key: lowercase query + engine set hash
- User-Agent rotation per request from built-in list
- Random request delay jitter between engine queries (100-500ms configurable)
- Safe search parameter forwarding to engines that support it
- Tracing instrumentation (trace-level only, no persistent query logging)

---

## Milestone 2: Fae Integration

Wire fae-search into Fae's tool system and add content extraction.

### Phase 2.1: WebSearchTool & FetchUrlTool

Implement Fae's `Tool` trait for both tools.

- `WebSearchTool` implementing `Tool` trait (name, description, schema, execute, allowed_in_mode)
- `FetchUrlTool` implementing `Tool` trait
- JSON schema definitions matching the brief's tool specs
- Tool mode gating (always allowed in ReadOnly+ modes)
- Result formatting for LLM consumption (clean, structured output)
- Unit tests for schema validation and execution

### Phase 2.2: Registry Wiring & Feature Flag

Integrate into Fae's build and tool registration.

- Add `web-search` feature flag to root Cargo.toml
- Add fae-search as path dependency (optional, behind feature flag)
- Register WebSearchTool + FetchUrlTool in `build_tool_registry()` (agent/mod.rs)
- Enable by default in `AgentToolMode::ReadOnly` and above
- Verify tool schemas appear in LLM API payloads
- Integration test: full agent loop with web search tool available

### Phase 2.3: Content Extraction (fetch_page_content)

Fetch URLs and extract readable text content.

- HTTP fetch with reqwest (follow redirects, respect timeouts)
- HTML parsing with scraper crate
- Content extraction: strip nav, ads, footer, scripts, styles
- Extract main article/content body
- Return clean text with title and word count
- Truncation for very large pages (configurable max chars)
- Unit tests with sample HTML pages

### Phase 2.4: Circuit Breaker & Adaptive Engine Selection

Reliability under real-world conditions.

- Track per-engine success/failure counts
- Circuit breaker: disable engine after N consecutive failures
- Half-open state: retry disabled engine after cooldown period
- Exponential backoff on repeated failures
- Health status reporting (which engines are currently active)
- Unit tests for circuit breaker state transitions

---

## Milestone 3: Production Hardening

Comprehensive testing, documentation, and additional engines.

### Phase 3.1: Test Suite with Mock Fixtures

Comprehensive offline-testable suite.

- HTML fixture files per engine (saved from real responses)
- Parser tests against fixtures (detect selector breakage)
- Fallback tests: simulate engine failures, verify graceful degradation
- Cache tests: hit/miss, TTL expiry, capacity eviction
- Request delay tests: verify jitter is applied
- Error path tests: timeout, parse error, HTTP error
- All tests must pass in CI without network access

### Phase 3.2: Integration Tests

Live validation (manual/periodic, not CI).

- Live search tests per engine (marked `#[ignore]`)
- Cross-engine result quality validation
- Rate limit behavior verification
- End-to-end: agent loop with web search producing useful responses
- Selector breakage detection (alert if engine returns 0 results)

### Phase 3.3: Documentation, Startpage Engine & Safe Search

Final polish for production release.

- Startpage engine (proxied Google fallback)
- Safe search enforcement across all engines
- API documentation on all public items
- Update Fae's README with web search capability
- Update CLAUDE.md with fae-search architecture notes

---

## Quality Standards (Enforced on Every Phase)

```
FORBIDDEN in src/:
  .unwrap()  .expect()  panic!()  todo!()  unimplemented!()

REQUIRED:
  cargo fmt --all -- --check
  cargo clippy --all-features -- -D warnings
  cargo nextest run --all-features
  thiserror for all error types
  Doc comments on all public items
  Tests written BEFORE implementation (TDD)
```

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Crate structure | Separate `fae-search` lib crate | Clean separation, independent testing |
| Primary engine | DuckDuckGo | Most scraper-friendly, privacy-aligned |
| HTTP client | reqwest (already in tree) | No new dependencies for HTTP |
| HTML parsing | scraper crate | CSS selector-based, proven by metasearch2 |
| Cache | moka (in-memory) | TTL support, async-friendly, no external deps |
| Error handling | thiserror | Matches Fae's existing pattern |
| Async runtime | tokio (already in tree) | No new runtime dependency |
| Source licensing | CC0 (metasearch2) for code, clean-room for Websurfx ideas | Legal clarity |
