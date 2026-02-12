# Phase 3.2: Session Persistence & Replay

## Overview

Implement session persistence for the fae_llm agent loop. Sessions store conversation messages (user, assistant, tool calls, tool results) to disk as JSON. Sessions can be resumed with state validation. Typed continuation errors cover session corruption, schema mismatch, and missing data. A `ConversationContext` manager wraps session + agent loop for ergonomic multi-turn usage.

**Module:** `src/fae_llm/session/`

---

## Task 1: Session types and error variants

**Files:**
- `src/fae_llm/session/types.rs` (new)
- `src/fae_llm/error.rs` (add SESSION_ERROR code + SessionError variant)

**Description:**

Define core session types:

```rust
/// Unique session identifier.
pub type SessionId = String;

/// Metadata about a session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMeta {
    pub id: SessionId,
    pub created_at: u64,          // Unix epoch seconds
    pub updated_at: u64,
    pub turn_count: usize,
    pub total_tokens: u64,
    pub system_prompt: Option<String>,
    pub model: Option<String>,     // ModelRef display string
    pub schema_version: u32,       // For forward compat
}

/// A persisted session: metadata + message history.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub meta: SessionMeta,
    pub messages: Vec<Message>,    // re-use providers::message::Message
}

/// Why a session resume failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionResumeError {
    NotFound(SessionId),
    Corrupted { id: SessionId, reason: String },
    SchemaMismatch { id: SessionId, found: u32, expected: u32 },
}
```

Add to `error.rs`:
- `pub const SESSION_ERROR: &str = "SESSION_ERROR";`
- `FaeLlmError::SessionError(String)` variant

**Tests:**
- `session_meta_serde_round_trip`
- `session_serde_round_trip`
- `session_meta_default_values`
- `session_resume_error_variants`
- `session_error_code`
- `session_error_display`
- All types are Send + Sync

**Acceptance:**
- Types compile, serialize/deserialize correctly
- Error code follows existing convention
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`

---

## Task 2: SessionStore trait and in-memory implementation

**Files:**
- `src/fae_llm/session/store.rs` (new)

**Description:**

Define the `SessionStore` trait and an in-memory implementation:

```rust
/// Async session storage backend.
#[async_trait]
pub trait SessionStore: Send + Sync {
    /// Create a new session, returning its ID.
    async fn create(&self, system_prompt: Option<&str>) -> Result<SessionId, FaeLlmError>;
    /// Load a session by ID.
    async fn load(&self, id: &str) -> Result<Session, FaeLlmError>;
    /// Save (overwrite) a session.
    async fn save(&self, session: &Session) -> Result<(), FaeLlmError>;
    /// Delete a session.
    async fn delete(&self, id: &str) -> Result<(), FaeLlmError>;
    /// List all session IDs with metadata.
    async fn list(&self) -> Result<Vec<SessionMeta>, FaeLlmError>;
    /// Check if a session exists.
    async fn exists(&self, id: &str) -> Result<bool, FaeLlmError>;
}

/// In-memory session store (for tests and ephemeral usage).
pub struct MemorySessionStore { ... }
```

`MemorySessionStore` stores sessions in `Arc<RwLock<HashMap<SessionId, Session>>>`.
Session IDs generated as `"sess_{unix_millis}_{random_suffix}"`.

**Tests:**
- `memory_store_create_returns_id`
- `memory_store_save_and_load`
- `memory_store_load_not_found`
- `memory_store_delete`
- `memory_store_list`
- `memory_store_exists`
- `memory_store_overwrite`
- `memory_store_is_send_sync`

**Acceptance:**
- Trait is object-safe (dyn SessionStore works)
- All CRUD operations work
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`

---

## Task 3: Filesystem SessionStore implementation

**Files:**
- `src/fae_llm/session/fs_store.rs` (new)

**Description:**

Implement `SessionStore` for filesystem persistence:

```rust
/// Filesystem-backed session store.
///
/// Sessions stored as `{data_dir}/{session_id}.json`.
/// Uses atomic write (temp file + rename) for crash safety.
pub struct FsSessionStore {
    data_dir: PathBuf,
}
```

- Constructor: `FsSessionStore::new(data_dir: impl Into<PathBuf>) -> Result<Self, FaeLlmError>` (creates dir if needed)
- `save`: write to temp file, fsync, rename (atomic)
- `load`: read + parse JSON
- `delete`: remove file
- `list`: enumerate `*.json` files, parse metadata from each
- `exists`: check file exists

