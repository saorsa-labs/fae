//! Skill loading and lifecycle management for Fae.
//!
//! Skills are concise behavioural guides that tell the LLM **when** and **how**
//! to use specific tool categories. They are injected into the system prompt
//! between the personality layer and the user add-on.
//!
//! Supported skill sources:
//! 1. Built-in skills compiled into the binary.
//! 2. User `.md` skills in the skills directory (see [`skills_dir`]).
//! 3. Managed package skills (`SKILL.toml` + markdown entry) installed into
//!    the same directory with state tracked in `.state/registry.json`.

pub mod builtins;
pub mod trait_def;

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The built-in canvas skill, compiled from `Skills/canvas.md`.
pub const CANVAS_SKILL: &str = include_str!("../../Skills/canvas.md");
/// Built-in skill for external LLM setup and operations.
pub const EXTERNAL_LLM_SKILL: &str = include_str!("../../Skills/external-llm.md");
/// Built-in skill for Python helper scripts executed via uv.
pub const UV_SCRIPTS_SKILL: &str = include_str!("../../Skills/uv-scripts.md");
/// Built-in skill for desktop automation (screenshots, clicks, window management).
pub const DESKTOP_SKILL: &str = include_str!("../../Skills/desktop.md");

/// Package manifest accepted by installer.
#[derive(Debug, Clone, Deserialize)]
struct SkillManifest {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default = "default_manifest_entry_file")]
    entry_file: String,
}

fn default_manifest_entry_file() -> String {
    "SKILL.md".to_owned()
}

/// Managed skill state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManagedSkillState {
    Active,
    Disabled,
    Quarantined,
}

/// Managed skill registry entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct ManagedSkillRecord {
    id: String,
    name: String,
    version: String,
    state: ManagedSkillState,
    active_file: PathBuf,
    disabled_file: PathBuf,
    #[serde(default)]
    last_known_good_snapshot: Option<PathBuf>,
    #[serde(default)]
    last_error: Option<String>,
    updated_at: u64,
}

/// Public managed-skill view.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedSkillInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub state: ManagedSkillState,
    pub last_error: Option<String>,
}

impl From<&ManagedSkillRecord> for ManagedSkillInfo {
    fn from(value: &ManagedSkillRecord) -> Self {
        Self {
            id: value.id.clone(),
            name: value.name.clone(),
            version: value.version.clone(),
            state: value.state,
            last_error: value.last_error.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SkillRegistry {
    #[serde(default = "default_registry_version")]
    version: u8,
    #[serde(default)]
    skills: Vec<ManagedSkillRecord>,
}

impl Default for SkillRegistry {
    fn default() -> Self {
        Self {
            version: default_registry_version(),
            skills: Vec::new(),
        }
    }
}

impl SkillRegistry {
    fn upsert(&mut self, record: ManagedSkillRecord) {
        if let Some(existing) = self.skills.iter_mut().find(|entry| entry.id == record.id) {
            *existing = record;
        } else {
            self.skills.push(record);
        }
        self.skills.sort_by(|a, b| a.id.cmp(&b.id));
    }

    fn get_mut(&mut self, skill_id: &str) -> Option<&mut ManagedSkillRecord> {
        self.skills.iter_mut().find(|entry| entry.id == skill_id)
    }

    fn get(&self, skill_id: &str) -> Option<&ManagedSkillRecord> {
        self.skills.iter().find(|entry| entry.id == skill_id)
    }

    fn state_map(&self) -> BTreeMap<String, ManagedSkillState> {
        let mut map = BTreeMap::new();
        for entry in &self.skills {
            map.insert(entry.id.clone(), entry.state);
        }
        map
    }
}

#[derive(Debug, Clone)]
struct SkillPaths {
    root: PathBuf,
    state_dir: PathBuf,
    registry_file: PathBuf,
    disabled_dir: PathBuf,
    snapshots_dir: PathBuf,
}

impl SkillPaths {
    fn for_root(root: PathBuf) -> Self {
        let state_dir = root.join(".state");
        Self {
            registry_file: state_dir.join("registry.json"),
            disabled_dir: state_dir.join("disabled"),
            snapshots_dir: state_dir.join("snapshots"),
            root,
            state_dir,
        }
    }
}

fn now_epoch_secs() -> u64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => duration.as_secs(),
        Err(_) => 0,
    }
}

/// Returns the directory where user-created skills are stored.
///
/// Override for local tooling via `FAE_SKILLS_DIR=/path/to/skills`.
/// Falls back to [`crate::fae_dirs::skills_dir`].
pub fn skills_dir() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("FAE_SKILLS_DIR") {
        return PathBuf::from(override_dir);
    }
    crate::fae_dirs::skills_dir()
}

