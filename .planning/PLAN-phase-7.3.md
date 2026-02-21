# Phase 7.3: Embedding Engine — Task Plan

**Goal:** Add an `EmbeddingEngine` using `ort` + `all-MiniLM-L6-v2` for 384-dim sentence
embeddings, store vectors in sqlite-vec virtual table, batch embed existing records.

**Entry condition:** Phase 7.2 complete — all memory callers use `SqliteMemoryRepository`.
**Exit condition:** `just check` green; embedding engine loads ONNX model, embeds text,
stores/retrieves vectors via sqlite-vec; all records have embeddings after batch migration.

**Key findings from research:**
- `ort` 2.0.0-rc.11, `hf-hub` 0.4, `sqlite-vec` 0.1, `tokenizers` 0.22 already in Cargo.toml
- sqlite-vec crate exists but is NOT loaded — no `sqlite_vec::load()` call anywhere
- Schema has commented-out `vec_embeddings` table placeholder (schema.rs:57-62)
- `CURRENT_SCHEMA_VERSION` is 2 — needs bump to 3
- Kokoro TTS pattern: `Session::builder().commit_from_file()` → `Tensor::from_array()` → `session.run()`
- Model download via `hf_hub::api::sync::Api::new()` → `repo.get("file")` (same as Kokoro)
- Tokenizer via `tokenizers::Tokenizer::from_file()` (tokenizer.json from HF repo)
- No `fastembed` — use raw ort + tokenizers directly
- `MemoryRecord` has no embedding field — vectors live in separate `vec_embeddings` table
- Linker anchor needs `black_box` reference for new embedding module

---

## Task 1: Load sqlite-vec extension and create vec_embeddings table

**Why:** The sqlite-vec crate is a dependency but never loaded. The vector table must exist
before any embeddings can be stored or queried.

**Files (modify):**
- `src/memory/sqlite.rs` (load extension in constructor, add vector methods)
- `src/memory/schema.rs` (uncomment vec_embeddings DDL, bump schema version)
- `src/memory/types.rs` (bump `CURRENT_SCHEMA_VERSION` to 3)

**Work:**
1. In `SqliteMemoryRepository::new()`, call `sqlite_vec::load(&conn)?` after opening the connection,
   before `apply_schema()`. This enables the `vec0` virtual table module.
2. In `schema.rs`, uncomment the `CREATE VIRTUAL TABLE IF NOT EXISTS vec_embeddings` DDL:
   ```sql
   CREATE VIRTUAL TABLE IF NOT EXISTS vec_embeddings USING vec0(
       record_id TEXT PRIMARY KEY,
       embedding FLOAT[384]
   );
   ```
3. Bump `CURRENT_SCHEMA_VERSION` from 2 to 3.
4. In `migrate_if_needed()`, add migration logic for version 2→3 that creates the vec table.
5. Add methods to `SqliteMemoryRepository`:
   - `pub fn store_embedding(&self, record_id: &str, embedding: &[f32]) -> Result<(), SqliteMemoryError>`
   - `pub fn get_embedding(&self, record_id: &str) -> Result<Option<Vec<f32>>, SqliteMemoryError>`
   - `pub fn search_by_vector(&self, query_vec: &[f32], limit: usize) -> Result<Vec<(String, f64)>, SqliteMemoryError>`
     Returns `(record_id, distance)` pairs, ordered by nearest.
   - `pub fn has_embedding(&self, record_id: &str) -> Result<bool, SqliteMemoryError>`
   - `pub fn count_embeddings(&self) -> Result<usize, SqliteMemoryError>`
6. Write tests:
   - `vec_extension_loads` — verify `select vec_version()` works
   - `store_and_retrieve_embedding` — insert 384-dim vector, get it back
   - `search_by_vector_returns_nearest` — insert 3 vectors, query, verify ordering
   - `has_embedding_true_false` — check presence
   - `count_embeddings_matches` — verify count

