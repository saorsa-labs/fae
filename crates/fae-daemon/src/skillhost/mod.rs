//! ADR-013 Vision A — the daemon governed skill-execution host (A2.5).
//!
//! [`SkillHost`] discovers Fae's integrity'd skills from a skills directory
//! (mirroring the Swift `SkillManager` layout: one subdirectory per skill, each
//! with a `SKILL.md`, an optional `MANIFEST.json`, and an optional `scripts/`),
//! and exposes three governed operations that A3's protocol surface wraps:
//!
//! * `list` — names + descriptions + availability (quarantined skills are
//!   listed as unavailable-with-reason, never silently dropped).
//! * `activate` — the full post-frontmatter `SKILL.md` body for prompt injection.
//! * `run` — build the `uv run --script …` command for a declared, verified
//!   script, which the caller routes through the EXISTING governed
//!   [`ToolHost`](crate::toolhost::ToolHost) bash path (`execute_governed`).
//!   **There is no second execution lane** — skill scripts run through the same
//!   authorize → path → damage → confirm → audit pipeline as any bash call.
//!
//! **Skill type** (Swift `SkillParser`): a skill is *executable* iff it has a
//! `scripts/` directory, else *instruction-only*. Executable skills MUST carry a
//! valid `MANIFEST.json` with SHA-256 `integrity.checksums`; a missing/invalid
//! manifest or any integrity anomaly quarantines the skill (fail-closed).
//! Integrity is verified at discovery AND again immediately before execution.
//!
//! **Vision-B boundary (unchanged):** the Swift multi-turn loop still drives; it
//! calls INTO this host. No loop relocation, no conductor-as-`ModelProvider`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use crate::skillhost::audit::{SkillEvent, SkillHostAudit, SkillHostAuditRecord};
use crate::skillhost::manifest::{SkillIntegrity, SkillManifest};
use crate::toolhost::{SystemToolHostClock, ToolHostClock};

pub mod audit;
pub mod integrity;
pub mod manifest;
pub mod parse;
pub mod usage;

const SKILL_MD: &str = "SKILL.md";
const MANIFEST_JSON: &str = "MANIFEST.json";
const SCRIPTS_DIR: &str = "scripts";

/// Whether a skill carries executable scripts or is instruction-only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillKind {
    /// Has a `scripts/` directory — requires a verified manifest to run.
    Executable,
    /// No scripts — activation-only (no manifest required).
    Instruction,
}

/// A skill's load-time availability.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Availability {
    /// Parsed + (for executable) integrity-verified — usable.
    Available,
    /// Failed a load-time gate; carries the quarantine reason. Never executable.
    Quarantined(String),
}

/// One discovered skill.
#[derive(Debug, Clone)]
struct SkillEntry {
    name: String,
    description: String,
    kind: SkillKind,
    dir: PathBuf,
    availability: Availability,
}

/// A public listing row for `skillhost.list`.
#[derive(Debug, Clone, serde::Serialize)]
pub struct SkillListing {
    /// The skill name (frontmatter `name`).
    pub name: String,
    /// The progressive-disclosure description.
    pub description: String,
    /// Executable vs instruction-only.
    pub kind: SkillKind,
    /// `true` when usable; `false` when quarantined.
    pub available: bool,
    /// The quarantine reason when `available == false`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// The command plan for a verified skill run: an owner-confirmable bash command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunPlan {
    /// The skill whose script is being run.
    pub skill: String,
    /// The `uv run --script <abs-path>` command to route through the ToolHost
    /// bash tool (`execute_governed`).
    pub command: String,
}

