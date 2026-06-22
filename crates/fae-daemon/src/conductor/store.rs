//! Append-only JSONL store for conductor telemetry, receipts, and recipes.
//!
//! Mirrors the daemon's audit-log convention. **Isolated from Fae's durable
//! memory store** — route telemetry, recipe candidates, and eval outcomes live
//! here, never in personal memory. Only user-visible durable facts may enter
//! the memory store, via the memory ingest gate.
//!
//! M0b ships the primitive only: open, append, read-recipe. The daemon decides
//! the final path (under the run dir) in M1; M0b does not wire it in.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::conductor::error::ConductorError;
use crate::conductor::recipe::FaeConductorRecipe;
use crate::conductor::telemetry::{ConductorRouteEvent, RouteReceipt};

const EVENTS_FILE: &str = "conductor_route_events.jsonl";
const RECEIPTS_FILE: &str = "conductor_receipts.jsonl";
const RECIPES_DIR: &str = "recipes";

/// Append-only store. Cheap to clone (holds only a path).
#[derive(Debug, Clone)]
pub struct ConductorStore {
    dir: PathBuf,
}

impl ConductorStore {
    /// Open (or create) the store at `dir`. Creates `dir` and `recipes/` with
    /// `0700` permissions on Unix. Does **not** touch any other path — the
    /// caller is responsible for placing `dir` away from the memory store.
    pub fn open(dir: impl AsRef<Path>) -> Result<Self, ConductorError> {
        let dir = dir.as_ref().to_path_buf();
        create_private_dir(&dir)?;
        create_private_dir(&dir.join(RECIPES_DIR))?;
        Ok(Self { dir })
    }

    #[allow(dead_code)] // exercised in unit tests; M2 store introspection surfaces it
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Append one route event. JSONL: one JSON object per line.
    pub fn append_event(&self, event: &ConductorRouteEvent) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(EVENTS_FILE), event)
    }

    /// Append one route receipt (audit / team-view source).
    pub fn append_receipt(&self, receipt: &RouteReceipt) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(RECEIPTS_FILE), receipt)
    }

    /// Persist a recipe version. Path: `recipes/<recipe_id>.v<version>.json`.
    /// Overwrites an exact (id, version) match (idempotent re-writes); never
    /// touches other versions. `recipe_id` is sanitized to a safe filename set.
    #[allow(dead_code)] // exercised in unit tests; M2 recipe persistence surfaces it
    pub fn store_recipe(&self, recipe: &FaeConductorRecipe) -> Result<PathBuf, ConductorError> {
        let safe_id = sanitize_id(&recipe.id)?;
        let path = self
            .dir
            .join(RECIPES_DIR)
            .join(format!("{safe_id}.v{}.json", recipe.version));
        let json = serde_json::to_vec_pretty(recipe)?;
        // Atomic-ish: write to a sibling temp then rename.
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, &json)?;
        std::fs::rename(&tmp, &path)?;
        Ok(path)
    }

    /// Load a specific recipe version. `None` if absent.
    #[allow(dead_code)] // exercised in unit tests; M2 recipe loading surfaces it
    pub fn load_recipe(
        &self,
        recipe_id: &str,
        version: u32,
    ) -> Result<Option<FaeConductorRecipe>, ConductorError> {
        let safe_id = sanitize_id(recipe_id)?;
        let path = self
            .dir
            .join(RECIPES_DIR)
            .join(format!("{safe_id}.v{version}.json"));
        if !path.exists() {
            return Ok(None);
        }
        let bytes = std::fs::read(&path)?;
        let recipe = serde_json::from_slice(&bytes)?;
        Ok(Some(recipe))
    }
}

fn append_jsonl<T: serde::Serialize>(path: &Path, value: &T) -> Result<(), ConductorError> {
    // Serialize the line fully in memory, then write it + the trailing newline
    // in a single `write_all`. This shrinks the crash-truncation window to the
    // kernel write itself (acceptable for an append-only telemetry log; a
    // partial line is detectable on read as invalid JSON and skippable).
    let mut line = serde_json::to_string(value)?;
    line.push('\n');
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(line.as_bytes())?;
    Ok(())
}