**Tests (using tempfile::tempdir):**
- `fs_store_create_and_load`
- `fs_store_save_persists_to_disk`
- `fs_store_load_not_found`
- `fs_store_delete_removes_file`
- `fs_store_list_sessions`
- `fs_store_exists`
- `fs_store_atomic_write_creates_file`
- `fs_store_corrupted_file_returns_error`
- `fs_store_is_send_sync`

**Acceptance:**
- Files appear on disk at expected paths
- Atomic writes (no partial writes on crash)
- Corrupted JSON returns SessionError
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`

---

## Task 4: Session validation on resume

**Files:**
- `src/fae_llm/session/validation.rs` (new)

**Description:**

Implement session validation that runs before resume:

```rust
/// Current schema version for sessions.
pub const CURRENT_SCHEMA_VERSION: u32 = 1;

/// Validate a session is safe to resume.
///
/// Checks:
/// 1. Schema version matches (or is upgradeable)
/// 2. Message sequence is valid (alternating roles, proper tool call/result pairing)
/// 3. Session metadata is consistent with messages
///
/// Returns Ok(()) or typed SessionResumeError.
pub fn validate_session(session: &Session) -> Result<(), SessionResumeError> { ... }

/// Validate message sequence integrity.
pub fn validate_message_sequence(messages: &[Message]) -> Result<(), String> { ... }
```

Validation rules:
- Schema version must be <= CURRENT_SCHEMA_VERSION
- Messages must not be empty (at least system or user message)
- Tool result messages must be preceded by an assistant message with matching tool call
- turn_count in meta should match actual message pattern

**Tests:**
- `validate_empty_session_fails`
- `validate_valid_session_passes`
- `validate_schema_mismatch_fails`
- `validate_future_schema_fails`
- `validate_orphan_tool_result_fails`
- `validate_valid_tool_sequence_passes`
- `validate_turn_count_mismatch_warns` (lenient - warns but passes)

**Acceptance:**
- All validation rules enforced
- Typed errors returned (not string parsing)
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`

---

## Task 5: Session-aware agent loop (ConversationContext)

**Files:**
- `src/fae_llm/session/context.rs` (new)

**Description:**

`ConversationContext` wraps session store + agent loop for ergonomic multi-turn:

```rust
/// Manages a conversation session with automatic persistence.
///
/// Each call to `send()` appends the user message, runs the agent loop,
/// appends the result, and persists the updated session.
pub struct ConversationContext {
    session: Session,
    store: Arc<dyn SessionStore>,
    config: AgentConfig,
    provider: Arc<dyn ProviderAdapter>,
    registry: Arc<ToolRegistry>,
}

impl ConversationContext {
    /// Start a new conversation.
    pub async fn new(
        store: Arc<dyn SessionStore>,
        config: AgentConfig,
        provider: Arc<dyn ProviderAdapter>,
        registry: Arc<ToolRegistry>,
    ) -> Result<Self, FaeLlmError>;

    /// Resume an existing conversation.
    pub async fn resume(
        id: &str,
        store: Arc<dyn SessionStore>,
        config: AgentConfig,
        provider: Arc<dyn ProviderAdapter>,
        registry: Arc<ToolRegistry>,
    ) -> Result<Self, FaeLlmError>;

    /// Send a user message and get the agent's response.
    pub async fn send(&mut self, message: &str) -> Result<AgentLoopResult, FaeLlmError>;

    /// Get the current session.
    pub fn session(&self) -> &Session;

    /// Get the session ID.
    pub fn session_id(&self) -> &str;
}
```

Flow for `send()`:
1. Append `Message::user(message)` to session
2. Build `AgentLoop`, call `run_with_messages(session.messages.clone())`
3. Append assistant messages (from `build_messages_from_result`)
4. Update session meta (turn_count, updated_at, total_tokens)
5. Persist via `store.save(&session)`
6. Return `AgentLoopResult`

**Tests (using MemorySessionStore + MockProvider):**
- `context_new_creates_session`
- `context_send_appends_messages`
- `context_send_persists_session`
- `context_resume_loads_session`
- `context_resume_validates_session`
- `context_resume_not_found_returns_error`
- `context_multi_turn_accumulates_messages`
- `context_session_id_accessor`

