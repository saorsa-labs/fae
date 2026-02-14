# Phase 3.2: Integration Tests

## Overview

Add comprehensive live integration tests for fae-search. All tests are `#[ignore]` since they
require network access. Run manually with `cargo test -p fae-search -- --ignored`.

We already have basic live tests per engine. This phase adds multi-engine orchestration,
quality validation, and selector breakage detection.

---

## Task 1: Multi-engine live orchestration tests

**File:** `fae-search/tests/orchestrator_integration.rs`

Add `#[ignore]` live tests:
- `live_multi_engine_search` — query with all 4 engines, verify results from multiple engines
- `live_search_dedup_works` — search a common query, verify deduplication reduces total count
- `live_search_respects_max_results` — verify truncation with max_results=3

---

## Task 2: Cross-engine quality and selector breakage detection

**File:** `fae-search/tests/orchestrator_integration.rs`

Add `#[ignore]` tests:
- `live_each_engine_returns_results` — query each engine individually, fail if any returns 0
  (selector breakage detection)
- `live_results_have_valid_urls` — verify all result URLs parse as valid `url::Url`
- `live_results_have_non_empty_snippets` — verify snippet quality

---

## Task 3: Content extraction live test

**File:** `fae-search/tests/orchestrator_integration.rs`

Add `#[ignore]` test:
- `live_fetch_page_content` — fetch a known stable URL (rust-lang.org), verify title extracted,
  word count > 0, content non-empty

---

## Task 4: Cache integration test

**File:** `fae-search/tests/orchestrator_integration.rs`

Add `#[ignore]` test:
- `live_cached_search_returns_same_results` — run same query twice, second should use cache
  (verify results match)

---

## Summary

~10 new integration tests, all `#[ignore]`, covering live orchestration, quality validation,
selector breakage, and content extraction.
