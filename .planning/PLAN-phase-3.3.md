# Phase 3.3: Documentation, Startpage Engine & Safe Search

## Overview

Final phase of Milestone 3. Implement the Startpage engine (proxied Google fallback),
ensure safe search works across all engines, and audit API documentation.

---

## Task 1: Implement Startpage engine

**Files:**
- `fae-search/src/engines/startpage.rs` (new)
- `fae-search/src/engines/mod.rs` (add module + re-export)
- `fae-search/src/orchestrator/search.rs` (wire up Startpage in query_engine)
- `fae-search/test-data/startpage.html` (fixture)

**Description:**
Startpage proxies Google results. Uses GET to `https://www.startpage.com/do/search`.
Parse organic results from `div.w-gl__result` containers.
- Title: `.w-gl__result-title`
- URL: `a` href within title
- Snippet: `.w-gl__description`
Safe search: `qadf=none` (off) or omit for default.

Add fixture-based tests like other engines.

---

## Task 2: Wire Startpage into orchestrator + add tests

**Files:**
- `fae-search/src/orchestrator/search.rs` (replace stub with real impl)

**Description:**
Replace the `SearchEngine::Startpage` stub error with actual `StartpageEngine.search()` call.
Add `#[ignore]` live test for Startpage.

---

## Task 3: Documentation audit

**Files:** All public modules

**Description:**
Verify all public items have doc comments. Run `cargo doc -p fae-search --all-features --no-deps`
and fix any warnings. Check:
- All pub functions, structs, enums, traits, constants
- Module-level docs
- Doc examples compile

---

## Summary

3 tasks: Startpage engine, orchestrator wiring, documentation audit.
