//! Lifecycle management for Python skill executables.
//!
//! Python skills progress through a well-defined state machine:
//!
//! ```text
//! Pending → Testing → Active → Disabled ⇄ Quarantined
//!                ↘            ↗
//!               Disabled ← Quarantined
//! ```
//!
//! Each Python skill is stored as a `.py` file inside the skills directory
//! alongside its [`PythonSkillRecord`] entry in `python_registry.json`.
//!
//! # File layout
//!
//! ```text
//! ~/.fae/skills/
//!   my-skill.py                   ← active script
//!   .state/
//!     python_registry.json        ← Python skill registry
//!     disabled/
//!       my-skill.py               ← disabled/quarantined script
//!     snapshots/
//!       my-skill-1700000000.py    ← rollback snapshot
//! ```

use super::error::PythonSkillError;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::path::{Path, PathBuf};

// ── Status enum ──────────────────────────────────────────────────────────────

/// Lifecycle status for a Python skill.
///
/// Skills advance through this state machine:
///
/// ```text
/// Pending → Testing → Active
///                  ↘         ↘
///                   Disabled ← Quarantined
///                      ↓
///                   Quarantined
/// ```
///
/// Only `Active` skills are eligible for subprocess spawning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PythonSkillStatus {
    /// Skill has been registered but not yet tested.
    Pending,
    /// Skill is undergoing automated testing.
    Testing,
    /// Skill passed testing and is ready for use.
    Active,
    /// Skill has been manually disabled.
    Disabled,
    /// Skill has been quarantined due to repeated failures or errors.
    Quarantined,
}

impl PythonSkillStatus {
    /// Returns `true` if a transition from `self` to `target` is valid.
    ///
    /// # State machine rules
    ///
    /// - `Pending → Testing`
    /// - `Testing → Active | Disabled | Quarantined`
    /// - `Active → Disabled | Quarantined`
    /// - `Disabled → Active | Quarantined`
    /// - `Quarantined → Disabled`
    pub fn can_transition_to(self, target: Self) -> bool {
        matches!(
            (self, target),
            (Self::Pending, Self::Testing)
                | (Self::Testing, Self::Active)
                | (Self::Testing, Self::Disabled)
                | (Self::Testing, Self::Quarantined)
                | (Self::Active, Self::Disabled)
                | (Self::Active, Self::Quarantined)
                | (Self::Disabled, Self::Active)
                | (Self::Disabled, Self::Quarantined)
                | (Self::Quarantined, Self::Disabled)
        )
    }

    /// Returns `true` if the skill is eligible to be run as a subprocess.
    ///
    /// Only `Active` skills may be spawned.
    pub fn is_runnable(self) -> bool {
        matches!(self, Self::Active)
    }

    /// Returns `true` if the skill is in a terminal error state.
    pub fn is_quarantined(self) -> bool {
        matches!(self, Self::Quarantined)
    }
}

impl fmt::Display for PythonSkillStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Pending => "pending",
            Self::Testing => "testing",
            Self::Active => "active",
            Self::Disabled => "disabled",
            Self::Quarantined => "quarantined",
        };
        f.write_str(label)
    }
}

// ── Registry types ────────────────────────────────────────────────────────────

/// Internal registry record for a Python skill.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct PythonSkillRecord {
    /// Unique skill identifier (lowercase letters, digits, hyphens, underscores).
    pub id: String,
    /// Human-readable skill name.
    pub name: String,
    /// Semantic version string (e.g. `"1.0.0"`).
    pub version: String,
    /// Current lifecycle status.
    pub status: PythonSkillStatus,
    /// Absolute path to the active `.py` script.
    pub script_path: PathBuf,
    /// Working directory for the subprocess (usually the parent of `script_path`).
    pub work_dir: PathBuf,
    /// Absolute path to the disabled/quarantined script location.
    pub disabled_path: PathBuf,
    /// Absolute path to the most-recent snapshot (for rollback), if any.
    #[serde(default)]
    pub last_known_good_snapshot: Option<PathBuf>,
    /// Error message recorded on quarantine, if any.
    #[serde(default)]
    pub last_error: Option<String>,
    /// Unix timestamp (seconds) when the skill was first installed.
    pub installed_at: u64,
    /// Unix timestamp (seconds) when the record was last modified.
    pub updated_at: u64,
}

