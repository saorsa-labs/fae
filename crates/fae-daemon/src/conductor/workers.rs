//! Vetted worker registry. The static policy may **only** select workers from
//! this registry — there is no runtime auto-discovery, and no path by which an
//! arbitrary ACP session or remote endpoint becomes routable.
//!
//! M2 Stage 1 keeps `local-model` always present and admits cloud-backed ACP
//! worker ids only as explicit, startup-vetted registrations. A provisioned
//! credential is represented as a boolean grant state; the registry never stores
//! credential material.

use std::collections::HashMap;

use crate::conductor::recipe::WorkerLocality;

/// The canonical local worker id. Resolves to the daemon's loaded engine.
pub const LOCAL_MODEL_WORKER_ID: &str = "local-model";

/// Vetted worker ids used by the native ACP/cloud seams.
pub const CODEX_CLOUD_WORKER_ID: &str = "acp:codex";
pub const CLAUDE_CLOUD_WORKER_ID: &str = "acp:claude";
pub const GEMINI_CLOUD_WORKER_ID: &str = "acp:gemini";
pub const COPILOT_CLOUD_WORKER_ID: &str = "acp:copilot";

/// ADR-014 cloud lane (`RemoteProvider` locality): the prefix for OpenRouter
/// remote-provider worker ids. The full id is `cloud:openrouter/<model>`, e.g.
/// `cloud:openrouter/openai/gpt-4.1-mini`.
pub const OPENROUTER_CLOUD_WORKER_PREFIX: &str = "cloud:openrouter/";