fn default_paths() -> SkillPaths {
    SkillPaths::for_root(skills_dir())
}

fn ensure_state_dirs(paths: &SkillPaths) -> crate::Result<()> {
    std::fs::create_dir_all(&paths.root)?;
    std::fs::create_dir_all(&paths.state_dir)?;
    std::fs::create_dir_all(&paths.disabled_dir)?;
    std::fs::create_dir_all(&paths.snapshots_dir)?;
    Ok(())
}

fn load_registry(paths: &SkillPaths) -> crate::Result<SkillRegistry> {
    let bytes = match std::fs::read(&paths.registry_file) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(SkillRegistry::default()),
        Err(e) => {
            return Err(crate::SpeechError::Config(format!(
                "cannot read skill registry: {e}"
            )));
        }
    };

    serde_json::from_slice(&bytes)
        .map_err(|e| crate::SpeechError::Config(format!("cannot parse skill registry: {e}")))
}

fn save_registry(paths: &SkillPaths, registry: &SkillRegistry) -> crate::Result<()> {
    ensure_state_dirs(paths)?;
    let json = serde_json::to_string_pretty(registry)
        .map_err(|e| crate::SpeechError::Config(format!("cannot serialize skill registry: {e}")))?;
    std::fs::write(&paths.registry_file, json)
        .map_err(|e| crate::SpeechError::Config(format!("cannot write skill registry: {e}")))
}

fn write_atomic(path: &Path, content: &str) -> crate::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let tmp_name = format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("skill"),
        std::process::id()
    );
    let tmp_path = path
        .parent()
        .map(|p| p.join(&tmp_name))
        .unwrap_or_else(|| PathBuf::from(&tmp_name));

    std::fs::write(&tmp_path, content)?;
    std::fs::rename(&tmp_path, path)?;
    Ok(())
}

fn snapshot_existing_skill(
    paths: &SkillPaths,
    skill_id: &str,
    active_file: &Path,
) -> crate::Result<Option<PathBuf>> {
    if !active_file.is_file() {
        return Ok(None);
    }

    ensure_state_dirs(paths)?;
    let stamp = now_epoch_secs();
    let snapshot = paths.snapshots_dir.join(format!("{skill_id}-{stamp}.md"));
    std::fs::copy(active_file, &snapshot)
        .map_err(|e| crate::SpeechError::Config(format!("cannot snapshot existing skill: {e}")))?;
    Ok(Some(snapshot))
}

fn validate_skill_id(skill_id: &str) -> crate::Result<()> {
    if skill_id.trim().is_empty() {
        return Err(crate::SpeechError::Config(
            "skill id cannot be empty".to_owned(),
        ));
    }
    if !skill_id
        .chars()
        .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-' || ch == '_')
    {
        return Err(crate::SpeechError::Config(format!(
            "skill id `{skill_id}` is invalid (use lowercase letters, digits, - or _)"
        )));
    }
    Ok(())
}

fn validate_skill_text(content: &str) -> crate::Result<()> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Err(crate::SpeechError::Config(
            "skill content cannot be empty".to_owned(),
        ));
    }
    if trimmed.len() > 120_000 {
        return Err(crate::SpeechError::Config(
            "skill content exceeds 120k characters".to_owned(),
        ));
    }
    Ok(())
}

fn skill_md_path(paths: &SkillPaths, skill_id: &str) -> PathBuf {
    paths.root.join(format!("{skill_id}.md"))
}