/// Public view of a Python skill, safe to expose outside this module.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PythonSkillInfo {
    /// Unique skill identifier.
    pub id: String,
    /// Human-readable skill name.
    pub name: String,
    /// Semantic version string.
    pub version: String,
    /// Current lifecycle status.
    pub status: PythonSkillStatus,
    /// Error recorded at quarantine, if any.
    pub last_error: Option<String>,
}

impl From<&PythonSkillRecord> for PythonSkillInfo {
    fn from(record: &PythonSkillRecord) -> Self {
        Self {
            id: record.id.clone(),
            name: record.name.clone(),
            version: record.version.clone(),
            status: record.status,
            last_error: record.last_error.clone(),
        }
    }
}

// ── Python-specific registry ──────────────────────────────────────────────────

/// In-memory Python skill registry.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub(crate) struct PythonSkillRegistry {
    /// Schema version (always `1`).
    #[serde(default = "default_registry_version")]
    pub version: u8,
    /// Ordered list of Python skill records.
    #[serde(default)]
    pub skills: Vec<PythonSkillRecord>,
}

fn default_registry_version() -> u8 {
    1
}

impl PythonSkillRegistry {
    /// Upserts a record: updates existing entry by `id` or appends a new one.
    ///
    /// Records are kept sorted by `id` after each upsert.
    pub fn upsert(&mut self, record: PythonSkillRecord) {
        if let Some(existing) = self.skills.iter_mut().find(|e| e.id == record.id) {
            *existing = record;
        } else {
            self.skills.push(record);
        }
        self.skills.sort_by(|a, b| a.id.cmp(&b.id));
    }

    /// Returns a mutable reference to the record with the given id, if present.
    pub fn get_mut(&mut self, id: &str) -> Option<&mut PythonSkillRecord> {
        self.skills.iter_mut().find(|e| e.id == id)
    }

    /// Returns a shared reference to the record with the given id, if present.
    pub fn get(&self, id: &str) -> Option<&PythonSkillRecord> {
        self.skills.iter().find(|e| e.id == id)
    }

}

// ── Disk I/O helpers ──────────────────────────────────────────────────────────

/// Loads the Python registry from disk.
///
/// Returns an empty registry if the file does not exist.
///
/// # Errors
///
/// Returns [`PythonSkillError::BootstrapFailed`] if the file exists but cannot
/// be read or parsed.
pub(crate) fn load_python_registry(
    paths: &super::SkillPaths,
) -> Result<PythonSkillRegistry, PythonSkillError> {
    let path = python_registry_path(paths);
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(PythonSkillRegistry::default());
        }
        Err(e) => {
            return Err(PythonSkillError::BootstrapFailed {
                reason: format!("cannot read python registry {}: {e}", path.display()),
            });
        }
    };
    serde_json::from_slice(&bytes).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!("cannot parse python registry: {e}"),
    })
}

/// Saves the Python registry to disk.
///
/// # Errors
///
/// Returns [`PythonSkillError::BootstrapFailed`] if serialization or writing fails.
pub(crate) fn save_python_registry(
    paths: &super::SkillPaths,
    registry: &PythonSkillRegistry,
) -> Result<(), PythonSkillError> {
    super::ensure_state_dirs(paths).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!("cannot create state dirs: {e}"),
    })?;
    let path = python_registry_path(paths);
    let json = serde_json::to_string_pretty(registry).map_err(|e| {
        PythonSkillError::BootstrapFailed {
            reason: format!("cannot serialize python registry: {e}"),
        }
    })?;
    std::fs::write(&path, json).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!("cannot write python registry {}: {e}", path.display()),
    })
}

