//! Session persistence and replay for agent conversations.
//!
//! This module provides session storage, validation, and context management
//! for persisting multi-turn agent conversations across restarts.
//!
//! # Submodules
//!
//! - [`types`] — Core types: [`Session`], [`SessionMeta`], [`SessionResumeError`]
//! - [`store`] — Storage trait and in-memory implementation

pub mod store;
pub mod types;

pub use store::{MemorySessionStore, SessionStore};
pub use types::{Session, SessionId, SessionMeta, SessionResumeError, CURRENT_SCHEMA_VERSION};
