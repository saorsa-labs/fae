//! Durable mutation manifest for self-authored artifacts.
//!
//! Tracks every mutable artifact in the self-authored layer with:
//! - provenance (`source`, `action`, `reason`, timestamp),
//! - monotonic versioning,
//! - promotion state (staging/canary/active/quarantined/snapshot/removed).

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::{Component, Path, PathBuf};
use tracing::warn;

const MUTATION_MANIFEST_SCHEMA_VERSION: u32 = 1;
const MUTATION_MANIFEST_TMP_SUFFIX: &str = "tmp";

/// Promotion state of a mutable artifact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PromotionState {
    Staging,
    Canary,
    Active,
    Quarantined,
    Snapshot,
    Removed,
    Unknown,
}

/// Classification of mutable artifacts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MutableArtifactKind {
    SoulMemory,
    OnboardingProfile,
    MarkdownSkill,
    PythonSkillManifest,
    PythonSkillEntrypoint,
    PolicyPack,
    SkillRegistry,
    DisabledArtifact,
    SnapshotArtifact,
    StagingArtifact,
    Other,
}

/// Mutation provenance attached to each artifact update.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MutationProvenance {
    /// Source subsystem (e.g. `host.command`, `startup`).
    pub source: String,
    /// Action name (e.g. `skill.python.install`).
    pub action: String,
    /// Optional free-form reason.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Epoch seconds for this provenance stamp.
    pub at_secs: u64,
}

/// One tracked mutable artifact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MutationArtifactRecord {
    /// Stable manifest path key (e.g. `data/skills/calendar.md`).
    pub path: String,
    /// Artifact classification.
    pub kind: MutableArtifactKind,
    /// Current promotion state.
    pub promotion_state: PromotionState,
    /// Monotonic mutation version.
    pub version: u64,
    /// Current content digest (blake3 hex).
    pub digest_blake3: String,
    /// Current size in bytes.
    pub size_bytes: u64,
    /// Whether the artifact currently exists.
    pub exists: bool,
    /// First-seen timestamp.
    pub created_at_secs: u64,
    /// Last-mutated timestamp.
    pub updated_at_secs: u64,
    /// First provenance stamp.
    pub created_by: MutationProvenance,
    /// Last provenance stamp.
    pub last_mutation: MutationProvenance,
}

/// Top-level mutation manifest.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MutationManifest {
    /// Manifest schema version.
    pub schema_version: u32,
    /// Last update timestamp.
    pub updated_at_secs: u64,
    /// Artifact records.
    pub artifacts: Vec<MutationArtifactRecord>,
}

impl Default for MutationManifest {
    fn default() -> Self {
        Self {
            schema_version: MUTATION_MANIFEST_SCHEMA_VERSION,
            updated_at_secs: 0,
            artifacts: Vec::new(),
        }
    }
}

/// Metadata for a sync call.
#[derive(Debug, Clone)]
pub struct MutationSyncEvent {
    pub source: String,
    pub action: String,
    pub reason: Option<String>,
}

impl MutationSyncEvent {
    #[must_use]
    pub fn new(
        source: impl Into<String>,
        action: impl Into<String>,
        reason: Option<String>,
    ) -> Self {
        Self {
            source: source.into(),
            action: action.into(),
            reason,
        }
    }
}

/// Summarized mutation-manifest status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MutationManifestSummary {
    pub manifest_path: String,
    pub artifact_count: usize,
    pub tombstoned_count: usize,
    pub changed_count: usize,
    pub removed_in_sync: usize,
    pub updated_at_secs: u64,
}

/// Returns the default mutation manifest file path.
#[must_use]
pub fn default_mutation_manifest_file() -> PathBuf {
    crate::fae_dirs::mutation_manifest_file()
}

/// Read the mutation manifest from the default path.
pub fn read_mutation_manifest() -> Result<MutationManifest> {
    read_mutation_manifest_from_path(&default_mutation_manifest_file())
}