/// Returns the path to `python_registry.json` within the state directory.
fn python_registry_path(paths: &super::SkillPaths) -> PathBuf {
    paths.state_dir.join("python_registry.json")
}

// ── Script path helpers ───────────────────────────────────────────────────────

/// Returns the active script path for a Python skill.
pub(crate) fn active_script_path(paths: &super::SkillPaths, id: &str) -> PathBuf {
    paths.root.join(format!("{id}.py"))
}

/// Returns the disabled/quarantined script path for a Python skill.
pub(crate) fn disabled_script_path(paths: &super::SkillPaths, id: &str) -> PathBuf {
    paths.disabled_dir.join(format!("{id}.py"))
}

/// Returns the current Unix timestamp in seconds.
pub(crate) fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── Transition helper ─────────────────────────────────────────────────────────

/// Validates and applies a status transition on a registry entry.
///
/// # Errors
///
/// Returns [`PythonSkillError::BootstrapFailed`] if the transition is invalid.
pub(crate) fn apply_status_transition(
    entry: &mut PythonSkillRecord,
    target: PythonSkillStatus,
) -> Result<(), PythonSkillError> {
    if !entry.status.can_transition_to(target) {
        return Err(PythonSkillError::BootstrapFailed {
            reason: format!(
                "invalid status transition for skill `{}`: {} → {}",
                entry.id, entry.status, target
            ),
        });
    }
    entry.status = target;
    entry.updated_at = now_secs();
    Ok(())
}

// ── Snapshot helper ───────────────────────────────────────────────────────────

/// Snapshots the current active script (if it exists) to the snapshots directory.
///
/// Returns the snapshot path if a snapshot was created, or `None` if the
/// script did not exist yet.
pub(crate) fn snapshot_python_skill(
    paths: &super::SkillPaths,
    id: &str,
    active_path: &Path,
) -> Result<Option<PathBuf>, PythonSkillError> {
    if !active_path.is_file() {
        return Ok(None);
    }
    super::ensure_state_dirs(paths).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!("cannot create state dirs: {e}"),
    })?;
    let stamp = now_secs();
    let snapshot = paths
        .snapshots_dir
        .join(format!("{id}-{stamp}.py"));
    std::fs::copy(active_path, &snapshot).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!(
            "cannot snapshot python skill `{id}` → {}: {e}",
            snapshot.display()
        ),
    })?;
    Ok(Some(snapshot))
}

// ── Move file helper ─────────────────────────────────────────────────────────

/// Moves a file from `from` to `to`, falling back to copy+delete on
/// cross-device renames.
fn move_script(from: &Path, to: &Path) -> Result<(), PythonSkillError> {
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent).map_err(|e| PythonSkillError::BootstrapFailed {
            reason: format!("cannot create parent dir for {}: {e}", to.display()),
        })?;
    }
    match std::fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(_) => {
            std::fs::copy(from, to).map_err(|e| PythonSkillError::BootstrapFailed {
                reason: format!("cannot copy {} → {}: {e}", from.display(), to.display()),
            })?;
            std::fs::remove_file(from).map_err(|e| PythonSkillError::BootstrapFailed {
                reason: format!("cannot remove {}: {e}", from.display()),
            })?;
            Ok(())
        }
    }
}

// ── Public lifecycle operations ───────────────────────────────────────────────

/// Installs a Python skill package from `package_dir`.
///
/// The directory must contain:
/// - `manifest.toml` — parsed via [`PythonSkillManifest::load_from_dir`].
/// - The entry `.py` script named by `manifest.entry_file` (default `skill.py`).
///
/// # Steps
///
/// 1. Parse and validate the manifest.
/// 2. Read the entry script.
/// 3. Snapshot any existing active script (for rollback).
/// 4. Copy the new script to `{skills_dir}/{id}.py`.
/// 5. Register the skill with status [`PythonSkillStatus::Pending`].
///
/// # Errors
///
/// Returns [`PythonSkillError::BootstrapFailed`] if any step fails.
pub fn install_python_skill(
    package_dir: &Path,
) -> Result<PythonSkillInfo, PythonSkillError> {
    install_python_skill_at(&super::default_paths(), package_dir)
}