/// Build the canonical OpenRouter remote-provider worker id for `model`.
pub fn openrouter_worker_id(model: &str) -> String {
    format!("{OPENROUTER_CLOUD_WORKER_PREFIX}{model}")
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WorkerRegistration {
    locality: WorkerLocality,
    provisioned: bool,
}

/// Compile-time-vetted set of worker ids the conductor may route to.
#[derive(Debug, Clone)]
pub struct WorkerRegistry {
    workers: HashMap<String, WorkerRegistration>,
}

impl Default for WorkerRegistry {
    /// Safe default: only the local model is routable.
    fn default() -> Self {
        Self::m1()
    }
}

impl WorkerRegistry {
    /// The M1-compatible registry — `local-model` only.
    pub fn m1() -> Self {
        let mut workers = HashMap::new();
        workers.insert(
            LOCAL_MODEL_WORKER_ID.to_string(),
            WorkerRegistration {
                locality: WorkerLocality::LocalModel,
                provisioned: true,
            },
        );
        Self { workers }
    }

    /// Build a registry from startup credential presence. Only non-empty
    /// credentials add the corresponding cloud-backed worker; credential values
    /// are deliberately discarded.
    pub fn from_cloud_credentials<I>(credentials: I) -> Self
    where
        I: IntoIterator<Item = (&'static str, Option<String>)>,
    {
        let mut registry = Self::m1();
        for (worker_id, credential) in credentials {
            if credential
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            {
                registry.register_cloud_backed(worker_id, true);
            }
        }
        registry
    }

    /// Add a vetted cloud-backed ACP worker. Tests use `provisioned = false` to
    /// exercise the approval gate; production startup passes `true` only when a
    /// credential is present.
    pub fn register_cloud_backed(&mut self, id: impl Into<String>, provisioned: bool) {
        self.workers.insert(
            id.into(),
            WorkerRegistration {
                locality: WorkerLocality::CloudBackedAcp,
                provisioned,
            },
        );
    }

    /// Add a vetted same-owner fleet worker (x0x peer, the `OwnerFleet` lane).
    /// M4: the conductor treats a provisioned `OwnerFleet` worker as
    /// standing-grantable (Tier B), exactly like a credentialed cloud worker —
    /// the provisioning IS the consent (ADR-012 principle 2). Real mesh
    /// transport is dormant (M4-E); this registration is the policy/registry
    /// surface the gate pipeline consults.
    #[allow(dead_code)] // exercised in unit tests; M4-D executor dispatch wires production startup
    pub fn register_owner_fleet(&mut self, id: impl Into<String>, provisioned: bool) {
        self.workers.insert(
            id.into(),
            WorkerRegistration {
                locality: WorkerLocality::OwnerFleet,
                provisioned,
            },
        );
    }

    /// Add a vetted `RemoteProvider` worker (ADR-014 cloud lane, e.g. an
    /// OpenRouter model). Registered ONLY at startup when the owner has opted
    /// into the `RemoteAllowed` lane (`FAE_PRIVACY_LANE=all`) AND the OpenRouter
    /// credential is present; `provisioned = true` supplies the standing grant
    /// the non-local approval gate requires. The credential itself is never
    /// stored here — only the boolean grant state.
    pub fn register_remote_provider(&mut self, id: impl Into<String>, provisioned: bool) {
        self.workers.insert(
            id.into(),
            WorkerRegistration {
                locality: WorkerLocality::RemoteProvider,
                provisioned,
            },
        );
    }

    /// Whether `id` is a known, vetted worker.
    pub fn contains(&self, id: &str) -> bool {
        self.workers.contains_key(id)
    }

    /// Locality for a known worker.
    pub fn locality(&self, id: &str) -> Option<WorkerLocality> {
        self.workers
            .get(id)
            .map(|registration| registration.locality)
    }

    /// Whether a known worker has a provisioned standing grant credential.
    pub fn is_provisioned(&self, id: &str) -> bool {
        self.workers
            .get(id)
            .is_some_and(|registration| registration.provisioned)
    }

    /// Registered worker ids, stable-sorted for startup pricing defaults.
    pub fn worker_ids(&self) -> Vec<String> {
        let mut ids = self.workers.keys().cloned().collect::<Vec<_>>();
        ids.sort();
        ids
    }

    /// Number of registered workers.
    #[allow(dead_code)] // exercised in unit tests; M2 worker introspection surfaces it
    pub fn len(&self) -> usize {
        self.workers.len()
    }

    /// Whether the registry is empty.
    #[allow(dead_code)] // exercised in unit tests; M2 worker introspection surfaces it
    pub fn is_empty(&self) -> bool {
        self.workers.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn m1_registry_has_only_local_model() {
        let r = WorkerRegistry::m1();
        assert!(r.contains(LOCAL_MODEL_WORKER_ID));
        assert_eq!(
            r.locality(LOCAL_MODEL_WORKER_ID),
            Some(WorkerLocality::LocalModel)
        );
        assert!(r.is_provisioned(LOCAL_MODEL_WORKER_ID));
        assert_eq!(r.len(), 1);
        // No remote / ACP / peer ids are routable by default.
        assert!(!r.contains("remote-gpt4"));
        assert!(!r.contains("x0x-peer"));
        assert!(!r.contains("acp-session-1"));
    }

    #[test]
    fn cloud_workers_are_keyed_by_credential_presence() {
        let registry = WorkerRegistry::from_cloud_credentials([
            (CODEX_CLOUD_WORKER_ID, Some("sk-test".to_string())),
            (CLAUDE_CLOUD_WORKER_ID, Some("   ".to_string())),
            (GEMINI_CLOUD_WORKER_ID, None),
        ]);
        assert!(registry.contains(LOCAL_MODEL_WORKER_ID));
        assert!(registry.contains(CODEX_CLOUD_WORKER_ID));
        assert!(registry.is_provisioned(CODEX_CLOUD_WORKER_ID));
        assert_eq!(
            registry.locality(CODEX_CLOUD_WORKER_ID),
            Some(WorkerLocality::CloudBackedAcp)
        );
        assert!(!registry.contains(CLAUDE_CLOUD_WORKER_ID));
        assert!(!registry.contains(GEMINI_CLOUD_WORKER_ID));
    }

    #[test]
    fn unprovisioned_vetted_worker_can_exercise_approval_gate() {
        let mut registry = WorkerRegistry::m1();
        registry.register_cloud_backed(CODEX_CLOUD_WORKER_ID, false);
        assert!(registry.contains(CODEX_CLOUD_WORKER_ID));
        assert!(!registry.is_provisioned(CODEX_CLOUD_WORKER_ID));
    }

    #[test]
    fn remote_provider_worker_registers_with_remote_locality() {
        let mut registry = WorkerRegistry::m1();
        let id = openrouter_worker_id("openai/gpt-4.1-mini");
        assert_eq!(id, "cloud:openrouter/openai/gpt-4.1-mini");
        assert!(id.starts_with(OPENROUTER_CLOUD_WORKER_PREFIX));
        registry.register_remote_provider(&id, true);
        assert!(registry.contains(&id));
        assert_eq!(registry.locality(&id), Some(WorkerLocality::RemoteProvider));
        assert!(registry.is_provisioned(&id));
        // The local model stays present and unaffected.
        assert!(registry.contains(LOCAL_MODEL_WORKER_ID));
    }
}
