# Phase 1.5: Cache, UA Rotation & Request Jitter

Production hardening for the search library. UA rotation and safe search are already implemented; this phase adds caching and request jitter.

## Task 1: Add moka dependency + cache module scaffold (TDD)

Add the `moka` crate for async-friendly LRU caching. Create the cache module with types and tests.

**Cache design:**
- Key: `CacheKey` = lowercase query + sorted engine set hash
- Value: `Vec<SearchResult>` (the final deduplicated, scored, sorted results)
- TTL: `config.cache_ttl_seconds` (default 600s)
- Max capacity: 100 entries (hardcoded, reasonable for in-memory)

**Files:**
- Create: `fae-search/src/cache.rs`
- Modify: `fae-search/src/lib.rs` (add `mod cache`)
- Modify: `fae-search/Cargo.toml` (add moka dependency)

**Acceptance criteria:**
- Tests: cache key generation deterministic for same inputs
- Tests: cache key differs when query differs
- Tests: cache key differs when engine set differs
- Tests: cache insert and retrieve works
- Tests: cache miss returns None

---

## Task 2: Integrate cache into search function

Wire the cache into the `search()` function in lib.rs.

**Behavior:**
- Before calling orchestrator, check cache for existing results
- If cache hit, return cached results immediately (log at trace level)
- If cache miss, run orchestrator, cache results, return
- If `cache_ttl_seconds` is 0, skip caching entirely
- Cache is process-global (lazy static or once_cell)

**Files:**
- Modify: `fae-search/src/lib.rs`
- Modify: `fae-search/src/cache.rs`

**Acceptance criteria:**
- Tests: second identical search returns cached results
- Tests: cache disabled (ttl=0) always runs orchestrator
- Tests: different queries get different cache entries
- Tracing: cache hits logged at trace level

---

## Task 3: Request jitter between engine queries

Add configurable random delay between engine queries in the orchestrator to avoid rate limiting.

**Behavior:**
- Between each engine query, sleep for a random duration in `config.request_delay_ms` range
- Use `tokio::time::sleep` with `rand::thread_rng().gen_range(min..=max)`
- If min == max == 0, skip the delay entirely
- Log jitter at trace level

**Files:**
- Modify: `fae-search/src/orchestrator/search.rs`

**Acceptance criteria:**
- When delay is (0,0), no sleep occurs
- When delay is configured, queries are staggered (not all simultaneous)
- Tracing logs the delay duration at trace level

---

## Task 4: Add tracing spans for full pipeline visibility

Add structured tracing spans around the search pipeline.

**Spans:**
- `search` span on the top-level `search()` function
- `orchestrate` span around the orchestrator
- `cache_check` span for cache lookup
- Per-engine spans already exist from prior phases

**Files:**
- Modify: `fae-search/src/lib.rs`
- Modify: `fae-search/src/orchestrator/search.rs`
- Modify: `fae-search/src/cache.rs`

**Acceptance criteria:**
- Span hierarchy visible in tracing output
- No query text logged above trace level
- Zero clippy warnings

---

## Task 5: Final validation and documentation

Ensure all public APIs are documented, all tests pass, and the crate is production-ready.

**Files:**
- Verify: all public items have doc comments
- Verify: `cargo doc --all-features --no-deps` passes with zero warnings
- Verify: `cargo clippy --all-features --all-targets -- -D warnings` clean
- Verify: all tests pass

**Acceptance criteria:**
- `cargo doc` zero warnings
- All public types/functions documented
- README or crate-level docs updated if needed
- All tests pass