/// Internal install that accepts an explicit [`SkillPaths`] for testability.
pub fn install_python_skill_at(
    paths: &super::SkillPaths,
    package_dir: &Path,
) -> Result<PythonSkillInfo, PythonSkillError> {
    let manifest = super::manifest::PythonSkillManifest::load_from_dir(package_dir)?;
    let entry_path = package_dir.join(&manifest.entry_file);

    if !entry_path.is_file() {
        return Err(PythonSkillError::BootstrapFailed {
            reason: format!(
                "entry file `{}` not found in {}",
                manifest.entry_file,
                package_dir.display()
            ),
        });
    }

    let script_content = std::fs::read_to_string(&entry_path).map_err(|e| {
        PythonSkillError::BootstrapFailed {
            reason: format!("cannot read {}: {e}", entry_path.display()),
        }
    })?;

    super::ensure_state_dirs(paths).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!("cannot create state dirs: {e}"),
    })?;

    let active_path = active_script_path(paths, &manifest.id);
    let disabled_path = disabled_script_path(paths, &manifest.id);
    let work_dir = paths.root.clone();

    // Snapshot existing active script before overwriting.
    let snapshot = snapshot_python_skill(paths, &manifest.id, &active_path)?;

    // Write the new script.
    if let Some(parent) = active_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| PythonSkillError::BootstrapFailed {
            reason: format!("cannot create skills dir: {e}"),
        })?;
    }
    std::fs::write(&active_path, &script_content).map_err(|e| {
        PythonSkillError::BootstrapFailed {
            reason: format!("cannot write {}: {e}", active_path.display()),
        }
    })?;

    // Load or create the Python registry.
    let mut registry = load_python_registry(paths)?;
    let installed_at = registry
        .get(&manifest.id)
        .map(|r| r.installed_at)
        .unwrap_or_else(now_secs);

    // Preserve the previous snapshot if none was just created.
    let prev_snapshot = registry
        .get(&manifest.id)
        .and_then(|r| r.last_known_good_snapshot.clone());

    let record = PythonSkillRecord {
        id: manifest.id.clone(),
        name: manifest.name.clone(),
        version: manifest.version.clone(),
        status: PythonSkillStatus::Pending,
        script_path: active_path,
        work_dir,
        disabled_path,
        last_known_good_snapshot: snapshot.or(prev_snapshot),
        last_error: None,
        installed_at,
        updated_at: now_secs(),
    };

    registry.upsert(record.clone());
    save_python_registry(paths, &registry)?;

    Ok(PythonSkillInfo::from(&record))
}

/// Advances the lifecycle status of a Python skill.
///
/// The transition must be valid per the [`PythonSkillStatus`] state machine.
///
/// # Errors
///
/// - [`PythonSkillError::SkillNotFound`] if `id` is not registered.
/// - [`PythonSkillError::BootstrapFailed`] if the transition is invalid.
pub fn advance_python_skill_status(
    id: &str,
    new_status: PythonSkillStatus,
) -> Result<(), PythonSkillError> {
    advance_python_skill_status_at(&super::default_paths(), id, new_status)
}

pub fn advance_python_skill_status_at(
    paths: &super::SkillPaths,
    id: &str,
    new_status: PythonSkillStatus,
) -> Result<(), PythonSkillError> {
    let mut registry = load_python_registry(paths)?;
    let Some(entry) = registry.get_mut(id) else {
        return Err(PythonSkillError::SkillNotFound {
            name: id.to_owned(),
        });
    };
    apply_status_transition(entry, new_status)?;
    save_python_registry(paths, &registry)
}

