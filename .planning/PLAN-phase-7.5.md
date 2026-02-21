# Phase 7.5: Backup, Recovery & Hardening

## Goal
Production-harden the SQLite memory system with integrity checking, automated backups, and documentation updates.

## Tasks

### Task 1: SQLite integrity check on startup + error variants

**Files:** `src/memory/sqlite.rs`

**What:**
- Add `SqliteMemoryError::Corrupt(String)` variant
- Add `pub fn integrity_check(&self) -> Result<(), SqliteMemoryError>` method
  - Runs `PRAGMA quick_check` (fast version of integrity_check)
  - Returns `Ok(())` on pass, `Err(Corrupt(...))` on failure
- Call `integrity_check()` in `SqliteMemoryRepository::new()` after schema setup
- If integrity check fails on startup, log error but don't panic — caller decides
- Add `MemoryConfig.integrity_check_on_startup: bool` (default: true)
- Tests: verify integrity_check passes on fresh DB, test error variant

**Exit:** Startup runs integrity check. Clean compilation, all tests pass.

---

### Task 2: SQLite backup function

**Files:** new `src/memory/backup.rs`, `src/memory/mod.rs`

**What:**
- Create `src/memory/backup.rs` with:
  - `pub fn backup_database(db_path: &Path, backup_dir: &Path) -> Result<PathBuf>`
    - Uses SQLite's `VACUUM INTO` for atomic backup (single SQL statement)
    - Backup filename: `fae-backup-{YYYYMMDD-HHMMSS}.db`
    - Returns path to backup file
  - `pub fn rotate_backups(backup_dir: &Path, keep_count: usize) -> Result<usize>`
    - Lists all `fae-backup-*.db` files, sorted by name (newest first)
    - Deletes files beyond `keep_count`
    - Returns number deleted
- Register module in `src/memory/mod.rs`: `pub(crate) mod backup;`
- Tests: backup creates valid SQLite file, rotation keeps correct count

**Exit:** Working backup + rotation functions. All tests pass.

---

### Task 3: Wire backup into scheduler

**Files:** `src/scheduler/tasks.rs`, `src/scheduler/runner.rs`, `src/config.rs`

**What:**
- Add `TASK_MEMORY_BACKUP` constant in tasks.rs
- Add `run_memory_backup(root_dir: &Path) -> Result<String>` in tasks.rs or jsonl.rs
  - Calls `backup_database()` with `{root_dir}/backups/` dir
  - Calls `rotate_backups()` with keep_count from config
  - Returns summary string
- Register in `with_memory_maintenance()` in runner.rs: daily at 02:00
- Add `MemoryConfig.backup_keep_count: usize` (default: 7)
- Repurpose `run_memory_reindex` to run `integrity_check()` instead of just counting

**Exit:** Daily automated backup via scheduler. All tests pass.

---

### Task 4: Update documentation

**Files:** `docs/Memory.md`, `CLAUDE.md`

**What:**
- Rewrite `docs/Memory.md` for SQLite era:
  - Storage: `~/.fae/memory/fae.db` (SQLite + sqlite-vec)
  - Schema: memory_records, memory_audit, vec_embeddings tables
  - Embedding: all-MiniLM-L6-v2 via ort, 384-dim vectors
  - Hybrid retrieval: semantic (0.6) + structural (0.4)
  - Backup: daily automated, 7 retained, rotation
  - Integrity: quick_check on startup
  - Migration: one-time JSONL → SQLite (automatic)
- Update `CLAUDE.md` memory sections to reflect SQLite architecture
- Remove references to JSONL runtime files

**Exit:** Documentation accurately reflects current architecture.