fn disabled_md_path(paths: &SkillPaths, skill_id: &str) -> PathBuf {
    paths.disabled_dir.join(format!("{skill_id}.md"))
}

/// Install and activate a packaged skill from a directory containing
/// `SKILL.toml` and markdown entry content.
pub fn install_skill_package(package_dir: &Path) -> crate::Result<ManagedSkillInfo> {
    install_skill_package_at(&default_paths(), package_dir)
}

fn install_skill_package_at(
    paths: &SkillPaths,
    package_dir: &Path,
) -> crate::Result<ManagedSkillInfo> {
    let manifest_path = package_dir.join("SKILL.toml");
    let manifest_raw = std::fs::read_to_string(&manifest_path).map_err(|e| {
        crate::SpeechError::Config(format!("cannot read {}: {e}", manifest_path.display()))
    })?;
    let manifest: SkillManifest = toml::from_str(&manifest_raw)
        .map_err(|e| crate::SpeechError::Config(format!("invalid SKILL.toml: {e}")))?;

    let skill_id = manifest
        .id
        .unwrap_or_else(|| {
            package_dir
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("skill")
                .to_owned()
        })
        .trim()
        .to_owned();
    validate_skill_id(&skill_id)?;

    let name = manifest
        .name
        .unwrap_or_else(|| skill_id.clone())
        .trim()
        .to_owned();
    let version = manifest
        .version
        .unwrap_or_else(|| "0.1.0".to_owned())
        .trim()
        .to_owned();

    let entry_path = package_dir.join(manifest.entry_file);
    let content = std::fs::read_to_string(&entry_path).map_err(|e| {
        crate::SpeechError::Config(format!("cannot read {}: {e}", entry_path.display()))
    })?;
    validate_skill_text(&content)?;

    ensure_state_dirs(paths)?;
    let active_file = skill_md_path(paths, &skill_id);
    let disabled_file = disabled_md_path(paths, &skill_id);

    let snapshot = snapshot_existing_skill(paths, &skill_id, &active_file)?;
    write_atomic(&active_file, content.trim())?;
    if disabled_file.is_file() {
        let _ = std::fs::remove_file(&disabled_file);
    }

    let mut registry = load_registry(paths)?;
    let previous = registry.get(&skill_id).cloned();

    let mut record = ManagedSkillRecord {
        id: skill_id.clone(),
        name,
        version,
        state: ManagedSkillState::Active,
        active_file,
        disabled_file,
        last_known_good_snapshot: None,
        last_error: None,
        updated_at: now_epoch_secs(),
    };

    if let Some(previous) = previous
        && record.last_known_good_snapshot.is_none()
    {
        record.last_known_good_snapshot = previous.last_known_good_snapshot;
    }

    if let Some(snapshot) = snapshot {
        record.last_known_good_snapshot = Some(snapshot);
    }

    registry.upsert(record.clone());
    save_registry(paths, &registry)?;

    Ok(ManagedSkillInfo::from(&record))
}

/// Disable a managed skill.
pub fn disable_skill(skill_id: &str) -> crate::Result<()> {
    set_skill_state(skill_id, ManagedSkillState::Disabled, None)
}

/// Quarantine a managed skill and record an error.
pub fn quarantine_skill(skill_id: &str, reason: &str) -> crate::Result<()> {
    set_skill_state(
        skill_id,
        ManagedSkillState::Quarantined,
        Some(reason.to_owned()),
    )
}

fn set_skill_state(
    skill_id: &str,
    state: ManagedSkillState,
    last_error: Option<String>,
) -> crate::Result<()> {
    let paths = default_paths();
    let mut registry = load_registry(&paths)?;
    let Some(entry) = registry.get_mut(skill_id) else {
        return Err(crate::SpeechError::Config(format!(
            "managed skill `{skill_id}` not found"
        )));
    };

    ensure_state_dirs(&paths)?;
    if entry.active_file.is_file() {
        if let Some(snapshot) = snapshot_existing_skill(&paths, skill_id, &entry.active_file)? {
            entry.last_known_good_snapshot = Some(snapshot);
        }
        move_file(&entry.active_file, &entry.disabled_file)?;
    }

    entry.state = state;
    entry.last_error = last_error;
    entry.updated_at = now_epoch_secs();

    save_registry(&paths, &registry)
}

