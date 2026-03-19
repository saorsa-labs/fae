# Phase 7.1: SQLite Foundation — Task Plan

**Goal:** Restructure `src/memory.rs` into a `src/memory/` module, add `rusqlite` +
`sqlite-vec` dependencies, and implement `SqliteMemoryRepository` with an identical
public API to the existing `MemoryRepository`. All existing unit tests must pass
against both backends.

**Entry condition:** `just check` is green on `main`.
**Exit condition:** `just check` is green; all memory unit tests pass; `SqliteMemoryRepository`
passes the identical test suite as `MemoryRepository`.

---

## Task 1: Add rusqlite and sqlite-vec to Cargo.toml

**Why:** The SQLite backend cannot be compiled without these crates. Adding them first
lets the rest of the work compile incrementally.

**Files:**
- `Cargo.toml`

**Work:**
1. Add `rusqlite = { version = "0.31", features = ["bundled"] }` to `[dependencies]`.
2. Add `sqlite-vec = "0.1"` to `[dependencies]`.
3. Run `cargo check` to confirm the dependency tree resolves cleanly.
4. Run `just fmt-check` to confirm no formatting changes are needed.

**Acceptance criteria:**
- `cargo check` passes with zero errors and zero warnings.
- `cargo tree | grep rusqlite` shows the bundled variant.
- No existing tests are broken.

---

## Task 2: Create src/memory/ module directory and types.rs

**Why:** The 2,963-line `src/memory.rs` must be split into focused sub-modules before
new files are added. `types.rs` is extracted first because every other sub-module
depends on the shared types.

**Files (create):**
- `src/memory/mod.rs`
- `src/memory/types.rs`

**Files (delete):**
- `src/memory.rs` (contents moved into the new module)

**Work:**
1. Create `src/memory/` directory.
2. Create `src/memory/types.rs` containing all shared type definitions moved verbatim
   from `src/memory.rs`:
   - Constants: `CURRENT_SCHEMA_VERSION`, `MAX_RECORD_TEXT_LEN`, `TRUNCATION_SUFFIX`,
     all `PROFILE_*_CONFIDENCE`, `FACT_*_CONFIDENCE`, `ONBOARDING_*` constants,
     `SCORE_*` weight constants, `SECS_PER_DAY`.
   - Enums: `MemoryKind`, `MemoryStatus`, `MemoryAuditOp`.
   - Structs: `MemoryRecord`, `MemoryAuditEntry`, `MemorySearchHit`,
     `MemoryCaptureReport`, `MemoryWriteSummary`, `MemoryConflictSummary`.
   - Private helpers: `default_memory_status()`, `default_confidence()`,
     `display_kind()`, `now_epoch_secs()`, `now_epoch_nanos()`, `new_id()`,
     `truncate_record_text()`, `tokenize()`, `score_record()`.
3. Create `src/memory/mod.rs` that:
   - Declares `pub mod types;`, `pub mod jsonl;` (Task 3), `pub mod sqlite;` (Task 5),
     `pub mod schema;` (Task 4).
   - Re-exports everything the rest of the codebase currently imports from
     `crate::memory::*`.
4. Delete `src/memory.rs`.
5. Run `cargo check` — must be zero errors, zero warnings.

**Acceptance criteria:**
- `src/memory.rs` no longer exists.
- `src/memory/mod.rs` and `src/memory/types.rs` exist.
- `cargo check` passes with zero warnings.
- All callers (`pipeline/coordinator.rs`, `intelligence/`, `scheduler/tasks.rs`,
  `host/handler.rs`) compile without changes.

---

## Task 3: Move JSONL implementation to src/memory/jsonl.rs

**Why:** The existing JSONL-backed `MemoryRepository` and `MemoryOrchestrator` are moved
verbatim into `jsonl.rs` to make room for the new SQLite backend. No logic changes.

**Files (create):**
- `src/memory/jsonl.rs`

