# Phase 7.2: JSONL → SQLite Migration — Task Plan

**Goal:** One-time JSONL→SQLite data migration at startup, switch all callers from
`MemoryRepository` (JSONL) to `SqliteMemoryRepository`, preserve JSONL backup.

**Entry condition:** Phase 7.1 complete — `SqliteMemoryRepository` exists with full CRUD and 11 passing tests.
**Exit condition:** `just check` green; all memory callers use SQLite; JSONL data migrated on first startup; old JSONL files preserved as backup.

---

## Task 1: Normalize SqliteMemoryRepository API to match caller expectations

**Why:** The existing `MemoryOrchestrator` and callers expect specific signatures from
`MemoryRepository` (JSONL). Before switching, we must align the SQLite API so callers
compile without changes beyond swapping the type.

**Files (modify):**
- `src/memory/sqlite.rs`

**Work:**
1. Change `insert_record` to return `Result<MemoryRecord, SqliteMemoryError>` (full record, not just ID).
   After INSERT, SELECT the row back and return it. This matches the JSONL API.
2. Add `insert_record_raw(&self, record: &MemoryRecord) -> Result<(), SqliteMemoryError>` —
   preserves original `id`, `created_at`, `updated_at`, `status`, `supersedes`, `tags`.
   Used by the migration import (Task 2). Also inserts an audit entry with op=Migrate.
3. Add `insert_audit_raw(&self, entry: &MemoryAuditEntry) -> Result<(), SqliteMemoryError>` —
   bulk import of existing audit entries during migration.
4. Change `list_records()` (no args) to return all active records (matches JSONL behavior).
   Rename the existing version to `list_records_filtered(include_inactive: bool)`.
5. Change `schema_version()` to return `Result<u32, SqliteMemoryError>` (not Option).
   Return 0 if no version found.
6. Change `apply_retention_policy` param from `u64` to accept both via `Into<u64>`.
   Actually just keep `u64` — callers will be updated in Task 4.
7. Implement `From<SqliteMemoryError> for crate::SpeechError` so callers can use `?`
   with the project-wide error type.
8. Update all 11 existing tests to match new signatures.

**Acceptance criteria:**
- All 11 SQLite tests still pass with new signatures.
- `insert_record` returns full `MemoryRecord`.
- `insert_record_raw` and `insert_audit_raw` exist for migration.
- `cargo check` zero warnings.

---

## Task 2: Create src/memory/migrate.rs — JSONL→SQLite migration

**Why:** Existing users have data in `records.jsonl` and `audit.jsonl`. This must be
imported into SQLite on first startup, with verification and backup.

**Files (create):**
- `src/memory/migrate.rs`

**Files (modify):**
- `src/memory/mod.rs` (add `pub(crate) mod migrate;`)

**Work:**
1. Create `migrate.rs` with:
   - `pub(crate) fn needs_migration(root_dir: &Path) -> bool` —
     Returns true if `records.jsonl` exists AND `fae.db` does NOT exist (or has no records).
   - `pub(crate) fn run_jsonl_to_sqlite(root_dir: &Path) -> Result<MigrationReport>` —
     a. Backup: copy `records.jsonl` → `records.jsonl.pre-sqlite-backup`
     b. Backup: copy `audit.jsonl` → `audit.jsonl.pre-sqlite-backup`
     c. Open `MemoryRepository::new(root_dir)` to read JSONL data.
     d. Open `SqliteMemoryRepository::new(root_dir)` (creates fae.db).
     e. Read all records via `repo.list_records()` (include inactive via internal method).
     f. For each record, call `sqlite_repo.insert_record_raw(&record)`.
     g. Read all audit entries, call `sqlite_repo.insert_audit_raw(&entry)`.
     h. Verify: count records in SQLite matches JSONL count.
     i. Return `MigrationReport { records_migrated, audit_entries_migrated, backup_paths }`.
2. `MigrationReport` struct with counts and paths.
3. Add `#[cfg(test)]` tests:
   - `migration_imports_all_records` — seed JSONL, run migration, verify SQLite has all records.
   - `migration_preserves_record_fields` — verify ID, kind, status, tags, timestamps match.
   - `migration_creates_backups` — verify .pre-sqlite-backup files exist.
   - `migration_is_idempotent` — running twice doesn't duplicate records.
   - `needs_migration_false_when_no_jsonl` — fresh install, no JSONL files.

**Acceptance criteria:**
- All migration tests pass.
- JSONL records faithfully imported into SQLite with all fields preserved.
- Backup files created before migration.
- `cargo check` zero warnings.

---

## Task 3: Switch MemoryOrchestrator to SqliteMemoryRepository

**Why:** The orchestrator is the central entry point for memory operations. Switching it
to SQLite changes the backend for all pipeline-level memory operations.

**Files (modify):**
- `src/memory/jsonl.rs` (MemoryOrchestrator struct and impl)
- `src/memory/sqlite.rs` (may need minor signature adjustments)