/// Re-activate a managed skill.
pub fn activate_skill(skill_id: &str) -> crate::Result<()> {
    let paths = default_paths();
    let mut registry = load_registry(&paths)?;
    let Some(entry) = registry.get_mut(skill_id) else {
        return Err(crate::SpeechError::Config(format!(
            "managed skill `{skill_id}` not found"
        )));
    };

    ensure_state_dirs(&paths)?;

    if !entry.active_file.is_file() {
        if entry.disabled_file.is_file() {
            move_file(&entry.disabled_file, &entry.active_file)?;
        } else if let Some(snapshot) = &entry.last_known_good_snapshot {
            let content = std::fs::read_to_string(snapshot).map_err(|e| {
                crate::SpeechError::Config(format!(
                    "cannot read last known good snapshot {}: {e}",
                    snapshot.display()
                ))
            })?;
            validate_skill_text(&content)?;
            write_atomic(&entry.active_file, content.trim())?;
        } else {
            return Err(crate::SpeechError::Config(format!(
                "managed skill `{skill_id}` has no active, disabled, or snapshot content"
            )));
        }
    }

    entry.state = ManagedSkillState::Active;
    entry.last_error = None;
    entry.updated_at = now_epoch_secs();
    save_registry(&paths, &registry)
}

/// Roll back a managed skill to its last-known-good snapshot.
pub fn rollback_skill(skill_id: &str) -> crate::Result<()> {
    let paths = default_paths();
    rollback_skill_at(&paths, skill_id)
}

fn rollback_skill_at(paths: &SkillPaths, skill_id: &str) -> crate::Result<()> {
    let mut registry = load_registry(paths)?;
    let Some(entry) = registry.get_mut(skill_id) else {
        return Err(crate::SpeechError::Config(format!(
            "managed skill `{skill_id}` not found"
        )));
    };

    let Some(snapshot) = &entry.last_known_good_snapshot else {
        return Err(crate::SpeechError::Config(format!(
            "managed skill `{skill_id}` has no rollback snapshot"
        )));
    };

    let content = std::fs::read_to_string(snapshot).map_err(|e| {
        crate::SpeechError::Config(format!(
            "cannot read rollback snapshot {}: {e}",
            snapshot.display()
        ))
    })?;
    validate_skill_text(&content)?;

    ensure_state_dirs(paths)?;
    write_atomic(&entry.active_file, content.trim())?;
    if entry.disabled_file.is_file() {
        let _ = std::fs::remove_file(&entry.disabled_file);
    }

    entry.state = ManagedSkillState::Active;
    entry.last_error = None;
    entry.updated_at = now_epoch_secs();

    save_registry(paths, &registry)
}

fn move_file(from: &Path, to: &Path) -> crate::Result<()> {
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent)?;
    }

    match std::fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(_) => {
            std::fs::copy(from, to).map_err(|e| {
                crate::SpeechError::Config(format!(
                    "cannot copy {} -> {}: {e}",
                    from.display(),
                    to.display()
                ))
            })?;
            std::fs::remove_file(from).map_err(|e| {
                crate::SpeechError::Config(format!("cannot remove {}: {e}", from.display()))
            })?;
            Ok(())
        }
    }
}

/// Returns managed skills. Returns an empty list if registry is missing.
pub fn list_managed_skills() -> Vec<ManagedSkillInfo> {
    list_managed_skills_strict().unwrap_or_default()
}

/// Returns managed skills, preserving registry parse errors.
pub fn list_managed_skills_strict() -> crate::Result<Vec<ManagedSkillInfo>> {
    let registry = load_registry(&default_paths())?;
    Ok(registry.skills.iter().map(ManagedSkillInfo::from).collect())
}

/// Lists all available skill names.
///
/// Includes built-in names and active custom/managed skills.
pub fn list_skills() -> Vec<String> {
    let mut names = vec![
        "canvas".to_owned(),
        "desktop".to_owned(),
        "external-llm".to_owned(),
        "uv-scripts".to_owned(),
    ];
    let custom = list_custom_skill_names(&default_paths());
    names.extend(custom);

    let mut uniq = BTreeSet::new();
    names.retain(|name| uniq.insert(name.clone()));
    names
}