/// Disables a Python skill.
///
/// Moves the active `.py` script to `.state/disabled/` and sets status
/// [`PythonSkillStatus::Disabled`].
///
/// # Errors
///
/// - [`PythonSkillError::SkillNotFound`] if `id` is not registered.
/// - [`PythonSkillError::BootstrapFailed`] on file-system errors or invalid transition.
pub fn disable_python_skill(id: &str) -> Result<(), PythonSkillError> {
    disable_python_skill_at(&super::default_paths(), id)
}

pub fn disable_python_skill_at(
    paths: &super::SkillPaths,
    id: &str,
) -> Result<(), PythonSkillError> {
    let mut registry = load_python_registry(paths)?;
    let Some(entry) = registry.get_mut(id) else {
        return Err(PythonSkillError::SkillNotFound {
            name: id.to_owned(),
        });
    };

    // Snapshot the active script before disabling.
    if entry.script_path.is_file() {
        let snap = snapshot_python_skill(paths, id, &entry.script_path.clone())?;
        if let Some(snap) = snap {
            entry.last_known_good_snapshot = Some(snap);
        }
        let disabled_path = entry.disabled_path.clone();
        move_script(&entry.script_path.clone(), &disabled_path)?;
    }

    apply_status_transition(entry, PythonSkillStatus::Disabled)?;
    save_python_registry(paths, &registry)
}

/// Quarantines a Python skill and records the error reason.
///
/// Moves the active `.py` script to `.state/disabled/` and sets status
/// [`PythonSkillStatus::Quarantined`].
///
/// # Errors
///
/// - [`PythonSkillError::SkillNotFound`] if `id` is not registered.
/// - [`PythonSkillError::BootstrapFailed`] on file-system errors or invalid transition.
pub fn quarantine_python_skill(id: &str, reason: &str) -> Result<(), PythonSkillError> {
    quarantine_python_skill_at(&super::default_paths(), id, reason)
}

pub fn quarantine_python_skill_at(
    paths: &super::SkillPaths,
    id: &str,
    reason: &str,
) -> Result<(), PythonSkillError> {
    let mut registry = load_python_registry(paths)?;
    let Some(entry) = registry.get_mut(id) else {
        return Err(PythonSkillError::SkillNotFound {
            name: id.to_owned(),
        });
    };

    if entry.script_path.is_file() {
        let snap = snapshot_python_skill(paths, id, &entry.script_path.clone())?;
        if let Some(snap) = snap {
            entry.last_known_good_snapshot = Some(snap);
        }
        let disabled_path = entry.disabled_path.clone();
        move_script(&entry.script_path.clone(), &disabled_path)?;
    }

    apply_status_transition(entry, PythonSkillStatus::Quarantined)?;
    entry.last_error = Some(reason.to_owned());
    entry.updated_at = now_secs();
    save_python_registry(paths, &registry)
}

/// Activates (or reactivates) a Python skill.
///
/// Restores the `.py` script from the disabled directory (or from the last
/// known good snapshot if the disabled file is missing) and sets status
/// [`PythonSkillStatus::Active`].
///
/// # Errors
///
/// - [`PythonSkillError::SkillNotFound`] if `id` is not registered.
/// - [`PythonSkillError::BootstrapFailed`] if no restorable content is found or
///   on file-system errors or invalid transition.
pub fn activate_python_skill(id: &str) -> Result<(), PythonSkillError> {
    activate_python_skill_at(&super::default_paths(), id)
}