/// A skill-host operation failure. Every non-`Ok` path is fail-closed.
#[derive(Debug, thiserror::Error)]
pub enum SkillHostError {
    /// No skill with that name (or an unsafe name).
    #[error("skill not found: {0}")]
    NotFound(String),
    /// The skill exists but is quarantined (integrity/manifest/parse failure).
    #[error("skill quarantined: {name}: {reason}")]
    Quarantined {
        /// The skill name.
        name: String,
        /// The quarantine reason.
        reason: String,
    },
    /// A run was requested for an instruction-only skill.
    #[error("skill is not executable: {0}")]
    NotExecutable(String),
    /// The requested (or default) script is not a declared, verified file.
    #[error("skill script not found or undeclared: {0}")]
    ScriptNotFound(String),
    /// The fail-closed audit write failed — the operation is refused.
    #[error("skill audit write failed: {0}")]
    Audit(String),
    /// Archive was refused (Phase G4): only `auto-*` skills may be archived.
    #[error("skill archive refused: {name}: {reason}")]
    ArchiveRefused {
        /// The skill name supplied.
        name: String,
        /// Why the archive was refused.
        reason: String,
    },
    /// The filesystem move for an archive failed (Phase G4).
    #[error("skill archive move failed: {0}")]
    ArchiveMove(String),
}

/// The governed skill-discovery + execution-preparation host.
pub struct SkillHost {
    skills_dir: PathBuf,
    entries: Mutex<Vec<SkillEntry>>,
    audit: Arc<dyn SkillHostAudit>,
    clock: Arc<dyn ToolHostClock>,
    usage: Mutex<usage::UsageStore>,
}

impl SkillHost {
    /// Discover skills under `skills_dir` and audit each `loaded`/`quarantined`
    /// event. A missing/unreadable `skills_dir` yields an empty host (no skills)
    /// — never an error, so a fresh install with no skills serves cleanly.
    pub fn new(skills_dir: impl AsRef<Path>, audit: Arc<dyn SkillHostAudit>) -> Self {
        Self::with_clock_inner(skills_dir, audit, Arc::new(SystemToolHostClock), None)
    }

    /// Construct with a persistent usage-counter file (Phase G4). Counters are
    /// loaded from `usage_path` (corrupt file → fresh + warning) and persisted
    /// on every increment/discovery.
    pub fn with_usage_path(
        skills_dir: impl AsRef<Path>,
        audit: Arc<dyn SkillHostAudit>,
        usage_path: PathBuf,
    ) -> Self {
        Self::with_clock_inner(
            skills_dir,
            audit,
            Arc::new(SystemToolHostClock),
            Some(usage_path),
        )
    }

    /// Construct with an explicit clock (tests inject a fixed clock).
    #[cfg(test)]
    pub fn with_clock(
        skills_dir: impl AsRef<Path>,
        audit: Arc<dyn SkillHostAudit>,
        clock: Arc<dyn ToolHostClock>,
    ) -> Self {
        Self::with_clock_inner(skills_dir, audit, clock, None)
    }

    fn with_clock_inner(
        skills_dir: impl AsRef<Path>,
        audit: Arc<dyn SkillHostAudit>,
        clock: Arc<dyn ToolHostClock>,
        usage_path: Option<PathBuf>,
    ) -> Self {
        let skills_dir = skills_dir.as_ref().to_path_buf();
        let entries = discover(&skills_dir);
        let mut usage_store = usage_path
            .map(usage::UsageStore::load)
            .unwrap_or_else(usage::UsageStore::empty);
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        usage_store.note_discovered(&names, clock.now_ms());
        let host = Self {
            skills_dir,
            entries: Mutex::new(entries),
            audit,
            clock,
            usage: Mutex::new(usage_store),
        };
        host.audit_discovery();
        host
    }

    /// Emit one `loaded`/`quarantined` audit row per discovered skill. Best
    /// effort: an audit-write failure at discovery does not abort startup (the
    /// per-run path re-audits and fails closed there).
    fn audit_discovery(&self) {
        let entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        for e in entries.iter() {
            let (event, status) = match &e.availability {
                Availability::Available => (
                    SkillEvent::Loaded,
                    match e.kind {
                        SkillKind::Executable => "verified".to_string(),
                        SkillKind::Instruction => "instruction_only".to_string(),
                    },
                ),
                Availability::Quarantined(reason) => (SkillEvent::Quarantined, reason.clone()),
            };
            let _ = self.audit.record(SkillHostAuditRecord {
                event_type: "skill_event",
                ts_ms: self.clock.now_ms(),
                skill: e.name.clone(),
                event,
                checksum_status: status,
                call_id: String::new(),
            });
        }
    }

