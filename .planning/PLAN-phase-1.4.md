# Phase 1.4: Search Orchestrator

Concurrent multi-engine queries with result ranking, deduplication, and graceful degradation.

## Task 1: URL normalization utility + tests (TDD)

Create `src/orchestrator/url_normalize.rs` with a `normalize_url` function that canonicalizes URLs for deduplication.

**Normalization rules:**
- Lowercase scheme and host
- Remove trailing slashes
- Remove default ports (80, 443)
- Sort query parameters alphabetically
- Remove tracking parameters (utm_*, fbclid, gclid, ref, etc.)
- Remove fragment (#)
- Decode percent-encoded unreserved characters

**Files:**
- Create: `fae-search/src/orchestrator/mod.rs`
- Create: `fae-search/src/orchestrator/url_normalize.rs`
- Modify: `fae-search/src/lib.rs` (add `mod orchestrator`)

**Acceptance criteria:**
- Unit tests cover all normalization rules
- URLs like `https://Example.COM/path/` and `https://example.com/path` normalize to same string
- Tracking params stripped
- Invalid URLs passed through unchanged

---

## Task 2: Result deduplication logic + tests (TDD)

Create `src/orchestrator/dedup.rs` that deduplicates search results by normalized URL.

**Behavior:**
- Group results by normalized URL
- When duplicates found, keep highest-scored result
- Track which engines contributed each URL (for cross-engine boost in Task 4)
- Return `DeduplicatedResult` struct containing the best result + list of contributing engines

**Files:**
- Create: `fae-search/src/orchestrator/dedup.rs`

**Acceptance criteria:**
- Tests: duplicate URLs from different engines merged correctly
- Tests: highest-scored result kept
- Tests: engine source list tracks all contributing engines
- Tests: unique URLs pass through unchanged

---

## Task 3: Weighted scoring + tests (TDD)

Create `src/orchestrator/scoring.rs` with position-decay weighted scoring.

**Scoring formula:**
- `score = engine_weight * position_decay`
- `position_decay = 1.0 / (1.0 + position_index * 0.1)` (result at index 0 gets 1.0, index 9 gets ~0.5)
- Engine weights come from `SearchEngine::weight()` (Google=1.2, DDG=1.0, Brave=1.0, Bing=0.8, Startpage=0.9)

**Files:**
- Create: `fae-search/src/orchestrator/scoring.rs`

**Acceptance criteria:**
- Tests: Google result at position 0 scores higher than Bing result at position 0
- Tests: Position 0 scores higher than position 5 for same engine
- Tests: scoring function is deterministic
- Tests: edge cases (empty results, single result)

---

## Task 4: Cross-engine boost + tests (TDD)

Add cross-engine boost to scoring: URLs appearing in multiple engines get a score bonus.

**Boost formula:**
- `boosted_score = base_score * (1.0 + 0.2 * (engine_count - 1))`
- URL in 1 engine: no boost (1.0x)
- URL in 2 engines: 1.2x
- URL in 3 engines: 1.4x
- URL in 4 engines: 1.6x

Integrate with dedup from Task 2 — dedup identifies multi-engine URLs, boost applies the multiplier.

**Files:**
- Modify: `fae-search/src/orchestrator/scoring.rs`
- Modify: `fae-search/src/orchestrator/dedup.rs` (if needed for engine tracking)

**Acceptance criteria:**
- Tests: URL in 2 engines scores higher than same URL in 1 engine
- Tests: boost multiplier is correct for 1-4 engines
- Tests: boost integrates with position-decay scoring

---

## Task 5: Concurrent multi-engine fan-out orchestrator

Create `src/orchestrator/search.rs` — the core orchestrator that fans out queries to all engines concurrently.

**Behavior:**
1. Create engine instances for each `SearchEngine` in config
2. Fan out with `tokio::join!` / `futures::future::join_all`
3. Collect results, logging per-engine errors at warn level
4. Apply scoring (Task 3) to each engine's results
5. Merge all results, deduplicate (Task 2), apply cross-engine boost (Task 4)
6. Sort by final score descending
7. Truncate to `config.max_results`
8. Return final results

**Files:**
- Create: `fae-search/src/orchestrator/search.rs`
- Modify: `fae-search/src/orchestrator/mod.rs` (re-export orchestrate function)

**Acceptance criteria:**
- Function signature: `pub async fn orchestrate_search(query: &str, config: &SearchConfig) -> Result<Vec<SearchResult>>`
- Uses `tokio::join!` or `join_all` for concurrent execution
- Logs individual engine failures at warn level
- Results sorted by score descending
- Truncated to max_results

---

## Task 6: Graceful degradation + tests

Add error handling: partial failures return partial results, only error if ALL engines fail.

**Behavior:**
- If 3/4 engines fail but 1 returns results → return those results (success)
- If all engines fail → return `SearchError::AllEnginesFailed` with summary of failures
- Per-engine errors collected and included in the AllEnginesFailed message
- Empty result sets from engines treated as success (not failure)

**Files:**
- Modify: `fae-search/src/orchestrator/search.rs`
- Add tests to orchestrator module

**Acceptance criteria:**
- Tests: mock 3 failing + 1 succeeding engine → returns results
- Tests: mock all 4 engines failing → returns AllEnginesFailed error
- Tests: all engines return empty → returns empty vec (not error)
- Tests: error message includes per-engine failure reasons

---

## Task 7: Wire orchestrator into public API

Replace the stubs in `lib.rs` (`search` and `search_default`) with calls to the orchestrator.

**Changes:**
- `search()` calls `orchestrator::orchestrate_search()`
- `search_default()` already delegates to `search()` — no change needed
- Update lib.rs stub tests to expect success with mock (or remove stub tests)
- `fetch_page_content` remains a stub (Phase 2.3)

**Files:**
- Modify: `fae-search/src/lib.rs`

**Acceptance criteria:**
- `search()` no longer returns "not yet implemented" error
- `search()` validates config, then calls orchestrator
- `search_default()` works via `search()` delegation
- `fetch_page_content()` remains a stub (not in scope)
- Existing tests updated to reflect new behavior

---

## Task 8: Orchestrator integration tests

End-to-end tests using mock engines to verify the full pipeline.

**Test scenarios:**
- Full pipeline: 4 mock engines → dedup → score → boost → sorted results
- Single engine mode: only 1 engine configured → results returned
- Score ordering: verify final results are sorted by score descending
- Max results: verify truncation works
- Cross-engine URL: same URL from multiple engines → boosted and deduplicated
- Config validation: invalid config rejected before orchestration

**Files:**
- Create or extend tests in `fae-search/src/orchestrator/` modules
- Add integration test file if needed: `fae-search/tests/orchestrator_integration.rs`

**Acceptance criteria:**
- All scenarios pass
- No network calls (all mock-based)
- Tests run in CI without special setup
- Zero warnings from cargo clippy