/// Read the mutation manifest from an explicit path.
pub fn read_mutation_manifest_from_path(path: &Path) -> Result<MutationManifest> {
    load_manifest(path)
}

/// Return summarized mutation-manifest status for runtime surfaces.
pub fn summarize_mutation_manifest() -> Result<MutationManifestSummary> {
    let path = default_mutation_manifest_file();
    let manifest = read_mutation_manifest_from_path(&path)?;
    let artifact_count = manifest.artifacts.iter().filter(|r| r.exists).count();
    let tombstoned_count = manifest.artifacts.len().saturating_sub(artifact_count);
    Ok(MutationManifestSummary {
        manifest_path: path.display().to_string(),
        artifact_count,
        tombstoned_count,
        changed_count: 0,
        removed_in_sync: 0,
        updated_at_secs: manifest.updated_at_secs,
    })
}

/// Synchronize the mutation manifest at the default location.
pub fn sync_mutation_manifest(event: MutationSyncEvent) -> Result<MutationManifestSummary> {
    sync_mutation_manifest_to_path(&default_mutation_manifest_file(), event)
}

/// Synchronize the mutation manifest at an explicit location.
///
/// This scan is authoritative for "every mutable artifact" in the self-authored
/// surface and records any file creation, mutation, state transition, or removal.
pub fn sync_mutation_manifest_to_path(
    manifest_path: &Path,
    event: MutationSyncEvent,
) -> Result<MutationManifestSummary> {
    let now = now_epoch_secs();
    let data_dir = crate::fae_dirs::data_dir();
    let config_dir = crate::fae_dirs::config_dir();
    let skills_dir = crate::fae_dirs::skills_dir();
    let python_skills_dir = crate::fae_dirs::python_skills_dir();

    let mut files = BTreeSet::new();
    for root in [
        skills_dir.clone(),
        python_skills_dir.clone(),
        data_dir.join("staging"),
        data_dir.join("tmp"),
    ] {
        collect_files_recursive(&root, &mut files)?;
    }
    for direct_file in [data_dir.join("SOUL.md"), data_dir.join("onboarding.md")] {
        if direct_file.is_file() {
            files.insert(direct_file);
        }
    }

    let classifier = ArtifactClassifier::new(
        data_dir.clone(),
        skills_dir.clone(),
        python_skills_dir.clone(),
    );

    let provenance = MutationProvenance {
        source: event.source,
        action: event.action,
        reason: event.reason,
        at_secs: now,
    };

    let mut manifest = load_manifest(manifest_path)?;
    let mut records_by_path: BTreeMap<String, MutationArtifactRecord> = manifest
        .artifacts
        .into_iter()
        .map(|record| (record.path.clone(), record))
        .collect();

    let mut current_keys = BTreeSet::new();
    let mut changed_count = 0usize;
    let mut removed_in_sync = 0usize;

    for file_path in files {
        let metadata = match std::fs::metadata(&file_path) {
            Ok(meta) => meta,
            Err(e) => {
                warn!(
                    path = %file_path.display(),
                    error = %e,
                    "mutation_manifest: failed to read metadata"
                );
                continue;
            }
        };
        if !metadata.is_file() {
            continue;
        }

        let digest = match digest_file_blake3(&file_path) {
            Ok(value) => value,
            Err(e) => {
                warn!(
                    path = %file_path.display(),
                    error = %e,
                    "mutation_manifest: failed to hash file"
                );
                continue;
            }
        };

        let key = artifact_key(&file_path, &data_dir, &config_dir);
        current_keys.insert(key.clone());

        let (kind, state) = classifier.classify(&file_path);
        let size_bytes = metadata.len();

        if let Some(record) = records_by_path.get_mut(&key) {
            let content_changed = record.digest_blake3 != digest || record.size_bytes != size_bytes;
            let state_changed = record.kind != kind || record.promotion_state != state;
            let existence_changed = !record.exists;

            record.kind = kind;
            record.promotion_state = state;
            record.exists = true;

            if content_changed || state_changed || existence_changed {
                record.version = record.version.saturating_add(1);
                record.digest_blake3 = digest;
                record.size_bytes = size_bytes;
                record.updated_at_secs = now;
                record.last_mutation = provenance.clone();
                changed_count = changed_count.saturating_add(1);
            }
        } else {
            records_by_path.insert(
                key.clone(),
                MutationArtifactRecord {
                    path: key,
                    kind,
                    promotion_state: state,
                    version: 1,
                    digest_blake3: digest,
                    size_bytes,
                    exists: true,
                    created_at_secs: now,
                    updated_at_secs: now,
                    created_by: provenance.clone(),
                    last_mutation: provenance.clone(),
                },
            );
            changed_count = changed_count.saturating_add(1);
        }
    }

    for record in records_by_path.values_mut() {
        if !current_keys.contains(&record.path) && record.exists {
            record.exists = false;
            record.promotion_state = PromotionState::Removed;
            record.version = record.version.saturating_add(1);
            record.updated_at_secs = now;
            record.last_mutation = provenance.clone();
            changed_count = changed_count.saturating_add(1);
            removed_in_sync = removed_in_sync.saturating_add(1);
        }
    }

    let artifacts: Vec<MutationArtifactRecord> = records_by_path.into_values().collect();
    let artifact_count = artifacts.iter().filter(|record| record.exists).count();
    let tombstoned_count = artifacts.len().saturating_sub(artifact_count);

    manifest.schema_version = MUTATION_MANIFEST_SCHEMA_VERSION;
    manifest.updated_at_secs = now;
    manifest.artifacts = artifacts;
    save_manifest(manifest_path, &manifest)?;

    Ok(MutationManifestSummary {
        manifest_path: manifest_path.display().to_string(),
        artifact_count,
        tombstoned_count,
        changed_count,
        removed_in_sync,
        updated_at_secs: now,
    })
}

