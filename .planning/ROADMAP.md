# Fae Native macOS App — Production Readiness Roadmap

## Previous Milestones (Complete)

- Milestone 1: Core Pipeline & Linker Fix
- Milestone 2: Event Flow & UI Wiring
- Milestone 3: Apple Ecosystem Tools
- Milestone 4: Onboarding Redesign
- Milestone 5: Handoff & Production Polish
- Milestone 6: Dogfood Readiness (v0.7.0)

---

## Milestone 7: Memory Architecture v2 — SQLite + Semantic Retrieval

**Goal:** Migrate Fae's memory from JSONL flat files to SQLite + sqlite-vec with semantic embedding-based retrieval. Production-ready: fully tested, documented, zero warnings.

**Problems Solved:**
1. **Retrieval quality** — lexical-only `score_record()` misses synonyms/paraphrases ("brother" ≠ "sibling")
2. **Storage reliability** — JSONL full-file rewrites on every mutation, no ACID, global write mutex

**Key Design Decisions:**
- Single SQLite database (`~/.fae/fae.db`) with sqlite-vec extension for vectors
- Embedding via `ort` (already a dep for Kokoro TTS) + all-MiniLM-L6-v2 (384-dim)
- `MemoryRepository` public API stays identical — internal swap only
- Hybrid scoring: semantic (0.6) + confidence (0.2) + freshness (0.1) + kind (0.1)
- Lexical fallback when embedding engine unavailable
- Research document: `.claude/plans/tingly-spinning-lemur.md`

---

### Phase 7.1: SQLite Foundation

- **Focus**: Add rusqlite + sqlite-vec dependencies, create database schema, implement `SqliteMemoryRepository` with identical public API to current `MemoryRepository`
- **Deliverables**: SQLite-backed repository that passes all existing memory unit tests
- **Dependencies**: None (additive)
- **Estimated Tasks**: 5-7
- **Key files**: `Cargo.toml`, new `src/memory/sqlite.rs`, `src/memory/schema.rs`

### Phase 7.2: JSONL → SQLite Migration

- **Focus**: Auto-detect storage backend on startup, one-time JSONL→SQLite migrator with backup and verification, backward compatibility during transition
- **Deliverables**: Seamless migration on first startup after upgrade, JSONL backup preserved
- **Dependencies**: Phase 7.1
- **Estimated Tasks**: 4-5
- **Key files**: `src/memory/migrate.rs`, `src/memory/mod.rs`

### Phase 7.3: Embedding Engine

- **Focus**: `EmbeddingEngine` struct using `ort` (reuses Kokoro pattern), all-MiniLM-L6-v2 ONNX model download via `hf-hub`, embed text to 384-dim f32 vectors, embed records on insert + batch embed during migration
- **Deliverables**: Working embedding pipeline, all records have vectors in sqlite-vec
- **Dependencies**: Phase 7.2
- **Estimated Tasks**: 4-6
- **Key files**: new `src/memory/embedding.rs`, `src/memory/sqlite.rs`

### Phase 7.4: Hybrid Retrieval

- **Focus**: Replace `score_record()` with hybrid semantic + structural scoring via sqlite-vec KNN. Semantic similarity (0.6) + confidence (0.2) + freshness (0.1) + kind bonus (0.1). Lexical fallback when embeddings unavailable.
- **Deliverables**: Dramatically improved recall quality, backward-compatible API
- **Dependencies**: Phase 7.3
- **Estimated Tasks**: 3-5
- **Key files**: `src/memory/sqlite.rs`, `src/memory/mod.rs`, `src/pipeline/coordinator.rs`

### Phase 7.5: Backup, Recovery & Hardening

- **Focus**: `PRAGMA integrity_check` on startup, backup rotation (daily/weekly), corruption detection with fallback modes (full → structural-only → read-only → emergency), remove legacy JSONL code paths, documentation
- **Deliverables**: Production-hardened memory with self-healing, updated CLAUDE.md and architecture docs
- **Dependencies**: Phase 7.4
- **Estimated Tasks**: 4-6
- **Key files**: `src/memory/backup.rs`, `src/memory/mod.rs`, `CLAUDE.md`, `docs/Memory.md`