    /// List all discovered skills (available + quarantined). Quarantined skills
    /// are included with `available == false` + a reason — never dropped.
    #[must_use]
    pub fn list(&self) -> Vec<SkillListing> {
        self.entries
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .map(|e| match &e.availability {
                Availability::Available => SkillListing {
                    name: e.name.clone(),
                    description: e.description.clone(),
                    kind: e.kind,
                    available: true,
                    reason: None,
                },
                Availability::Quarantined(reason) => SkillListing {
                    name: e.name.clone(),
                    description: e.description.clone(),
                    kind: e.kind,
                    available: false,
                    reason: Some(reason.clone()),
                },
            })
            .collect()
    }

    /// Return the full post-frontmatter `SKILL.md` body for prompt injection.
    ///
    /// Instruction-only skills activate freely. Executable skills are
    /// **re-verified** (integrity from disk) before their body is returned, so a
    /// skill tampered with after discovery cannot be activated.
    ///
    /// # Errors
    /// [`SkillHostError`] for unknown, quarantined, or (executable) newly-failing
    /// integrity.
    pub fn activate(&self, name: &str) -> Result<String, SkillHostError> {
        let entry = self.lookup(name)?;
        if let Availability::Quarantined(reason) = &entry.availability {
            return Err(SkillHostError::Quarantined {
                name: entry.name.clone(),
                reason: reason.clone(),
            });
        }
        // Re-verify executable skills against disk before handing out the body.
        if entry.kind == SkillKind::Executable {
            self.reverify(&entry)?;
        }
        let md_path = entry.dir.join(SKILL_MD);
        let content = std::fs::read_to_string(&md_path)
            .map_err(|_| SkillHostError::NotFound(entry.name.clone()))?;
        let front = parse::parse_skill_md(&content)
            .ok_or_else(|| SkillHostError::NotFound(entry.name.clone()))?;
        Ok(front.body)
    }

    /// Prepare a governed run of a skill script: re-verify integrity from disk,
    /// resolve the (declared) script, and build the `uv run --script …` command.
    /// The caller routes the command through the ToolHost bash tool — this does
    /// NOT execute anything itself.
    ///
    /// `script` selects `scripts/<script>.py`; when `None`, the first declared
    /// `.py` in the manifest is used (Swift `findExecutableScript` semantics).
    ///
    /// # Errors
    /// [`SkillHostError`] for unknown/quarantined/non-executable skills, an
    /// undeclared or missing script, or an audit-write failure (fail closed).
    pub fn prepare_run(
        &self,
        name: &str,
        script: Option<&str>,
        call_id: &str,
    ) -> Result<RunPlan, SkillHostError> {
        let entry = self.lookup(name)?;
        if let Availability::Quarantined(reason) = &entry.availability {
            return Err(SkillHostError::Quarantined {
                name: entry.name.clone(),
                reason: reason.clone(),
            });
        }
        if entry.kind != SkillKind::Executable {
            return Err(SkillHostError::NotExecutable(entry.name.clone()));
        }
        // Immediately-before-execution integrity re-check (fresh from disk).
        let integrity = self.reverify(&entry)?;

        // Resolve the script to a DECLARED checksum key (defense in depth: even
        // past the integrity gate, only a declared+verified script may run).
        let relative = resolve_script(script, &integrity)
            .ok_or_else(|| SkillHostError::ScriptNotFound(entry.name.clone()))?;
        let abs = entry.dir.join(&relative);
        if !abs.is_file() {
            return Err(SkillHostError::ScriptNotFound(entry.name.clone()));
        }

        // Audit BEFORE returning the plan — an unauditable run is refused.
        self.audit
            .record(SkillHostAuditRecord {
                event_type: "skill_event",
                ts_ms: self.clock.now_ms(),
                skill: entry.name.clone(),
                event: SkillEvent::Executed,
                checksum_status: "verified".into(),
                call_id: call_id.to_string(),
            })
            .map_err(|e| SkillHostError::Audit(e.to_string()))?;

        // Phase G4: bump the usage counter on successful run preparation.
        self.usage
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .increment(&entry.name, self.clock.now_ms());

        Ok(RunPlan {
            skill: entry.name.clone(),
            command: format!("uv run --script {}", shell_quote(&abs.to_string_lossy())),
        })
    }

