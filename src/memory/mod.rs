//! Persistent memory system for Fae.
//!
//! Sub-modules:
//! - `types`: Shared types, constants, enums, and helpers (backend-agnostic).
//! - `jsonl`: JSONL-backed `MemoryRepository`, `MemoryOrchestrator`, and legacy
//!   markdown identity store.
//!
//! Future modules (Phase 7.1+):
//! - `schema`: SQLite DDL definitions.
//! - `sqlite`: SQLite-backed `SqliteMemoryRepository`.

pub mod jsonl;
pub mod types;

// Re-export everything the rest of the codebase imports from `crate::memory::*`.
// This ensures zero caller changes after the module split.

// Types
pub use types::{
    MemoryAuditEntry, MemoryAuditOp, MemoryCaptureReport, MemoryConflictSummary, MemoryKind,
    MemoryRecord, MemorySearchHit, MemoryStatus, MemoryWriteSummary,
};

// Public functions
pub use types::{current_memory_schema_version, default_memory_root_dir};

// JSONL implementation
pub use jsonl::{
    MemoryOrchestrator, MemoryRepository, MemoryStore, Person, PrimaryUser,
};

// JSONL free functions
pub use jsonl::{
    run_memory_gc, run_memory_migration, run_memory_reindex, run_memory_reflection,
};