/// Restrict `id` to `[A-Za-z0-9._-]` and reject empty/path-like values. Prevents
/// path escape via a crafted recipe id (oracle risk: path traversal).
#[allow(dead_code)] // exercised in unit tests; M2 recipe persistence routes through it
fn sanitize_id(id: &str) -> Result<String, ConductorError> {
    if id.is_empty() || id.len() > 128 {
        return Err(ConductorError::Path(format!(
            "recipe id length out of range: {}",
            id.len()
        )));
    }
    if id == "." || id == ".." {
        return Err(ConductorError::Path(format!(
            "recipe id is a reserved name: {id:?}"
        )));
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return Err(ConductorError::Path(format!(
            "recipe id contains disallowed characters: {id:?}"
        )));
    }
    Ok(id.to_string())
}

#[cfg(unix)]
fn create_private_dir(path: &Path) -> Result<(), ConductorError> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn create_private_dir(path: &Path) -> Result<(), ConductorError> {
    std::fs::create_dir_all(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::recipe::{
        AggregationMode, AggregationPolicy, BudgetPolicy, ConductorRole, ConductorTaskClass,
        ConductorTopology, EscalationPolicy, PrivacyLane, RoleSlot, StopPolicy, WorkerLocality,
        WorkerSelector,
    };
    use crate::conductor::telemetry::{ConductorRouteEvent, TargetKind};
    use std::time::Duration;

    fn sample_recipe(id: &str, version: u32) -> FaeConductorRecipe {
        let w = WorkerSelector {
            id: "local:tiny".into(),
            kind: "local_model".into(),
            locality: WorkerLocality::LocalModel,
            capabilities: vec!["chat".into()],
            provider: None,
            model: None,
            trust_scope: None,
        };
        FaeConductorRecipe {
            id: id.into(),
            version,
            task_class: ConductorTaskClass::Chat,
            feature_predicates: vec![],
            allowed_workers: vec![w.clone()],
            privacy_lane: PrivacyLane::LocalOnly,
            topology: ConductorTopology::Direct,
            role_slots: vec![RoleSlot {
                role: ConductorRole::Worker,
                worker: w,
                prompt_template_id: "w".into(),
                prompt_template: "answer".into(),
                output_schema: None,
                required: true,
            }],
            budget: BudgetPolicy {
                max_turns: 1,
                max_role_calls: 1,
                timeout: Duration::from_millis(10_000),
                max_tokens: None,
                max_cost_micros: None,
            },
            escalation: EscalationPolicy {
                min_confidence_to_stay_local: 0.5,
                allow_acp: false,
                allow_mesh: false,
            },
            aggregation: AggregationPolicy {
                mode: AggregationMode::FirstAnswer,
                require_verifier_approval: false,
            },
            stop: StopPolicy {
                stop_after_verifier: true,
                stop_on_budget_exhaustion: true,
                max_correction_loops: 0,
            },
        }
    }

    #[test]
    fn store_append_event_and_receipt_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        let event = ConductorRouteEvent::turn_level(
            crate::conductor::fingerprint::RequestFingerprint("a".repeat(64)),
            ConductorTaskClass::Chat,
            ConductorTopology::Direct,
            TargetKind::LocalModel,
            PrivacyLane::LocalOnly,
            42,
        );
        store.append_event(&event).unwrap();
        store.append_event(&event).unwrap();

        let content =
            std::fs::read_to_string(dir.path().join("conductor_route_events.jsonl")).unwrap();
        assert_eq!(content.lines().count(), 2);
        // Each line is valid JSON.
        for line in content.lines() {
            let _: ConductorRouteEvent = serde_json::from_str(line).unwrap();
        }
    }

    #[test]
    fn recipe_store_and_load_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        let r = sample_recipe("r-1", 1);
        let path = store.store_recipe(&r).unwrap();
        assert!(path.exists());

        let loaded = store.load_recipe("r-1", 1).unwrap().unwrap();
        assert_eq!(r, loaded);
        assert!(store.load_recipe("r-1", 2).unwrap().is_none());
    }

    #[test]
    fn sanitize_rejects_path_escape() {
        assert!(sanitize_id("../etc/passwd").is_err());
        assert!(sanitize_id("").is_err());
        assert!(sanitize_id("a/b").is_err());
        assert!(sanitize_id(".").is_err());
        assert!(sanitize_id("..").is_err());
        assert!(sanitize_id("good-id.v1").is_ok());
    }
}