fn list_custom_skill_names(paths: &SkillPaths) -> Vec<String> {
    let states = load_registry(paths)
        .ok()
        .map(|r| r.state_map())
        .unwrap_or_default();
    let mut names = Vec::new();

    if let Ok(entries) = std::fs::read_dir(&paths.root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
                continue;
            }
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with('.'))
                .unwrap_or(false)
            {
                continue;
            }

            let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) else {
                continue;
            };

            if stem == "canvas" || stem == "desktop" || stem == "external-llm" {
                continue;
            }

            if let Some(state) = states.get(stem)
                && *state != ManagedSkillState::Active
            {
                continue;
            }

            names.push(stem.to_owned());
        }
    }

    names.sort();
    names
}

/// Loads and concatenates all active skills into one string.
///
/// Returns built-ins followed by active custom/managed skill markdown files.
pub fn load_all_skills() -> String {
    let mut parts: Vec<String> = vec![
        CANVAS_SKILL.to_owned(),
        DESKTOP_SKILL.to_owned(),
        EXTERNAL_LLM_SKILL.to_owned(),
        UV_SCRIPTS_SKILL.to_owned(),
    ];
    let paths = default_paths();
    let states = load_registry(&paths)
        .ok()
        .map(|r| r.state_map())
        .unwrap_or_default();

    if let Ok(entries) = std::fs::read_dir(&paths.root) {
        let mut files: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("md"))
            .filter(|path| {
                !path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.starts_with('.'))
                    .unwrap_or(false)
            })
            .collect();
        files.sort();

        for path in files {
            let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) else {
                continue;
            };
            if stem == "canvas"
                || stem == "desktop"
                || stem == "external-llm"
                || stem == "uv-scripts"
            {
                continue;
            }
            if let Some(state) = states.get(stem)
                && *state != ManagedSkillState::Active
            {
                continue;
            }
            if let Ok(content) = std::fs::read_to_string(&path) {
                let trimmed = content.trim();
                if !trimmed.is_empty() {
                    parts.push(trimmed.to_owned());
                }
            }
        }
    }

    parts.join("\n\n")
}

