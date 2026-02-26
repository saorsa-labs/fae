# Memory Fixture Scaffold

This directory is reserved for backward-compatibility and migration fixtures used by
`MemoryMigrationCompatibilityTests`.

Planned fixture files:

- `manifest.toml` — fixture metadata and schema/version hints
- `records.jsonl` — durable memory records spanning legacy and current status variants
- `audit.jsonl` — audit history entries for migration and lineage verification

Status: scaffold only; concrete fixture datasets to be added in a follow-up task.