fn load_manifest(path: &Path) -> Result<MutationManifest> {
    if !path.exists() {
        return Ok(MutationManifest::default());
    }
    let raw = std::fs::read_to_string(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed reading mutation manifest {}: {e}",
            path.display()
        ))
    })?;
    match serde_json::from_str::<MutationManifest>(&raw) {
        Ok(manifest) => Ok(manifest),
        Err(e) => {
            warn!(
                path = %path.display(),
                error = %e,
                "mutation_manifest: parse failed, resetting to empty manifest"
            );
            Ok(MutationManifest::default())
        }
    }
}

fn save_manifest(path: &Path, manifest: &MutationManifest) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            SpeechError::Config(format!(
                "failed creating mutation manifest dir {}: {e}",
                parent.display()
            ))
        })?;
    }

    let encoded = serde_json::to_string_pretty(manifest)
        .map_err(|e| SpeechError::Config(format!("failed serializing mutation manifest: {e}")))?;

    let mut tmp_path = path.to_path_buf();
    tmp_path.set_extension(MUTATION_MANIFEST_TMP_SUFFIX);

    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&tmp_path)
        .map_err(|e| {
            SpeechError::Config(format!(
                "failed opening mutation manifest temp file {}: {e}",
                tmp_path.display()
            ))
        })?;
    file.write_all(encoded.as_bytes()).map_err(|e| {
        SpeechError::Config(format!(
            "failed writing mutation manifest temp file {}: {e}",
            tmp_path.display()
        ))
    })?;
    file.sync_all().map_err(|e| {
        SpeechError::Config(format!(
            "failed syncing mutation manifest temp file {}: {e}",
            tmp_path.display()
        ))
    })?;
    std::fs::rename(&tmp_path, path).map_err(|e| {
        SpeechError::Config(format!(
            "failed promoting mutation manifest temp file {} -> {}: {e}",
            tmp_path.display(),
            path.display()
        ))
    })?;
    Ok(())
}