**Files (modify):**
- `src/memory/mod.rs`

**Work:**
1. Create `src/memory/jsonl.rs` containing all remaining code from the old `memory.rs`:
   - `MemoryStore`, `PrimaryUser`, `Person` structs and all their methods.
   - `MemoryManifest` struct (private) and `impl Default`.
   - Static globals: `RECORD_COUNTER`, `MEMORY_WRITE_LOCK`; `memory_write_lock()`.
   - Constants specific to JSONL storage: `MANIFEST_FILE`, `RECORDS_FILE`, `AUDIT_FILE`.
   - `MemoryRepository` struct and its complete `impl`.
   - `MemoryOrchestrator` struct and its complete `impl`.
   - All free functions: `run_memory_reflection`, `run_memory_reindex`, `run_memory_gc`,
     `run_memory_migration`, `default_memory_root_dir`.
   - All parse helpers.
   - The entire `#[cfg(test)] mod tests { ... }` block (unchanged).
2. Add `use super::types::*;` at the top of `jsonl.rs`.
3. In `src/memory/mod.rs`, add pub re-exports from `jsonl`.

**Acceptance criteria:**
- All existing memory tests pass: `cargo test` with zero failures.
- `cargo check` is warning-free.
- No callers need changes.

---

## Task 4: Create src/memory/schema.rs — SQLite DDL

**Why:** Centralising all `CREATE TABLE` statements in one file makes them reviewable,
testable in isolation, and easy to extend in later phases.

**Files (create):**
- `src/memory/schema.rs`

**Files (modify):**
- `src/memory/mod.rs` (add `pub(crate) mod schema;`)

**Work:**
1. Create `src/memory/schema.rs` with:
   - `pub const SCHEMA_SQL: &str` containing all DDL (WAL mode, foreign keys,
     `memory_records`, `memory_audit`, `vec_embeddings` placeholder, `schema_meta`).
   - `pub fn apply_schema(conn: &rusqlite::Connection) -> rusqlite::Result<()>`.
   - Indexes on `status`, `kind`, `updated_at`, and `at`.
2. Add `#[cfg(test)]` block:
   - Opens in-memory connection.
   - Calls `apply_schema` twice (idempotency check).
   - Asserts both return `Ok(())`.

**Acceptance criteria:**
- `cargo test memory::schema` passes.
- `apply_schema` is idempotent.
- No clippy warnings.

---

## Task 5: Implement SqliteMemoryRepository — core CRUD

**Why:** Main deliverable of Phase 7.1. Implements the same public API as
`MemoryRepository` backed by SQLite.

**Files (create):**
- `src/memory/sqlite.rs`

**Files (modify):**
- `src/memory/mod.rs` (add `pub use sqlite::SqliteMemoryRepository;`)

**Work:**
Implement `SqliteMemoryRepository` matching `MemoryRepository` method-for-method:

- `new(root_dir)` — opens/creates `{root_dir}/fae.db`, calls `apply_schema`.
- `root()` — returns the root directory path.
- `ensure_layout()` — idempotent schema application.
- `schema_version()` / `migrate_if_needed(target)` — via `schema_meta` table.
- `list_records()` / `audit_entries()` — SELECT queries.
- `insert_record(kind, text, confidence, source_turn_id, tags)` — INSERT + audit.
- `patch_record(id, new_text, note)` — UPDATE + audit.
- `supersede_record(old_id, new_text, ...)` — transactional UPDATE old + INSERT new + audit.
- `invalidate_record(id, note)` — UPDATE status + audit.
- `forget_soft_record(id, note)` — UPDATE status to Forgotten + audit.
- `forget_hard_record(id, note)` — DELETE + audit.
- `find_active_by_tag(tag)` — SELECT WHERE status='active' with JSON tag matching.
- `search(query, limit, include_inactive)` — list + `score_record()` from types.rs.
- `apply_retention_policy(retention_days)` — UPDATE old episodes to Forgotten.