    /// Return usage counters for all discovered skills, zero-filled for skills
    /// that have never run (Phase G4).
    #[must_use]
    pub fn list_usage(&self) -> Vec<usage::UsageListing> {
        let entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        self.usage
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .merged_listing(names.into_iter())
    }

    /// Move an `auto-*` skill to `<skills-parent>/skills-archived/<name>`
    /// (Phase G4). Fail-closed: `name` must start with `"auto-"` and be a
    /// currently discovered skill. Re-runs discovery after the move so
    /// subsequent `list`/`activate`/`run` calls no longer see it.
    ///
    /// # Errors
    /// [`SkillHostError::ArchiveRefused`] for non-`auto-` names,
    /// [`SkillHostError::NotFound`] for unknown skills, and
    /// [`SkillHostError::ArchiveMove`] for filesystem failures.
    pub fn archive(&self, name: &str) -> Result<(), SkillHostError> {
        if !name.starts_with("auto-") {
            return Err(SkillHostError::ArchiveRefused {
                name: name.to_string(),
                reason: "only auto-generated skills (name prefix 'auto-') may be archived"
                    .to_string(),
            });
        }
        let entry = self.lookup(name)?;
        let archive_root = self
            .skills_dir
            .parent()
            .ok_or_else(|| SkillHostError::ArchiveMove("skills dir has no parent".to_string()))?
            .join("skills-archived");
        std::fs::create_dir_all(&archive_root)
            .map_err(|e| SkillHostError::ArchiveMove(format!("create archive dir: {e}")))?;
        let target = archive_root.join(name);
        std::fs::rename(&entry.dir, &target).map_err(|e| {
            SkillHostError::ArchiveMove(format!("rename {}: {e}", entry.dir.display()))
        })?;
        // Re-discover so the archived skill disappears from all surfaces.
        *self.entries.lock().unwrap_or_else(PoisonError::into_inner) = discover(&self.skills_dir);
        Ok(())
    }

    /// Re-load + re-validate + re-verify an executable skill from disk. Returns
    /// the verified integrity block. Any failure is a fresh quarantine.
    fn reverify(&self, entry: &SkillEntry) -> Result<SkillIntegrity, SkillHostError> {
        match load_executable(&entry.dir) {
            Ok(integrity) => Ok(integrity),
            Err(reason) => Err(SkillHostError::Quarantined {
                name: entry.name.clone(),
                reason,
            }),
        }
    }

    /// Find a skill by name (cloned out of the entries lock), rejecting unsafe
    /// names.
    fn lookup(&self, name: &str) -> Result<SkillEntry, SkillHostError> {
        if !is_safe_skill_name(name) {
            return Err(SkillHostError::NotFound(name.to_string()));
        }
        self.entries
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|e| e.name == name)
            .cloned()
            .ok_or_else(|| SkillHostError::NotFound(name.to_string()))
    }
}

/// Scan `skills_dir` subdirectories into entries (one per `SKILL.md`).
fn discover(skills_dir: &Path) -> Vec<SkillEntry> {
    let mut entries = Vec::new();
    let Ok(read) = std::fs::read_dir(skills_dir) else {
        return entries;
    };
    for dirent in read.flatten() {
        let dir = dirent.path();
        if !dir.is_dir() {
            continue;
        }
        let md_path = dir.join(SKILL_MD);
        let Ok(content) = std::fs::read_to_string(&md_path) else {
            continue; // no SKILL.md ⇒ not a skill
        };
        let Some(front) = parse::parse_skill_md(&content) else {
            continue; // unparseable frontmatter ⇒ skip
        };
        if !is_safe_skill_name(&front.name) {
            continue;
        }
        let kind = if dir.join(SCRIPTS_DIR).is_dir() {
            SkillKind::Executable
        } else {
            SkillKind::Instruction
        };
        let availability = match kind {
            SkillKind::Instruction => Availability::Available,
            SkillKind::Executable => match load_executable(&dir) {
                Ok(_) => Availability::Available,
                Err(reason) => Availability::Quarantined(reason),
            },
        };
        entries.push(SkillEntry {
            name: front.name,
            description: front.description,
            kind,
            dir,
            availability,
        });
    }
    entries.sort_by(|a, b| a.name.cmp(&b.name));
    entries
}

