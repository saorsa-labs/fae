//! Session storage trait and in-memory implementation.
//!
//! Defines the [`SessionStore`] trait for async session CRUD operations,
//! and provides [`MemorySessionStore`] for testing and ephemeral usage.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::session::store::MemorySessionStore;
//!
//! let store = MemorySessionStore::new();
//! let store2 = store.clone();
//! assert_eq!(format!("{store:?}").contains("MemorySessionStore"), true);
//! ```

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::RwLock;

use super::types::{Session, SessionId, SessionMeta};
use crate::fae_llm::error::FaeLlmError;

/// Async session storage backend.
///
/// Implementations persist sessions across application restarts.
/// All methods are async to support both in-memory and filesystem backends.
#[async_trait]
pub trait SessionStore: Send + Sync {
    /// Create a new empty session, returning its generated ID.
    async fn create(&self, system_prompt: Option<&str>) -> Result<SessionId, FaeLlmError>;

    /// Load a session by ID.
    ///
    /// Returns `SessionError` if the session does not exist or is corrupted.
    async fn load(&self, id: &str) -> Result<Session, FaeLlmError>;

    /// Save (overwrite) a session.
    async fn save(&self, session: &Session) -> Result<(), FaeLlmError>;

    /// Delete a session by ID.
    ///
    /// Returns `Ok(())` even if the session did not exist.
    async fn delete(&self, id: &str) -> Result<(), FaeLlmError>;

    /// List metadata for all stored sessions.
    async fn list(&self) -> Result<Vec<SessionMeta>, FaeLlmError>;

    /// Check if a session with the given ID exists.
    async fn exists(&self, id: &str) -> Result<bool, FaeLlmError>;
}

/// In-memory session store for testing and ephemeral usage.
///
/// Sessions are stored in an `Arc<RwLock<HashMap>>` and are lost when
/// the store is dropped. Thread-safe and cheaply cloneable.
#[derive(Debug, Clone)]
pub struct MemorySessionStore {
    sessions: Arc<RwLock<HashMap<SessionId, Session>>>,
}

impl MemorySessionStore {
    /// Create a new empty in-memory store.
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }
}

impl Default for MemorySessionStore {
    fn default() -> Self {
        Self::new()
    }
}

/// Generate a unique session ID.
///
/// Format: `sess_{unix_millis}_{random_suffix}`
fn generate_session_id() -> SessionId {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let suffix: u32 = rand_suffix();
    format!("sess_{now}_{suffix:06}")
}

/// Generate a pseudo-random 6-digit suffix.
///
/// Uses a simple hash of the current time + thread ID for uniqueness
/// without pulling in a full RNG crate.
fn rand_suffix() -> u32 {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let thread_id = std::thread::current().id();
    let hash = now.wrapping_mul(6364136223846793005).wrapping_add(
        // Mix in thread ID via Debug format (stable across platforms)
        format!("{thread_id:?}")
            .bytes()
            .fold(0u128, |acc, b| acc.wrapping_mul(31).wrapping_add(b as u128)),
    );
    (hash % 1_000_000) as u32
}

#[async_trait]
impl SessionStore for MemorySessionStore {
    async fn create(&self, system_prompt: Option<&str>) -> Result<SessionId, FaeLlmError> {
        let id = generate_session_id();
        let session = Session::new(
            id.clone(),
            system_prompt.map(String::from),
            None,
        );
        let mut sessions = self.sessions.write().await;
        sessions.insert(id.clone(), session);
        Ok(id)
    }

    async fn load(&self, id: &str) -> Result<Session, FaeLlmError> {
        let sessions = self.sessions.read().await;
        sessions
            .get(id)
            .cloned()
            .ok_or_else(|| FaeLlmError::SessionError(format!("session not found: {id}")))
    }

    async fn save(&self, session: &Session) -> Result<(), FaeLlmError> {
        let mut sessions = self.sessions.write().await;
        sessions.insert(session.meta.id.clone(), session.clone());
        Ok(())
    }

    async fn delete(&self, id: &str) -> Result<(), FaeLlmError> {
        let mut sessions = self.sessions.write().await;
        sessions.remove(id);
        Ok(())
    }

    async fn list(&self) -> Result<Vec<SessionMeta>, FaeLlmError> {
        let sessions = self.sessions.read().await;
        let metas: Vec<SessionMeta> = sessions.values().map(|s| s.meta.clone()).collect();
        Ok(metas)
    }