fn collect_files_recursive(path: &Path, out: &mut BTreeSet<PathBuf>) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }

    let metadata = std::fs::symlink_metadata(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed reading mutable root metadata {}: {e}",
            path.display()
        ))
    })?;

    if metadata.file_type().is_symlink() {
        return Ok(());
    }
    if metadata.is_file() {
        out.insert(path.to_path_buf());
        return Ok(());
    }
    if !metadata.is_dir() {
        return Ok(());
    }

    for entry in std::fs::read_dir(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed reading mutable dir {}: {e}",
            path.display()
        ))
    })? {
        let entry = entry
            .map_err(|e| SpeechError::Config(format!("failed reading mutable dir entry: {e}")))?;
        collect_files_recursive(&entry.path(), out)?;
    }

    Ok(())
}

fn digest_file_blake3(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed reading file {} for hash: {e}",
            path.display()
        ))
    })?;
    Ok(blake3::hash(&bytes).to_hex().to_string())
}

fn now_epoch_secs() -> u64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => duration.as_secs(),
        Err(_) => 0,
    }
}

fn artifact_key(path: &Path, data_dir: &Path, config_dir: &Path) -> String {
    if let Ok(relative) = path.strip_prefix(data_dir) {
        return format!("data/{}", normalize_path(relative));
    }
    if let Ok(relative) = path.strip_prefix(config_dir) {
        return format!("config/{}", normalize_path(relative));
    }
    normalize_path(path)
}

fn normalize_path(path: &Path) -> String {
    let mut parts: Vec<String> = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().to_string()),
            Component::Prefix(prefix) => {
                parts.push(prefix.as_os_str().to_string_lossy().to_string())
            }
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => parts.push("..".to_owned()),
        }
    }
    parts.join("/")
}

struct ArtifactClassifier {
    data_dir: PathBuf,
    skills_dir: PathBuf,
    python_skills_dir: PathBuf,
    managed_skill_states: BTreeMap<String, PromotionState>,
    python_skill_states: BTreeMap<String, PromotionState>,
}

impl ArtifactClassifier {
    fn new(data_dir: PathBuf, skills_dir: PathBuf, python_skills_dir: PathBuf) -> Self {
        let managed_skill_states =
            load_managed_skill_states(&skills_dir.join(".state/registry.json"));
        let python_skill_states =
            load_python_skill_states(&python_skills_dir.join(".state/registry.json"));
        Self {
            data_dir,
            skills_dir,
            python_skills_dir,
            managed_skill_states,
            python_skill_states,
        }
    }

    fn classify(&self, path: &Path) -> (MutableArtifactKind, PromotionState) {
        if let Ok(relative) = path.strip_prefix(&self.data_dir) {
            let rel = normalize_path(relative);
            if rel == "SOUL.md" {
                return (MutableArtifactKind::SoulMemory, PromotionState::Active);
            }
            if rel == "onboarding.md" {
                return (
                    MutableArtifactKind::OnboardingProfile,
                    PromotionState::Active,
                );
            }
            if rel.starts_with("staging/") || rel.starts_with("tmp/") {
                return (
                    MutableArtifactKind::StagingArtifact,
                    PromotionState::Staging,
                );
            }
        }

        if let Ok(relative) = path.strip_prefix(&self.skills_dir) {
            return self.classify_skills_artifact(path, relative);
        }

        if let Ok(relative) = path.strip_prefix(&self.python_skills_dir) {
            return self.classify_python_artifact(path, relative);
        }

        (MutableArtifactKind::Other, PromotionState::Unknown)
    }