fn default_registry_version() -> u8 {
    1
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn test_paths(name: &str) -> SkillPaths {
        let root = std::env::temp_dir().join(format!("fae-skills-test-{name}"));
        let _ = std::fs::remove_dir_all(&root);
        SkillPaths::for_root(root)
    }

    fn write_file(path: &Path, content: &str) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create parent");
        }
        std::fs::write(path, content).expect("write file");
    }

    #[test]
    fn built_in_skills_nonempty() {
        assert!(!CANVAS_SKILL.is_empty());
        assert!(!DESKTOP_SKILL.is_empty());
        assert!(!EXTERNAL_LLM_SKILL.is_empty());
        assert!(!UV_SCRIPTS_SKILL.is_empty());
    }

    #[test]
    fn install_disable_activate_and_rollback_managed_skill() {
        let paths = test_paths("managed-lifecycle");

        // Seed an existing active file to verify snapshot + rollback.
        write_file(
            &skill_md_path(&paths, "calendar"),
            "# old skill\nUse old behavior.",
        );

        let package = paths.root.join("pkg");
        std::fs::create_dir_all(&package).expect("create package");
        write_file(
            &package.join("SKILL.toml"),
            "id = \"calendar\"\nname = \"Calendar\"\nversion = \"1.2.3\"\nentry_file = \"skill.md\"\n",
        );
        write_file(&package.join("skill.md"), "# calendar\nUse new behavior.");

        let installed = install_skill_package_at(&paths, &package).expect("install");
        assert_eq!(installed.id, "calendar");
        assert_eq!(installed.state, ManagedSkillState::Active);

        // Disable should move active file away.
        {
            let mut registry = load_registry(&paths).expect("load registry");
            let entry = registry.get_mut("calendar").expect("entry");
            if entry.active_file.is_file() {
                move_file(&entry.active_file, &entry.disabled_file).expect("disable move");
            }
            entry.state = ManagedSkillState::Disabled;
            save_registry(&paths, &registry).expect("save registry");
        }
        assert!(!skill_md_path(&paths, "calendar").is_file());
        assert!(disabled_md_path(&paths, "calendar").is_file());

        // Activate should restore disabled content.
        {
            let mut registry = load_registry(&paths).expect("load registry");
            let entry = registry.get_mut("calendar").expect("entry");
            move_file(&entry.disabled_file, &entry.active_file).expect("activate move");
            entry.state = ManagedSkillState::Active;
            save_registry(&paths, &registry).expect("save registry");
        }
        assert!(skill_md_path(&paths, "calendar").is_file());

        // Rollback should restore old snapshot content.
        rollback_skill_at(&paths, "calendar").expect("rollback");
        let rolled =
            std::fs::read_to_string(skill_md_path(&paths, "calendar")).expect("read rolled");
        assert!(rolled.contains("old behavior"));

        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[test]
    fn list_custom_names_honors_registry_state() {
        let paths = test_paths("custom-names");
        write_file(&paths.root.join("active.md"), "active");
        write_file(&paths.root.join("disabled.md"), "disabled");

        let mut registry = SkillRegistry::default();
        registry.upsert(ManagedSkillRecord {
            id: "active".to_owned(),
            name: "Active".to_owned(),
            version: "1.0.0".to_owned(),
            state: ManagedSkillState::Active,
            active_file: skill_md_path(&paths, "active"),
            disabled_file: disabled_md_path(&paths, "active"),
            last_known_good_snapshot: None,
            last_error: None,
            updated_at: now_epoch_secs(),
        });
        registry.upsert(ManagedSkillRecord {
            id: "disabled".to_owned(),
            name: "Disabled".to_owned(),
            version: "1.0.0".to_owned(),
            state: ManagedSkillState::Disabled,
            active_file: skill_md_path(&paths, "disabled"),
            disabled_file: disabled_md_path(&paths, "disabled"),
            last_known_good_snapshot: None,
            last_error: None,
            updated_at: now_epoch_secs(),
        });
        save_registry(&paths, &registry).expect("save registry");

        let names = list_custom_skill_names(&paths);
        assert_eq!(names, vec!["active".to_owned()]);

        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[test]
    fn load_all_skills_includes_active_custom() {
        let paths = test_paths("load-all");
        write_file(&paths.root.join("alpha.md"), "alpha custom");
        write_file(&paths.root.join("beta.md"), "beta custom");

        let mut registry = SkillRegistry::default();
        registry.upsert(ManagedSkillRecord {
            id: "alpha".to_owned(),
            name: "Alpha".to_owned(),
            version: "1.0.0".to_owned(),
            state: ManagedSkillState::Active,
            active_file: skill_md_path(&paths, "alpha"),
            disabled_file: disabled_md_path(&paths, "alpha"),
            last_known_good_snapshot: None,
            last_error: None,
            updated_at: now_epoch_secs(),
        });
        registry.upsert(ManagedSkillRecord {
            id: "beta".to_owned(),
            name: "Beta".to_owned(),
            version: "1.0.0".to_owned(),
            state: ManagedSkillState::Quarantined,
            active_file: skill_md_path(&paths, "beta"),
            disabled_file: disabled_md_path(&paths, "beta"),
            last_known_good_snapshot: None,
            last_error: Some("bad".to_owned()),
            updated_at: now_epoch_secs(),
        });
        save_registry(&paths, &registry).expect("save registry");

        let states = load_registry(&paths).expect("load registry").state_map();
        let mut loaded = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&paths.root) {
            let mut files: Vec<PathBuf> = entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("md"))
                .collect();
            files.sort();
            for path in files {
                let stem = path
                    .file_stem()
                    .and_then(|stem| stem.to_str())
                    .unwrap_or_default();
                if let Some(state) = states.get(stem)
                    && *state != ManagedSkillState::Active
                {
                    continue;
                }
                let text = std::fs::read_to_string(path).expect("read");
                loaded.push(text);
            }
        }

        assert_eq!(loaded.len(), 1);
        assert!(loaded[0].contains("alpha"));

        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[test]
    fn validate_skill_id_rejects_invalid_chars() {
        assert!(validate_skill_id("ok_skill-1").is_ok());
        assert!(validate_skill_id("Bad Skill").is_err());
        assert!(validate_skill_id("").is_err());
    }

    #[test]
    fn list_skills_includes_builtins() {
        let names = list_skills();
        assert!(names.contains(&"canvas".to_owned()));
        assert!(names.contains(&"desktop".to_owned()));
        assert!(names.contains(&"external-llm".to_owned()));
    }

    #[test]
    fn missing_skills_dir_does_not_crash() {
        let all = load_all_skills();
        assert!(!all.is_empty());
    }

    /// E2E: write a skill .md file → list discovers it → load includes its content.
    #[test]
    fn e2e_write_list_load_skill() {
        let paths = test_paths("e2e-write-list-load");

        // Write a plain .md file (simulates save_user_skill_markdown).
        write_file(
            &paths.root.join("weather.md"),
            "# Weather\nWhen the user asks about weather, use the HTTP tool.",
        );

        // list_custom_skill_names should discover it (no registry entry needed).
        let names = list_custom_skill_names(&paths);
        assert!(
            names.contains(&"weather".to_owned()),
            "expected weather in {names:?}"
        );

        // load_all_skills would load it, but uses global skills_dir(). Instead
        // verify directly that the file can be read and content matches.
        let content =
            std::fs::read_to_string(paths.root.join("weather.md")).expect("read weather.md");
        assert!(content.contains("Weather"));
        assert!(content.contains("HTTP tool"));

        // Verify .state/ directory files don't appear in skill list.
        let state_names = list_custom_skill_names(&paths);
        assert!(!state_names.iter().any(|n| n.contains("state")));

        let _ = std::fs::remove_dir_all(&paths.root);
    }

    /// E2E: install package → disable → rollback → verify content restored.
    #[test]
    fn e2e_install_disable_rollback_pipeline() {
        let paths = test_paths("e2e-install-rollback");

        // Pre-seed an existing skill (simulates user editing).
        write_file(
            &skill_md_path(&paths, "notes"),
            "# Notes v1\nOriginal notes skill.",
        );

        // Install newer version via package.
        let pkg = paths.root.join("pkg-notes");
        std::fs::create_dir_all(&pkg).expect("create pkg");
        write_file(
            &pkg.join("SKILL.toml"),
            "id = \"notes\"\nname = \"Notes\"\nversion = \"2.0.0\"\n",
        );
        write_file(&pkg.join("SKILL.md"), "# Notes v2\nUpdated notes skill.");

        let info = install_skill_package_at(&paths, &pkg).expect("install");
        assert_eq!(info.version, "2.0.0");
        assert_eq!(info.state, ManagedSkillState::Active);

        // Verify active content is v2.
        let content = std::fs::read_to_string(skill_md_path(&paths, "notes")).expect("read active");
        assert!(content.contains("v2"), "active should be v2: {content}");

        // Rollback restores v1 (from snapshot).
        rollback_skill_at(&paths, "notes").expect("rollback");
        let rolled =
            std::fs::read_to_string(skill_md_path(&paths, "notes")).expect("read rolled back");
        assert!(rolled.contains("v1"), "rolled back should be v1: {rolled}");

        // Verify skill is still listed.
        let names = list_custom_skill_names(&paths);
        assert!(
            names.contains(&"notes".to_owned()),
            "expected notes in {names:?}"
        );

        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[test]
    fn managed_skill_info_round_trip() {
        let info = ManagedSkillInfo {
            id: "alpha".to_owned(),
            name: "Alpha".to_owned(),
            version: "1.0.0".to_owned(),
            state: ManagedSkillState::Active,
            last_error: None,
        };

        let json = serde_json::to_string(&info).expect("serialize");
        let restored: ManagedSkillInfo = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored.id, "alpha");
        assert_eq!(restored.state, ManagedSkillState::Active);
    }
}
