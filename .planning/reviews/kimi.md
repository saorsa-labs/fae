# Kimi K2 External Review
**Date**: 2026-02-21
**Model**: Kimi K2 (Moonshot AI)
**Phase**: 7.5 - Backup, Recovery & Hardening

## Review Summary
Grade: B

"Solid implementation with proper backup/rotation logic, but has error handling gaps and a fragile SQL construction pattern that should be addressed."

## Findings (verbatim from Kimi)

**[MEDIUM]** `src/memory/backup.rs:52` - VACUUM INTO uses string formatting with quote escaping. While `replace('\'', "''")` is standard SQL escaping, this pattern is fragile and risks injection if `backup_dir` contains malicious paths. Since VACUUM INTO doesn't support parameter binding, consider validating the path contains only safe characters (alphanumeric, hyphens, underscores) or use a temporary safe filename and move atomically.

**[MEDIUM]** `src/memory/backup.rs:56` - Return value of `ensure_sqlite_vec_loaded()` is silently ignored. If sqlite-vec initialization fails, the code proceeds and will likely fail later with a cryptic error. Should propagate: `ensure_sqlite_vec_loaded().map_err(...)?`.

**[MEDIUM]** `src/memory/backup.rs:83` - `entry.ok()?` silently drops directory entry errors (permissions, corrupted filesystem, etc.), potentially masking why backups aren't being rotated. Consider logging warnings for errors or propagating them.

**[LOW]** `src/memory/backup.rs:39` - Converting IO errors to strings via `e.to_string()` loses error context and prevents downstream code from inspecting error kinds. Prefer preserving the original error or using `#[from]` in the error enum.

**[LOW]** `src/memory/backup.rs:44` - Using `chrono::Local::now()` for backup filenames may cause ambiguity during DST transitions (duplicate or missing hours). Consider UTC (`Utc::now()`) for deterministic ordering.

**[LOW]** `src/memory/backup.rs:140` - Test calls `ensure_sqlite_vec_loaded()` which likely modifies global process state without isolation or cleanup. Could cause test pollution if run in parallel with other memory tests.

**[INFO]** `src/memory/backup.rs:97` - File deletion failures during rotation are logged but not propagated. Callers cannot distinguish between "rotated successfully" and "partially failed" without parsing logs. Consider collecting errors and returning a compound result.

## Grade: B
