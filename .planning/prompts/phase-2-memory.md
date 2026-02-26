# Phase 2: Memory & Intelligence — Fae Remembers

## Your Mission

Give Fae persistent memory. She should remember what users tell her across conversations using SQLite + semantic search. When someone says "my name is David", Fae should remember it and recall it later.

**Deliverable**: Tell Fae your name → quit app → relaunch → ask "what's my name?" → correct answer.

---

## Prerequisites (completed by Phase 0 + Phase 1)

- Pure Swift app compiles and runs
- Voice pipeline works: speak → STT → LLM → TTS → playback
- `FaeCore`, `FaeEventBus`, `PipelineCoordinator` are functional
- `FaeConfig` loads from `~/Library/Application Support/fae/config.toml`
- GRDB.swift is in Package.swift dependencies

---

## Context

### Current Memory Architecture (Rust — what you're porting)

Fae's memory lives in SQLite at `~/Library/Application Support/fae/fae.db`. The Rust implementation uses:
- `rusqlite` + `sqlite-vec` for vector search
- `all-MiniLM-L6-v2` (384-dim) ONNX embeddings
- Hybrid scoring: semantic similarity (0.6) + confidence (0.2) + freshness (0.1) + kind bonus (0.1)

### Rust Source Files to Read

| File | Lines | What to port |
|------|-------|-------------|
| `src/memory/schema.rs` | ~200 | DDL for all tables |
| `src/memory/sqlite.rs` | 1,779 | Full SQLite repository — CRUD, search, scoring |
| `src/memory/types.rs` | ~400 | Memory types, kind enum, hybrid scoring formula |
| `src/memory/embedding.rs` | ~300 | Embedding engine (all-MiniLM-L6-v2) |
| `src/memory/jsonl.rs` | ~600 | MemoryOrchestrator (recall/capture logic) |
| `src/memory/backup.rs` | ~200 | VACUUM INTO backup, rotation |

---

## Tasks

### 2.1 — SQLite Memory Store (GRDB.swift)

**`Sources/Fae/Memory/SQLiteMemoryStore.swift`**

Port from `src/memory/sqlite.rs` (1,779 lines) and `src/memory/schema.rs`.

```swift
import GRDB

actor SQLiteMemoryStore {
    private let dbQueue: DatabaseQueue

    init() throws {
        let dbPath = FaeConfig.configDir.appendingPathComponent("fae.db")
        dbQueue = try DatabaseQueue(path: dbPath.path)
        try migrate()
    }
}
```

**Schema** — Read `src/memory/schema.rs` for the exact DDL. Key tables:

