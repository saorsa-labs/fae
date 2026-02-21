# Security Review
**Date**: 2026-02-21
**Phase**: 7.5 - Backup, Recovery & Hardening
**Scope**: src/memory/backup.rs, src/memory/sqlite.rs, src/scheduler/tasks.rs

## Findings

- [MEDIUM] src/memory/backup.rs:52 - VACUUM INTO uses string formatting with single-quote escaping (`replace('\'', "''")`) for the backup path. While VACUUM INTO does not support parameterized binding and the path is internally generated (not user-supplied), the escaping pattern is fragile. If path generation ever becomes user-influenced, this is a SQL injection vector. Consider validating path characters or using std::fs::canonicalize.
- [OK] src/memory/sqlite.rs:21-39 - Existing unsafe block for sqlite-vec extension loading is unchanged from prior review; SAFETY comment present and documented.
- [OK] src/memory/backup.rs - No hardcoded credentials, tokens, or secrets.
- [OK] src/memory/backup.rs - No http:// URLs; no network calls.
- [OK] src/memory/backup.rs - Backup directory is created via std::fs::create_dir_all; no path traversal risk as path is derived from config root.
- [OK] src/scheduler/tasks.rs:860 - backup_keep_count read from MemoryConfig::default(); default is 7. This is not user-input-controlled directly.
- [OK] No Command::new or shell invocations in changed files.
- [LOW] src/memory/backup.rs:44 - Local time used for backup filenames via chrono::Local::now(). Could cause DST ambiguity (duplicate or skipped timestamps). Use Utc::now() for deterministic ordering.

## Summary
The VACUUM INTO path escaping (MEDIUM) is the only notable finding. The path is internally generated so practical risk is low, but the pattern should be documented. All other security posture is clean.

## Grade: A-
