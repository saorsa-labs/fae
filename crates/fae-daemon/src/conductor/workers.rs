//! Vetted worker registry. The static policy may **only** select workers from
//! this registry — there is no runtime auto-discovery, and no path by which an
//! arbitrary ACP session or remote endpoint becomes routable.
//!
//! M1 registry: `local-model` only (the daemon's loaded `ProviderAdapter`).
//! Adding a vetted local-ACP worker is an explicit code change, not a runtime
//! discovery. This is the spec's "vetted registry" guarantee (§6.2) and the
//! `direct`-default byte-identity contract (§8): the only executable worker in
//! M1 resolves to the same engine `inject_text_core` uses today.

use std::collections::HashSet;

/// The canonical M1 worker id. Resolves to the daemon's loaded engine.
pub const LOCAL_MODEL_WORKER_ID: &str = "local-model";

/// Compile-time-vetted set of worker ids the conductor may route to.
#[derive(Debug, Clone)]
pub struct WorkerRegistry {
    ids: HashSet<String>,
}

impl Default for WorkerRegistry {
    /// M1 default: only the local model is routable.
    fn default() -> Self {
        Self::m1()
    }
}

impl WorkerRegistry {
    /// The M1 registry — `local-model` only.
    pub fn m1() -> Self {
        let mut ids = HashSet::new();
        ids.insert(LOCAL_MODEL_WORKER_ID.to_string());
        Self { ids }
    }

    /// Whether `id` is a known, vetted worker.
    pub fn contains(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    /// Number of registered workers.
    #[allow(dead_code)] // exercised in unit tests; M2 worker introspection surfaces it
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    /// Whether the registry is empty.
    #[allow(dead_code)] // exercised in unit tests; M2 worker introspection surfaces it
    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn m1_registry_has_only_local_model() {
        let r = WorkerRegistry::m1();
        assert!(r.contains(LOCAL_MODEL_WORKER_ID));
        assert_eq!(r.len(), 1);
        // No remote / ACP / peer ids are routable.
        assert!(!r.contains("remote-gpt4"));
        assert!(!r.contains("x0x-peer"));
        assert!(!r.contains("acp-session-1"));
    }
}
