//! Filesystem-backed session store.
//!
//! Implements [`SessionStore`] with JSON files on disk. Each session is
//! stored as `{data_dir}/{session_id}.json`. Writes are atomic (temp file
//! + fsync + rename) to prevent corruption on crash.
//!
//! # Examples
//!
//! ```no_run
//! use fae::fae_llm::session::fs_store::FsSessionStore;
//!
//! let store = FsSessionStore::new("/tmp/fae-sessions").unwrap();
//! ```

use std::path::{Path, PathBuf};

use async_trait::async_trait;

use super::store::SessionStore;
use super::types::{Session, SessionId, SessionMeta};
use crate::fae_llm::error::FaeLlmError;

/// Filesystem-backed session store.
///
/// Sessions are stored as `{data_dir}/{session_id}.json` with atomic
/// writes (temp file -> fsync -> rename) for crash safety.
#[derive(Debug, Clone)]
pub struct FsSessionStore {
    data_dir: PathBuf,
}

impl FsSessionStore {
    /// Create a new filesystem session store.
    ///
    /// Creates the data directory if it does not exist.
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError::SessionError`] if the directory cannot be created.
    pub fn new(data_dir: impl Into<PathBuf>) -> Result<Self, FaeLlmError> {
        let data_dir = data_dir.into();
        std::fs::create_dir_all(&data_dir).map_err(|e| {
            FaeLlmError::SessionError(format!(
                "failed to create session directory {}: {e}",
                data_dir.display()
            ))
        })?;
        Ok(Self { data_dir })
    }

    /// Returns the path to a session file.
    fn session_path(&self, id: &str) -> PathBuf {
        self.data_dir.join(format!("{id}.json"))
    }

    /// Returns the data directory path.
    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    /// Read and parse a session file from disk.
    fn read_session_file(&self, path: &Path) -> Result<Session, FaeLlmError> {
        let content = std::fs::read_to_string(path).map_err(|e| {
            FaeLlmError::SessionError(format!(
                "failed to read session file {}: {e}",
                path.display()
            ))
        })?;
        serde_json::from_str(&content).map_err(|e| {
            FaeLlmError::SessionError(format!(
                "failed to parse session file {}: {e}",
                path.display()
            ))
        })
    }

    /// Atomically write a session to disk.
    ///
    /// Writes to a temp file, fsyncs, then renames for crash safety.
    fn write_session_atomic(&self, session: &Session) -> Result<(), FaeLlmError> {
        let path = self.session_path(&session.meta.id);
        let json = serde_json::to_string_pretty(session)
            .map_err(|e| FaeLlmError::SessionError(format!("failed to serialize session: {e}")))?;

        // Write to temp file in the same directory (for atomic rename)
        let tmp_path = self.data_dir.join(format!(".{}.tmp", session.meta.id));
        std::fs::write(&tmp_path, json.as_bytes()).map_err(|e| {
            FaeLlmError::SessionError(format!(
                "failed to write temp file {}: {e}",
                tmp_path.display()
            ))
        })?;

        // fsync the file
        if let Ok(file) = std::fs::File::open(&tmp_path) {
            let _ = file.sync_all();
        }

        // Atomic rename
        std::fs::rename(&tmp_path, &path).map_err(|e| {
            FaeLlmError::SessionError(format!(
                "failed to rename temp file to {}: {e}",
                path.display()
            ))
        })?;

        Ok(())
    }
}

/// Generate a unique session ID (same logic as MemorySessionStore).
fn generate_session_id() -> SessionId {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let suffix = rand_suffix();
    format!("sess_{now}_{suffix:06}")
}

/// Generate a pseudo-random 6-digit suffix.
fn rand_suffix() -> u32 {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let thread_id = std::thread::current().id();
    let hash = now.wrapping_mul(6364136223846793005).wrapping_add(
        format!("{thread_id:?}")
            .bytes()
            .fold(0u128, |acc, b| acc.wrapping_mul(31).wrapping_add(b as u128)),
    );
    (hash % 1_000_000) as u32
}

#[async_trait]
impl SessionStore for FsSessionStore {
    async fn create(&self, system_prompt: Option<&str>) -> Result<SessionId, FaeLlmError> {
        let id = generate_session_id();
        let session = Session::new(id.clone(), system_prompt.map(String::from), None);
        self.write_session_atomic(&session)?;
        Ok(id)
    }

    async fn load(&self, id: &str) -> Result<Session, FaeLlmError> {
        let path = self.session_path(id);
        if !path.exists() {
            return Err(FaeLlmError::SessionError(format!(
                "session not found: {id}"
            )));
        }
        self.read_session_file(&path)
    }

    async fn save(&self, session: &Session) -> Result<(), FaeLlmError> {
        self.write_session_atomic(session)
    }

    async fn delete(&self, id: &str) -> Result<(), FaeLlmError> {
        let path = self.session_path(id);
        if path.exists() {
            std::fs::remove_file(&path).map_err(|e| {
                FaeLlmError::SessionError(format!(
                    "failed to delete session file {}: {e}",
                    path.display()
                ))
            })?;
        }
        Ok(())
    }

    async fn list(&self) -> Result<Vec<SessionMeta>, FaeLlmError> {
        let mut metas = Vec::new();
        let entries = std::fs::read_dir(&self.data_dir).map_err(|e| {
            FaeLlmError::SessionError(format!(
                "failed to read session directory {}: {e}",
                self.data_dir.display()
            ))
        })?;

        for entry in entries {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            // Skip temp files
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|name| name.starts_with('.'))
            {
                continue;
            }
            match self.read_session_file(&path) {
                Ok(session) => metas.push(session.meta),
                Err(_) => continue, // Skip unreadable files
            }
        }

        Ok(metas)
    }

    async fn exists(&self, id: &str) -> Result<bool, FaeLlmError> {
        Ok(self.session_path(id).exists())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::providers::message::Message;
    use crate::fae_llm::session::types::CURRENT_SCHEMA_VERSION;

    fn temp_store() -> (tempfile::TempDir, FsSessionStore) {
        let dir =
            tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir creation succeeded"));
        let store = FsSessionStore::new(dir.path())
            .unwrap_or_else(|_| unreachable!("store creation succeeded"));
        (dir, store)
    }

    #[tokio::test]
    async fn fs_store_create_and_load() {
        let (_dir, store) = temp_store();
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
        assert_eq!(session.meta.id, id);
        assert_eq!(session.meta.system_prompt.as_deref(), Some("Be helpful."));
        assert_eq!(session.meta.schema_version, CURRENT_SCHEMA_VERSION);
    }

    #[tokio::test]
    async fn fs_store_save_persists_to_disk() {
        let (_dir, store) = temp_store();
        let mut session = Session::new("persist_test", None, None);
        session.push_message(Message::user("hello"));
        session.push_message(Message::assistant("hi there"));

        let save = store.save(&session).await;
        assert!(save.is_ok());

        // Verify file exists on disk
        let path = store.session_path("persist_test");
        assert!(path.exists());

        // Read back
        let loaded = store.load("persist_test").await;
        assert!(loaded.is_ok());
        let loaded = match loaded {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert_eq!(loaded.messages.len(), 2);
    }

    #[tokio::test]
    async fn fs_store_load_not_found() {
        let (_dir, store) = temp_store();
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
    async fn fs_store_delete_removes_file() {
        let (_dir, store) = temp_store();
        let id = store.create(None).await;
        assert!(id.is_ok());
        let id = match id {
            Ok(i) => i,
            Err(_) => unreachable!("create succeeded"),
        };

        let path = store.session_path(&id);
        assert!(path.exists());

        let del = store.delete(&id).await;
        assert!(del.is_ok());
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn fs_store_delete_nonexistent_is_ok() {
        let (_dir, store) = temp_store();
        let result = store.delete("nonexistent").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn fs_store_list_sessions() {
        let (_dir, store) = temp_store();

        // Create multiple sessions
        let id1 = store.create(None).await;
        assert!(id1.is_ok());
        let id2 = store.create(Some("prompt")).await;
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
    async fn fs_store_list_empty() {
        let (_dir, store) = temp_store();
        let metas = store.list().await;
        assert!(metas.is_ok());
        let metas = match metas {
            Ok(m) => m,
            Err(_) => unreachable!("list succeeded"),
        };
        assert!(metas.is_empty());
    }

    #[tokio::test]
    async fn fs_store_exists() {
        let (_dir, store) = temp_store();
        let exists_before = store.exists("test_exist").await;
        assert!(matches!(exists_before, Ok(false)));

        let session = Session::new("test_exist", None, None);
        let save = store.save(&session).await;
        assert!(save.is_ok());

        let exists_after = store.exists("test_exist").await;
        assert!(matches!(exists_after, Ok(true)));
    }

    #[tokio::test]
    async fn fs_store_atomic_write_creates_file() {
        let (_dir, store) = temp_store();
        let session = Session::new("atomic_test", None, None);
        let result = store.write_session_atomic(&session);
        assert!(result.is_ok());

        let path = store.session_path("atomic_test");
        assert!(path.exists());

        // Verify no temp file lingering
        let tmp_path = store.data_dir.join(".atomic_test.tmp");
        assert!(!tmp_path.exists());
    }

    #[tokio::test]
    async fn fs_store_corrupted_file_returns_error() {
        let (dir, store) = temp_store();
        // Write garbage to a session file
        let bad_path = dir.path().join("bad_session.json");
        std::fs::write(&bad_path, "not valid json {{{")
            .unwrap_or_else(|_| unreachable!("write succeeded"));

        let result = store.load("bad_session").await;
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("load should fail"),
        };
        assert_eq!(err.code(), "SESSION_ERROR");
        assert!(err.message().contains("parse"));
    }

    #[tokio::test]
    async fn fs_store_overwrite_preserves_data() {
        let (_dir, store) = temp_store();
        let mut session = Session::new("overwrite_test", None, None);
        let save1 = store.save(&session).await;
        assert!(save1.is_ok());

        session.push_message(Message::user("added later"));
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
    async fn fs_store_list_skips_temp_files() {
        let (dir, store) = temp_store();
        // Create a normal session
        let id = store.create(None).await;
        assert!(id.is_ok());

        // Create a temp file that should be skipped
        let tmp_path = dir.path().join(".temp_session.tmp");
        std::fs::write(&tmp_path, "{}").unwrap_or_else(|_| unreachable!("write succeeded"));

        let metas = store.list().await;
        assert!(metas.is_ok());
        let metas = match metas {
            Ok(m) => m,
            Err(_) => unreachable!("list succeeded"),
        };
        assert_eq!(metas.len(), 1); // Only the real session, not the temp file
    }

    #[tokio::test]
    async fn fs_store_with_tool_calls() {
        let (_dir, store) = temp_store();
        let mut session = Session::new("tool_test", None, None);

        let tool_calls = vec![crate::fae_llm::providers::message::AssistantToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: r#"{"path":"test.rs"}"#.into(),
        }];
        session.push_message(Message::assistant_with_tool_calls(
            Some("Reading...".into()),
            tool_calls,
        ));
        session.push_message(Message::tool_result("call_1", "fn main() {}"));

        let save = store.save(&session).await;
        assert!(save.is_ok());

        let loaded = store.load("tool_test").await;
        assert!(loaded.is_ok());
        let loaded = match loaded {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert_eq!(loaded.messages.len(), 2);
        assert_eq!(loaded.messages[0].tool_calls.len(), 1);
    }

    #[test]
    fn fs_store_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<FsSessionStore>();
    }

    #[test]
    fn fs_store_data_dir_accessor() {
        let dir = tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir succeeded"));
        let store =
            FsSessionStore::new(dir.path()).unwrap_or_else(|_| unreachable!("store succeeded"));
        assert_eq!(store.data_dir(), dir.path());
    }

    #[test]
    fn fs_store_debug() {
        let dir = tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir succeeded"));
        let store =
            FsSessionStore::new(dir.path()).unwrap_or_else(|_| unreachable!("store succeeded"));
        let debug = format!("{store:?}");
        assert!(debug.contains("FsSessionStore"));
    }

    #[test]
    fn fs_store_clone() {
        let dir = tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir succeeded"));
        let store =
            FsSessionStore::new(dir.path()).unwrap_or_else(|_| unreachable!("store succeeded"));
        let cloned = store.clone();
        assert_eq!(store.data_dir(), cloned.data_dir());
    }

    #[test]
    fn fs_store_creates_missing_directory() {
        let dir = tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir succeeded"));
        let nested = dir.path().join("a").join("b").join("c");
        let store = FsSessionStore::new(&nested);
        assert!(store.is_ok());
        assert!(nested.exists());
    }
}
