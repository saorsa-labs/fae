//! M3-C4 — offline/CLI recipe-mutation driver (human-in-the-loop promotion).
//!
//! Matches the [`--offline-turn`](crate::offline_turn) pattern: a manual-args
//! early branch in `main.rs` dispatches here, constructs a
//! [`DaemonConductorRecipePort`] from the isolated conductor store, and runs a
//! **dry-run validate** OR an **apply**. This is the ONLY production construction
//! site for the port (otherwise tests-only). Mutation stays
//! offline/CLI-only/human-approves-every-promotion: **NO scheduler, NO auto-deploy,
//! NO live path.** The content-aware classifier remains a hard prerequisite for
//! any live mutation loop (owner directive 2026-06-25).
//!
//! ## F-16 (SOUL drift) — scope note
//!
//! The single-prompt identity/SOUL guard is **already** C1's
//! [`check_soul_framing_dropped`](crate::conductor::prompt_lint) (explicitly: "the
//! actual F-16 threat — a mutation that rewrites identity"). The F-16
//! *SOUL-drift metric* (proxy metric + periodic review trigger, per the research
//! plan) is **deferred**: it's temporal/measurement work needing a reward signal
//! or a scheduler task, not a prompt-lint extension, and a periodic trigger would
//! drift toward scheduler/live behavior (blocked by the classifier gate). Recorded
//! in the execution-plan Sequencing notes.
//!
//! ## Invocation
//!
//! ```text
//! # Dry-run (validate only — no write, no audit event):
//! fae-daemon conductor metaopt-run --recipe <id> --patch-file <path>
//!
//! # Apply (promote — writes a new version + audit event):
//! fae-daemon conductor metaopt-run --recipe <id> --patch-file <path> \
//!     --apply --expected-base-version <n> --yes
//! ```
//!
//! `--patch-file` is a JSON array of [`ConductorRecipePatch`]es. Apply requires
//! ALL of `--apply`, `--expected-base-version`, and `--yes` (the human-approval
//! gate) — omitting any of the three fails before any write.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use fae_metaopt::{ConductorRecipePatch, ConductorRecipePort, RecipeSummary};

use super::recipe_mutation::DaemonConductorRecipePort;
use super::store::ConductorStore;

/// Parsed `conductor metaopt-run` arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetaoptArgs {
    pub recipe_id: String,
    pub patch_file: PathBuf,
    /// When true, promote (apply); when false, dry-run validate only.
    pub apply: bool,
    /// Required when `apply` is true (the CAS base version).
    pub expected_base_version: Option<u32>,
    /// Human-approval flag; required when `apply` is true.
    pub yes: bool,
}

impl MetaoptArgs {
    /// Parse from a raw args iterator (everything after `conductor metaopt-run`).
    pub fn parse(mut args: impl Iterator<Item = String>) -> Result<MetaoptArgs, String> {
        let mut recipe_id: Option<String> = None;
        let mut patch_file: Option<PathBuf> = None;
        let mut apply = false;
        let mut expected_base_version: Option<u32> = None;
        let mut yes = false;
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--recipe" => recipe_id = Some(take_value(&mut args, "--recipe")?),
                "--patch-file" => {
                    patch_file = Some(PathBuf::from(take_value(&mut args, "--patch-file")?))
                }
                "--apply" => apply = true,
                "--yes" => yes = true,
                "--expected-base-version" => {
                    let raw = take_value(&mut args, "--expected-base-version")?;
                    expected_base_version = Some(raw.parse::<u32>().map_err(|_| {
                        format!("--expected-base-version must be a u32, got {raw}")
                    })?);
                }
                other => return Err(format!("unknown argument: {other}")),
            }
        }
        let recipe_id = recipe_id.ok_or("--recipe <id> is required")?;
        let patch_file = patch_file.ok_or("--patch-file <path> is required")?;
        if apply {
            let expected = expected_base_version
                .ok_or("--apply requires --expected-base-version <n> (the CAS base version)")?;
            if !yes {
                return Err(
                    "--apply requires --yes (human approval: this promotes a recipe mutation)"
                        .into(),
                );
            }
            return Ok(MetaoptArgs {
                recipe_id,
                patch_file,
                apply: true,
                expected_base_version: Some(expected),
                yes: true,
            });
        }
        Ok(MetaoptArgs {
            recipe_id,
            patch_file,
            apply: false,
            expected_base_version,
            yes,
        })
    }
}