    async fn exists(&self, id: &str) -> Result<bool, FaeLlmError> {
        let sessions = self.sessions.read().await;
        Ok(sessions.contains_key(id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::types::CURRENT_SCHEMA_VERSION;

    #[tokio::test]
    async fn memory_store_create_returns_id() {
        let store = MemorySessionStore::new();
        let id = store.create(None).await;
        assert!(id.is_ok());
        let id = match id {
            Ok(i) => i,
            Err(_) => unreachable!("create succeeded"),
        };
        assert!(id.starts_with("sess_"));
    }

    #[tokio::test]
    async fn memory_store_create_with_system_prompt() {
        let store = MemorySessionStore::new();
        let id = store.create(Some("Be helpful.")).await;
        assert!(id.is_ok());
        let id = match id {
            Ok(i) => i,
            Err(_) => unreachable!("create succeeded"),
        };
        let session = store.load(&id).await;
        assert!(session.is_ok());
        let session = match session {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert_eq!(session.meta.system_prompt.as_deref(), Some("Be helpful."));
    }

    #[tokio::test]
    async fn memory_store_save_and_load() {
        let store = MemorySessionStore::new();
        let mut session = Session::new("test_001", None, None);
        session.push_message(crate::fae_llm::providers::message::Message::user("hello"));

        let save_result = store.save(&session).await;
        assert!(save_result.is_ok());

        let loaded = store.load("test_001").await;
        assert!(loaded.is_ok());
        let loaded = match loaded {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert_eq!(loaded.meta.id, "test_001");
        assert_eq!(loaded.messages.len(), 1);
    }

    #[tokio::test]
    async fn memory_store_load_not_found() {
        let store = MemorySessionStore::new();
        let result = store.load("nonexistent").await;
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("load should fail"),
        };
        assert_eq!(err.code(), "SESSION_ERROR");
        assert!(err.message().contains("not found"));
    }

    #[tokio::test]
    async fn memory_store_delete() {
        let store = MemorySessionStore::new();
        let id = store.create(None).await;
        assert!(id.is_ok());
        let id = match id {
            Ok(i) => i,
            Err(_) => unreachable!("create succeeded"),
        };

        let exists = store.exists(&id).await;
        assert!(matches!(exists, Ok(true)));

        let del = store.delete(&id).await;
        assert!(del.is_ok());

        let exists = store.exists(&id).await;
        assert!(matches!(exists, Ok(false)));
    }

    #[tokio::test]
    async fn memory_store_delete_nonexistent_is_ok() {
        let store = MemorySessionStore::new();
        let result = store.delete("nonexistent").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn memory_store_list() {
        let store = MemorySessionStore::new();
        let id1 = store.create(None).await;
        let id2 = store.create(Some("prompt")).await;
        assert!(id1.is_ok());
        assert!(id2.is_ok());

        let metas = store.list().await;
        assert!(metas.is_ok());
        let metas = match metas {
            Ok(m) => m,
            Err(_) => unreachable!("list succeeded"),
        };
        assert_eq!(metas.len(), 2);
    }

    #[tokio::test]
    async fn memory_store_list_empty() {
        let store = MemorySessionStore::new();
        let metas = store.list().await;
        assert!(metas.is_ok());
        let metas = match metas {
            Ok(m) => m,
            Err(_) => unreachable!("list succeeded"),
        };
        assert!(metas.is_empty());
    }

    #[tokio::test]
    async fn memory_store_exists() {
        let store = MemorySessionStore::new();
        let exists_before = store.exists("test_exist").await;
        assert!(matches!(exists_before, Ok(false)));

        let session = Session::new("test_exist", None, None);
        let save = store.save(&session).await;
        assert!(save.is_ok());

        let exists_after = store.exists("test_exist").await;
        assert!(matches!(exists_after, Ok(true)));
    }

    #[tokio::test]
    async fn memory_store_overwrite() {
        let store = MemorySessionStore::new();
        let mut session = Session::new("overwrite_test", None, None);
        let save1 = store.save(&session).await;
        assert!(save1.is_ok());

        session.push_message(crate::fae_llm::providers::message::Message::user("added"));
        let save2 = store.save(&session).await;
        assert!(save2.is_ok());

        let loaded = store.load("overwrite_test").await;
        assert!(loaded.is_ok());
        let loaded = match loaded {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert_eq!(loaded.messages.len(), 1);
    }

    #[tokio::test]
    async fn memory_store_schema_version_set() {
        let store = MemorySessionStore::new();
        let id = store.create(None).await;
        assert!(id.is_ok());
        let id = match id {
            Ok(i) => i,
            Err(_) => unreachable!("create succeeded"),
        };
        let session = store.load(&id).await;
        assert!(session.is_ok());
        let session = match session {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert_eq!(session.meta.schema_version, CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn memory_store_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<MemorySessionStore>();
    }

    #[test]
    fn memory_store_clone() {
        let store = MemorySessionStore::new();
        let _cloned = store.clone();
    }

    #[test]
    fn memory_store_default() {
        let store = MemorySessionStore::default();
        let debug = format!("{store:?}");
        assert!(debug.contains("MemorySessionStore"));
    }

    #[test]
    fn generate_session_id_format() {
        let id = generate_session_id();
        assert!(id.starts_with("sess_"));
        // Should have format sess_{millis}_{6digits}
        let parts: Vec<&str> = id.splitn(3, '_').collect();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[0], "sess");
    }

    #[test]
    fn generate_session_id_unique() {
        let id1 = generate_session_id();
        // Small sleep to ensure different timestamp
        std::thread::sleep(std::time::Duration::from_millis(1));
        let id2 = generate_session_id();
        assert_ne!(id1, id2);
    }

    #[test]
    fn session_store_is_object_safe() {
        // Verify the trait can be used as a trait object
        fn _takes_dyn_store(_store: &dyn SessionStore) {}
        fn _takes_arc_store(_store: Arc<dyn SessionStore>) {}
    }
}
