# Fae Memory (Swift Runtime)

This guide documents memory behavior in the current Swift app.

## Storage

Memory lives in:

- `~/Library/Application Support/fae/fae.db` (SQLite via GRDB)
- `~/Library/Application Support/fae/backups/` (rotating backups)

Core tables include:

- `memory_records`
- `memory_audit`

## Record model

Kinds:

- `profile`, `fact`, `episode`, `event`, `person`, `interest`, `commitment`

Lifecycle status:

- `active`, `superseded`, `invalidated`, `forgotten`

## Runtime lifecycle

Per completed turn:

1. Recall relevant memory before generation
2. Inject bounded `<memory_context>`
3. Capture episode + durable candidates
4. Resolve conflicts through supersession lineage
5. Apply retention cleanup for episodic records

## Retrieval

- Primary retrieval: lexical scoring in `SQLiteMemoryStore.search`
- Optional semantic reranking in `MemoryOrchestrator` via `MLXEmbeddingEngine`
- Embedding backend: `foundation-hash-384`

## Capture

`MemoryOrchestrator.capture(...)` automatically extracts:

- explicit remember/forget directives
- name/profile preferences
- interests
- commitments
- events
- person relationships

## Maintenance tasks

`FaeScheduler` runs:

- `memory_migrate` (hourly)
- `memory_reindex` (every 3h)
- `memory_reflect` (every 6h)
- `memory_gc` (daily)
- `memory_backup` (daily)

## Config

Memory config in `config.toml`:

```toml
[memory]
enabled = true
maxRecallResults = 6
```

## Source files

- `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift`
- `native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift`
- `native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift`
- `native/macos/Fae/Sources/Fae/Memory/MemoryBackup.swift`