fn take_value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("{flag} requires a value"))
}

/// What the CLI produced (printed to stdout; returned to tests).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaoptOutcome {
    /// Dry-run: the patch batch validated; nothing written.
    DryRun { summary: RecipeSummary },
    /// Apply: a new head version was written + an audit event appended.
    Applied {
        new_version: u32,
        summary: RecipeSummary,
    },
}

impl std::fmt::Display for MetaoptOutcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MetaoptOutcome::DryRun { summary } => {
                writeln!(f, "[metaopt] DRY-RUN validated (no write).")?;
                write!(f, "{summary:#?}")
            }
            MetaoptOutcome::Applied {
                new_version,
                summary,
                ..
            } => {
                writeln!(f, "[metaopt] APPLIED — new head version {new_version}.")?;
                write!(f, "{summary:#?}")
            }
        }
    }
}

/// Run the CLI against an injected store (main.rs opens the real conductor store;
/// tests pass a temp store). Reads the patch file, validates, and either
/// dry-runs or applies. Never touches the executor / scheduler / session.
pub async fn run(args: MetaoptArgs, store: Arc<ConductorStore>) -> Result<MetaoptOutcome, String> {
    let patches = read_patch_file(&args.patch_file)?;
    // CLI-level precheck: --recipe is authoritative. validate_batch/apply_batch
    // derive the recipe_id from the patches (the trait takes no recipe_id), so a
    // patch file targeting a different id would silently validate/apply THAT
    // recipe. Reject here for consistent UX + to defend hand-built callers.
    let mut ids = patches.iter().map(ConductorRecipePatch::recipe_id);
    if let Some(first) = ids.next() {
        if ids.any(|id| id != first) {
            return Err("patch file mixes recipe ids".into());
        }
        if first != args.recipe_id {
            return Err(format!(
                "patch recipe_id {first} ≠ --recipe {}",
                args.recipe_id
            ));
        }
    }
    let port = DaemonConductorRecipePort::new(store);
    if args.apply {
        // Human-approval gate (enforced HERE, not only in the parser — MetaoptArgs
        // fields are public, so a hand-built apply with yes=false must still fail).
        if !args.yes {
            return Err(
                "--apply requires --yes (human approval: this promotes a recipe mutation)".into(),
            );
        }
        // expected_base_version: parser guarantees Some when apply, but re-check
        // so run() is safe against a hand-built args.
        let expected = args.expected_base_version.ok_or_else(|| {
            "--apply requires --expected-base-version <n> (the CAS base version)".to_string()
        })?;
        let new_version = port
            .apply_batch(&args.recipe_id, expected, &patches)
            .await
            .map_err(|e| format!("apply_batch failed: {e}"))?;
        let summary = port
            .current_recipe_summary(&args.recipe_id)
            .await
            .map_err(|e| format!("post-apply summary read failed: {e}"))?;
        Ok(MetaoptOutcome::Applied {
            new_version,
            summary,
        })
    } else {
        // validate_batch returns PatchRejection (not RecipePortError); surface
        // the rejection's Debug form for the human reviewer.
        let summary = port
            .validate_batch(&patches)
            .await
            .map_err(|e| format!("validation rejected: {e:?}"))?;
        Ok(MetaoptOutcome::DryRun { summary })
    }
}