/// Load + validate + integrity-verify an executable skill dir. Returns the
/// verified integrity block, or a quarantine reason.
fn load_executable(dir: &Path) -> Result<SkillIntegrity, String> {
    let manifest_path = dir.join(MANIFEST_JSON);
    let bytes = std::fs::read(&manifest_path).map_err(|_| "missing_manifest".to_string())?;
    let manifest = SkillManifest::parse(&bytes).map_err(|e| e.0)?;
    let integrity = manifest.validate_executable().map_err(|e| e.0)?;
    integrity::verify(&integrity.algorithm, &integrity.checksums, dir)?;
    Ok(integrity.clone())
}

/// Resolve the run target to a declared checksum key. With an explicit
/// `script`, require `scripts/<script>.py` to be declared. Without one, pick the
/// first declared `scripts/*.py` (deterministic: `checksums` is a `BTreeMap`,
/// so iteration is sorted).
fn resolve_script(script: Option<&str>, integrity: &SkillIntegrity) -> Option<String> {
    match script {
        Some(name) => {
            if !is_safe_script_name(name) {
                return None;
            }
            let key = format!("scripts/{name}.py");
            integrity.checksums.contains_key(&key).then_some(key)
        }
        None => integrity
            .checksums
            .keys()
            .find(|k| k.starts_with("scripts/") && k.ends_with(".py"))
            .cloned(),
    }
}