**Acceptance criteria:**
- sqlite-vec extension loaded on every connection open
- vec_embeddings virtual table created automatically
- Vector CRUD methods work (store, get, search, has, count)
- Schema version is 3
- All existing tests still pass

---

## Task 2: Create EmbeddingEngine with model download and inference

**Why:** The core embedding pipeline: download model, tokenize text, run ONNX inference,
return 384-dim f32 vector.

**Files (create):**
- `src/memory/embedding.rs`

**Files (modify):**
- `src/memory/mod.rs` (add `pub mod embedding;`)
- `src/linker_anchor.rs` (add black_box reference)

**Work:**
1. Create `src/memory/embedding.rs` with:
   ```rust
   pub struct EmbeddingEngine {
       session: ort::session::Session,
       tokenizer: tokenizers::Tokenizer,
   }
   ```
2. `EmbeddingEngine::new(model_dir: &Path) -> Result<Self, SpeechError>`:
   - Load ONNX model via `Session::builder().with_intra_threads(2).commit_from_file(model_path)`
   - Load tokenizer via `Tokenizer::from_file(tokenizer_path)`
   - Set truncation to max 256 tokens (model limit)
3. `pub fn embed(&self, text: &str) -> Result<Vec<f32>, SpeechError>`:
   - Tokenize text → `input_ids`, `attention_mask`, `token_type_ids`
   - Create tensors, run session
   - Mean-pool the token embeddings (mask-aware)
   - L2-normalize the result
   - Return 384-dim f32 vector
4. `pub fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, SpeechError>`:
   - Same but for multiple texts at once (pad to max length in batch)
5. `pub fn download_model(cache_dir: &Path) -> Result<PathBuf, SpeechError>`:
   - Use `hf_hub::api::sync::Api::new()` → `repo.get()` for:
     - `onnx/model.onnx` (or `model_quantized.onnx` if available)
     - `tokenizer.json`
   - Return path to the model directory
6. `pub const EMBEDDING_DIM: usize = 384;`
7. Add `black_box` reference in `linker_anchor.rs`
8. Tests:
   - `embedding_dim_constant` — assert EMBEDDING_DIM == 384
   - `download_and_load` — integration test that downloads model and creates engine (may be slow, mark with `#[ignore]` for CI)
   - `embed_produces_correct_dimensions` — verify output is 384-dim
   - `embed_is_normalized` — verify L2 norm ≈ 1.0
   - `similar_texts_have_high_similarity` — "hello world" vs "hi world" should have cos-sim > 0.8
   - `different_texts_have_low_similarity` — "hello world" vs "quantum physics" should have cos-sim < 0.5

**Acceptance criteria:**
- `EmbeddingEngine::new()` loads model and tokenizer
- `embed()` returns 384-dim normalized f32 vector
- Similar texts produce similar vectors (sanity check)
- Model downloads from HuggingFace on first use
- `cargo check` zero warnings

---

## Task 3: Integrate embedding into SqliteMemoryRepository insert path

**Why:** New records should be embedded automatically on insert when the engine is available.

**Files (modify):**
- `src/memory/sqlite.rs` (add optional embedding engine)
- `src/memory/jsonl.rs` (pass engine through orchestrator)

**Work:**
1. Add `embedding_engine: Option<Arc<EmbeddingEngine>>` field to `SqliteMemoryRepository`.
2. Add `pub fn set_embedding_engine(&self, engine: Arc<EmbeddingEngine>)` method
   (or make it a constructor parameter).
   Actually, since `SqliteMemoryRepository` wraps `Mutex<Connection>`, adding
   a field means either a second mutex or restructuring. Simpler approach:
   accept engine as parameter to `insert_record`:
   - `pub fn insert_record_with_embedding(&self, ..., engine: Option<&EmbeddingEngine>) -> Result<...>`
   - OR: embed externally and call `store_embedding` separately.
   Best approach: keep `insert_record` unchanged, call `store_embedding` after insert.
   The `MemoryOrchestrator` orchestrates: insert → embed → store_embedding.