**Acceptance:**
- New conversation creates session in store
- Each send() persists updated session
- Resume loads and validates
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`

---

## Task 6: Session module structure and re-exports

**Files:**
- `src/fae_llm/session/mod.rs` (new)
- `src/fae_llm/mod.rs` (add session module + re-exports)

**Description:**

Wire all session submodules together:

```rust
// src/fae_llm/session/mod.rs
pub mod context;
pub mod fs_store;
pub mod store;
pub mod types;
pub mod validation;

pub use context::ConversationContext;
pub use fs_store::FsSessionStore;
pub use store::{MemorySessionStore, SessionStore};
pub use types::{Session, SessionId, SessionMeta, SessionResumeError};
pub use validation::{CURRENT_SCHEMA_VERSION, validate_session, validate_message_sequence};
```

Update `src/fae_llm/mod.rs`:
- Add `pub mod session;`
- Add re-exports for key session types

**Tests:**
- `session_types_accessible_from_fae_llm`
- `all_session_types_are_send_sync`
- Verify doc comments compile

**Acceptance:**
- All session types accessible from `fae::fae_llm::session::*`
- Key types re-exported from `fae::fae_llm::*`
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`
- `cargo doc --all-features --no-deps` passes

---

## Task 7: Session lifecycle integration tests

**Files:**
- `src/fae_llm/session/mod.rs` (add integration_tests module)

**Description:**

End-to-end integration tests covering the full session lifecycle:

1. **Create → send → persist → resume → send → verify**
   - Create ConversationContext with MemorySessionStore
   - Send user message, verify response
   - Extract session ID
   - Resume with new ConversationContext from same store
   - Send follow-up, verify conversation history preserved

2. **Filesystem round-trip**
   - Create ConversationContext with FsSessionStore (tempdir)
   - Send messages
   - Create new FsSessionStore on same dir
   - Resume, verify messages intact

3. **Corrupted session recovery**
   - Manually corrupt session JSON in FsSessionStore
   - Attempt resume, verify SessionError returned
   - Verify error is typed (SessionResumeError::Corrupted)

4. **Multiple concurrent sessions**
   - Create 3 sessions in same store
   - Send messages to each
   - List sessions, verify all 3 exist
   - Delete one, verify 2 remain

5. **Session with tool calls**
   - Create context with mock tool-calling provider
   - Send message that triggers tool call
   - Resume session
   - Verify tool call + result messages preserved

**Tests:**
- `integration_create_send_resume_send`
- `integration_fs_round_trip`
- `integration_corrupted_session_recovery`
- `integration_multiple_concurrent_sessions`
- `integration_session_with_tool_calls`

**Acceptance:**
- All integration tests pass
- Full lifecycle verified
- `cargo check && cargo clippy -- -D warnings && cargo nextest run`

---

## Task 8: Final validation, cleanup, and documentation

**Files:**
- All session module files (doc cleanup)
- `src/fae_llm/mod.rs` (verify re-exports)

**Description:**

Final pass:
1. Run full validation: `just check` (or cargo fmt + clippy + test + doc)
2. Verify all public items have doc comments
3. Verify all doc examples compile
4. Verify zero warnings from `cargo doc --all-features --no-deps`
5. Verify zero clippy warnings
6. Clean up any unused imports
7. Verify no `.unwrap()` or `.expect()` in production code
8. Verify all types are Send + Sync

**Tests:**
- Run full test suite: `cargo nextest run --all-features`
- Verify test count increased

**Acceptance:**
- `just check` passes (or full manual validation)
- Zero warnings
- Zero test failures
- All public APIs documented
- Session module fully integrated

---

## Summary

**Task dependency order:**
1. Task 1 (types + error) — standalone
2. Task 2 (store trait + memory impl) — depends on Task 1
3. Task 3 (fs store) — depends on Task 1, 2
4. Task 4 (validation) — depends on Task 1
5. Task 5 (ConversationContext) — depends on Task 1, 2, 4
6. Task 6 (module wiring) — depends on Task 1-5
7. Task 7 (integration tests) — depends on all
8. Task 8 (final validation) — depends on all

**Total new code:** ~800-1000 lines across 6 new files
**Total new tests:** ~40-50 tests