---

### Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| sqlite-vec crate immature | Pure C extension, stable v0.1.6, MIT license, fallback to lexical search |
| Binary size increase from rusqlite | bundled feature compiles SQLite from source (~2-3 MB), acceptable |
| all-MiniLM-L6-v2 model download adds startup time | Download once via hf-hub (same pattern as Kokoro), cache locally |
| JSONL migration data loss | Full backup before migration, verify record counts, rollback on failure |
| sqlite-vec brute-force KNN slow at scale | <10ms for 100K × 384-dim vectors, upgrade path to hnswlib-rs if needed |

### Out of Scope

- Graph database / Apache AGE (SQL relationships table sufficient)
- LanceDB (too heavy for embedded desktop app)
- HNSW indexing (premature — brute-force fast enough at Fae's scale)
- PostgreSQL / server-based storage
- Multi-user / concurrent access patterns

---

## Milestone 6: Dogfood Readiness (COMPLETE)

**Goal:** Fix all 11 validated findings from the dogfood review. Production-ready: fully tested, documented, zero warnings.

**Source:** Dogfood readiness review (2026-02-20), all 11 findings validated against codebase.

**Key Design Decisions:**
- "show conversation" opens the **conversation panel** (not canvas)
- WhatsApp/Discord requires **native Settings UI**
- Embedded-only models enforced — **REMOVE all API/Agent backend code entirely**
- No Ollama/LM Studio/external API servers — **REMOVE fae_llm OpenAI/Anthropic providers**

---

### Phase 6.1: Backend Cleanup

**Rationale:** Foundational changes that touch many files. Must land first to avoid conflicts.

| Task | Description | Key Files |
|------|-------------|-----------|
| Remove LlmBackend::Api and LlmBackend::Agent | Delete enum variants, api_url/api_key/api_model/api_type/cloud_provider config fields, build_remote_provider(), API fallback logic | `config.rs`, `startup.rs`, `agent/mod.rs`, `agent/http_provider.rs`, `llm/api.rs`, `external_llm.rs`, `intelligence/mod.rs`, `channels/brain.rs` |
| Remove/update API-dependent tests | Remove or adapt tests exercising Api/Agent backends | `tests/e2e_anthropic.rs`, `tests/e2e_openai.rs`, `tests/anthropic_contract.rs`, `tests/openai_contract.rs`, `tests/cross_provider.rs`, `tests/llm_config_integration.rs` |
| Fix fae_dirs test flake | Serialize env-mutating tests with `serial_test` crate | `fae_dirs.rs`, `Cargo.toml` |
| Clean up Models settings tab | Remove non-local model backend references | `SettingsModelsTab.swift` |

**Exit:** `just check` passes, zero Api/Agent references, fae_dirs tests reliable.

---

### Phase 6.1b: fae_llm Provider Cleanup

**Rationale:** User directive — Fae only uses downloaded embedded models. No Ollama, LM Studio, or external API servers. Remove unused provider infrastructure.

| Task | Description | Key Files |
|------|-------------|-----------|
| Remove OpenAI provider | Delete openai.rs, remove pub use/re-exports | `fae_llm/providers/openai.rs`, `fae_llm/mod.rs` |
| Remove Anthropic provider | Delete anthropic.rs, remove pub use/re-exports | `fae_llm/providers/anthropic.rs`, `fae_llm/mod.rs` |
| Remove fallback provider | Delete fallback.rs (only used for API→local fallback) | `fae_llm/providers/fallback.rs`, `fae_llm/providers/mod.rs` |
| Clean fae_llm config | Remove provider API key fields, simplify config types | `fae_llm/config/types.rs`, `fae_llm/config/defaults.rs`, `fae_llm/config/service.rs` |
| Remove credential API key support | Clean llm.api_key from credential examples/doc comments | `credentials/types.rs`, `credentials/mod.rs`, `diagnostics/mod.rs` |
| Clean observability redaction | Remove API key redaction helpers if unused | `fae_llm/observability/redact.rs` |

**Exit:** `fae_llm` only contains local/embedded provider. No OpenAI/Anthropic/fallback code. `just check` green.

---

### Phase 6.2: Event Wiring

**Rationale:** Critical event chain fixes — Rust emits events but Swift doesn't act.

| Task | Description | Key Files |
|------|-------------|-----------|
| Wire canvas/conversation window show/hide | PipelineAuxBridgeController calls AuxiliaryWindowManager show/hide. Add conversation_visibility event. "show conversation" opens conversation panel. | `PipelineAuxBridgeController.swift`, `AuxiliaryWindowManager.swift`, `FaeNativeApp.swift`, `coordinator.rs`, `handler.rs` |
| Complete JIT permission flow | Extend JitPermissionController for calendar/reminders/notes/mail. Wire OnboardingController.onPermissionResult. Connect AvailabilityGatedTool JIT channel. | `JitPermissionController.swift`, `OnboardingController.swift`, `agent/mod.rs`, `availability_gate.rs` |
| Wire device handoff end-to-end | Handler emits events for device.move/go_home. Swift observer processes device.transfer_requested. NSUserActivity handoff. | `handler.rs`, new `DeviceHandoffController.swift`, `FaeHandoffKit/` |

**Exit:** "Show conversation" opens conversation. "Show canvas" opens canvas. JIT permissions for all Apple tools. Device handoff emits NSUserActivity.

---

### Phase 6.3: UX Feedback

**Rationale:** User-facing feedback improvements for polished dogfood experience.

| Task | Description | Key Files |
|------|-------------|-----------|
| Startup progress display | Handle aggregate_progress in ConversationBridgeController. JS progress indicator with download % and load stage. | `ConversationBridgeController.swift`, `conversation.html` |
| Real-time streaming bubbles | Partial STT to subtitle. Stream assistant text incrementally. | `ConversationBridgeController.swift`, `conversation.html` |
| Audio level JS handler | Add window.setAudioLevel() to drive orb RMS visualization. | `conversation.html` |
| Orb right-click context menu | contextmenu handler on collapsed orb for hide/show. | `conversation.html`, `WindowStateController.swift` |

**Exit:** Download progress visible. Real-time streaming text. Orb reacts to audio. Right-click context menu works.

---

### Phase 6.4: Settings Expansion

**Rationale:** Missing Settings UI prevents users from configuring tools and channels.

| Task | Description | Key Files |
|------|-------------|-----------|
| Add Tools settings tab | SettingsToolsTab with tool mode picker (Off/ReadOnly/ReadWrite/Full). Uses config.patch. | New `SettingsToolsTab.swift`, `SettingsView.swift` |
| Add Channels settings tab | SettingsChannelsTab with Discord/WhatsApp config forms. | New `SettingsChannelsTab.swift`, `SettingsView.swift` |
| Remove false CameraSkill claim | Remove CameraSkill from builtins — no camera tool exists. Update system prompt. | `builtins.rs`, `system_prompt.md` |

**Exit:** Tools tab allows tool mode changes. Channels tab configures Discord/WhatsApp. No false capability claims.

---

### Phase 6.5: Integration Validation

**Rationale:** End-to-end verification before team-wide dogfood release.

| Task | Description | Key Files |
|------|-------------|-----------|
| End-to-end smoke tests | Test all 11 fixed paths | New integration tests |
| Documentation updates | Update CLAUDE.md, architecture docs, system prompt | Doc files |
| Swift test suite | Tests for new controllers and settings tabs | `Tests/` |
| Release prep | Version bump, changelog, `just check` | `Cargo.toml`, `CHANGELOG.md` |

**Exit:** All tests pass (Rust + Swift). `just check` green. All 11 findings resolved. v0.7.0 ready.
