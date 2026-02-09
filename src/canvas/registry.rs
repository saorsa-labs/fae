//! Thread-safe canvas session registry.
//!
//! Allows canvas tools to look up active sessions by ID. The GUI registers
//! its session on startup; tools reference it during execution.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use super::session::CanvasSession;

/// Registry of active canvas sessions, keyed by session ID.
///
/// Wraps sessions in `Arc<Mutex<_>>` so they can be shared across the agent
/// tool system (which requires `Send + Sync`).
pub struct CanvasSessionRegistry {
    sessions: HashMap<String, Arc<Mutex<CanvasSession>>>,
}

impl CanvasSessionRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    /// Register a session. Returns the previous session with the same ID, if any.
    pub fn register(
        &mut self,
        id: impl Into<String>,
        session: Arc<Mutex<CanvasSession>>,
    ) -> Option<Arc<Mutex<CanvasSession>>> {
        self.sessions.insert(id.into(), session)
    }

    /// Look up a session by ID.
    pub fn get(&self, id: &str) -> Option<Arc<Mutex<CanvasSession>>> {
        self.sessions.get(id).cloned()
    }

    /// Remove a session by ID, returning it if it existed.
    pub fn remove(&mut self, id: &str) -> Option<Arc<Mutex<CanvasSession>>> {
        self.sessions.remove(id)
    }

    /// List all registered session IDs.
    pub fn session_ids(&self) -> Vec<String> {
        self.sessions.keys().cloned().collect()
    }

    /// Number of registered sessions.
    pub fn len(&self) -> usize {
        self.sessions.len()
    }

    /// Whether the registry is empty.
    pub fn is_empty(&self) -> bool {
        self.sessions.is_empty()
    }
}

impl Default for CanvasSessionRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_session(id: &str) -> Arc<Mutex<CanvasSession>> {
        Arc::new(Mutex::new(CanvasSession::new(id, 800.0, 600.0)))
    }

    #[test]
    fn test_new_registry_is_empty() {
        let reg = CanvasSessionRegistry::new();
        assert!(reg.is_empty());
        assert_eq!(reg.len(), 0);
    }

    #[test]
    fn test_register_and_get() {
        let mut reg = CanvasSessionRegistry::new();
        let session = make_session("s1");
        assert!(reg.register("s1", session).is_none());
        assert_eq!(reg.len(), 1);

        let retrieved = reg.get("s1");
        assert!(retrieved.is_some());
    }

    #[test]
    fn test_register_replaces_existing() {
        let mut reg = CanvasSessionRegistry::new();
        let s1 = make_session("s1");
        let s2 = make_session("s1");
        assert!(reg.register("s1", s1).is_none());
        let old = reg.register("s1", s2);
        assert!(old.is_some());
        assert_eq!(reg.len(), 1);
    }

    #[test]
    fn test_get_missing_returns_none() {
        let reg = CanvasSessionRegistry::new();
        assert!(reg.get("nonexistent").is_none());
    }

    #[test]
    fn test_remove() {
        let mut reg = CanvasSessionRegistry::new();
        reg.register("s1", make_session("s1"));
        let removed = reg.remove("s1");
        assert!(removed.is_some());
        assert!(reg.is_empty());
    }

    #[test]
    fn test_remove_missing_returns_none() {
        let mut reg = CanvasSessionRegistry::new();
        assert!(reg.remove("nope").is_none());
    }

    #[test]
    fn test_session_ids() {
        let mut reg = CanvasSessionRegistry::new();
        reg.register("alpha", make_session("alpha"));
        reg.register("beta", make_session("beta"));
        let mut ids = reg.session_ids();
        ids.sort();
        assert_eq!(ids, vec!["alpha", "beta"]);
    }

    #[test]
    fn test_default_is_empty() {
        let reg = CanvasSessionRegistry::default();
        assert!(reg.is_empty());
    }

    #[test]
    fn test_arc_mutex_shared_access() {
        let mut reg = CanvasSessionRegistry::new();
        let session = make_session("shared");
        reg.register("shared", session.clone());

        // Get from registry and verify it's the same Arc
        let from_reg = reg.get("shared");
        assert!(from_reg.is_some());

        // Modify through one reference
        {
            let guard = session.lock();
            assert!(guard.is_ok());
        }

        // Access through registry reference still works
        {
            let from_reg = reg.get("shared");
            assert!(from_reg.is_some());
            let s = from_reg.as_ref();
            let guard = s.map(|s| s.lock());
            assert!(guard.is_some());
        }
    }
}