**Work:**
1. Change `MemoryOrchestrator.repo` field type from `MemoryRepository` to `SqliteMemoryRepository`.
2. Update `MemoryOrchestrator::new()` to:
   a. Check `needs_migration(root_dir)` — if true, run `run_jsonl_to_sqlite(root_dir)`.
   b. Create `SqliteMemoryRepository::new(root_dir)` instead of `MemoryRepository::new(root_dir)`.
3. Update all `self.repo.*` calls in MemoryOrchestrator methods to match SqliteMemoryRepository API.
   Key changes:
   - `insert_record` — may need to adjust tag parameter (slice vs Vec).
   - `supersede_record` — now takes `&SupersedeParams`.
   - Handle `SqliteMemoryError` → `SpeechError` conversion (via From impl from Task 1).
4. Update the `ensure_ready_with_migration` method.
5. Ensure all 18 JSONL orchestrator tests still pass (they use tempdir, so they'll
   test the SQLite path now).

**Acceptance criteria:**
- All existing MemoryOrchestrator tests pass (now exercising SQLite backend).
- `MemoryOrchestrator::new()` creates SQLite repo and runs migration if needed.
- `cargo check` zero warnings.

---

## Task 4: Update all direct MemoryRepository callers

**Why:** Several files construct `MemoryRepository` directly. These must switch to
`SqliteMemoryRepository` for the migration to be complete.

**Files (modify):**
- `src/scheduler/tasks.rs` (lines ~655, ~682, ~814)
- `src/intelligence/store.rs` (IntelligenceStore wraps MemoryRepository)
- `src/intelligence/skill_proposals.rs` (~line 185)
- `src/intelligence/mod.rs` (~line 119, if still live)
- `src/memory/mod.rs` (update re-exports)

**Work:**
1. `scheduler/tasks.rs`:
   - Replace `MemoryRepository::new(root)` with `SqliteMemoryRepository::new(root)?`
     at all 3 production sites.
   - The free functions `run_memory_migrate_for_root`, stale check, briefing check
     all need to use SQLite.
   - Update test helpers that construct MemoryRepository.
2. `intelligence/store.rs`:
   - Change `IntelligenceStore` to hold `SqliteMemoryRepository` instead of `MemoryRepository`.
   - Update `pub fn repo(&self)` return type.
3. `intelligence/skill_proposals.rs`:
   - Replace `MemoryRepository::new(memory_path)` with `SqliteMemoryRepository::new(memory_path)?`.
4. `intelligence/mod.rs`:
   - If `apply_extraction_result` is still using JSONL, switch to SQLite.
5. Update `src/memory/mod.rs` re-exports — keep `MemoryRepository` exported for
   backward compat but add `SqliteMemoryRepository` as the primary export.
6. Update the four free functions in `jsonl.rs` (`run_memory_gc`, `run_memory_reflection`,
   `run_memory_reindex`, `run_memory_migration`) to use SqliteMemoryRepository internally,
   OR create SQLite equivalents. These are called by the scheduler.

**Acceptance criteria:**
- `cargo check` zero warnings.
- No production code constructs `MemoryRepository` (JSONL) directly.
- All tests in scheduler, intelligence, and memory modules pass.

---

## Task 5: Integration test and final validation

**Why:** End-to-end verification that the full migration pipeline works.

**Files (modify/create):**
- `src/memory/migrate.rs` (add integration-level test if needed)
- Various test adjustments

**Work:**
1. Run `cargo fmt --all -- --check` — fix any drift.
2. Run `cargo clippy --all-features -- -D warnings` — fix all warnings.
3. Run `cargo test --lib` — all tests pass.
4. Verify module structure: `src/memory/{mod,types,jsonl,schema,sqlite,migrate}.rs`.
5. Verify no production code path constructs `MemoryRepository` (JSONL) directly
   (grep for `MemoryRepository::new` outside of `#[cfg(test)]` and migration code).
6. Verify `SqliteMemoryRepository` is the default backend for all memory operations.

**Acceptance criteria:**
- `just check` (or equivalent) exits 0.
- All memory tests pass.
- No `.unwrap()` or `.expect()` outside `#[cfg(test)]`.
- JSONL backend preserved for migration read-only path only.

---

## Summary

| # | Task | Key Files | Est. Lines |
|---|------|-----------|-----------|
| 1 | Normalize SQLite API | `sqlite.rs` | ~100 |
| 2 | Create migration module | new `migrate.rs` | ~250 |
| 3 | Switch MemoryOrchestrator to SQLite | `jsonl.rs` | ~80 |
| 4 | Update all direct callers | `scheduler/tasks.rs`, `intelligence/` | ~60 |
| 5 | Integration test + validation | various | ~20 |

**Out of scope for Phase 7.2:**
- Embedding engine (Phase 7.3)
- Hybrid retrieval / KNN (Phase 7.4)
- Backup rotation / integrity checks (Phase 7.5)
- Removing JSONL code entirely (kept for migration read path)