fn read_patch_file(path: &Path) -> Result<Vec<ConductorRecipePatch>, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("read patch-file {}: {e}", path.display()))?;
    let patches: Vec<ConductorRecipePatch> = serde_json::from_str(&text)
        .map_err(|e| format!("parse patch-file {}: {e}", path.display()))?;
    Ok(patches)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::recipe::{
        AggregationMode, AggregationPolicy, BudgetPolicy, ConductorRole, ConductorTaskClass,
        ConductorTopology, EscalationPolicy, PrivacyLane, RoleSlot, StopPolicy, WorkerLocality,
        WorkerSelector,
    };
    use crate::conductor::store::ConductorStore;
    use fae_metaopt::{ConductorRecipePatch, ConductorRoleDto};
    use std::time::Duration;

    // ── parser tests ─────────────────────────────────────────────────────────

    fn argv(rest: &[&str]) -> std::vec::IntoIter<String> {
        rest.iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .into_iter()
    }

    #[test]
    fn parse_dry_run_minimal() {
        let a = MetaoptArgs::parse(argv(&["--recipe", "r1", "--patch-file", "p.json"]))
            .expect("dry-run parse");
        assert_eq!(a.recipe_id, "r1");
        assert_eq!(a.patch_file, PathBuf::from("p.json"));
        assert!(!a.apply);
    }

    #[test]
    fn parse_apply_full() {
        let a = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            "p.json",
            "--apply",
            "--expected-base-version",
            "3",
            "--yes",
        ]))
        .expect("apply parse");
        assert!(a.apply);
        assert_eq!(a.expected_base_version, Some(3));
        assert!(a.yes);
    }

    #[test]
    fn parse_apply_requires_expected_base_version() {
        let err = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            "p.json",
            "--apply",
            "--yes",
        ]))
        .unwrap_err();
        assert!(err.contains("--expected-base-version"), "{err}");
    }

    #[test]
    fn parse_apply_requires_yes() {
        let err = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            "p.json",
            "--apply",
            "--expected-base-version",
            "1",
        ]))
        .unwrap_err();
        assert!(err.contains("--yes"), "{err}");
    }

    #[test]
    fn parse_requires_recipe() {
        let err = MetaoptArgs::parse(argv(&["--patch-file", "p.json"])).unwrap_err();
        assert!(err.contains("--recipe"), "{err}");
    }

    #[test]
    fn parse_requires_patch_file() {
        let err = MetaoptArgs::parse(argv(&["--recipe", "r1"])).unwrap_err();
        assert!(err.contains("--patch-file"), "{err}");
    }

    #[test]
    fn parse_rejects_unknown_flag() {
        let err = MetaoptArgs::parse(argv(&["--recipe", "r1", "--patch-file", "p", "--bogus"]))
            .unwrap_err();
        assert!(err.contains("unknown argument"), "{err}");
    }

    // ── execution tests (temp store + real patch file) ───────────────────────

    fn tmp_store() -> (tempfile::TempDir, Arc<ConductorStore>) {
        let dir = tempfile::tempdir().expect("tmp");
        let store = Arc::new(ConductorStore::open(dir.path()).expect("open"));
        (dir, store)
    }

    /// A minimal valid recipe (Direct, one local Worker) the CLI can mutate.
    fn direct_recipe() -> crate::conductor::recipe::FaeConductorRecipe {
        let w = WorkerSelector {
            id: "local:qwen".into(),
            kind: "local_model".into(),
            locality: WorkerLocality::LocalModel,
            capabilities: vec!["chat".into()],
            provider: None,
            model: None,
            trust_scope: None,
        };
        crate::conductor::recipe::FaeConductorRecipe {
            id: "r1".into(),
            version: 1,
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

    /// Write a JSON patch array (one valid MutateRolePrompt) into `dir`.
    fn write_patch_file(
        dir: &tempfile::TempDir,
        name: &str,
        patches: &[ConductorRecipePatch],
    ) -> PathBuf {
        let path = dir.path().join(name);
        std::fs::write(&path, serde_json::to_string_pretty(patches).expect("ser")).expect("write");
        path
    }

    #[tokio::test]
    async fn dry_run_validates_and_writes_nothing() {
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist v1");
        let patch = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r1".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "Answer the user clearly and concisely.".into(),
        };
        let path = write_patch_file(&dir, "ok.json", &[patch]);
        let args = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            path.to_str().unwrap(),
        ]))
        .expect("parse");
        let outcome = run(args, store.clone()).await.expect("dry-run");
        assert!(matches!(outcome, MetaoptOutcome::DryRun { .. }));
        // No write, no audit event.
        assert_eq!(store.read_recipe_mutations().expect("events").len(), 0);
        assert_eq!(store.load_latest_recipe("r1").unwrap().unwrap().version, 1);
    }

    #[tokio::test]
    async fn apply_with_yes_writes_next_version_and_event() {
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist v1");
        let patch = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r1".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "Answer the user clearly and concisely.".into(),
        };
        let path = write_patch_file(&dir, "ok.json", &[patch]);
        let args = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            path.to_str().unwrap(),
            "--apply",
            "--expected-base-version",
            "1",
            "--yes",
        ]))
        .expect("parse");
        let outcome = run(args, store.clone()).await.expect("apply");
        match outcome {
            MetaoptOutcome::Applied { new_version, .. } => assert_eq!(new_version, 2),
            other => panic!("expected Applied, got {other:?}"),
        }
        // New head + audit event present.
        assert_eq!(store.load_latest_recipe("r1").unwrap().unwrap().version, 2);
        let events = store.read_recipe_mutations().expect("events");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].to_version, 2);
    }

    #[tokio::test]
    async fn invalid_patch_file_rejected() {
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist v1");
        // Not valid JSON / not a patch array.
        let path = dir.path().join("bad.json");
        std::fs::write(&path, "not json").expect("write");
        let args = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            path.to_str().unwrap(),
        ]))
        .expect("parse");
        let err = run(args, store.clone()).await.unwrap_err();
        assert!(err.contains("parse patch-file"), "{err}");
        assert_eq!(store.read_recipe_mutations().expect("events").len(), 0);
    }

    #[tokio::test]
    async fn apply_without_yes_rejected_by_parser_no_write() {
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist v1");
        let patch = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r1".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "Be helpful.".into(),
        };
        let path = write_patch_file(&dir, "ok.json", &[patch]);
        // --apply + --expected-base-version but NO --yes.
        let err = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            path.to_str().unwrap(),
            "--apply",
            "--expected-base-version",
            "1",
        ]))
        .unwrap_err();
        assert!(err.contains("--yes"), "{err}");
        // Parser rejected ⇒ run() never called ⇒ no write/event.
        assert_eq!(store.read_recipe_mutations().expect("events").len(), 0);
        assert_eq!(store.load_latest_recipe("r1").unwrap().unwrap().version, 1);
    }

    #[tokio::test]
    async fn hand_built_apply_without_yes_rejected_in_run() {
        // MetaoptArgs fields are public: a hand-built apply with yes=false must
        // still be rejected by run() (the parser is not the only enforcement).
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist v1");
        let patch = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r1".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "Be helpful.".into(),
        };
        let path = write_patch_file(&dir, "ok.json", &[patch]);
        let args = MetaoptArgs {
            recipe_id: "r1".into(),
            patch_file: path,
            apply: true,
            expected_base_version: Some(1),
            yes: false, // hand-built bypass attempt
        };
        let err = run(args, store.clone()).await.unwrap_err();
        assert!(err.contains("--yes"), "{err}");
        // No write, no event.
        assert_eq!(store.read_recipe_mutations().expect("events").len(), 0);
        assert_eq!(store.load_latest_recipe("r1").unwrap().unwrap().version, 1);
    }

    #[tokio::test]
    async fn dry_run_rejects_cross_recipe_patch_file() {
        // --recipe r1 with a patch file targeting r2 must be rejected at the CLI
        // layer (validate_batch derives the recipe_id from patches, ignoring
        // --recipe). --recipe is authoritative.
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist r1 v1");
        // A patch whose recipe_id ≠ the --recipe id.
        let patch = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r2".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "Be helpful.".into(),
        };
        let path = write_patch_file(&dir, "cross.json", &[patch]);
        let args = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            path.to_str().unwrap(),
        ]))
        .expect("parse");
        let err = run(args, store.clone()).await.unwrap_err();
        assert!(err.contains("patch recipe_id r2 ≠ --recipe r1"), "{err}");
        // No write, no event.
        assert_eq!(store.read_recipe_mutations().expect("events").len(), 0);
    }

    #[tokio::test]
    async fn dry_run_rejects_mixed_id_patch_file() {
        let (dir, store) = tmp_store();
        store.store_recipe(&direct_recipe()).expect("persist r1 v1");
        let p1 = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r1".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "A.".into(),
        };
        let p2 = ConductorRecipePatch::MutateRolePrompt {
            recipe_id: "r2".into(),
            role: ConductorRoleDto::Worker,
            new_prompt: "B.".into(),
        };
        let path = write_patch_file(&dir, "mixed.json", &[p1, p2]);
        let args = MetaoptArgs::parse(argv(&[
            "--recipe",
            "r1",
            "--patch-file",
            path.to_str().unwrap(),
        ]))
        .expect("parse");
        let err = run(args, store.clone()).await.unwrap_err();
        assert!(err.contains("mixes recipe ids"), "{err}");
        assert_eq!(store.read_recipe_mutations().expect("events").len(), 0);
    }
}