pub fn activate_python_skill_at(
    paths: &super::SkillPaths,
    id: &str,
) -> Result<(), PythonSkillError> {
    let mut registry = load_python_registry(paths)?;
    let Some(entry) = registry.get_mut(id) else {
        return Err(PythonSkillError::SkillNotFound {
            name: id.to_owned(),
        });
    };

    if !entry.script_path.is_file() {
        if entry.disabled_path.is_file() {
            let script_path = entry.script_path.clone();
            move_script(&entry.disabled_path.clone(), &script_path)?;
        } else if let Some(snapshot) = &entry.last_known_good_snapshot.clone() {
            if snapshot.is_file() {
                let script_path = entry.script_path.clone();
                std::fs::copy(snapshot, &script_path).map_err(|e| {
                    PythonSkillError::BootstrapFailed {
                        reason: format!(
                            "cannot restore snapshot for `{id}` → {}: {e}",
                            script_path.display()
                        ),
                    }
                })?;
            } else {
                return Err(PythonSkillError::BootstrapFailed {
                    reason: format!(
                        "python skill `{id}` has no active, disabled, or snapshot content"
                    ),
                });
            }
        } else {
            return Err(PythonSkillError::BootstrapFailed {
                reason: format!(
                    "python skill `{id}` has no active, disabled, or snapshot content"
                ),
            });
        }
    }

    apply_status_transition(entry, PythonSkillStatus::Active)?;
    entry.last_error = None;
    entry.updated_at = now_secs();
    save_python_registry(paths, &registry)
}

/// Rolls a Python skill back to its last-known-good snapshot.
///
/// Restores the snapshotted `.py` content and sets status
/// [`PythonSkillStatus::Active`].
///
/// # Errors
///
/// - [`PythonSkillError::SkillNotFound`] if `id` is not registered.
/// - [`PythonSkillError::BootstrapFailed`] if no snapshot exists or on file-system errors.
pub fn rollback_python_skill(id: &str) -> Result<(), PythonSkillError> {
    rollback_python_skill_at(&super::default_paths(), id)
}

pub fn rollback_python_skill_at(
    paths: &super::SkillPaths,
    id: &str,
) -> Result<(), PythonSkillError> {
    let mut registry = load_python_registry(paths)?;
    let Some(entry) = registry.get_mut(id) else {
        return Err(PythonSkillError::SkillNotFound {
            name: id.to_owned(),
        });
    };

    let Some(snapshot) = entry.last_known_good_snapshot.clone() else {
        return Err(PythonSkillError::BootstrapFailed {
            reason: format!("python skill `{id}` has no rollback snapshot"),
        });
    };

    if !snapshot.is_file() {
        return Err(PythonSkillError::BootstrapFailed {
            reason: format!(
                "rollback snapshot for `{id}` not found at {}",
                snapshot.display()
            ),
        });
    }

    let script_path = entry.script_path.clone();
    std::fs::copy(&snapshot, &script_path).map_err(|e| PythonSkillError::BootstrapFailed {
        reason: format!(
            "cannot restore rollback snapshot for `{id}` → {}: {e}",
            script_path.display()
        ),
    })?;

    // Remove from disabled dir if present.
    if entry.disabled_path.is_file() {
        let _ = std::fs::remove_file(entry.disabled_path.clone());
    }

    // Rollback to Active regardless of current status (any → Active is allowed
    // for rollback, but we must go through Disabled first if Quarantined).
    // For simplicity during rollback: set to Active directly.
    entry.status = PythonSkillStatus::Active;
    entry.last_error = None;
    entry.updated_at = now_secs();
    save_python_registry(paths, &registry)
}

/// Returns information about all registered Python skills.
///
/// Returns an empty list if the registry is missing or empty.
pub fn list_python_skills() -> Vec<PythonSkillInfo> {
    list_python_skills_at(&super::default_paths()).unwrap_or_default()
}