    fn classify_skills_artifact(
        &self,
        path: &Path,
        relative: &Path,
    ) -> (MutableArtifactKind, PromotionState) {
        let rel = normalize_path(relative);

        if rel == ".state/registry.json" {
            return (MutableArtifactKind::SkillRegistry, PromotionState::Active);
        }
        if rel.starts_with(".state/snapshots/") {
            return (
                MutableArtifactKind::SnapshotArtifact,
                PromotionState::Snapshot,
            );
        }
        if rel.starts_with(".state/disabled/") {
            return (
                MutableArtifactKind::DisabledArtifact,
                PromotionState::Quarantined,
            );
        }
        if rel.starts_with("intelligence/") && rel.ends_with(".toml") {
            return (MutableArtifactKind::PolicyPack, PromotionState::Active);
        }

        let extension = path
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or_default();
        if extension.eq_ignore_ascii_case("md") {
            let skill_id = path
                .file_stem()
                .and_then(|v| v.to_str())
                .map(str::to_owned)
                .unwrap_or_default();
            let state = self
                .managed_skill_states
                .get(&skill_id)
                .copied()
                .unwrap_or(PromotionState::Active);
            return (MutableArtifactKind::MarkdownSkill, state);
        }

        (MutableArtifactKind::Other, PromotionState::Active)
    }

    fn classify_python_artifact(
        &self,
        path: &Path,
        relative: &Path,
    ) -> (MutableArtifactKind, PromotionState) {
        let rel = normalize_path(relative);

        if rel == ".state/registry.json" {
            return (MutableArtifactKind::SkillRegistry, PromotionState::Active);
        }
        if rel.starts_with(".state/snapshots/") {
            return (
                MutableArtifactKind::SnapshotArtifact,
                PromotionState::Snapshot,
            );
        }
        if rel.starts_with(".state/disabled/") {
            return (
                MutableArtifactKind::DisabledArtifact,
                PromotionState::Quarantined,
            );
        }

        let skill_id = relative
            .components()
            .next()
            .and_then(|component| match component {
                Component::Normal(value) => value.to_str().map(str::to_owned),
                _ => None,
            })
            .unwrap_or_default();
        let state = self
            .python_skill_states
            .get(&skill_id)
            .copied()
            .unwrap_or(PromotionState::Active);

        let file_name = path
            .file_name()
            .and_then(|v| v.to_str())
            .unwrap_or_default();
        if file_name == "manifest.toml" {
            return (MutableArtifactKind::PythonSkillManifest, state);
        }
        if path
            .extension()
            .and_then(|v| v.to_str())
            .is_some_and(|ext| ext.eq_ignore_ascii_case("py"))
        {
            return (MutableArtifactKind::PythonSkillEntrypoint, state);
        }

        (MutableArtifactKind::Other, state)
    }
}

fn load_managed_skill_states(registry_path: &Path) -> BTreeMap<String, PromotionState> {
    let mut map = BTreeMap::new();
    let raw = match std::fs::read_to_string(registry_path) {
        Ok(raw) => raw,
        Err(_) => return map,
    };

    let value: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(value) => value,
        Err(e) => {
            warn!(
                path = %registry_path.display(),
                error = %e,
                "mutation_manifest: failed to parse managed skill registry"
            );
            return map;
        }
    };

    let Some(skills) = value.get("skills").and_then(|v| v.as_array()) else {
        return map;
    };
    for item in skills {
        let Some(id) = item.get("id").and_then(|v| v.as_str()) else {
            continue;
        };
        let state = item
            .get("state")
            .and_then(|v| v.as_str())
            .map(status_to_promotion_state)
            .unwrap_or(PromotionState::Active);
        map.insert(id.to_owned(), state);
    }

    map
}

fn load_python_skill_states(registry_path: &Path) -> BTreeMap<String, PromotionState> {
    let mut map = BTreeMap::new();
    let raw = match std::fs::read_to_string(registry_path) {
        Ok(raw) => raw,
        Err(_) => return map,
    };

    let value: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(value) => value,
        Err(e) => {
            warn!(
                path = %registry_path.display(),
                error = %e,
                "mutation_manifest: failed to parse python skill registry"
            );
            return map;
        }
    };

    let Some(skills) = value.get("skills").and_then(|v| v.as_array()) else {
        return map;
    };
    for item in skills {
        let Some(id) = item.get("id").and_then(|v| v.as_str()) else {
            continue;
        };
        let state = item
            .get("status")
            .and_then(|v| v.as_str())
            .map(status_to_promotion_state)
            .unwrap_or(PromotionState::Active);
        map.insert(id.to_owned(), state);
    }

    map
}