3. Update `MemoryOrchestrator` to hold `Option<Arc<EmbeddingEngine>>`:
   - In `capture_memory_turn`, after inserting the record, embed and store the vector.
   - If embedding fails, log warning but don't fail the insert.
4. Tests:
   - `insert_then_embed_stores_vector` — insert record, embed text, store embedding, verify retrieval
   - `orchestrator_embeds_on_capture` — verify embedding stored after capture (requires engine)
   - `orchestrator_works_without_engine` — verify capture works when engine is None

**Acceptance criteria:**
- New records get embedded automatically when engine available
- Missing engine degrades gracefully (no embedding, no error)
- All existing tests still pass (they don't have an engine)

---

## Task 4: Batch embed existing records and migration

**Why:** Existing records in SQLite have no embeddings. They need batch embedding for
semantic search to work on historical data.

**Files (modify):**
- `src/memory/embedding.rs` (add batch embed helper)
- `src/memory/sqlite.rs` (add batch embed method)
- `src/memory/jsonl.rs` (add batch embed scheduler task)

**Work:**
1. Add `pub fn batch_embed_missing(&self, engine: &EmbeddingEngine) -> Result<usize, SqliteMemoryError>`
   to `SqliteMemoryRepository`:
   - Query all active records that don't have an embedding in `vec_embeddings`
   - Batch embed their text (in chunks of ~32 for efficiency)
   - Store each embedding
   - Return count of newly embedded records
2. Add a scheduler-compatible function `run_memory_embed(root_dir, engine)`:
   - Called during startup or as a background task
   - Embeds all records missing embeddings
   - Logs progress
3. Wire into `MemoryOrchestrator::ensure_ready_with_migration()`:
   - After migration completes, if embedding engine is available, run batch embed
4. Tests:
   - `batch_embed_missing_embeds_all` — insert 5 records, batch embed, verify all have vectors
   - `batch_embed_skips_already_embedded` — insert 3, embed 1 manually, batch embed, verify only 2 new

**Acceptance criteria:**
- All existing records get embeddings during batch embed
- Already-embedded records are skipped (idempotent)
- Progress is logged
- All tests pass

---

## Task 5: Integration test and final validation

**Why:** End-to-end verification of the full embedding pipeline.

**Work:**
1. Run `cargo fmt --all -- --check` — fix any drift
2. Run `cargo clippy --all-features -- -D warnings` — fix all warnings
3. Run `cargo test --lib` — all tests pass
4. Verify embedding engine download and basic inference works
5. Verify sqlite-vec virtual table is created on new databases
6. Verify schema migration 2→3 works
7. No `.unwrap()` or `.expect()` outside `#[cfg(test)]`

**Acceptance criteria:**
- `just check` exits 0
- All memory + embedding tests pass
- Embedding engine produces correct 384-dim vectors
- sqlite-vec stores and retrieves vectors correctly

---

## Summary

| # | Task | Key Files | Est. Lines |
|---|------|-----------|-----------|
| 1 | sqlite-vec extension + vec_embeddings table | `sqlite.rs`, `schema.rs`, `types.rs` | ~150 |
| 2 | EmbeddingEngine (download, tokenize, infer) | new `embedding.rs`, `linker_anchor.rs` | ~300 |
| 3 | Integrate embedding into insert path | `sqlite.rs`, `jsonl.rs` | ~80 |
| 4 | Batch embed existing records | `embedding.rs`, `sqlite.rs`, `jsonl.rs` | ~120 |
| 5 | Integration test + validation | various | ~20 |

**Out of scope for Phase 7.3:**
- Hybrid retrieval scoring (Phase 7.4)
- Replacing `score_record()` / `search()` (Phase 7.4)
- Backup and recovery for vec table (Phase 7.5)
