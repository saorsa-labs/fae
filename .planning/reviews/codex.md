# Codex External Review
**Date**: 2026-02-21
**Model**: gpt-5.3-codex (OpenAI Codex v0.104.0)
**Phase**: 7.5 - Backup, Recovery & Hardening

## Review Status: COMPLETED
Codex ran against diff HEAD~4..HEAD. Examined backup.rs, sqlite.rs, tasks.rs, runner.rs, config.rs, jsonl.rs, types.rs, Memory.md, CLAUDE.md.

## Key Findings from Codex Analysis

1. **Config not wired to runtime**: Codex identified that `backup_keep_count` in `run_memory_backup_for_root` reads from `MemoryConfig::default().backup_keep_count` rather than from the live runtime config. This is a confirmed gap.
   - Evidence: `src/scheduler/tasks.rs:860`

2. **Test coverage for TASK_MEMORY_BACKUP dispatch**: Codex noted that `execute_builtin_with_memory_root` dispatch test at line 1080 only tests TASK_MEMORY_GC with custom retention_days; there is no parallel test for TASK_MEMORY_BACKUP. The `with_memory_maintenance` deduplication test does verify the task is registered, but not that the backup logic executes end-to-end via the dispatch path.

3. **Module integration confirmed correct**: `pub(crate) mod backup` is present in `src/memory/mod.rs`; all references resolve.

4. **VACUUM INTO path formatting**: Codex observed the `replace('\'', "''")` pattern on backup path. Path is internally generated; risk is theoretical.

5. **All code verified present and applied**: Codex confirmed all diff changes are applied to the working tree.

## Grade: B+

Notes: Two LOW findings (config-not-wired, missing dispatch test). No CRITICAL or HIGH issues found.
