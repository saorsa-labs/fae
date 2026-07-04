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
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use crate::conductor::error::ConductorError;
use crate::conductor::recipe::FaeConductorRecipe;
use crate::conductor::telemetry::{
    ConductorRouteEvent, FeedbackRecord, RecipeMutationRecord, RouteReceipt, ShadowTurnRecord,
};

const EVENTS_FILE: &str = "conductor_route_events.jsonl";
const RECEIPTS_FILE: &str = "conductor_receipts.jsonl";
const BUDGET_USAGE_FILE: &str = "conductor_budget_usage.jsonl";
const FEEDBACK_FILE: &str = "conductor_feedback.jsonl";
const SHADOW_FILE: &str = "conductor_shadow.jsonl";
const MUTATIONS_FILE: &str = "conductor_recipe_mutations.jsonl";
/// ADR-013 Vision A (A2): the governed ToolHost's fail-closed policy audit.
/// Sibling to the conductor telemetry files; lives in the SAME private store
/// dir, NEVER in `fae.db`/`MemoryOrchestrator` (storage-isolation invariant).
const TOOLHOST_AUDIT_FILE: &str = "toolhost_audit.jsonl";
/// ADR-013 Vision A (B4): the governed ToolHost's fail-closed mutation receipts.
/// Sibling to `toolhost_audit.jsonl` in the SAME private store dir, NEVER in
/// `fae.db`/`MemoryOrchestrator` (storage-isolation invariant).
const TOOLHOST_RECEIPTS_FILE: &str = "toolhost_receipts.jsonl";
/// ADR-013 Vision A (A2.5): the governed SkillHost's fail-closed lifecycle audit
/// (`skill_loaded`/`skill_quarantined`/`skill_executed`). Sibling to the
/// ToolHost audit; SAME private store dir, NEVER `fae.db`/`MemoryOrchestrator`.
const SKILLHOST_AUDIT_FILE: &str = "skillhost_audit.jsonl";
/// Phase F1: the native jailed agentic loop's per-delegation receipts
/// (`fae.delegate`). Sibling to the ToolHost/SkillHost audit; SAME private store
/// dir, NEVER `fae.db`/`MemoryOrchestrator` (storage-isolation invariant). The
/// receipt records `prompt_sha256`, NEVER the raw delegated prompt.
const DELEGATION_RECEIPTS_FILE: &str = "delegation_receipts.jsonl";
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

    /// Read all persisted receipts (the reward aggregator's outcome-metrics
    /// window — M2-live §2.3). Missing file ⇒ empty (fresh store); a corrupt /
    /// partial line is an error so the reward aggregator fails closed rather
    /// than silently dropping outcome signal. Mirrors [`read_shadow_records`].
    #[allow(dead_code)] // TODO(M2-live, 2026-06-24): used when reward_snapshot reads the window
    pub(crate) fn read_receipts(&self) -> Result<Vec<RouteReceipt>, ConductorError> {
        ensure_store_dir_available(&self.dir)?;
        read_jsonl(&self.dir.join(RECEIPTS_FILE))
    }

    /// Append one budget-governance usage row. The concrete row type lives in
    /// `budget.rs`; the store owns only the isolated JSONL persistence seam.
    #[allow(dead_code)] // TODO(M2, 2026-06-23): used when BudgetGovernor wires into executor
    pub(crate) fn append_budget_usage_line<T: serde::Serialize>(
        &self,
        record: &T,
    ) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(BUDGET_USAGE_FILE), record)
    }

    /// Read persisted budget-governance rows as raw JSONL lines. Missing file
    /// means a fresh initialized store; missing/corrupt store directory is an
    /// error so the BudgetGovernor can fail closed.
    #[allow(dead_code)] // TODO(M2, 2026-06-23): used when BudgetGovernor wires into executor
    pub(crate) fn read_budget_usage_lines(&self) -> Result<Vec<String>, ConductorError> {
        ensure_store_dir_available(&self.dir)?;
        let path = self.dir.join(BUDGET_USAGE_FILE);
        let file = match std::fs::File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error.into()),
        };
        let reader = std::io::BufReader::new(file);
        let mut lines = Vec::new();
        for line in reader.lines() {
            let line = line?;
            if !line.trim().is_empty() {
                lines.push(line);
            }
        }
        Ok(lines)
    }

    /// Append one shadow-router turn record (§8). Decision-only records: never
    /// user text, never executed decisions — only the decisions the deployed +
    /// candidate policies *would have* made (see the shadow router's structural
    /// no-egress guarantee). Joined to receipts on `request_fingerprint`.
    #[allow(dead_code)] // TODO(M2, 2026-06-23): wired when the shadow router enters the live loop
    pub(crate) fn append_shadow_record(
        &self,
        record: &ShadowTurnRecord,
    ) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(SHADOW_FILE), record)
    }

    /// Read all persisted shadow records (the reward aggregator's live window).
    #[allow(dead_code)] // TODO(M2, 2026-06-23): used when aggregate_reward reads the window
    pub(crate) fn read_shadow_records(&self) -> Result<Vec<ShadowTurnRecord>, ConductorError> {
        ensure_store_dir_available(&self.dir)?;
        read_jsonl(&self.dir.join(SHADOW_FILE))
    }

    /// Append one explicit user-feedback row to the feedback log (§7 MAJOR-4).
    /// Late-arriving feedback is NOT in the receipt (written at turn-end,
    /// before feedback exists); it lives in its own JSONL and is joined to
    /// receipts on `request_fingerprint` at reward scoring time.
    ///
    /// *M2 invariant:* the record carries enum-like tokens only, never user
    /// text — enforced by the [`FeedbackRecord`] type.
    #[allow(dead_code)] // TODO(M2, 2026-06-23): wired when the UI capture surface lands
    pub fn append_feedback(&self, record: &FeedbackRecord) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(FEEDBACK_FILE), record)
    }

    /// Append one governed-ToolHost policy-audit row (ADR-013 Vision A, A2).
    ///
    /// Generic over the record type so the conductor store has NO dependency on
    /// the `toolhost` module (one-way boundary: toolhost → conductor, never the
    /// reverse). The caller serializes a `ToolHostAuditRecord`.
    pub fn append_toolhost_audit(
        &self,
        record: &impl serde::Serialize,
    ) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(TOOLHOST_AUDIT_FILE), record)
    }

    /// Append one governed-ToolHost mutation receipt (ADR-013 Vision A, B4).
    ///
    /// Generic over the record type so the conductor store keeps its one-way
    /// boundary (toolhost → conductor, never the reverse). The caller serializes
    /// a `MutationReceipt`. Fail-closed: the ToolHost denies the mutation if this
    /// write errors.
    pub fn append_toolhost_receipt(
        &self,
        record: &impl serde::Serialize,
    ) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(TOOLHOST_RECEIPTS_FILE), record)
    }

    /// Append one native-delegation receipt (Phase F1, `fae.delegate`).
    ///
    /// Generic over the record type so the conductor store keeps its one-way
    /// boundary (delegate → conductor, never the reverse). The caller serializes
    /// a `DelegationReceipt` — which carries `prompt_sha256`, never the raw
    /// prompt.
    pub fn append_delegation_receipt(
        &self,
        record: &impl serde::Serialize,
    ) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(DELEGATION_RECEIPTS_FILE), record)
    }

    /// Append one governed-SkillHost lifecycle-audit row (ADR-013 Vision A, A2.5).
    ///
    /// Generic over the record type so the conductor store has NO dependency on
    /// the `skillhost` module (one-way boundary: skillhost → conductor). The
    /// caller serializes a `SkillHostAuditRecord`.
    pub fn append_skillhost_audit(
        &self,
        record: &impl serde::Serialize,
    ) -> Result<(), ConductorError> {
        append_jsonl(&self.dir.join(SKILLHOST_AUDIT_FILE), record)
    }

    /// Read all persisted feedback rows. Missing file means a fresh store
    /// (no feedback yet); a corrupt store directory is an error so the reward
    /// aggregator can fail closed rather than silently drop negative signals.
    #[allow(dead_code)] // TODO(M2, 2026-06-23): used when aggregate_reward joins the window
    pub(crate) fn read_feedback(&self) -> Result<Vec<FeedbackRecord>, ConductorError> {
        ensure_store_dir_available(&self.dir)?;
        read_jsonl(&self.dir.join(FEEDBACK_FILE))
    }

    /// Append a redacted recipe-mutation audit line (M3-C3). The record is
    /// prompt-free (F-4): only version lineage + patch KINDS are persisted.
    #[allow(dead_code)] // M3-C3: DaemonConductorRecipePort calls this on apply/rollback
    pub(crate) fn append_recipe_mutation(
        &self,
        record: &RecipeMutationRecord,
    ) -> Result<(), ConductorError> {
        ensure_store_dir_available(&self.dir)?;
        append_jsonl(&self.dir.join(MUTATIONS_FILE), record)
    }

    /// Read all recipe-mutation audit rows (tests + future reviewer surface).
    #[allow(dead_code)] // M3-C3: exercised in tests; the reviewer UI surfaces it later
    pub(crate) fn read_recipe_mutations(
        &self,
    ) -> Result<Vec<RecipeMutationRecord>, ConductorError> {
        ensure_store_dir_available(&self.dir)?;
        read_jsonl(&self.dir.join(MUTATIONS_FILE))
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

    /// Persist a NEW recipe version with **no-overwrite** semantics (M3-C3 CAS).
    /// Unlike [`store_recipe`](Self::store_recipe) (which overwrites an exact
    /// (id, version) match for idempotent re-writes), this FAILS if the target
    /// file already exists — closing the CAS race where a concurrent writer's
    /// version-N could be clobbered. The recipe's `version` must already be set
    /// to the intended new version by the caller.
    #[allow(dead_code)] // M3-C3: DaemonConductorRecipePort::apply_batch / rollback
    pub(crate) fn store_recipe_new_version(
        &self,
        recipe: &FaeConductorRecipe,
    ) -> Result<PathBuf, ConductorError> {
        let safe_id = sanitize_id(&recipe.id)?;
        let path = self
            .dir
            .join(RECIPES_DIR)
            .join(format!("{safe_id}.v{}.json", recipe.version));
        let json = serde_json::to_vec_pretty(recipe)?;
        // `create_new(true)`: the open fails (AlreadyExists) if the file is
        // present — the CAS guarantee. No temp+rename: rename would overwrite,
        // defeating the create_new guard.
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)?;
        use std::io::Write;
        file.write_all(&json)?;
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

    /// Load the highest-numbered version for a recipe — the CAS base for recipe
    /// mutation (`current_recipe_summary` / `apply_batch`'s `expected_base_version`).
    /// `None` if no versions exist (a recipe never persisted).
    ///
    /// Scans `recipes/<safe_id>.v<digits>.json`, picks the max version, delegates
    /// to [`load_recipe`](Self::load_recipe). **No head-pointer file**: the scan is
    /// crash-safe (the version files ARE the truth) and the recipes dir is small —
    /// fine for dormant/CLI M3 volume. A head pointer would add a second file to
    /// keep in sync for no benefit at this scale.
    ///
    /// Security: reuses [`sanitize_id`] (path-traversal-safe), globs only the exact
    /// `<safe_id>.v` prefix + `<digits>.json` suffix. A crafted filename cannot
    /// spoof a higher version (digits-only `u32` parse) and a prefix-colliding id
    /// (`foo` vs `foo2`) cannot bleed (the `.` after `safe_id` bounds the match).
    #[allow(dead_code)] // exercised in unit tests; M3-C2 recipe validation surfaces it
    pub fn load_latest_recipe(
        &self,
        recipe_id: &str,
    ) -> Result<Option<FaeConductorRecipe>, ConductorError> {
        let safe_id = sanitize_id(recipe_id)?;
        let dir = self.dir.join(RECIPES_DIR);
        let read = match std::fs::read_dir(&dir) {
            Ok(read) => read,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        let prefix = format!("{safe_id}.");
        let mut best: Option<u32> = None;
        for entry in read {
            let entry = entry?;
            // Bind the OsString: `.to_str()` borrows it, so it must outlive `name`.
            let file_name = entry.file_name();
            let Some(name) = file_name.to_str() else {
                continue;
            };
            // Match `<safe_id>.v<digits>.json` exactly.
            let Some(rest) = name.strip_prefix(&prefix) else {
                continue;
            };
            let Some(digits) = rest.strip_prefix("v").and_then(|r| r.strip_suffix(".json")) else {
                continue;
            };
            // Fail closed: a file matching the version shape (`<safe_id>.v*.json`)
            // with a non-`u32` version is corruption / tampering, not a legitimate
            // sibling (the store's read_jsonl shares this fail-closed posture). A
            // non-matching file (e.g. `<safe_id>.metadata.json`) hit `continue` above.
            let version = digits.parse::<u32>().map_err(|_| {
                ConductorError::Path(format!(
                    "corrupt recipe version file (non-numeric version): {name}"
                ))
            })?;
            best = Some(best.map_or(version, |b| b.max(version)));
        }
        match best {
            Some(version) => self.load_recipe(recipe_id, version),
            None => Ok(None),
        }
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

/// Read a JSONL file into typed rows. A missing file means a fresh store
/// (returns empty); a corrupt/partial line is an error so callers fail closed
/// rather than silently dropping rows (e.g. a dropped negative feedback signal).
fn read_jsonl<T: serde::de::DeserializeOwned>(path: &Path) -> Result<Vec<T>, ConductorError> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let reader = std::io::BufReader::new(file);
    let mut rows = Vec::new();
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let row: T = serde_json::from_str(&line)?;
        rows.push(row);
    }
    Ok(rows)
}

fn ensure_store_dir_available(dir: &Path) -> Result<(), ConductorError> {
    let metadata = std::fs::metadata(dir)?;
    if !metadata.is_dir() {
        return Err(ConductorError::Path(format!(
            "conductor store path is not a directory: {}",
            dir.display()
        )));
    }
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

    // V7 (oracle ea2dc52c MINOR-2): the three telemetry read seams fail closed
    // on a corrupt/partial JSON line rather than silently dropping rows. A
    // dropped row would be worst for feedback (a lost negative signal).
    fn inject_corrupt_line(dir: &std::path::Path, file: &str) {
        std::fs::write(dir.join(file), "{\"this is\": not valid json\n").unwrap();
    }

    #[test]
    fn read_receipts_fails_closed_on_corrupt_line() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        inject_corrupt_line(dir.path(), "conductor_receipts.jsonl");
        assert!(store.read_receipts().is_err());
    }

    #[test]
    fn read_shadow_records_fails_closed_on_corrupt_line() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        inject_corrupt_line(dir.path(), "conductor_shadow.jsonl");
        assert!(store.read_shadow_records().is_err());
    }

    #[test]
    fn read_feedback_fails_closed_on_corrupt_line() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        inject_corrupt_line(dir.path(), "conductor_feedback.jsonl");
        assert!(store.read_feedback().is_err());
    }

    // MAJOR-1 (oracle ea2dc52c): a missing *file* on a fresh store is empty
    // (legitimate), but a missing/corrupt store *directory* is an error — never
    // silently return empty (which would drop every persisted row).
    #[test]
    fn fresh_store_missing_files_read_empty() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        assert!(store.read_receipts().unwrap().is_empty());
        assert!(store.read_shadow_records().unwrap().is_empty());
        assert!(store.read_feedback().unwrap().is_empty());
    }

    #[test]
    fn read_seams_fail_closed_when_store_dir_disappears() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConductorStore::open(dir.path()).unwrap();
        // Simulate a corrupt/removed store directory (e.g. external deletion).
        std::fs::remove_dir_all(dir.path()).unwrap();
        assert!(
            store.read_receipts().is_err(),
            "receipts fail closed on missing dir"
        );
        assert!(
            store.read_shadow_records().is_err(),
            "shadow fail closed on missing dir"
        );
        assert!(
            store.read_feedback().is_err(),
            "feedback fail closed on missing dir"
        );
    }
}
