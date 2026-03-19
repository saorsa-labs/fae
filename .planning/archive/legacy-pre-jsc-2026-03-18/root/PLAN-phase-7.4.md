# Phase 7.4: Hybrid Retrieval

## Goal
Replace lexical-only `score_record()` retrieval with hybrid semantic + structural scoring. Dramatically improve recall quality by combining sqlite-vec KNN vector search with existing lexical/structural signals.

## Architecture

```
Query text
    ├──▶ EmbeddingEngine::embed(query) → 384-dim vector
    │         └──▶ SqliteMemoryRepository::search_by_vector(vec, k*limit) → Vec<(record_id, distance)>
    │
    └──▶ tokenize(query) → query_tokens
              └──▶ score_record(record, query_tokens) → lexical+structural score

    Fusion: merge both result sets by record_id, compute hybrid_score, sort, truncate to limit
```

## Scoring Formula (per ROADMAP)

```
hybrid_score = semantic_weight * semantic_sim     (0.6)
             + confidence_weight * confidence     (0.2)
             + freshness_weight * freshness       (0.1)
             + kind_bonus                         (0.1 max)

Where:
  semantic_sim = 1.0 - (distance / 2.0)   [sqlite-vec returns L2 distance on L2-normalized vecs → max 2.0]
  confidence   = record.confidence clamped [0.0, 1.0]
  freshness    = 1.0 / (1.0 + age_days)
  kind_bonus   = Profile: 0.10, Fact/Event/Commitment/Person/Interest: 0.06, Episode: 0.0
```

Fallback: When embedding engine unavailable, fall back to existing lexical `score_record()`.

---

## Tasks

### Task 1: Add `hybrid_search()` to `SqliteMemoryRepository`

**Files:** `src/memory/sqlite.rs`, `src/memory/types.rs`

**What:**
- Add `hybrid_score()` function in `types.rs` — takes semantic distance, confidence, freshness, kind → hybrid score
- Add `SqliteMemoryRepository::hybrid_search(&self, query_vec: &[f32], query: &str, limit: usize) -> Result<Vec<MemorySearchHit>>`
  - Calls `search_by_vector(query_vec, limit * 3)` to get candidate record IDs with distances
  - Loads those records from `memory_records` table by ID
  - Computes `hybrid_score()` for each
  - Also runs lexical `score_record()` on those same records as a secondary signal
  - Returns sorted, truncated to `limit`
- Add constants for hybrid weights in `types.rs`
- Tests: unit tests for `hybrid_score()`, integration test for `hybrid_search()`

**Exit:** `hybrid_search()` returns scored results combining semantic + structural signals. All tests pass.

---

### Task 2: Wire hybrid retrieval into `recall_context()`

**Files:** `src/memory/jsonl.rs`

**What:**
- Modify `MemoryOrchestrator::recall_context()` to:
  1. If embedding engine available: embed query, call `self.repo.hybrid_search(vec, query, limit)`
  2. If embedding engine unavailable: fall back to existing `self.repo.search(query, limit, false)`
- The rest of `recall_context()` stays the same (durable/episode filtering, formatting)
- Update `min_profile_confidence` filtering to work with hybrid scores (thresholds may need adjustment since score distribution changes)

**Exit:** `recall_context()` uses hybrid search when embeddings available, lexical fallback otherwise. Tests pass.

---

### Task 3: Add `search_by_vector` active-only filtering + integration tests

**Files:** `src/memory/sqlite.rs`

**What:**
- `search_by_vector()` currently returns ALL embedded records including inactive ones. Add active-only filtering by joining with `memory_records WHERE status = 'active'`
- OR: filter in `hybrid_search()` after loading records (simpler, already loads them)
- Add integration tests that verify:
  - Hybrid search returns better results than lexical for synonym queries
  - Inactive records excluded from hybrid results
  - Fallback to lexical when no embeddings exist
  - Empty query behavior

**Exit:** Hybrid search correctly filters inactive records. Integration tests demonstrate improved recall. All tests pass.

---

### Task 4: Update scoring constants and add config fields

**Files:** `src/memory/types.rs`, `src/config.rs`

**What:**
- Rename/replace old `SCORE_*` constants with `HYBRID_*` constants
- Keep old constants for lexical fallback path
- Add to `MemoryConfig`:
  - `semantic_weight: f32` (default 0.6) — weight of semantic similarity in hybrid score
  - `use_hybrid_search: bool` (default true) — master switch for hybrid vs lexical-only
- Wire config into `recall_context()` and `hybrid_search()`

**Exit:** Config-driven hybrid weights. Lexical fallback still works when `use_hybrid_search = false`. Tests pass, zero warnings.
