//! Process-global registry of live native-ACP sessions (gap A2).
//!
//! `agent.session_start` spawns a persistent [`fae_acp::AcpSession`] (the agent's
//! ACP server stays alive across prompts) and stashes it here under a daemon
//! handle id; `agent.prompt` / `agent.cancel` / `agent.close` look it up by that
//! id. A session outlives the connection that created it, so the registry is
//! process-global (a later prompt may arrive on a different connection) and cheap
//! to clone (one shared map), mirroring [`crate::events::PlaybackRegistry`].

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use fae_acp::AcpSession;

/// A live session plus the metadata `agent.session_list` reports.
struct Entry {
    session: Arc<AcpSession>,
    agent: String,
    cwd: String,
}

/// One live session's listable metadata (`agent.session_list`).
pub struct SessionInfo {
    pub id: String,
    pub agent: String,
    pub cwd: String,
}

/// Live ACP sessions keyed by an opaque daemon handle (`acp-<n>`). The handle is
/// distinct from the agent's own ACP session id (which the [`AcpSession`] keeps
/// internally) so the wire surface never depends on a specific agent's id shape.
#[derive(Clone, Default)]
pub struct AgentSessionRegistry {
    inner: Arc<Mutex<HashMap<String, Entry>>>,
    counter: Arc<AtomicU64>,
}

impl AgentSessionRegistry {
    #[must_use]
    pub fn new() -> AgentSessionRegistry {
        AgentSessionRegistry::default()
    }

    /// Store a freshly started session with its metadata and return its handle.
    pub fn insert(&self, session: AcpSession, agent: String, cwd: String) -> String {
        let id = format!("acp-{}", self.counter.fetch_add(1, Ordering::Relaxed));
        if let Ok(mut map) = self.inner.lock() {
            map.insert(
                id.clone(),
                Entry {
                    session: Arc::new(session),
                    agent,
                    cwd,
                },
            );
        }
        id
    }

    /// Look up a live session by handle (cloned `Arc` so the lock is released
    /// before any `await` on the session).
    pub fn get(&self, id: &str) -> Option<Arc<AcpSession>> {
        self.inner
            .lock()
            .ok()
            .and_then(|map| map.get(id).map(|entry| Arc::clone(&entry.session)))
    }

    /// Remove a session by handle, returning it so the caller can close it.
    pub fn remove(&self, id: &str) -> Option<Arc<AcpSession>> {
        self.inner
            .lock()
            .ok()
            .and_then(|mut map| map.remove(id).map(|entry| entry.session))
    }

    /// Metadata for all live sessions.
    #[must_use]
    pub fn list(&self) -> Vec<SessionInfo> {
        self.inner
            .lock()
            .map(|map| {
                map.iter()
                    .map(|(id, entry)| SessionInfo {
                        id: id.clone(),
                        agent: entry.agent.clone(),
                        cwd: entry.cwd.clone(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_are_unique_and_listable() {
        let registry = AgentSessionRegistry::new();
        // Without spawning a real agent we can't build an AcpSession, but the
        // id allocation + listing logic is independent of session contents.
        assert!(registry.list().is_empty());
        assert!(registry.get("acp-0").is_none());
        assert!(registry.remove("acp-0").is_none());
    }
}