Implementation notes:
- `Mutex<rusqlite::Connection>` for thread safety.
- `rusqlite::params![]` for all queries — no string interpolation.
- Tags stored as JSON array string.
- Enums stored as snake_case strings.
- Zero `.unwrap()` / `.expect()` in production code.

**Acceptance criteria:**
- `cargo check` passes with zero warnings.
- `cargo clippy -- -D warnings` clean.

---

## Task 6: Write the SqliteMemoryRepository test suite

**Why:** TDD contract tests. Mirrors the existing JSONL test coverage.

**Files (modify):**
- `src/memory/sqlite.rs` (add `#[cfg(test)] mod tests`)

**Work:**
Add test module with these tests:

| Test | Verifies |
|------|----------|
| `sqlite_creates_schema_and_layout` | `new()` + `ensure_layout()` |
| `sqlite_insert_search_and_soft_forget` | Insert, search, forget_soft |
| `sqlite_supersede_marks_old_record` | Supersede old → new |
| `sqlite_patch_updates_text` | Patch text + updated_at |
| `sqlite_invalidate_record` | Invalidate sets status |
| `sqlite_forget_hard_removes_row` | Hard delete removes row |
| `sqlite_find_active_by_tag` | Tag-based lookup |
| `sqlite_retention_policy_soft_forgets_old` | Retention policy on episodes |
| `sqlite_schema_version_starts_at_current` | Schema version correct |
| `sqlite_migrate_if_needed_noop_when_current` | Idempotent migration |
| `sqlite_concurrent_insert_preserves_records` | Thread safety |

Each test uses `tempfile::TempDir`, exercises API, asserts postconditions.

**Acceptance criteria:**
- `cargo test memory::sqlite` passes with zero failures.
- `cargo test` (full suite) still passes.
- `cargo clippy -- -D warnings` clean.

---

## Task 7: Final validation — just check and zero warnings

**Why:** Confirms the full phase is shippable.

**Work:**
1. `just fmt` — fix formatting drift.
2. `just lint` — fix clippy violations.
3. `just test` — all tests pass (JSONL + SQLite + all modules).
4. `just build-strict` — `RUSTFLAGS="-D warnings"` clean.
5. Confirm `src/memory.rs` no longer exists.
6. Confirm module structure: `src/memory/{mod,types,jsonl,schema,sqlite}.rs`.
7. Confirm all public re-exports cover callers' needs.

**Acceptance criteria:**
- `just check` exits 0.
- `cargo test` exits 0 with zero failures.
- No `.unwrap()` or `.expect()` outside `#[cfg(test)]` blocks.
- `SqliteMemoryRepository` is exported from `crate::memory`.
- `MemoryOrchestrator` is unchanged — still wraps JSONL `MemoryRepository`.

---

## Summary

| # | Task | Key Files | Est. Lines |
|---|------|-----------|-----------|
| 1 | Add rusqlite + sqlite-vec deps | `Cargo.toml` | ~5 |
| 2 | Create memory/ module + types.rs | `src/memory/mod.rs`, `types.rs` | ~400 |
| 3 | Move JSONL impl to jsonl.rs | `src/memory/jsonl.rs` | ~2500 (moved) |
| 4 | SQLite schema DDL | `src/memory/schema.rs` | ~60 |
| 5 | SqliteMemoryRepository CRUD | `src/memory/sqlite.rs` | ~500 |
| 6 | SqliteMemoryRepository tests | `src/memory/sqlite.rs` | ~300 |
| 7 | Final validation | — | 0 |

**Out of scope for Phase 7.1:**
- Embedding / vector search (Phase 7.3)
- JSONL → SQLite migration (Phase 7.2)
- Switching MemoryOrchestrator to SqliteMemoryRepository (Phase 7.2)
- Hybrid scoring / KNN retrieval (Phase 7.4)
- Backup rotation / integrity checks (Phase 7.5)
