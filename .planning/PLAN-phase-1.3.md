# Phase 1.3: Google & Bing Engines + HTTP Hardening

## Goal

Implement Google and Bing search engine scrapers following the established pattern from Phase 1.2. Also address Codex review findings: add error_for_status() to all engines, wire safe_search config, and fix log levels.

## Tasks

### Task 1: Add error_for_status() and fix log levels across all engines

Address Codex review findings from Phase 1.2:

**Files:** `fae-search/src/engines/duckduckgo.rs`, `fae-search/src/engines/brave.rs`

**Changes:**
- After `.send().await`, add `.error_for_status()` mapping to SearchError::Http for 4xx/5xx responses
- Change `tracing::debug!(query, ...)` to `tracing::trace!(query, ...)` in both engines
- Add safe_search parameter: DDG `kp=-1` (off) or `kp=1` (on), Brave `safesearch=off`/`strict`
- Add tests for error_for_status behavior (mock not needed — just verify the code compiles and existing tests pass)

### Task 2: Implement Google HTML scraper

**Files:** `fae-search/src/engines/google.rs`

**Changes:**
- Implement `GoogleEngine::search()` using GET to `https://www.google.com/search?q=...`
- CSS selectors: `div.g` for result containers, `h3` for title, `a[href]` for URL, `.VwiC3b` or `div[data-sncf]` for snippet
- Filter out ads (`div.commercial-unit-*`, `div[data-text-ad]`)
- Handle Google's redirect URLs: `/url?q=...&sa=...` — extract `q` parameter
- Add `Accept-Language: en-US,en;q=0.9` header
- error_for_status() after send
- safe_search: `safe=active` (on) or omit (off)
- Log query at trace level
- Add `parse_google_html()` function for testability
- Add mock HTML fixture with realistic Google result HTML
- Tests: parse mock HTML, max_results, empty HTML, ad filtering, URL extraction
- Integration test with `#[ignore]`

### Task 3: Implement Bing HTML scraper

**Files:** `fae-search/src/engines/bing.rs`

**Changes:**
- Implement `BingEngine::search()` using GET to `https://www.bing.com/search?q=...`
- CSS selectors: `li.b_algo` for result containers, `h2 > a` for title+URL, `.b_caption p` for snippet
- Handle Bing's URL encoding (sometimes includes tracking redirect params)
- Add `Accept-Language: en-US,en;q=0.9` header
- error_for_status() after send
- safe_search: `safeSearch=Strict` (on) or `safeSearch=Off` (off)
- Log query at trace level
- Add `parse_bing_html()` function for testability
- Add mock HTML fixture with realistic Bing result HTML
- Tests: parse mock HTML, max_results, empty HTML, URL decoding
- Integration test with `#[ignore]`

### Task 4: Verify all engines compile and tests pass

**Files:** All fae-search files

**Changes:**
- Run `cargo check -p fae-search --all-features`
- Run `cargo clippy -p fae-search --all-features -- -D warnings`
- Run `cargo test -p fae-search --all-features`
- Run `cargo fmt -p fae-search -- --check`
- Ensure zero warnings, zero errors, all tests pass