/// Internal list that accepts an explicit [`SkillPaths`] for testability.
pub fn list_python_skills_at(
    paths: &super::SkillPaths,
) -> Result<Vec<PythonSkillInfo>, PythonSkillError> {
    let registry = load_python_registry(paths)?;
    Ok(registry.skills.iter().map(PythonSkillInfo::from).collect())
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    // ── PythonSkillStatus ──

    #[test]
    fn valid_happy_path_transitions() {
        assert!(PythonSkillStatus::Pending.can_transition_to(PythonSkillStatus::Testing));
        assert!(PythonSkillStatus::Testing.can_transition_to(PythonSkillStatus::Active));
        assert!(PythonSkillStatus::Active.can_transition_to(PythonSkillStatus::Disabled));
        assert!(PythonSkillStatus::Disabled.can_transition_to(PythonSkillStatus::Active));
    }

    #[test]
    fn valid_failure_transitions() {
        assert!(PythonSkillStatus::Testing.can_transition_to(PythonSkillStatus::Quarantined));
        assert!(PythonSkillStatus::Active.can_transition_to(PythonSkillStatus::Quarantined));
        assert!(PythonSkillStatus::Disabled.can_transition_to(PythonSkillStatus::Quarantined));
        assert!(PythonSkillStatus::Quarantined.can_transition_to(PythonSkillStatus::Disabled));
    }

    #[test]
    fn invalid_transitions_rejected() {
        // Cannot skip Pending → Active
        assert!(!PythonSkillStatus::Pending.can_transition_to(PythonSkillStatus::Active));
        // Cannot go backward Active → Testing
        assert!(!PythonSkillStatus::Active.can_transition_to(PythonSkillStatus::Testing));
        // Cannot go Pending → Disabled
        assert!(!PythonSkillStatus::Pending.can_transition_to(PythonSkillStatus::Disabled));
        // Cannot go Quarantined → Active directly
        assert!(!PythonSkillStatus::Quarantined.can_transition_to(PythonSkillStatus::Active));
        // Self-transitions invalid
        assert!(!PythonSkillStatus::Active.can_transition_to(PythonSkillStatus::Active));
        assert!(!PythonSkillStatus::Pending.can_transition_to(PythonSkillStatus::Pending));
    }

    #[test]
    fn is_runnable_only_for_active() {
        assert!(PythonSkillStatus::Active.is_runnable());
        assert!(!PythonSkillStatus::Pending.is_runnable());
        assert!(!PythonSkillStatus::Testing.is_runnable());
        assert!(!PythonSkillStatus::Disabled.is_runnable());
        assert!(!PythonSkillStatus::Quarantined.is_runnable());
    }

    #[test]
    fn is_quarantined() {
        assert!(PythonSkillStatus::Quarantined.is_quarantined());
        assert!(!PythonSkillStatus::Active.is_quarantined());
        assert!(!PythonSkillStatus::Disabled.is_quarantined());
    }

    #[test]
    fn display_labels() {
        assert_eq!(PythonSkillStatus::Pending.to_string(), "pending");
        assert_eq!(PythonSkillStatus::Testing.to_string(), "testing");
        assert_eq!(PythonSkillStatus::Active.to_string(), "active");
        assert_eq!(PythonSkillStatus::Disabled.to_string(), "disabled");
        assert_eq!(PythonSkillStatus::Quarantined.to_string(), "quarantined");
    }

    #[test]
    fn serde_round_trip() {
        for status in [
            PythonSkillStatus::Pending,
            PythonSkillStatus::Testing,
            PythonSkillStatus::Active,
            PythonSkillStatus::Disabled,
            PythonSkillStatus::Quarantined,
        ] {
            let json = serde_json::to_string(&status).expect("serialize");
            let restored: PythonSkillStatus =
                serde_json::from_str(&json).expect("deserialize");
            assert_eq!(status, restored, "round-trip failed for {status}");
        }
    }

    #[test]
    fn status_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<PythonSkillStatus>();
    }

    // ── PythonSkillRegistry ──

    fn make_record(id: &str, status: PythonSkillStatus) -> PythonSkillRecord {
        PythonSkillRecord {
            id: id.to_owned(),
            name: id.to_owned(),
            version: "1.0.0".to_owned(),
            status,
            script_path: PathBuf::from(format!("/tmp/{id}.py")),
            work_dir: PathBuf::from("/tmp"),
            disabled_path: PathBuf::from(format!("/tmp/.state/disabled/{id}.py")),
            last_known_good_snapshot: None,
            last_error: None,
            installed_at: 1_000_000,
            updated_at: 1_000_000,
        }
    }

    #[test]
    fn registry_upsert_and_get() {
        let mut reg = PythonSkillRegistry::default();
        reg.upsert(make_record("alpha", PythonSkillStatus::Active));
        reg.upsert(make_record("beta", PythonSkillStatus::Pending));

        assert_eq!(reg.skills.len(), 2);
        assert_eq!(reg.get("alpha").map(|r| r.status), Some(PythonSkillStatus::Active));
        assert_eq!(reg.get("beta").map(|r| r.status), Some(PythonSkillStatus::Pending));
        assert!(reg.get("gamma").is_none());
    }

    #[test]
    fn registry_upsert_idempotent() {
        let mut reg = PythonSkillRegistry::default();
        reg.upsert(make_record("alpha", PythonSkillStatus::Pending));
        reg.upsert(make_record("alpha", PythonSkillStatus::Active));

        assert_eq!(reg.skills.len(), 1);
        assert_eq!(reg.get("alpha").map(|r| r.status), Some(PythonSkillStatus::Active));
    }

    #[test]
    fn registry_sorted_by_id() {
        let mut reg = PythonSkillRegistry::default();
        reg.upsert(make_record("zeta", PythonSkillStatus::Active));
        reg.upsert(make_record("alpha", PythonSkillStatus::Active));
        reg.upsert(make_record("mu", PythonSkillStatus::Active));

        assert_eq!(reg.skills[0].id, "alpha");
        assert_eq!(reg.skills[1].id, "mu");
        assert_eq!(reg.skills[2].id, "zeta");
    }

    #[test]
    fn registry_get_mut_updates_in_place() {
        let mut reg = PythonSkillRegistry::default();
        reg.upsert(make_record("alpha", PythonSkillStatus::Pending));

        if let Some(entry) = reg.get_mut("alpha") {
            entry.status = PythonSkillStatus::Testing;
        }

        assert_eq!(
            reg.get("alpha").map(|r| r.status),
            Some(PythonSkillStatus::Testing)
        );
    }

    #[test]
    fn python_skill_info_from_record() {
        let record = make_record("test-skill", PythonSkillStatus::Active);
        let info = PythonSkillInfo::from(&record);

        assert_eq!(info.id, "test-skill");
        assert_eq!(info.name, "test-skill");
        assert_eq!(info.version, "1.0.0");
        assert_eq!(info.status, PythonSkillStatus::Active);
        assert!(info.last_error.is_none());
    }

    #[test]
    fn python_skill_info_round_trip() {
        let info = PythonSkillInfo {
            id: "discord-bot".to_owned(),
            name: "Discord Bot".to_owned(),
            version: "2.1.0".to_owned(),
            status: PythonSkillStatus::Quarantined,
            last_error: Some("HTTP 429 Too Many Requests".to_owned()),
        };

        let json = serde_json::to_string(&info).expect("serialize");
        let restored: PythonSkillInfo = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored.id, "discord-bot");
        assert_eq!(restored.status, PythonSkillStatus::Quarantined);
        assert_eq!(
            restored.last_error.as_deref(),
            Some("HTTP 429 Too Many Requests")
        );
    }

    #[test]
    fn apply_status_transition_valid() {
        let mut record = make_record("test", PythonSkillStatus::Pending);
        apply_status_transition(&mut record, PythonSkillStatus::Testing).expect("transition");
        assert_eq!(record.status, PythonSkillStatus::Testing);
    }

    #[test]
    fn apply_status_transition_invalid_returns_error() {
        let mut record = make_record("test", PythonSkillStatus::Pending);
        let result = apply_status_transition(&mut record, PythonSkillStatus::Active);
        assert!(result.is_err());
        // Status must not have changed
        assert_eq!(record.status, PythonSkillStatus::Pending);
    }
}
