# Phase 8.5: Semantic Skill Discovery

## Goal

Enable users to find installed skills by meaning, not keywords. Embed SKILL.md
descriptions and manifest descriptions using all-MiniLM-L6-v2, store vectors in
a dedicated `skill_embeddings` sqlite-vec table, and expose a search API.

## Architecture

```
User query: "send a message on Discord"
    ↓
EmbeddingEngine.embed(query)
    ↓
skill_embeddings table (sqlite-vec KNN)
    ↓
Top-K results: [(skill_id, distance, source)]
    ↓
SkillSearchResult { id, name, description, score }
```

## Tasks

### Task 1: SkillDiscoveryIndex type + schema

**File**: `src/skills/discovery.rs` (new)

Create `SkillDiscoveryIndex` backed by a rusqlite connection with a
`skill_embeddings` virtual table:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS skill_embeddings USING vec0(
    skill_id TEXT PRIMARY KEY,
    embedding FLOAT[384]
);

CREATE TABLE IF NOT EXISTS skill_metadata (
    skill_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT 'python',  -- 'python' | 'markdown' | 'builtin'
    indexed_at INTEGER NOT NULL DEFAULT 0
);
```

Public API:
```rust
pub struct SkillDiscoveryIndex { conn: Connection }

impl SkillDiscoveryIndex {
    pub fn open(db_path: &Path) -> Result<Self, PythonSkillError>
    pub fn index_skill(&self, skill_id: &str, name: &str, description: &str, source: &str, embedding: &[f32]) -> Result<(), PythonSkillError>
    pub fn remove_skill(&self, skill_id: &str) -> Result<(), PythonSkillError>
    pub fn search(&self, query_embedding: &[f32], limit: usize) -> Result<Vec<SkillSearchResult>, PythonSkillError>
    pub fn is_indexed(&self, skill_id: &str) -> Result<bool, PythonSkillError>
    pub fn indexed_count(&self) -> Result<usize, PythonSkillError>
}

pub struct SkillSearchResult {
    pub skill_id: String,
    pub name: String,
    pub description: String,
    pub source: String,
    pub score: f32,  // 0.0..1.0, higher = better match
}
```

Tests:
- `open_creates_tables`
- `index_and_search_returns_match`
- `remove_skill_deletes_from_index`
- `is_indexed_returns_correct_status`
- `search_empty_index_returns_empty`
- `indexed_count_tracks_entries`

### Task 2: Skill text extraction helpers

**File**: `src/skills/discovery.rs`

Functions to extract searchable text from each skill type:

```rust
/// Extracts description text from a Python skill manifest.
pub fn extract_python_skill_text(skills_dir: &Path, skill_id: &str) -> Option<(String, String)>
// Returns Some((name, description)) or None if manifest missing/invalid

/// Extracts description text from a markdown skill file.
pub fn extract_markdown_skill_text(skill_path: &Path) -> Option<(String, String)>
// Returns Some((name, first_paragraph)) — name from filename, description from content

/// Extracts description from builtin skill constants.
pub fn extract_builtin_skill_text(skill_name: &str, content: &str) -> (String, String)
// Returns (name, first 500 chars of content as description)
```

Tests:
- `extract_python_skill_text_from_manifest`
- `extract_python_skill_text_missing_manifest_returns_none`
- `extract_markdown_skill_text_from_file`
- `extract_builtin_skill_text_truncates`

### Task 3: Index rebuild (full reindex)

**File**: `src/skills/discovery.rs`

```rust
/// Rebuilds the entire skill discovery index.
/// Scans all Python skills, markdown skills, and builtins.
pub fn rebuild_skill_index(
    index: &SkillDiscoveryIndex,
    engine: &mut EmbeddingEngine,
    skills_dir: &Path,
    python_skills_dir: &Path,
) -> Result<usize, PythonSkillError>
// Returns number of skills indexed
```

Tests:
- `rebuild_indexes_python_skills`
- `rebuild_indexes_markdown_skills`
- `rebuild_skips_already_indexed` (idempotent)

### Task 4: Host command + module wiring

**File**: `src/host/contract.rs` — add `SkillDiscoverySearch` command
**File**: `src/host/channel.rs` — add handler dispatch
**File**: `src/host/handler.rs` — implement search handler
**File**: `src/skills/mod.rs` — expose `discovery` module

Host command: `skill.discovery.search`
Payload: `{"query": "...", "limit": 5}`
Response: `{"results": [{"skill_id": "...", "name": "...", "description": "...", "score": 0.85}]}`

Tests:
- Contract round-trip for new command
- Module exports accessible

### Task 5: Integration tests

**File**: `tests/python_skill_discovery.rs` (new)

- `index_python_skill_and_search_by_description`
- `search_returns_best_match_first`
- `empty_query_returns_empty`
- `reindex_updates_changed_descriptions`

## Non-goals

- No automatic reindexing on skill install (Phase 8.7 self-healing)
- No hybrid text+vector search (pure vector KNN for now)
- No UI changes

## Files

- `src/skills/discovery.rs` (new)
- `src/skills/mod.rs` (modified: expose discovery module)
- `src/host/contract.rs` (modified: SkillDiscoverySearch command)
- `src/host/channel.rs` (modified: handler dispatch)
- `src/host/handler.rs` (modified: search handler)
- `tests/python_skill_discovery.rs` (new)
