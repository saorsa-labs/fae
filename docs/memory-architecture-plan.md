# Fae Memory Architecture Plan

## Mission

Build a production-grade conversational memory system that is:

- fully automated in conversational flow
- durable, editable, and auditable
- robust across upgrades and schema evolution
- strong under real-world noisy language and long sessions

## Current baseline (implemented — Milestone 7 complete)

### Data model and storage

- SQLite database (`~/.fae/memory/fae.db`, WAL mode) with sqlite-vec extension
- Tables: `memory_records`, `memory_audit`, `vec_embeddings` (384-dim), `schema_meta`
- 7 memory kinds: `profile`, `fact`, `episode`, `event`, `person`, `interest`, `commitment`
- typed status: `active`, `superseded`, `invalidated`, `forgotten`
- embedding: all-MiniLM-L6-v2 (ONNX, 384-dim float32) via ort
- hybrid retrieval: semantic similarity (0.6) + confidence (0.2) + freshness (0.1) + kind bonus (0.1)
- lexical fallback when embedding engine unavailable
- PRAGMA quick_check integrity verification on startup
- daily VACUUM INTO atomic backups with 7-file rotation
- one-time JSONL → SQLite migration on upgrade (legacy files preserved as backup)

### Lifecycle automation

- recall before each LLM turn
- capture after each completed turn
- conflict supersession with lineage (`supersedes`)
- retention policy for episodic memory
- startup schema migration with backup + rollback

### Maintenance and observability

- scheduled jobs: migrate, reflect, reindex, gc
- runtime telemetry: recall, write, conflict, migration

## Gaps to close for world-class behavior

1. ~~Retrieval quality~~ **DONE (Milestone 7)**
- ~~current ranking is lexical + heuristics only~~
- ~~no semantic embedding index yet~~
- Implemented: hybrid semantic + structural scoring via sqlite-vec KNN

2. Extraction breadth
- capture currently relies on deterministic parsing patterns
- no dedicated structured extractor model pass yet

3. Governance and policy depth
- no per-memory sensitivity classes/ACL enforcement yet
- no explicit tenant/user namespace partitioning in schema yet

4. Context-budget adaptation
- prompt recall budget is char-bounded but static by config
- no automatic adaptation from live context pressure signals

## Target architecture

### 1) Memory tiers

- **Working memory**: short-lived turn state and queue context
- **Durable profile memory**: stable user preferences/identity/constraints
- **Durable fact memory**: reusable factual context
- **Episodic memory**: source-linked history for traceability and promotion

### 2) Capture pipeline

1. Persist episode summary for each turn
2. Run intent extraction (deterministic + optional model-assisted pass)
3. Normalize and score candidates
4. Conflict detect and resolve via supersede/invalidate rules
5. Write record + audit atomically
6. Queue index refresh

### 3) Recall pipeline

1. Candidate fetch from active durable records
2. Rank by:
- lexical overlap
- semantic similarity (target)
- confidence and freshness
- type-specific priors
3. Budget pack into `<memory_context>`
4. Emit observability metrics (`hits`, budget utilization)

### 4) Edit model

All edits are first-class operations:

- insert
- patch
- supersede
- invalidate
- soft forget
- hard forget

Every operation must be logged in audit except hard-delete content body.

### 5) Upgrade model

- strict schema version gate at startup
- migration chain by version
- automatic backup snapshot before mutate
- rollback on any failure
- idempotent migration contracts tested with fixtures

## Context-budget strategy

Memory quality depends on context headroom. Strategy:

1. Keep durable recall bounded (`recall_max_items`, `recall_max_chars`)
2. Keep conversation history bounded (`max_history_messages`)
3. Compact older history near context pressure threshold
4. Scale default context window from machine RAM
5. Add adaptive policy (target): reduce recall breadth automatically when compaction frequency spikes

## Reliability and safety requirements

- no panic/unwrap/expect in production memory paths
- global write serialization for record/audit mutation
- oversized capture data must degrade safely (truncate), not fail whole turn
- false-positive extraction guards for high-impact fields (name/identity)
- deterministic rollback tests for migration failure modes

## TDD and verification gates

For each memory behavior change:

1. add or update failing unit/integration tests
2. implement minimal code change
3. run targeted tests for changed subsystems
4. run formatter + strict clippy policy + full tests before release

Recommended quality gates:

- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`

## Delivery roadmap

### Phase 1 (hardening) — COMPLETE

- ✅ strengthen extraction precision for names/preferences
- ✅ enforce confidence gating for durable promotion/recall
- ✅ improve oversized-turn resilience

### Phase 2 (retrieval quality) — COMPLETE (Milestone 7)

- ✅ add embedding index and hybrid ranker (sqlite-vec + all-MiniLM-L6-v2)
- ✅ add dedupe by semantic near-duplicate, not only exact text
- recall observability dashboards (budget hit ratio, precision proxies) — future work

### Phase 3 (governance)

- sensitivity classes and restricted recall policy
- explicit user namespace partitioning
- stronger deletion/audit compliance workflows

### Phase 4 (adaptive intelligence)

- memory-context adaptive budget controller
- model-assisted extraction/validation pass
- reinforcement from correction signals over time
