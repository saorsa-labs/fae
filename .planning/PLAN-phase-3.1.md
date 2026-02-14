# Phase 3.1: Test Suite with Mock Fixtures

Comprehensive offline-testable suite with realistic HTML fixtures,
parser resilience tests, cache behaviour, and error path coverage.

## Prerequisites (Done in Phases 1.1-2.4)

- Four engine parsers: `parse_duckduckgo_html`, `parse_brave_html`, `parse_google_html`, `parse_bing_html`
- Cache module with `CacheKey`, `get`, `insert`
- Orchestrator pipeline: fan-out, score, dedup, boost, sort, truncate
- Circuit breaker: `CircuitBreaker`, `global_breaker()`
- Content extraction: `extract_content`, `extract_content_with_limit`
- Existing inline mock HTML tests per engine (simple/minimal HTML)
- Integration test: `tests/orchestrator_integration.rs`

## Tasks

---

## Task 1: Create realistic HTML fixture files for all 4 engines

Create `fae-search/test-data/` directory with realistic HTML fixtures that
closely resemble actual search engine result pages. These should include
typical page structure, ads, navigation, footers, and multiple result entries.

**Files:**
- Create: `fae-search/test-data/duckduckgo.html` (~15-20 results, DDG redirect URLs)
- Create: `fae-search/test-data/brave.html` (~10-15 results, standalone snippets to exclude)
- Create: `fae-search/test-data/google.html` (~10-15 results, redirect URLs, ad divs)
- Create: `fae-search/test-data/bing.html` (~10-15 results, b_algo containers)

**Acceptance criteria:**
- Each fixture has realistic HTML structure matching the engine's actual output
- Contains 10+ organic result entries per fixture
- Includes non-result elements (ads, nav, footer, featured snippets)
- DuckDuckGo: uses `//duckduckgo.com/l/?uddg=...` redirect wrapper
- Brave: includes `standalone` snippets that should be filtered
- Google: includes `/url?q=...` redirect wrapper and ad divs
- Bing: uses `li.b_algo` and `b_caption` structure
- All fixture HTML is valid and parseable by scraper

---

## Task 2: Add fixture-based parser tests and make parse functions pub(crate)

Make the parse functions accessible within the crate and add tests that
load the realistic fixtures to detect selector breakage.

**Files:**
- Modify: `fae-search/src/engines/duckduckgo.rs` (make `parse_duckduckgo_html` pub(crate))
- Modify: `fae-search/src/engines/brave.rs` (make `parse_brave_html` pub(crate))
- Modify: `fae-search/src/engines/google.rs` (make `parse_google_html` pub(crate))
- Modify: `fae-search/src/engines/bing.rs` (make `parse_bing_html` pub(crate))
- Modify: `fae-search/src/engines/mod.rs` (re-export parse functions for crate-internal use)
- Create: `fae-search/tests/parser_fixtures.rs` (fixture-based parser tests)

**Acceptance criteria:**
- All 4 parse functions are `pub(crate)` (still not public API)
- Fixture tests extract 10+ results from each realistic fixture
- Tests verify title, URL, snippet are non-empty for each result
- DuckDuckGo test verifies redirect URL unwrapping
- Brave test verifies standalone snippets are excluded
- Google test verifies redirect URL unwrapping
- Tests verify `max_results` truncation works with fixtures
- Tests verify empty/malformed HTML returns empty vec (not error)

---

## Task 3: Add comprehensive cache tests

Add cache behaviour tests covering key edge cases.

**Files:**
- Modify: `fae-search/src/cache.rs` (add more test cases)

**Acceptance criteria:**
- Test cache insert + retrieve returns same data
- Test cache miss returns None
- Test cache key normalisation (case, whitespace, engine order)
- Test different engine sets produce different keys
- Test multiple queries cached independently
- Test overwrite of same key updates value
- All tests pass without network access

---

## Task 4: Add orchestrator select_engines + circuit breaker integration tests

Test the engine selection logic with various circuit breaker states.

**Files:**
- Modify: `fae-search/src/orchestrator/search.rs` (add unit tests for `select_engines`)
- Modify: `fae-search/src/circuit_breaker.rs` (add edge case tests)

**Acceptance criteria:**
- Test `select_engines` returns all engines when all healthy
- Test `select_engines` filters out Open (tripped) engines
- Test `select_engines` allows HalfOpen engines through
- Test fallback: when all engines tripped, returns full list
- Test circuit breaker with rapid success/failure alternation
- Test circuit breaker with threshold=1 edge case
- Test multiple engines with mixed states
- All tests pass without network access

---

## Task 5: Add error path and content extraction edge case tests

Cover error scenarios across the crate: parse errors, config edge cases,
and content extraction with unusual HTML.

**Files:**
- Modify: `fae-search/src/content.rs` (add edge case tests)
- Modify: `fae-search/src/config.rs` (add edge case tests)
- Create: `fae-search/test-data/content_complex.html` (complex page for extraction tests)

**Acceptance criteria:**
- Content extraction: test with deeply nested HTML
- Content extraction: test with huge text (truncation at limit)
- Content extraction: test with no title tag
- Content extraction: test with multiple article elements
- Content extraction: test with only scripts/styles (minimal extraction)
- Config: test boundary values (max u64 timeout, single engine)
- All tests pass without network access