```sql
CREATE TABLE IF NOT EXISTS memories (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,           -- 'fact', 'preference', 'event', 'relationship', 'skill', 'observation'
    content TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 0.5,
    source TEXT,                  -- 'user', 'inferred', 'system'
    tags TEXT,                    -- JSON array
    embedding BLOB,              -- 384-dim float32 vector
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    accessed_at TEXT NOT NULL,
    access_count INTEGER NOT NULL DEFAULT 0,
    superseded_by TEXT,           -- id of newer memory that replaces this one
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS memory_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_id TEXT NOT NULL,
    action TEXT NOT NULL,         -- 'created', 'updated', 'accessed', 'superseded', 'deleted'
    details TEXT,
    timestamp TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS contacts (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    relationship TEXT,
    notes TEXT,
    trust_level TEXT DEFAULT 'known',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

**CRUD operations**:
- `store(memory:)` — insert with embedding
- `recall(query:embedding:limit:)` — hybrid search (see scoring below)
- `update(id:content:confidence:)` — update + audit trail
- `supersede(oldID:newMemory:)` — mark old as superseded, insert new
- `delete(id:)` — soft delete (is_active = 0)
- `getByKind(kind:limit:)` — fetch memories of a specific kind
- `getRecent(limit:)` — fetch most recently accessed

**Hybrid scoring formula** (port from `src/memory/types.rs`):

```
score = (semantic_similarity * 0.6) + (confidence * 0.2) + (freshness * 0.1) + (kind_bonus * 0.1)
```

Where:
- `semantic_similarity` = cosine similarity between query embedding and memory embedding (0.0–1.0)
- `confidence` = memory's confidence value (0.0–1.0)
- `freshness` = 1.0 / (1.0 + days_since_access) — more recent = higher
- `kind_bonus` = extra weight for certain memory kinds (facts: 0.1, preferences: 0.08, relationships: 0.06)

**Cosine similarity** — Use Accelerate framework for fast vector math:

```swift
import Accelerate

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
    vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))
    let denom = sqrt(normA) * sqrt(normB)
    return denom > 0 ? dot / denom : 0
}
```

**Note on vector search**: The Rust version uses `sqlite-vec` for vector similarity search. With GRDB, you have two options:
1. Load all active memory embeddings into memory and compute cosine similarity in Swift (fast for < 100K memories)
2. Use a SQLite extension for vector search if GRDB supports it

Option 1 is simpler and sufficient for the expected scale. Pre-load embeddings on startup, recompute on changes.

### 2.2 — Embedding Engine

**`Sources/Fae/ML/MLXEmbeddingEngine.swift`**

The Rust version uses all-MiniLM-L6-v2 (384-dim) via ONNX Runtime. For Swift, you have options:

**Option A — MLX embedding model** (recommended):
```swift
actor MLXEmbeddingEngine: EmbeddingEngine {
    // Load all-MiniLM-L6-v2 via MLX
    // Or use a smaller/faster embedding model from mlx-community
    func embed(text: String) async throws -> [Float]  // 384-dim vector
}
```

Check if `mlx-swift-lm` or the MLX ecosystem has embedding model support. Look at `mlx-community` on HuggingFace for available embedding models.

**Option B — Apple NLEmbedding** (simpler fallback):
```swift
import NaturalLanguage

actor NLEmbeddingEngine: EmbeddingEngine {
    func embed(text: String) async throws -> [Float] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw MemoryError.embeddingUnavailable
        }
        guard let vector = embedding.vector(for: text) else {
            throw MemoryError.embeddingFailed
        }
        return vector.map { Float($0) }
    }
}
```

`NLEmbedding` is built into macOS, zero download, but produces different-dimension vectors than MiniLM. If you use this, the SQLite schema's embedding column size changes. Existing memories from the Rust version would not be compatible, but since Fae hasn't launched, this is fine.

**Recommendation**: Try Option A first. If it's complex to set up, fall back to Option B.

### 2.3 — Memory Orchestrator

**`Sources/Fae/Memory/MemoryOrchestrator.swift`**

Port from `src/memory/jsonl.rs` (MemoryOrchestrator portions):

```swift
actor MemoryOrchestrator {
    private let store: SQLiteMemoryStore
    private let embedding: any EmbeddingEngine

    /// Called BEFORE LLM generation — find relevant memories for context
    func recall(query: String, limit: Int = 5) async throws -> [Memory] {
        let queryEmbedding = try await embedding.embed(text: query)
        return try await store.recall(query: query, embedding: queryEmbedding, limit: limit)
    }

    /// Called AFTER each completed conversation turn — extract and store memories
    func capture(turn: ConversationTurn) async throws {
        // 1. Use a simple heuristic or the LLM to extract memorable facts:
        //    - "My name is X" → fact memory
        //    - "I prefer X" → preference memory
        //    - "I work at X" → fact memory
        //    - "Remember that X" → explicit storage
        // 2. Generate embedding for each extracted memory
        // 3. Check for duplicates/conflicts with existing memories
        // 4. Store new or supersede existing
    }

    /// Consolidate duplicate/overlapping memories
    func reflect() async throws {
        // Find memories with high embedding similarity (>0.9)
        // Merge or supersede duplicates
        // Update confidence scores based on repetition
    }

    /// Retention cleanup — remove old, low-confidence, rarely-accessed memories
    func garbageCollect() async throws {
        // Delete memories that are:
        // - Superseded + older than 30 days
        // - confidence < 0.1 + not accessed in 90 days
        // - is_active = 0 + older than 7 days
    }
}
```

**Memory capture heuristics** (from the Rust implementation):
- Pattern matching for explicit statements: "my name is", "I'm called", "I live in", "I work at", "I like", "I prefer", "remember that"
- Detect relationship mentions: "my wife", "my boss", "my friend X"
- Confidence assignment: explicit user statements = 0.8, inferred = 0.5
- Source tagging: "user" for explicit, "inferred" for detected patterns

### 2.4 — Backup & Health

**`Sources/Fae/Memory/MemoryBackup.swift`**

```swift
struct MemoryBackup {
    static let backupDir = FaeConfig.configDir.appendingPathComponent("backups")
    static let maxBackups = 7