/// Skill-name safety (Swift `isSafeSkillName`): non-empty, and only
/// `[A-Za-z0-9._-]` (no path separators, no `..`).
fn is_safe_skill_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Script-name safety: same character class as a skill name (the caller appends
/// `.py`, so no extension/separators are permitted in the argument).
fn is_safe_script_name(name: &str) -> bool {
    is_safe_skill_name(name)
}

/// Minimal single-quote shell escaping for a path embedded in a bash command.
/// Wraps in single quotes and escapes any embedded single quote as `'\''`.
fn shell_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skillhost::audit::CapturingSkillAudit;
    use sha2::{Digest, Sha256};
    use std::collections::BTreeMap;

    fn hex_of(bytes: &[u8]) -> String {
        hex::encode(Sha256::digest(bytes))
    }

    struct FixedClock;
    impl ToolHostClock for FixedClock {
        fn now_ms(&self) -> u64 {
            1_700_000_000_000
        }
    }

    fn host(dir: &Path, audit: Arc<CapturingSkillAudit>) -> SkillHost {
        SkillHost::with_clock(dir, audit, Arc::new(FixedClock))
    }

    /// Write a valid executable skill `name` with one declared script.
    fn write_executable(root: &Path, name: &str) {
        let dir = root.join(name);
        std::fs::create_dir_all(dir.join("scripts")).expect("mkdir");
        let md = format!("---\nname: {name}\ndescription: does {name}\n---\n\nBody of {name}.\n");
        let script = b"print('ok')\n";
        std::fs::write(dir.join("SKILL.md"), md.as_bytes()).expect("md");
        std::fs::write(dir.join("scripts/run.py"), script).expect("py");
        let mut checksums = BTreeMap::new();
        checksums.insert("SKILL.md".to_string(), hex_of(md.as_bytes()));
        checksums.insert("scripts/run.py".to_string(), hex_of(script));
        let manifest = serde_json::json!({
            "schemaVersion": 1,
            "capabilities": ["execute"],
            "allowedTools": ["run_skill"],
            "timeoutSeconds": 120,
            "integrity": { "algorithm": "sha256", "checksums": checksums, "signature": null }
        });
        std::fs::write(
            dir.join("MANIFEST.json"),
            serde_json::to_vec_pretty(&manifest).expect("json"),
        )
        .expect("manifest");
    }

    fn write_instruction(root: &Path, name: &str) {
        let dir = root.join(name);
        std::fs::create_dir_all(&dir).expect("mkdir");
        let md = format!(
            "---\nname: {name}\ndescription: instr {name}\n---\n\nInstructions for {name}.\n"
        );
        std::fs::write(dir.join("SKILL.md"), md.as_bytes()).expect("md");
    }

    #[test]
    fn golden_executable_is_listed_activatable_runnable() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        let audit = Arc::new(CapturingSkillAudit::new());
        let h = host(root.path(), Arc::clone(&audit));

        // Listed + available.
        let listing = h.list();
        assert_eq!(listing.len(), 1);
        assert_eq!(listing[0].name, "forge");
        assert!(listing[0].available);
        assert_eq!(listing[0].kind, SkillKind::Executable);

        // Discovery audited a loaded/verified row.
        let rows = audit.snapshot();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].event, SkillEvent::Loaded);
        assert_eq!(rows[0].checksum_status, "verified");

        // Activatable (returns the body).
        let body = h.activate("forge").expect("activate");
        assert!(body.contains("Body of forge."));

        // Runnable (builds a uv run command + audits an executed row).
        let plan = h.prepare_run("forge", None, "call-1").expect("run");
        assert!(plan.command.starts_with("uv run --script "));
        assert!(plan.command.contains("scripts/run.py"));
        let executed: Vec<_> = audit
            .snapshot()
            .into_iter()
            .filter(|r| r.event == SkillEvent::Executed)
            .collect();
        assert_eq!(executed.len(), 1);
        assert_eq!(executed[0].call_id, "call-1");
    }

    #[test]
    fn tampered_script_byte_quarantines() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        // Corrupt the script AFTER writing the manifest.
        std::fs::write(root.path().join("forge/scripts/run.py"), b"print('EVIL')\n").expect("rw");
        let audit = Arc::new(CapturingSkillAudit::new());
        let h = host(root.path(), Arc::clone(&audit));
        let listing = h.list();
        assert!(!listing[0].available);
        assert_eq!(
            listing[0].reason.as_deref(),
            Some("modified:scripts/run.py")
        );
        // Cannot run or activate a quarantined skill.
        assert!(matches!(
            h.prepare_run("forge", None, "c"),
            Err(SkillHostError::Quarantined { .. })
        ));
        assert!(matches!(
            h.activate("forge"),
            Err(SkillHostError::Quarantined { .. })
        ));
        // Audited as quarantined.
        assert_eq!(audit.snapshot()[0].event, SkillEvent::Quarantined);
    }

    #[test]
    fn undeclared_extra_script_quarantines() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        std::fs::write(root.path().join("forge/scripts/evil.py"), b"boom\n").expect("evil");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        let listing = h.list();
        assert!(!listing[0].available);
        assert_eq!(
            listing[0].reason.as_deref(),
            Some("undeclared_script:scripts/evil.py")
        );
    }

    #[test]
    fn missing_manifest_on_executable_quarantines() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        std::fs::remove_file(root.path().join("forge/MANIFEST.json")).expect("rm");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        let listing = h.list();
        assert!(!listing[0].available);
        assert_eq!(listing[0].reason.as_deref(), Some("missing_manifest"));
        assert!(matches!(
            h.prepare_run("forge", None, "c"),
            Err(SkillHostError::Quarantined { .. })
        ));
    }

    #[test]
    fn instruction_only_skill_activatable_without_manifest() {
        let root = tempfile::tempdir().expect("tmp");
        write_instruction(root.path(), "proactive-awareness");
        let audit = Arc::new(CapturingSkillAudit::new());
        let h = host(root.path(), Arc::clone(&audit));
        let listing = h.list();
        assert!(listing[0].available);
        assert_eq!(listing[0].kind, SkillKind::Instruction);
        let body = h.activate("proactive-awareness").expect("activate");
        assert!(body.contains("Instructions for proactive-awareness."));
        // Instruction skills cannot be run.
        assert!(matches!(
            h.prepare_run("proactive-awareness", None, "c"),
            Err(SkillHostError::NotExecutable(_))
        ));
        assert_eq!(audit.snapshot()[0].checksum_status, "instruction_only");
    }

    #[test]
    fn unknown_skill_is_not_found() {
        let root = tempfile::tempdir().expect("tmp");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        assert!(matches!(
            h.activate("nope"),
            Err(SkillHostError::NotFound(_))
        ));
        assert!(matches!(
            h.prepare_run("nope", None, "c"),
            Err(SkillHostError::NotFound(_))
        ));
    }

    #[test]
    fn unsafe_skill_name_rejected() {
        let root = tempfile::tempdir().expect("tmp");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        assert!(matches!(
            h.activate("../etc/passwd"),
            Err(SkillHostError::NotFound(_))
        ));
    }

    #[test]
    fn run_audit_failure_fails_closed() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        let audit = Arc::new(CapturingSkillAudit::new());
        let h = host(root.path(), Arc::clone(&audit));
        audit.set_failing();
        assert!(matches!(
            h.prepare_run("forge", None, "c"),
            Err(SkillHostError::Audit(_))
        ));
    }

    #[test]
    fn usage_counter_increments_on_prepare_run() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        let before = h.list_usage();
        let forge = before.iter().find(|l| l.name == "forge").expect("forge");
        assert_eq!(forge.run_count, 0);
        assert_eq!(forge.first_seen_ms, Some(1_700_000_000_000));
        h.prepare_run("forge", None, "c1").expect("run");
        let after = h.list_usage();
        let forge = after.iter().find(|l| l.name == "forge").expect("forge");
        assert_eq!(forge.run_count, 1);
        assert_eq!(forge.last_used_ms, Some(1_700_000_000_000));
    }

    #[test]
    fn archive_non_auto_skill_refused() {
        let root = tempfile::tempdir().expect("tmp");
        write_instruction(root.path(), "collaborate");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        assert!(matches!(
            h.archive("collaborate"),
            Err(SkillHostError::ArchiveRefused { .. })
        ));
        // Still listed after the refused archive.
        assert_eq!(h.list().len(), 1);
    }

    #[test]
    fn archive_unknown_auto_skill_not_found() {
        let root = tempfile::tempdir().expect("tmp");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        assert!(matches!(
            h.archive("auto-ghost"),
            Err(SkillHostError::NotFound(_))
        ));
    }

    #[test]
    fn archive_auto_skill_moves_and_disappears_from_list() {
        let root = tempfile::tempdir().expect("tmp");
        // Skills live under <root>/skills so the archive lands at
        // <root>/skills-archived (sibling of the skills dir).
        let skills = root.path().join("skills");
        std::fs::create_dir_all(&skills).expect("mkdir");
        write_instruction(&skills, "auto-test-fixture");
        let h = host(&skills, Arc::new(CapturingSkillAudit::new()));
        assert_eq!(h.list().len(), 1);
        h.archive("auto-test-fixture").expect("archive");
        assert!(h.list().is_empty());
        assert!(root
            .path()
            .join("skills-archived/auto-test-fixture/SKILL.md")
            .is_file());
        // Gone from all surfaces after re-discovery.
        assert!(matches!(
            h.activate("auto-test-fixture"),
            Err(SkillHostError::NotFound(_))
        ));
    }

    #[test]
    fn named_undeclared_script_not_found() {
        let root = tempfile::tempdir().expect("tmp");
        write_executable(root.path(), "forge");
        let h = host(root.path(), Arc::new(CapturingSkillAudit::new()));
        // "run" is declared; "ghost" is not.
        assert!(h.prepare_run("forge", Some("run"), "c").is_ok());
        assert!(matches!(
            h.prepare_run("forge", Some("ghost"), "c"),
            Err(SkillHostError::ScriptNotFound(_))
        ));
        // A traversal script name is rejected.
        assert!(matches!(
            h.prepare_run("forge", Some("../evil"), "c"),
            Err(SkillHostError::ScriptNotFound(_))
        ));
    }
}