fn status_to_promotion_state(status: &str) -> PromotionState {
    match status {
        "pending" | "testing" => PromotionState::Canary,
        "disabled" | "quarantined" => PromotionState::Quarantined,
        "active" => PromotionState::Active,
        _ => PromotionState::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvRestore {
        data: Option<std::ffi::OsString>,
        config: Option<std::ffi::OsString>,
        skills: Option<std::ffi::OsString>,
        python_skills: Option<std::ffi::OsString>,
    }

    impl Drop for EnvRestore {
        fn drop(&mut self) {
            restore_env("FAE_DATA_DIR", self.data.take());
            restore_env("FAE_CONFIG_DIR", self.config.take());
            restore_env("FAE_SKILLS_DIR", self.skills.take());
            restore_env("FAE_PYTHON_SKILLS_DIR", self.python_skills.take());
        }
    }

    fn restore_env(key: &str, value: Option<std::ffi::OsString>) {
        match value {
            Some(v) => {
                // SAFETY: test-only env mutation guarded by ENV_LOCK.
                unsafe { std::env::set_var(key, v) };
            }
            None => {
                // SAFETY: test-only env mutation guarded by ENV_LOCK.
                unsafe { std::env::remove_var(key) };
            }
        }
    }

    fn setup_env(data_dir: &Path, config_dir: &Path) -> EnvRestore {
        let data_prev = std::env::var_os("FAE_DATA_DIR");
        let config_prev = std::env::var_os("FAE_CONFIG_DIR");
        let skills_prev = std::env::var_os("FAE_SKILLS_DIR");
        let python_skills_prev = std::env::var_os("FAE_PYTHON_SKILLS_DIR");

        // SAFETY: test-only env mutation guarded by ENV_LOCK.
        unsafe { std::env::set_var("FAE_DATA_DIR", data_dir) };
        // SAFETY: test-only env mutation guarded by ENV_LOCK.
        unsafe { std::env::set_var("FAE_CONFIG_DIR", config_dir) };
        // SAFETY: test-only env mutation guarded by ENV_LOCK.
        unsafe { std::env::set_var("FAE_SKILLS_DIR", data_dir.join("skills")) };
        // SAFETY: test-only env mutation guarded by ENV_LOCK.
        unsafe { std::env::set_var("FAE_PYTHON_SKILLS_DIR", data_dir.join("python-skills")) };

        EnvRestore {
            data: data_prev,
            config: config_prev,
            skills: skills_prev,
            python_skills: python_skills_prev,
        }
    }

    fn write_file(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create parent");
        }
        std::fs::write(path, contents).expect("write file");
    }

    fn load_record(manifest: &MutationManifest, key: &str) -> MutationArtifactRecord {
        manifest
            .artifacts
            .iter()
            .find(|record| record.path == key)
            .cloned()
            .expect("record should exist")
    }

    #[test]
    fn sync_tracks_versions_states_and_removals() {
        let _guard = ENV_LOCK.lock().expect("lock");
        let data = TempDir::new().expect("data tempdir");
        let config = TempDir::new().expect("config tempdir");
        let _restore = setup_env(data.path(), config.path());

        let skills_root = data.path().join("skills");
        let python_root = data.path().join("python-skills");

        write_file(&data.path().join("SOUL.md"), "soul v1");
        write_file(
            &skills_root.join("intelligence/skill-opportunity-policy.toml"),
            "calendar_min_event_mentions = 3\n",
        );
        write_file(&skills_root.join("calendar.md"), "# calendar\n");
        write_file(
            &skills_root.join(".state/registry.json"),
            r#"{"version":1,"skills":[{"id":"calendar","state":"active"}]}"#,
        );

        write_file(
            &python_root.join(".state/registry.json"),
            r#"{"version":1,"skills":[{"id":"calendar","status":"pending"}]}"#,
        );
        write_file(
            &python_root.join("calendar/manifest.toml"),
            "id = \"calendar\"\n",
        );
        write_file(&python_root.join("calendar/skill.py"), "print('v1')\n");
        write_file(
            &data.path().join("staging/gen-1/proposal.toml"),
            "intent = \"calendar\"\n",
        );

        let summary1 = sync_mutation_manifest(MutationSyncEvent::new(
            "host.command",
            "skill.python.install",
            Some("initial install".to_owned()),
        ))
        .expect("sync manifest");
        assert!(summary1.artifact_count >= 6);

        let manifest1 = read_mutation_manifest().expect("read manifest");
        let soul = load_record(&manifest1, "data/SOUL.md");
        assert_eq!(soul.kind, MutableArtifactKind::SoulMemory);
        assert_eq!(soul.promotion_state, PromotionState::Active);
        assert_eq!(soul.version, 1);

        let policy = load_record(
            &manifest1,
            "data/skills/intelligence/skill-opportunity-policy.toml",
        );
        assert_eq!(policy.kind, MutableArtifactKind::PolicyPack);

        let python_entry = load_record(&manifest1, "data/python-skills/calendar/skill.py");
        assert_eq!(
            python_entry.kind,
            MutableArtifactKind::PythonSkillEntrypoint
        );
        assert_eq!(python_entry.promotion_state, PromotionState::Canary);

        let staging = load_record(&manifest1, "data/staging/gen-1/proposal.toml");
        assert_eq!(staging.promotion_state, PromotionState::Staging);

        write_file(&python_root.join("calendar/skill.py"), "print('v2')\n");
        write_file(
            &python_root.join(".state/registry.json"),
            r#"{"version":1,"skills":[{"id":"calendar","status":"active"}]}"#,
        );

        let _summary2 = sync_mutation_manifest(MutationSyncEvent::new(
            "host.command",
            "skill.python.activate",
            None,
        ))
        .expect("sync manifest after update");
        let manifest2 = read_mutation_manifest().expect("read manifest");
        let python_entry2 = load_record(&manifest2, "data/python-skills/calendar/skill.py");
        assert_eq!(python_entry2.promotion_state, PromotionState::Active);
        assert_eq!(python_entry2.version, 2);

        std::fs::remove_file(data.path().join("staging/gen-1/proposal.toml"))
            .expect("remove staged file");
        let summary3 = sync_mutation_manifest(MutationSyncEvent::new(
            "host.command",
            "skill.cleanup",
            None,
        ))
        .expect("sync manifest after remove");
        assert_eq!(summary3.removed_in_sync, 1);

        let manifest3 = read_mutation_manifest().expect("read manifest");
        let staging3 = load_record(&manifest3, "data/staging/gen-1/proposal.toml");
        assert!(!staging3.exists);
        assert_eq!(staging3.promotion_state, PromotionState::Removed);
        assert_eq!(staging3.version, 2);
    }

    #[test]
    fn summarize_returns_zero_counts_when_manifest_missing() {
        let _guard = ENV_LOCK.lock().expect("lock");
        let data = TempDir::new().expect("data tempdir");
        let config = TempDir::new().expect("config tempdir");
        let _restore = setup_env(data.path(), config.path());

        let summary = summarize_mutation_manifest().expect("summary");
        assert_eq!(summary.artifact_count, 0);
        assert_eq!(summary.tombstoned_count, 0);
    }

    #[test]
    fn malformed_manifest_resets_to_empty_on_read() {
        let _guard = ENV_LOCK.lock().expect("lock");
        let data = TempDir::new().expect("data tempdir");
        let config = TempDir::new().expect("config tempdir");
        let _restore = setup_env(data.path(), config.path());

        let path = default_mutation_manifest_file();
        write_file(&path, "{not json");
        let manifest = read_mutation_manifest().expect("read fallback manifest");
        assert!(manifest.artifacts.is_empty());
        assert_eq!(manifest.schema_version, MUTATION_MANIFEST_SCHEMA_VERSION);
    }
}