    /// Atomic backup using VACUUM INTO
    static func backup(dbQueue: DatabaseQueue) throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let backupPath = backupDir.appendingPathComponent("fae-\(timestamp).db")
        try dbQueue.write { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [backupPath.path])
        }
        rotateBackups()
    }

    /// Keep only the 7 most recent backups
    static func rotateBackups() {
        // List .db files in backupDir, sorted by date
        // Delete oldest if count > maxBackups
    }

    /// Integrity check on startup
    static func verifyIntegrity(dbQueue: DatabaseQueue) throws -> Bool {
        try dbQueue.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA quick_check")
            return result == "ok"
        }
    }
}
```

### 2.5 — Wire Memory into Pipeline

Update `PipelineCoordinator` (from Phase 1) to integrate memory:

**Before LLM generation**:
```swift
// In the pipeline's processing of a speech segment:
let transcription = try await stt.transcribe(samples: segment.samples, sampleRate: segment.sampleRate)
let memories = try await memoryOrchestrator.recall(query: transcription.text, limit: 5)
let memoryContext = formatMemoriesForPrompt(memories)
let systemPrompt = personality.assembleVoicePrompt(
    userName: config.userName,
    memoryContext: memoryContext
)
// Pass to LLM generation with enriched system prompt
```

**After completed turn**:
```swift
// After assistant finishes speaking:
let turn = ConversationTurn(
    userText: transcription.text,
    assistantText: fullAssistantResponse,
    timestamp: Date(),
    toolsUsed: []
)
try await memoryOrchestrator.capture(turn: turn)
```

**Memory context formatting**:
```swift
func formatMemoriesForPrompt(_ memories: [Memory]) -> String {
    guard !memories.isEmpty else { return "" }
    var lines = ["[Recalled memories]:"]
    for mem in memories {
        lines.append("- [\(mem.kind)] \(mem.content) (confidence: \(mem.confidence))")
    }
    return lines.joined(separator: "\n")
}
```

---

## Verification

1. Build: `swift build` — zero errors
2. Launch Fae, say "My name is David"
3. Fae acknowledges
4. Say "What's my name?"
5. Fae responds "David" (using recalled memory)
6. Quit app completely
7. Relaunch
8. Say "What's my name?"
9. Fae responds "David" (persisted in SQLite)
10. Check `~/Library/Application Support/fae/fae.db` exists and has records:
    ```sql
    sqlite3 ~/Library/Application\ Support/fae/fae.db "SELECT kind, content, confidence FROM memories"
    ```
11. Memory recall latency < 50ms (for reasonable database size)

---

## Do NOT Do

- Do NOT implement tools or agent loop (Phase 3)
- Do NOT implement scheduler tasks (Phase 4) — just define the interfaces that scheduler will call
- Do NOT change the voice pipeline behavior beyond adding memory injection
- Do NOT delete the Rust `src/` directory
- Do NOT implement channel integrations
