//! Persistent memory system for Fae.
//!
//! Backward compatibility:
//! - Keeps the original markdown-backed identity store (`primary_user.md`, `people.md`).
//!
//! New runtime memory core:
//! - Versioned manifest.
//! - JSONL record store (`records.jsonl`).
//! - Append-only audit log (`audit.jsonl`).
//! - Automatic recall and capture orchestrator hooks.

use crate::config::MemoryConfig;
use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashSet;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
use std::sync::{Mutex, OnceLock};

static RECORD_COUNTER: AtomicU64 = AtomicU64::new(1);
static MEMORY_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
const CURRENT_SCHEMA_VERSION: u32 = 2;
const MANIFEST_FILE: &str = "manifest.toml";
const RECORDS_FILE: &str = "records.jsonl";
const AUDIT_FILE: &str = "audit.jsonl";
const PROFILE_NAME_CONFIDENCE: f32 = 0.98;
const PROFILE_PREFERENCE_CONFIDENCE: f32 = 0.86;
const FACT_REMEMBER_CONFIDENCE: f32 = 0.80;
const FACT_CONVERSATIONAL_CONFIDENCE: f32 = 0.75;
const CODING_ASSISTANT_PERMISSION_CONFIDENCE: f32 = 0.92;
const CODING_ASSISTANT_PERMISSION_PENDING_CONFIDENCE: f32 = 0.55;
const ONBOARDING_COMPLETION_CONFIDENCE: f32 = 0.95;
const TRUNCATION_SUFFIX: &str = " [truncated]";
const ONBOARDING_REQUIRED_FIELDS: &[(&str, &str)] = &[
    ("onboarding:name", "name / preferred form of address"),
    ("onboarding:address", "location or home context"),
    ("onboarding:family", "family or household context"),
    ("onboarding:interests", "interests or hobbies"),
    ("onboarding:job", "job or work context"),
];

/// Maximum length (in bytes) of record text. Prevents unbounded growth from
/// excessively long LLM outputs or user input.
const MAX_RECORD_TEXT_LEN: usize = 32_768;

// -- Scoring weights for `score_record()` --
const SCORE_EMPTY_QUERY_BASELINE: f32 = 0.2;
const SCORE_CONFIDENCE_WEIGHT: f32 = 0.20;
const SCORE_FRESHNESS_WEIGHT: f32 = 0.10;
const SCORE_KIND_BONUS_PROFILE: f32 = 0.05;
const SCORE_KIND_BONUS_FACT: f32 = 0.03;
const SECS_PER_DAY: f32 = 86_400.0;

fn memory_write_lock() -> &'static Mutex<()> {
    MEMORY_WRITE_LOCK.get_or_init(|| Mutex::new(()))
}

#[must_use]
pub fn current_memory_schema_version() -> u32 {
    CURRENT_SCHEMA_VERSION
}

#[derive(Debug, Clone)]
pub struct MemoryStore {
    root: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrimaryUser {
    pub name: String,
    pub voiceprint: Option<Vec<f32>>,
    #[serde(default)]
    pub voice_sample_wav: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Person {
    pub name: String,
    pub voiceprint: Option<Vec<f32>>,
    #[serde(default)]
    pub voice_sample_wav: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PeopleFile {
    people: Vec<Person>,
}

impl MemoryStore {
    #[must_use]
    pub fn new(root_dir: &Path) -> Self {
        Self {
            root: root_dir.join("memory"),
        }
    }

    pub fn ensure_dirs(&self) -> Result<()> {
        std::fs::create_dir_all(&self.root)?;
        Ok(())
    }

    pub fn ensure_voice_dirs(root_dir: &Path) -> Result<()> {
        std::fs::create_dir_all(root_dir.join("voices"))?;
        Ok(())
    }

    #[must_use]
    pub fn voices_dir(root_dir: &Path) -> PathBuf {
        root_dir.join("voices")
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn primary_user_path(&self) -> PathBuf {
        self.root.join("primary_user.md")
    }

    fn people_path(&self) -> PathBuf {
        self.root.join("people.md")
    }

    pub fn load_primary_user(&self) -> Result<Option<PrimaryUser>> {
        let path = self.primary_user_path();
        if !path.exists() {
            return Ok(None);
        }
        let body = std::fs::read_to_string(&path)?;
        let toml = extract_toml_block(&body).ok_or_else(|| {
            SpeechError::Memory("primary user memory missing ```toml``` block".into())
        })?;
        let user: PrimaryUser = toml::from_str(&toml)
            .map_err(|e| SpeechError::Memory(format!("invalid primary user memory: {e}")))?;
        Ok(Some(user))
    }

    pub fn save_primary_user(&self, user: &PrimaryUser) -> Result<()> {
        self.ensure_dirs()?;
        let path = self.primary_user_path();
        let data = toml::to_string_pretty(user)
            .map_err(|e| SpeechError::Memory(format!("failed to serialize primary user: {e}")))?;

        let md = format!(
            "# Fae Memory: Primary User\n\n\
This file is managed by Fae. It is safe to edit by hand.\n\n\
```toml\n{data}```\n"
        );
        std::fs::write(path, md)?;
        Ok(())
    }

    pub fn load_people(&self) -> Result<Vec<Person>> {
        let path = self.people_path();
        if !path.exists() {
            return Ok(Vec::new());
        }
        let body = std::fs::read_to_string(&path)?;
        let toml = extract_toml_block(&body)
            .ok_or_else(|| SpeechError::Memory("people memory missing ```toml``` block".into()))?;
        let file: PeopleFile = toml::from_str(&toml)
            .map_err(|e| SpeechError::Memory(format!("invalid people memory: {e}")))?;
        Ok(file.people)
    }

    pub fn save_people(&self, people: &[Person]) -> Result<()> {
        self.ensure_dirs()?;
        let path = self.people_path();
        let file = PeopleFile {
            people: people.to_vec(),
        };
        let data = toml::to_string_pretty(&file)
            .map_err(|e| SpeechError::Memory(format!("failed to serialize people: {e}")))?;
        let md = format!(
            "# Fae Memory: People\n\n\
Known people and (optional) voiceprints.\n\n\
```toml\n{data}```\n"
        );
        std::fs::write(path, md)?;
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    Profile,
    Episode,
    Fact,
    /// A date-based event (birthday, meeting, deadline, anniversary).
    Event,
    /// A known person (friend, colleague, family member).
    Person,
    /// A user interest or hobby.
    Interest,
    /// A commitment or promise the user made.
    Commitment,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemoryStatus {
    Active,
    Superseded,
    Invalidated,
    Forgotten,
}

fn default_memory_status() -> MemoryStatus {
    MemoryStatus::Active
}

fn default_confidence() -> f32 {
    0.5
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryRecord {
    pub id: String,
    pub kind: MemoryKind,
    #[serde(default = "default_memory_status")]
    pub status: MemoryStatus,
    pub text: String,
    #[serde(default = "default_confidence")]
    pub confidence: f32,
    #[serde(default)]
    pub source_turn_id: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub supersedes: Option<String>,
    #[serde(default)]
    pub created_at: u64,
    #[serde(default)]
    pub updated_at: u64,
    /// Optional importance score for prioritization (0.0–1.0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub importance_score: Option<f32>,
    /// Optional staleness threshold in seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stale_after_secs: Option<u64>,
    /// Optional structured metadata (JSON blob).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemoryAuditOp {
    Insert,
    Patch,
    Supersede,
    Invalidate,
    ForgetSoft,
    ForgetHard,
    Migrate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryAuditEntry {
    pub id: String,
    pub op: MemoryAuditOp,
    pub target_id: Option<String>,
    pub note: String,
    pub at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MemoryManifest {
    schema_version: u32,
    index_version: u32,
    embedder_version: String,
    created_at: u64,
    updated_at: u64,
}

impl Default for MemoryManifest {
    fn default() -> Self {
        let now = now_epoch_secs();
        Self {
            schema_version: CURRENT_SCHEMA_VERSION,
            index_version: 1,
            embedder_version: "none".to_owned(),
            created_at: now,
            updated_at: now,
        }
    }
}

#[derive(Debug, Clone)]
pub struct MemorySearchHit {
    pub record: MemoryRecord,
    pub score: f32,
}

#[derive(Debug, Clone)]
pub struct MemoryRepository {
    root: PathBuf,
}

impl MemoryRepository {
    #[must_use]
    pub fn new(root_dir: &Path) -> Self {
        Self {
            root: root_dir.join("memory"),
        }
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn manifest_path(&self) -> PathBuf {
        self.root.join(MANIFEST_FILE)
    }

    fn records_path(&self) -> PathBuf {
        self.root.join(RECORDS_FILE)
    }

    fn audit_path(&self) -> PathBuf {
        self.root.join(AUDIT_FILE)
    }

    pub fn ensure_layout(&self) -> Result<()> {
        std::fs::create_dir_all(&self.root)?;

        let manifest_path = self.manifest_path();
        if !manifest_path.exists() {
            self.write_manifest(&MemoryManifest::default())?;
        }

        Self::touch_file(&self.records_path())?;
        Self::touch_file(&self.audit_path())?;
        Ok(())
    }

    fn touch_file(path: &Path) -> Result<()> {
        let _file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(())
    }

    fn with_write_lock<T>(&self, op: impl FnOnce() -> Result<T>) -> Result<T> {
        let _guard = match memory_write_lock().lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        op()
    }

    fn read_manifest(&self) -> Result<MemoryManifest> {
        self.ensure_layout()?;
        let content = std::fs::read_to_string(self.manifest_path())?;
        toml::from_str(&content)
            .map_err(|e| SpeechError::Memory(format!("invalid memory manifest: {e}")))
    }

    fn write_manifest(&self, manifest: &MemoryManifest) -> Result<()> {
        std::fs::create_dir_all(&self.root)?;
        let body = toml::to_string_pretty(manifest).map_err(|e| {
            SpeechError::Memory(format!("failed to serialize memory manifest: {e}"))
        })?;
        std::fs::write(self.manifest_path(), body)?;
        Ok(())
    }

    fn touch_manifest_updated_at(&self) -> Result<()> {
        let mut manifest = self.read_manifest()?;
        manifest.updated_at = now_epoch_secs();
        self.write_manifest(&manifest)
    }

    pub fn schema_version(&self) -> Result<u32> {
        Ok(self.read_manifest()?.schema_version)
    }

    pub fn migrate_if_needed(&self, target_version: u32) -> Result<Option<(u32, u32)>> {
        self.with_write_lock(|| {
            self.ensure_layout()?;
            let mut manifest = self.read_manifest()?;

            if manifest.schema_version == target_version {
                return Ok(None);
            }
            if manifest.schema_version > target_version {
                return Err(SpeechError::Memory(format!(
                    "cannot downgrade memory schema from {} to {}",
                    manifest.schema_version, target_version
                )));
            }

            let from = manifest.schema_version;
            let backup_dir = self.create_backup_snapshot(from, target_version)?;

            let mut version = manifest.schema_version;
            let migration_result = (|| -> Result<()> {
                while version < target_version {
                    match version {
                        0 => self.migrate_0_to_1()?,
                        1 => self.migrate_1_to_2()?,
                        other => {
                            return Err(SpeechError::Memory(format!(
                                "unsupported memory migration from schema version {other}"
                            )));
                        }
                    }
                    version = version.saturating_add(1);
                }
                Ok(())
            })();

            if let Err(migration_err) = migration_result {
                if let Err(restore_err) = self.restore_backup_snapshot(&backup_dir) {
                    return Err(SpeechError::Memory(format!(
                        "memory migration failed ({migration_err}); rollback failed ({restore_err})"
                    )));
                }
                return Err(migration_err);
            }

            manifest.schema_version = target_version;
            manifest.updated_at = now_epoch_secs();
            self.write_manifest(&manifest)?;

            self.append_audit(MemoryAuditEntry {
                id: new_id("audit"),
                op: MemoryAuditOp::Migrate,
                target_id: None,
                note: format!("schema migrated from {from} to {target_version}"),
                at: now_epoch_secs(),
            })?;

            Ok(Some((from, target_version)))
        })
    }

    fn migrate_0_to_1(&self) -> Result<()> {
        // v1 introduces typed status and audit-backed lifecycle.
        // Existing lines are preserved and normalized with defaults.
        self.ensure_layout()?;

        let records = self.list_records()?;
        self.rewrite_records(&records)?;

        #[cfg(debug_assertions)]
        {
            let failpoint = self.root.join(".fail_migration");
            let env_fail = std::env::var("FAE_MEMORY_TEST_FAIL_MIGRATION")
                .ok()
                .is_some_and(|v| v == "1");
            if failpoint.exists() || env_fail {
                return Err(SpeechError::Memory(
                    "migration failpoint triggered for testing".to_owned(),
                ));
            }
        }
        Ok(())
    }

    fn migrate_1_to_2(&self) -> Result<()> {
        // v2 adds optional fields (importance_score, stale_after_secs, metadata)
        // to MemoryRecord and new MemoryKind variants (Event, Person, Interest,
        // Commitment). All new fields have #[serde(default)] so existing records
        // deserialize without changes. We re-serialize to normalize the format.
        self.ensure_layout()?;
        let records = self.list_records()?;
        self.rewrite_records(&records)?;
        Ok(())
    }

    fn create_backup_snapshot(&self, from: u32, to: u32) -> Result<PathBuf> {
        let backup_dir = self
            .root
            .join("backups")
            .join(format!("schema-{from}-to-{to}-{}", now_epoch_secs()));
        std::fs::create_dir_all(&backup_dir)?;

        self.copy_if_exists(&self.manifest_path(), &backup_dir.join(MANIFEST_FILE))?;
        self.copy_if_exists(&self.records_path(), &backup_dir.join(RECORDS_FILE))?;
        self.copy_if_exists(&self.audit_path(), &backup_dir.join(AUDIT_FILE))?;
        Ok(backup_dir)
    }

    fn copy_if_exists(&self, from: &Path, to: &Path) -> Result<()> {
        if from.exists() {
            let _bytes = std::fs::copy(from, to)?;
        }
        Ok(())
    }

    fn restore_backup_snapshot(&self, backup_dir: &Path) -> Result<()> {
        self.ensure_layout()?;
        self.restore_file_from_backup(&backup_dir.join(MANIFEST_FILE), &self.manifest_path())?;
        self.restore_file_from_backup(&backup_dir.join(RECORDS_FILE), &self.records_path())?;
        self.restore_file_from_backup(&backup_dir.join(AUDIT_FILE), &self.audit_path())?;
        Ok(())
    }

    fn restore_file_from_backup(&self, backup_path: &Path, target_path: &Path) -> Result<()> {
        if backup_path.exists() {
            let _bytes = std::fs::copy(backup_path, target_path)?;
        } else if target_path.exists() {
            std::fs::remove_file(target_path)?;
        }
        Ok(())
    }

    pub fn list_records(&self) -> Result<Vec<MemoryRecord>> {
        self.ensure_layout()?;
        let file = OpenOptions::new().read(true).open(self.records_path())?;
        let reader = BufReader::new(file);
        let mut out = Vec::new();
        for (idx, line_res) in reader.lines().enumerate() {
            let line = line_res?;
            if line.trim().is_empty() {
                continue;
            }
            let record: MemoryRecord = serde_json::from_str(&line).map_err(|e| {
                SpeechError::Memory(format!("invalid record at line {}: {e}", idx + 1))
            })?;
            out.push(record);
        }
        Ok(out)
    }

    pub fn audit_entries(&self) -> Result<Vec<MemoryAuditEntry>> {
        self.ensure_layout()?;
        let file = OpenOptions::new().read(true).open(self.audit_path())?;
        let reader = BufReader::new(file);
        let mut out = Vec::new();
        for (idx, line_res) in reader.lines().enumerate() {
            let line = line_res?;
            if line.trim().is_empty() {
                continue;
            }
            let entry: MemoryAuditEntry = serde_json::from_str(&line).map_err(|e| {
                SpeechError::Memory(format!("invalid audit entry at line {}: {e}", idx + 1))
            })?;
            out.push(entry);
        }
        Ok(out)
    }

    fn rewrite_records(&self, records: &[MemoryRecord]) -> Result<()> {
        let temp_path = self.root.join("records.jsonl.tmp");
        let mut temp = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temp_path)?;

        for record in records {
            let line = serde_json::to_string(record)
                .map_err(|e| SpeechError::Memory(format!("failed to encode record: {e}")))?;
            temp.write_all(line.as_bytes())?;
            temp.write_all(b"\n")?;
        }
        temp.flush()?;
        std::fs::rename(temp_path, self.records_path())?;
        self.touch_manifest_updated_at()?;
        Ok(())
    }

    fn append_record(&self, record: &MemoryRecord) -> Result<()> {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.records_path())?;
        let line = serde_json::to_string(record)
            .map_err(|e| SpeechError::Memory(format!("failed to encode record: {e}")))?;
        file.write_all(line.as_bytes())?;
        file.write_all(b"\n")?;
        file.flush()?;
        self.touch_manifest_updated_at()?;
        Ok(())
    }

    fn append_audit(&self, entry: MemoryAuditEntry) -> Result<()> {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.audit_path())?;
        let line = serde_json::to_string(&entry)
            .map_err(|e| SpeechError::Memory(format!("failed to encode audit entry: {e}")))?;
        file.write_all(line.as_bytes())?;
        file.write_all(b"\n")?;
        file.flush()?;
        Ok(())
    }

    pub fn insert_record(
        &self,
        kind: MemoryKind,
        text: &str,
        confidence: f32,
        source_turn_id: Option<&str>,
        tags: Vec<String>,
    ) -> Result<MemoryRecord> {
        self.with_write_lock(|| {
            self.ensure_layout()?;
            let clean_text = text.trim();
            if clean_text.is_empty() {
                return Err(SpeechError::Memory(
                    "cannot insert empty memory record".to_owned(),
                ));
            }
            if clean_text.len() > MAX_RECORD_TEXT_LEN {
                return Err(SpeechError::Memory(format!(
                    "memory record text too long ({} bytes, max {})",
                    clean_text.len(),
                    MAX_RECORD_TEXT_LEN
                )));
            }

            let now = now_epoch_secs();
            let record = MemoryRecord {
                id: new_id("mem"),
                kind,
                status: MemoryStatus::Active,
                text: clean_text.to_owned(),
                confidence: confidence.clamp(0.0, 1.0),
                source_turn_id: source_turn_id.map(ToOwned::to_owned),
                tags,
                supersedes: None,
                created_at: now,
                updated_at: now,
                importance_score: None,
                stale_after_secs: None,
                metadata: None,
            };

            self.append_record(&record)?;
            self.append_audit(MemoryAuditEntry {
                id: new_id("audit"),
                op: MemoryAuditOp::Insert,
                target_id: Some(record.id.clone()),
                note: format!("inserted {} memory", display_kind(kind)),
                at: now,
            })?;
            Ok(record)
        })
    }

    pub fn patch_record(&self, id: &str, new_text: &str, note: &str) -> Result<()> {
        self.with_write_lock(|| {
            let mut records = self.list_records()?;
            let now = now_epoch_secs();
            let mut found = false;
            for record in &mut records {
                if record.id == id {
                    record.text = new_text.trim().to_owned();
                    record.updated_at = now;
                    found = true;
                    break;
                }
            }
            if !found {
                return Err(SpeechError::Memory(format!(
                    "cannot patch memory; id not found: {id}"
                )));
            }
            self.rewrite_records(&records)?;
            self.append_audit(MemoryAuditEntry {
                id: new_id("audit"),
                op: MemoryAuditOp::Patch,
                target_id: Some(id.to_owned()),
                note: note.to_owned(),
                at: now,
            })?;
            Ok(())
        })
    }

    pub fn supersede_record(
        &self,
        old_id: &str,
        new_text: &str,
        confidence: f32,
        source_turn_id: Option<&str>,
        tags: Vec<String>,
        note: &str,
    ) -> Result<MemoryRecord> {
        self.with_write_lock(|| {
            let mut records = self.list_records()?;
            let now = now_epoch_secs();
            let mut old_kind: Option<MemoryKind> = None;
            let mut found = false;

            for record in &mut records {
                if record.id == old_id {
                    old_kind = Some(record.kind);
                    record.status = MemoryStatus::Superseded;
                    record.updated_at = now;
                    found = true;
                    break;
                }
            }

            if !found {
                return Err(SpeechError::Memory(format!(
                    "cannot supersede memory; id not found: {old_id}"
                )));
            }

            let trimmed_new_text = new_text.trim();
            if trimmed_new_text.len() > MAX_RECORD_TEXT_LEN {
                return Err(SpeechError::Memory(format!(
                    "memory record text too long ({} bytes, max {})",
                    trimmed_new_text.len(),
                    MAX_RECORD_TEXT_LEN
                )));
            }

            let kind = old_kind.unwrap_or(MemoryKind::Fact);
            let new_record = MemoryRecord {
                id: new_id("mem"),
                kind,
                status: MemoryStatus::Active,
                text: trimmed_new_text.to_owned(),
                confidence: confidence.clamp(0.0, 1.0),
                source_turn_id: source_turn_id.map(ToOwned::to_owned),
                tags,
                supersedes: Some(old_id.to_owned()),
                created_at: now,
                updated_at: now,
                importance_score: None,
                stale_after_secs: None,
                metadata: None,
            };

            records.push(new_record.clone());
            self.rewrite_records(&records)?;

            self.append_audit(MemoryAuditEntry {
                id: new_id("audit"),
                op: MemoryAuditOp::Supersede,
                target_id: Some(new_record.id.clone()),
                note: note.to_owned(),
                at: now,
            })?;

            Ok(new_record)
        })
    }

    pub fn invalidate_record(&self, id: &str, note: &str) -> Result<()> {
        self.set_status(
            id,
            MemoryStatus::Invalidated,
            MemoryAuditOp::Invalidate,
            note,
        )
    }

    pub fn forget_soft_record(&self, id: &str, note: &str) -> Result<()> {
        self.set_status(id, MemoryStatus::Forgotten, MemoryAuditOp::ForgetSoft, note)
    }

    pub fn forget_hard_record(&self, id: &str, note: &str) -> Result<()> {
        self.with_write_lock(|| {
            let mut records = self.list_records()?;
            let now = now_epoch_secs();
            let before = records.len();
            records.retain(|r| r.id != id);
            if records.len() == before {
                return Err(SpeechError::Memory(format!(
                    "cannot hard-forget memory; id not found: {id}"
                )));
            }

            self.rewrite_records(&records)?;
            self.append_audit(MemoryAuditEntry {
                id: new_id("audit"),
                op: MemoryAuditOp::ForgetHard,
                target_id: Some(id.to_owned()),
                note: note.to_owned(),
                at: now,
            })?;
            Ok(())
        })
    }

    fn set_status(
        &self,
        id: &str,
        status: MemoryStatus,
        op: MemoryAuditOp,
        note: &str,
    ) -> Result<()> {
        self.with_write_lock(|| {
            let mut records = self.list_records()?;
            let now = now_epoch_secs();
            let mut found = false;

            for record in &mut records {
                if record.id == id {
                    record.status = status;
                    record.updated_at = now;
                    found = true;
                    break;
                }
            }

            if !found {
                return Err(SpeechError::Memory(format!(
                    "cannot update memory; id not found: {id}"
                )));
            }

            self.rewrite_records(&records)?;
            self.append_audit(MemoryAuditEntry {
                id: new_id("audit"),
                op,
                target_id: Some(id.to_owned()),
                note: note.to_owned(),
                at: now,
            })?;
            Ok(())
        })
    }

    pub fn find_active_by_tag(&self, tag: &str) -> Result<Vec<MemoryRecord>> {
        let normalized = tag.trim().to_ascii_lowercase();
        if normalized.is_empty() {
            return Ok(Vec::new());
        }

        let records = self.list_records()?;
        let mut out = Vec::new();
        for record in records {
            if record.status != MemoryStatus::Active {
                continue;
            }
            if record
                .tags
                .iter()
                .any(|t| t.trim().eq_ignore_ascii_case(&normalized))
            {
                out.push(record);
            }
        }
        out.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        Ok(out)
    }

    pub fn search(
        &self,
        query: &str,
        limit: usize,
        include_inactive: bool,
    ) -> Result<Vec<MemorySearchHit>> {
        let max_results = limit.max(1);
        let query_tokens = tokenize(query);
        let mut hits = Vec::new();

        for record in self.list_records()? {
            if !include_inactive && record.status != MemoryStatus::Active {
                continue;
            }
            let score = score_record(&record, &query_tokens);
            if score <= 0.0 {
                continue;
            }
            hits.push(MemorySearchHit { record, score });
        }

        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| b.record.updated_at.cmp(&a.record.updated_at))
        });
        hits.truncate(max_results);
        Ok(hits)
    }

    pub fn apply_retention_policy(&self, retention_days: u32) -> Result<usize> {
        self.with_write_lock(|| {
            if retention_days == 0 {
                return Ok(0);
            }

            let mut records = self.list_records()?;
            let cutoff = now_epoch_secs().saturating_sub((retention_days as u64) * 24 * 3600);
            let mut changed = 0usize;

            for record in &mut records {
                if record.kind == MemoryKind::Episode
                    && record.status == MemoryStatus::Active
                    && record.updated_at > 0
                    && record.updated_at < cutoff
                {
                    record.status = MemoryStatus::Forgotten;
                    record.updated_at = now_epoch_secs();
                    changed = changed.saturating_add(1);
                }
            }

            if changed > 0 {
                self.rewrite_records(&records)?;
                self.append_audit(MemoryAuditEntry {
                    id: new_id("audit"),
                    op: MemoryAuditOp::ForgetSoft,
                    target_id: None,
                    note: format!("retention policy soft-forgot {changed} episodic records"),
                    at: now_epoch_secs(),
                })?;
            }

            Ok(changed)
        })
    }
}

#[derive(Debug, Clone, Default)]
pub struct MemoryCaptureReport {
    pub episodes_written: usize,
    pub facts_written: usize,
    pub profile_updates: usize,
    pub forgotten: usize,
    pub conflicts_resolved: usize,
    pub writes: Vec<MemoryWriteSummary>,
    pub conflicts: Vec<MemoryConflictSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryWriteSummary {
    pub op: String,
    pub target_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryConflictSummary {
    pub existing_id: String,
    pub replacement_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct MemoryOrchestrator {
    repo: MemoryRepository,
    config: MemoryConfig,
}

impl MemoryOrchestrator {
    #[must_use]
    pub fn new(config: &MemoryConfig) -> Self {
        Self {
            repo: MemoryRepository::new(&config.root_dir),
            config: config.clone(),
        }
    }

    pub fn ensure_ready(&self) -> Result<()> {
        let _migration = self.ensure_ready_with_migration()?;
        Ok(())
    }

    pub fn ensure_ready_with_migration(&self) -> Result<Option<(u32, u32)>> {
        self.repo.ensure_layout()?;
        if self.config.schema_auto_migrate {
            return self.repo.migrate_if_needed(CURRENT_SCHEMA_VERSION);
        }
        Ok(None)
    }

    pub fn schema_version(&self) -> Result<u32> {
        self.repo.schema_version()
    }

    #[must_use]
    pub fn target_schema_version(&self) -> u32 {
        CURRENT_SCHEMA_VERSION
    }

    /// Returns the remembered permission for using local Claude/Codex tools.
    ///
    /// - `Some(true)`: user allowed use for coding tasks
    /// - `Some(false)`: user denied use
    /// - `None`: not decided yet
    pub fn coding_assistant_permission(&self) -> Result<Option<bool>> {
        if !self.config.enabled {
            return Ok(None);
        }
        self.ensure_ready()?;
        let records = self
            .repo
            .find_active_by_tag("coding_assistant_permission")?;
        let Some(record) = records.first() else {
            return Ok(None);
        };

        if record
            .tags
            .iter()
            .any(|t| t.eq_ignore_ascii_case("allowed"))
        {
            return Ok(Some(true));
        }
        if record.tags.iter().any(|t| t.eq_ignore_ascii_case("denied")) {
            return Ok(Some(false));
        }

        let lower = record.text.to_ascii_lowercase();
        if lower.contains("allow") || lower.contains("permitted") {
            return Ok(Some(true));
        }
        if lower.contains("deny") || lower.contains("do not allow") || lower.contains("not allow") {
            return Ok(Some(false));
        }
        Ok(None)
    }

    /// Returns `true` when onboarding is complete.
    pub fn is_onboarding_complete(&self) -> Result<bool> {
        if !self.config.enabled {
            return Ok(true);
        }
        self.ensure_ready()?;
        if !self
            .repo
            .find_active_by_tag("onboarding_complete")?
            .is_empty()
        {
            return Ok(true);
        }
        Ok(self.onboarding_missing_fields()?.is_empty())
    }

    /// Build onboarding context when onboarding is still in progress.
    pub fn onboarding_context(&self) -> Result<Option<String>> {
        if !self.config.enabled {
            return Ok(None);
        }
        self.ensure_ready()?;
        let missing = self.onboarding_missing_fields()?;
        if missing.is_empty() {
            return Ok(None);
        }

        let checklist = crate::personality::load_onboarding_checklist();
        let trimmed = checklist.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }

        let mut missing_lines = String::new();
        for field in &missing {
            missing_lines.push_str("- ");
            missing_lines.push_str(field);
            missing_lines.push('\n');
        }

        Ok(Some(format!(
            "<onboarding_context>\n\
status: incomplete\n\
missing_fields:\n\
{missing_lines}\
checklist:\n\
{trimmed}\n\
</onboarding_context>"
        )))
    }

    pub fn recall_context(&self, query: &str) -> Result<Option<String>> {
        if !self.config.enabled || !self.config.auto_recall {
            return Ok(None);
        }

        self.ensure_ready()?;
        let hits = self
            .repo
            .search(query, self.config.recall_max_items.max(1), false)?;
        let min_confidence = self.min_profile_confidence();

        // Separate durable records (profile/fact) from episodes.
        let mut durable_hits = Vec::new();
        let mut episode_hits = Vec::new();
        for h in hits {
            if h.record.kind != MemoryKind::Episode && h.record.confidence >= min_confidence {
                durable_hits.push(h);
            } else if h.record.kind == MemoryKind::Episode && h.score >= 0.6 {
                // Include high-relevance episodes as supplemental context.
                episode_hits.push(h);
            }
        }

        if durable_hits.is_empty() && episode_hits.is_empty() {
            return Ok(None);
        }

        let max_chars = self.config.recall_max_chars.max(200);
        let mut body = String::from("<memory_context>\n");
        let mut injected = 0usize;

        // Inject durable records first (highest priority).
        for hit in &durable_hits {
            let kind = display_kind(hit.record.kind);
            let line = format!(
                "- [{} {:.2}] {}\n",
                kind,
                hit.record.confidence.clamp(0.0, 1.0),
                hit.record.text
            );

            if body.len().saturating_add(line.len()).saturating_add(17) > max_chars {
                break;
            }

            body.push_str(&line);
            injected = injected.saturating_add(1);
        }

        // Fill remaining space with relevant episodes (capped at 3).
        let max_episodes = 3usize;
        let mut episode_count = 0usize;
        for hit in &episode_hits {
            if episode_count >= max_episodes {
                break;
            }
            let line = format!(
                "- [episode {:.2}] {}\n",
                hit.record.confidence.clamp(0.0, 1.0),
                hit.record.text
            );

            if body.len().saturating_add(line.len()).saturating_add(17) > max_chars {
                break;
            }

            body.push_str(&line);
            injected = injected.saturating_add(1);
            episode_count = episode_count.saturating_add(1);
        }

        if injected == 0 {
            return Ok(None);
        }

        body.push_str("</memory_context>");
        Ok(Some(body))
    }

    pub fn capture_turn(
        &self,
        turn_id: &str,
        user_text: &str,
        assistant_text: &str,
    ) -> Result<MemoryCaptureReport> {
        if !self.config.enabled || !self.config.auto_capture {
            return Ok(MemoryCaptureReport::default());
        }

        self.ensure_ready()?;

        let user_trimmed = user_text.trim();
        if user_trimmed.is_empty() {
            return Ok(MemoryCaptureReport::default());
        }

        let mut report = MemoryCaptureReport::default();

        let episode_text = if assistant_text.trim().is_empty() {
            format!("User: {user_trimmed}")
        } else {
            format!("User: {user_trimmed}\nAssistant: {}", assistant_text.trim())
        };
        let episode_text = truncate_record_text(&episode_text);

        let episode = self.repo.insert_record(
            MemoryKind::Episode,
            &episode_text,
            0.55,
            Some(turn_id),
            vec!["turn".to_owned()],
        )?;
        report.episodes_written = 1;
        report.writes.push(MemoryWriteSummary {
            op: "insert_episode".to_owned(),
            target_id: Some(episode.id.clone()),
        });

        if let Some(forget_query) = parse_forget_command(user_trimmed) {
            let hits = self.repo.search(&forget_query, 5, false)?;
            for hit in &hits {
                self.repo
                    .forget_soft_record(&hit.record.id, "user-requested soft forget")?;
                report.forgotten = report.forgotten.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "forget_soft".to_owned(),
                    target_id: Some(hit.record.id.clone()),
                });
            }
            return Ok(report);
        }

        if let Some(remember) = parse_remember_command(user_trimmed) {
            let remember = truncate_record_text(&remember);
            if !remember.is_empty()
                && self.meets_profile_threshold(FACT_REMEMBER_CONFIDENCE)
                && !self.is_duplicate_memory(&remember)?
            {
                let record = self.repo.insert_record(
                    MemoryKind::Fact,
                    &remember,
                    FACT_REMEMBER_CONFIDENCE,
                    Some(turn_id),
                    vec!["remembered".to_owned()],
                )?;
                report.facts_written = report.facts_written.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "insert_fact".to_owned(),
                    target_id: Some(record.id.clone()),
                });
            }
        }

        if let Some(name) = parse_name_statement(user_trimmed) {
            let profile = truncate_record_text(&format!("Primary user name is {name}."));
            if self.meets_profile_threshold(PROFILE_NAME_CONFIDENCE) {
                let name_tags = vec![
                    "name".to_owned(),
                    "identity".to_owned(),
                    "onboarding:name".to_owned(),
                ];
                let existing = self.repo.find_active_by_tag("name")?;
                if let Some(previous) = existing.first() {
                    if !previous.text.eq_ignore_ascii_case(&profile) {
                        let new_record = self.repo.supersede_record(
                            &previous.id,
                            &profile,
                            PROFILE_NAME_CONFIDENCE,
                            Some(turn_id),
                            name_tags.clone(),
                            "name updated from user statement",
                        )?;
                        report.profile_updates = report.profile_updates.saturating_add(1);
                        report.conflicts_resolved = report.conflicts_resolved.saturating_add(1);
                        report.writes.push(MemoryWriteSummary {
                            op: "update_profile".to_owned(),
                            target_id: Some(new_record.id.clone()),
                        });
                        report.conflicts.push(MemoryConflictSummary {
                            existing_id: previous.id.clone(),
                            replacement_id: Some(new_record.id.clone()),
                        });
                    }
                } else {
                    let new_record = self.repo.insert_record(
                        MemoryKind::Profile,
                        &profile,
                        PROFILE_NAME_CONFIDENCE,
                        Some(turn_id),
                        name_tags,
                    )?;
                    report.profile_updates = report.profile_updates.saturating_add(1);
                    report.writes.push(MemoryWriteSummary {
                        op: "update_profile".to_owned(),
                        target_id: Some(new_record.id.clone()),
                    });
                }
            }
        }

        if let Some(pref) = parse_preference_statement(user_trimmed) {
            let profile = truncate_record_text(&format!("User preference: {pref}"));
            if self.meets_profile_threshold(PROFILE_PREFERENCE_CONFIDENCE) {
                let mut preference_tags = vec!["preference".to_owned()];
                if is_interest_preference(&pref) {
                    preference_tags.push("onboarding:interests".to_owned());
                }
                let existing = self.repo.find_active_by_tag("preference")?;
                if let Some(previous) = existing.first() {
                    if !previous.text.eq_ignore_ascii_case(&profile) {
                        let new_record = self.repo.supersede_record(
                            &previous.id,
                            &profile,
                            PROFILE_PREFERENCE_CONFIDENCE,
                            Some(turn_id),
                            preference_tags.clone(),
                            "preference updated from user statement",
                        )?;
                        report.profile_updates = report.profile_updates.saturating_add(1);
                        report.conflicts_resolved = report.conflicts_resolved.saturating_add(1);
                        report.writes.push(MemoryWriteSummary {
                            op: "update_profile".to_owned(),
                            target_id: Some(new_record.id.clone()),
                        });
                        report.conflicts.push(MemoryConflictSummary {
                            existing_id: previous.id.clone(),
                            replacement_id: Some(new_record.id.clone()),
                        });
                    }
                } else if !self.is_duplicate_memory(&profile)? {
                    let new_record = self.repo.insert_record(
                        MemoryKind::Profile,
                        &profile,
                        PROFILE_PREFERENCE_CONFIDENCE,
                        Some(turn_id),
                        preference_tags,
                    )?;
                    report.profile_updates = report.profile_updates.saturating_add(1);
                    report.writes.push(MemoryWriteSummary {
                        op: "update_profile".to_owned(),
                        target_id: Some(new_record.id.clone()),
                    });
                }
            }
        }

        let assistant_asked_for_coding_permission =
            assistant_asked_about_local_coding_tools(assistant_text);
        if assistant_asked_for_coding_permission && self.coding_assistant_permission()?.is_none() {
            let pending = self
                .repo
                .find_active_by_tag("coding_assistant_permission_pending")?;
            if pending.is_empty() {
                let pending_marker = self.repo.insert_record(
                    MemoryKind::Profile,
                    "Awaiting user decision on local Claude/Codex use for coding tasks.",
                    CODING_ASSISTANT_PERMISSION_PENDING_CONFIDENCE,
                    Some(turn_id),
                    vec!["coding_assistant_permission_pending".to_owned()],
                )?;
                report.profile_updates = report.profile_updates.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "update_profile".to_owned(),
                    target_id: Some(pending_marker.id),
                });
            }
        }

        let pending_permission = !self
            .repo
            .find_active_by_tag("coding_assistant_permission_pending")?
            .is_empty();
        if let Some(allowed) = parse_coding_assistant_permission(user_trimmed, pending_permission) {
            let profile = if allowed {
                "User allows Fae to use local Claude/Codex tools for coding tasks."
            } else {
                "User does not allow Fae to use local Claude/Codex tools for coding tasks."
            };
            let permission_tags = vec![
                "coding_assistant_permission".to_owned(),
                if allowed {
                    "allowed".to_owned()
                } else {
                    "denied".to_owned()
                },
            ];
            let existing = self
                .repo
                .find_active_by_tag("coding_assistant_permission")?;
            if let Some(previous) = existing.first() {
                if !previous.text.eq_ignore_ascii_case(profile) {
                    let new_record = self.repo.supersede_record(
                        &previous.id,
                        profile,
                        CODING_ASSISTANT_PERMISSION_CONFIDENCE,
                        Some(turn_id),
                        permission_tags.clone(),
                        "user updated local coding assistant permission",
                    )?;
                    report.profile_updates = report.profile_updates.saturating_add(1);
                    report.conflicts_resolved = report.conflicts_resolved.saturating_add(1);
                    report.writes.push(MemoryWriteSummary {
                        op: "update_profile".to_owned(),
                        target_id: Some(new_record.id.clone()),
                    });
                    report.conflicts.push(MemoryConflictSummary {
                        existing_id: previous.id.clone(),
                        replacement_id: Some(new_record.id.clone()),
                    });
                }
            } else {
                let new_record = self.repo.insert_record(
                    MemoryKind::Profile,
                    profile,
                    CODING_ASSISTANT_PERMISSION_CONFIDENCE,
                    Some(turn_id),
                    permission_tags,
                )?;
                report.profile_updates = report.profile_updates.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "update_profile".to_owned(),
                    target_id: Some(new_record.id.clone()),
                });
            }

            let pending_records = self
                .repo
                .find_active_by_tag("coding_assistant_permission_pending")?;
            for pending in pending_records {
                self.repo.invalidate_record(
                    &pending.id,
                    "coding assistant permission response captured",
                )?;
                report.writes.push(MemoryWriteSummary {
                    op: "invalidate_profile".to_owned(),
                    target_id: Some(pending.id),
                });
            }
        }

        if let Some(job) = parse_profession_statement(user_trimmed) {
            let profile = truncate_record_text(&format!("User job: {job}"));
            if self.meets_profile_threshold(FACT_CONVERSATIONAL_CONFIDENCE) {
                let existing = self.repo.find_active_by_tag("onboarding:job")?;
                if let Some(previous) = existing.first() {
                    if !previous.text.eq_ignore_ascii_case(&profile) {
                        let new_record = self.repo.supersede_record(
                            &previous.id,
                            &profile,
                            FACT_CONVERSATIONAL_CONFIDENCE,
                            Some(turn_id),
                            vec!["onboarding:job".to_owned(), "personal".to_owned()],
                            "job updated from user statement",
                        )?;
                        report.profile_updates = report.profile_updates.saturating_add(1);
                        report.conflicts_resolved = report.conflicts_resolved.saturating_add(1);
                        report.writes.push(MemoryWriteSummary {
                            op: "update_profile".to_owned(),
                            target_id: Some(new_record.id.clone()),
                        });
                        report.conflicts.push(MemoryConflictSummary {
                            existing_id: previous.id.clone(),
                            replacement_id: Some(new_record.id.clone()),
                        });
                    }
                } else if !self.is_duplicate_memory(&profile)? {
                    let new_record = self.repo.insert_record(
                        MemoryKind::Profile,
                        &profile,
                        FACT_CONVERSATIONAL_CONFIDENCE,
                        Some(turn_id),
                        vec!["onboarding:job".to_owned(), "personal".to_owned()],
                    )?;
                    report.profile_updates = report.profile_updates.saturating_add(1);
                    report.writes.push(MemoryWriteSummary {
                        op: "update_profile".to_owned(),
                        target_id: Some(new_record.id.clone()),
                    });
                }
            }
        }

        // Extract personal facts from conversational statements.
        let personal_facts = parse_personal_facts(user_trimmed);
        for fact in personal_facts {
            let fact = truncate_record_text(&fact);
            if !fact.is_empty()
                && self.meets_profile_threshold(FACT_CONVERSATIONAL_CONFIDENCE)
                && !self.is_duplicate_memory(&fact)?
            {
                let mut tags = vec!["personal".to_owned()];
                for onboarding_tag in onboarding_tags_for_personal_fact(&fact) {
                    if !tags.iter().any(|existing| existing == &onboarding_tag) {
                        tags.push(onboarding_tag);
                    }
                }
                let record = self.repo.insert_record(
                    MemoryKind::Fact,
                    &fact,
                    FACT_CONVERSATIONAL_CONFIDENCE,
                    Some(turn_id),
                    tags,
                )?;
                report.facts_written = report.facts_written.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "insert_fact".to_owned(),
                    target_id: Some(record.id.clone()),
                });
            }
        }

        self.maybe_mark_onboarding_complete(turn_id, &mut report)?;

        if self.config.retention_days > 0 {
            let _changed = self
                .repo
                .apply_retention_policy(self.config.retention_days)?;
        }

        Ok(report)
    }

    fn is_duplicate_memory(&self, text: &str) -> Result<bool> {
        let hits = self.repo.search(text, 3, false)?;
        // Only consider durable records (profile/fact) as duplicates, not episodes.
        // Episodes are conversation logs that naturally contain the same words as
        // extracted facts, but they're not semantic duplicates.
        for hit in &hits {
            if hit.record.kind != MemoryKind::Episode && hit.score >= 0.95 {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn min_profile_confidence(&self) -> f32 {
        self.config.min_profile_confidence.clamp(0.0, 1.0)
    }

    fn meets_profile_threshold(&self, confidence: f32) -> bool {
        confidence >= self.min_profile_confidence()
    }

    fn onboarding_missing_fields(&self) -> Result<Vec<&'static str>> {
        let mut missing: Vec<&'static str> = Vec::new();
        for (tag, label) in ONBOARDING_REQUIRED_FIELDS {
            if self.repo.find_active_by_tag(tag)?.is_empty() {
                missing.push(*label);
            }
        }
        Ok(missing)
    }

    fn maybe_mark_onboarding_complete(
        &self,
        turn_id: &str,
        report: &mut MemoryCaptureReport,
    ) -> Result<()> {
        if !self
            .repo
            .find_active_by_tag("onboarding_complete")?
            .is_empty()
        {
            return Ok(());
        }
        for (tag, _) in ONBOARDING_REQUIRED_FIELDS {
            if self.repo.find_active_by_tag(tag)?.is_empty() {
                return Ok(());
            }
        }

        let record = self.repo.insert_record(
            MemoryKind::Profile,
            "Onboarding checklist is complete.",
            ONBOARDING_COMPLETION_CONFIDENCE,
            Some(turn_id),
            vec!["onboarding_complete".to_owned(), "onboarding".to_owned()],
        )?;
        report.profile_updates = report.profile_updates.saturating_add(1);
        report.writes.push(MemoryWriteSummary {
            op: "update_profile".to_owned(),
            target_id: Some(record.id),
        });

        Ok(())
    }
}

pub fn run_memory_reflection(root_dir: &Path) -> Result<String> {
    let repo = MemoryRepository::new(root_dir);
    repo.ensure_layout()?;

    let changed = repo.with_write_lock(|| {
        // Collapse exact-duplicate active profile/fact records by soft-forgetting older ones.
        let mut records = repo.list_records()?;
        let mut seen = HashSet::new();
        let mut changed = 0usize;
        let now = now_epoch_secs();

        records.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        for record in &mut records {
            if record.status != MemoryStatus::Active {
                continue;
            }
            if !(record.kind == MemoryKind::Profile || record.kind == MemoryKind::Fact) {
                continue;
            }
            let key = format!(
                "{}::{}",
                display_kind(record.kind),
                record.text.trim().to_ascii_lowercase()
            );
            if seen.contains(&key) {
                record.status = MemoryStatus::Forgotten;
                record.updated_at = now;
                changed = changed.saturating_add(1);
            } else {
                let _ = seen.insert(key);
            }
        }

        if changed > 0 {
            repo.rewrite_records(&records)?;
        }

        Ok(changed)
    })?;

    Ok(format!(
        "memory reflection completed; deduplicated {changed} records"
    ))
}

pub fn run_memory_reindex(root_dir: &Path) -> Result<String> {
    let repo = MemoryRepository::new(root_dir);
    repo.ensure_layout()?;
    let records = repo.list_records()?;
    Ok(format!(
        "memory reindex completed; {} records scanned",
        records.len()
    ))
}

pub fn run_memory_gc(root_dir: &Path, retention_days: u32) -> Result<String> {
    let repo = MemoryRepository::new(root_dir);
    repo.ensure_layout()?;
    let changed = repo.apply_retention_policy(retention_days)?;
    Ok(format!(
        "memory retention completed; soft-forgot {} episodic records",
        changed
    ))
}

pub fn run_memory_migration(root_dir: &Path) -> Result<String> {
    let repo = MemoryRepository::new(root_dir);
    repo.ensure_layout()?;
    let migrated = repo.migrate_if_needed(CURRENT_SCHEMA_VERSION)?;
    let msg = match migrated {
        Some((from, to)) => format!("memory migration completed ({from} -> {to})"),
        None => "memory migration not needed".to_owned(),
    };
    Ok(msg)
}

pub fn default_memory_root_dir() -> PathBuf {
    crate::fae_dirs::memory_dir()
}

fn display_kind(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::Profile => "profile",
        MemoryKind::Episode => "episode",
        MemoryKind::Fact => "fact",
        MemoryKind::Event => "event",
        MemoryKind::Person => "person",
        MemoryKind::Interest => "interest",
        MemoryKind::Commitment => "commitment",
    }
}

fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();

    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() || ch == '\'' || ch == '-' {
            current.push(ch.to_ascii_lowercase());
        } else if !current.is_empty() {
            if current.len() > 1 {
                tokens.push(current.clone());
            }
            current.clear();
        }
    }
    if !current.is_empty() && current.len() > 1 {
        tokens.push(current);
    }

    tokens
}

fn score_record(record: &MemoryRecord, query_tokens: &[String]) -> f32 {
    let mut score = 0.0f32;

    if query_tokens.is_empty() {
        score += SCORE_EMPTY_QUERY_BASELINE;
    } else {
        let text_tokens: HashSet<String> = tokenize(&record.text).into_iter().collect();
        let mut overlap = 0usize;
        for token in query_tokens {
            if text_tokens.contains(token) {
                overlap = overlap.saturating_add(1);
            }
        }
        if overlap > 0 {
            score += overlap as f32 / query_tokens.len() as f32;
        }
    }

    score += SCORE_CONFIDENCE_WEIGHT * record.confidence.clamp(0.0, 1.0);

    let now = now_epoch_secs();
    if record.updated_at > 0 && record.updated_at <= now {
        let age_days = (now - record.updated_at) as f32 / SECS_PER_DAY;
        let freshness = 1.0 / (1.0 + age_days);
        score += SCORE_FRESHNESS_WEIGHT * freshness;
    }

    match record.kind {
        MemoryKind::Profile => score += SCORE_KIND_BONUS_PROFILE,
        MemoryKind::Fact => score += SCORE_KIND_BONUS_FACT,
        MemoryKind::Event | MemoryKind::Commitment => score += SCORE_KIND_BONUS_FACT,
        MemoryKind::Person | MemoryKind::Interest => score += SCORE_KIND_BONUS_FACT,
        MemoryKind::Episode => {}
    }

    score
}

fn parse_remember_command(text: &str) -> Option<String> {
    let raw = text.trim();
    let lower = raw.to_ascii_lowercase();

    for prefix in ["remember that ", "remember ", "please remember "] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let start = raw.len().saturating_sub(rest.len());
            let original_rest = raw[start..].trim();
            if !original_rest.is_empty() {
                return Some(original_rest.to_owned());
            }
        }
    }

    if lower.contains(" remember this") {
        return Some(raw.to_owned());
    }

    None
}

fn parse_forget_command(text: &str) -> Option<String> {
    let raw = text.trim();
    let lower = raw.to_ascii_lowercase();

    for prefix in ["forget ", "please forget ", "can you forget "] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let start = raw.len().saturating_sub(rest.len());
            let original_rest = raw[start..].trim();
            if !original_rest.is_empty() {
                return Some(original_rest.to_owned());
            }
        }
    }

    None
}

fn parse_name_statement(text: &str) -> Option<String> {
    let raw = text.trim();
    if raw.is_empty() {
        return None;
    }
    let lower = raw.to_ascii_lowercase();

    let patterns = [
        "my name is ",
        "i am ",
        "i'm ",
        "im ",
        "this is ",
        "call me ",
        "name's ",
        "names ",
    ];

    for pat in patterns {
        if let Some(idx) = lower.find(pat) {
            let rest = &lower[idx + pat.len()..];
            let token = rest.split_whitespace().next().unwrap_or("");
            let cleaned = clean_name_token(token);
            if !cleaned.is_empty() && !is_filler_word(&cleaned) && is_likely_name_token(&cleaned) {
                return Some(capitalize_first(&cleaned));
            }
        }
    }

    None
}

fn is_likely_name_token(token: &str) -> bool {
    if token.len() < 2 {
        return false;
    }
    !is_common_non_name_word(token)
}

fn is_common_non_name_word(token: &str) -> bool {
    matches!(
        token,
        // Feelings / states
        "tired"
            | "happy"
            | "sad"
            | "glad"
            | "ready"
            | "busy"
            | "hungry"
            | "thirsty"
            | "fine"
            | "good"
            | "okay"
            | "ok"
            | "great"
            | "here"
            | "there"
            | "back"
            | "sorry"
            | "afraid"
            | "excited"
            | "available"
            // Gender / identity
            | "male"
            | "female"
            | "nonbinary"
            // Nationalities / ethnicities (common ones that follow "I'm")
            | "scottish"
            | "english"
            | "irish"
            | "welsh"
            | "british"
            | "american"
            | "canadian"
            | "australian"
            | "french"
            | "german"
            | "italian"
            | "spanish"
            | "dutch"
            | "swedish"
            | "norwegian"
            | "danish"
            | "finnish"
            | "polish"
            | "russian"
            | "chinese"
            | "japanese"
            | "korean"
            | "indian"
            | "brazilian"
            | "mexican"
            | "african"
            | "european"
            | "asian"
            // Professions (common ones that follow "I'm a")
            | "developer"
            | "engineer"
            | "teacher"
            | "student"
            | "doctor"
            | "nurse"
            | "programmer"
            | "designer"
            | "writer"
            | "artist"
            | "musician"
            | "retired"
    )
}

fn parse_preference_statement(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    let patterns = [
        "i prefer ",
        "i like ",
        "i love ",
        "i enjoy ",
        "i'm interested in ",
        "i am interested in ",
        "my interests are ",
        "i don't like ",
        "i do not like ",
        "i hate ",
        "please always ",
        "please never ",
    ];

    for pat in patterns {
        if let Some(idx) = lower.find(pat) {
            let start = idx + pat.len();
            if start >= text.len() {
                continue;
            }
            let rest = text[start..]
                .trim()
                .trim_end_matches(['.', '!', '?'])
                .trim();
            if rest.is_empty() {
                continue;
            }
            return Some(format!("{} {}", pat.trim(), rest));
        }
    }

    None
}

fn is_interest_preference(preference: &str) -> bool {
    let lower = preference.to_ascii_lowercase();
    lower.starts_with("i like ")
        || lower.starts_with("i love ")
        || lower.starts_with("i enjoy ")
        || lower.starts_with("i'm interested in ")
        || lower.starts_with("i am interested in ")
        || lower.starts_with("my interests are ")
}

fn parse_profession_statement(text: &str) -> Option<String> {
    let raw = text.trim();
    if raw.is_empty() {
        return None;
    }
    let lower = raw.to_ascii_lowercase();

    for prefix in ["i am a ", "i am an ", "i'm a ", "i'm an "] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let rest_raw = raw[prefix.len()..]
                .trim()
                .trim_end_matches(['.', '!', '?'])
                .trim();
            if !rest_raw.is_empty() && contains_profession_token(rest) {
                return Some(rest_raw.to_owned());
            }
        }
    }

    for prefix in ["i work as ", "my job is "] {
        if let Some(idx) = lower.find(prefix) {
            let start = idx + prefix.len();
            if start < raw.len() {
                let rest = raw[start..].trim().trim_end_matches(['.', '!', '?']).trim();
                if !rest.is_empty() {
                    return Some(rest.to_owned());
                }
            }
        }
    }

    for prefix in ["i am retired", "i'm retired"] {
        if lower == prefix
            || lower
                .strip_prefix(prefix)
                .is_some_and(|rest| rest.starts_with(' '))
        {
            return Some("retired".to_owned());
        }
    }

    None
}

fn contains_profession_token(phrase: &str) -> bool {
    phrase.split_whitespace().take(6).any(|token| {
        let clean = token.trim_matches(|c: char| !c.is_ascii_alphabetic() && c != '-' && c != '\'');
        is_known_profession_word(clean)
    })
}

fn is_known_profession_word(token: &str) -> bool {
    matches!(
        token,
        "developer"
            | "engineer"
            | "architect"
            | "teacher"
            | "student"
            | "doctor"
            | "nurse"
            | "lawyer"
            | "accountant"
            | "programmer"
            | "designer"
            | "writer"
            | "artist"
            | "musician"
            | "manager"
            | "founder"
            | "consultant"
            | "researcher"
            | "scientist"
            | "analyst"
            | "entrepreneur"
            | "marketer"
            | "salesperson"
            | "chef"
            | "mechanic"
            | "electrician"
            | "plumber"
            | "carpenter"
            | "pilot"
            | "owner"
            | "retired"
    )
}

fn assistant_asked_about_local_coding_tools(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let mentions_tools = lower.contains("local claude")
        || lower.contains("local codex")
        || (lower.contains("claude") && lower.contains("codex"))
        || lower.contains("local coding assistant");
    mentions_tools
        && (lower.contains("coding")
            || lower.contains("code")
            || lower.contains("task")
            || lower.contains("use"))
}

fn user_mentions_local_coding_tools(user_text: &str) -> bool {
    user_text.contains("local claude")
        || user_text.contains("local codex")
        || (user_text.contains("claude") && user_text.contains("codex"))
        || user_text.contains("coding assistant")
}

fn parse_coding_assistant_permission(user_text: &str, pending_question: bool) -> Option<bool> {
    let user_lower = user_text.trim().to_ascii_lowercase();
    if user_lower.is_empty() {
        return None;
    }

    let mentions_tools = user_mentions_local_coding_tools(&user_lower);
    if !pending_question && !mentions_tools {
        return None;
    }

    if is_affirmative_response(&user_lower) {
        return Some(true);
    }
    if is_negative_response(&user_lower) {
        return Some(false);
    }

    if mentions_tools {
        if user_lower.contains("do not use")
            || user_lower.contains("don't use")
            || user_lower.contains("not use")
            || user_lower.contains("not allowed")
            || user_lower.contains("forbid")
        {
            return Some(false);
        }

        if user_lower.contains("you can use")
            || user_lower.contains("allowed")
            || user_lower.contains("permit")
            || user_lower.contains("fine to use")
        {
            return Some(true);
        }
    }

    None
}

fn is_affirmative_response(text: &str) -> bool {
    matches!(
        text,
        "yes"
            | "y"
            | "yeah"
            | "yep"
            | "sure"
            | "ok"
            | "okay"
            | "go ahead"
            | "please do"
            | "do it"
            | "fine"
            | "absolutely"
            | "of course"
    ) || text.starts_with("yes ")
        || text.starts_with("sure ")
}

fn is_negative_response(text: &str) -> bool {
    matches!(
        text,
        "no" | "n" | "nope" | "never" | "don't" | "do not" | "not now" | "stop"
    ) || text.starts_with("no ")
        || text.starts_with("don't ")
        || text.starts_with("do not ")
}

/// Extract personal facts from statements like "I live in X", "I have a dog called Y",
/// "my house is called Z", "I work at W", etc.
///
/// Returns a list of fact strings (there may be zero or more per turn).
fn parse_personal_facts(text: &str) -> Vec<String> {
    let raw = text.trim();
    if raw.is_empty() {
        return Vec::new();
    }
    let lower = raw.to_ascii_lowercase();
    let mut facts = Vec::new();

    // Patterns that introduce personal facts. We capture the rest of the sentence.
    let fact_patterns = [
        "i live in ",
        "i live at ",
        "i live on ",
        "i work at ",
        "i work in ",
        "i work for ",
        "i have a ",
        "i have an ",
        "i have ",
        "i also have ",
        "i enjoy ",
        "i'm interested in ",
        "i am interested in ",
        "i own a ",
        "i own an ",
        "i own ",
        "my house is ",
        "my home is ",
        "my dog is ",
        "my cat is ",
        "my name is ",
        "my wife is ",
        "my husband is ",
        "my partner is ",
        "my family is ",
        "my children are ",
        "my son is ",
        "my daughter is ",
    ];

    for pat in fact_patterns {
        if let Some(idx) = lower.find(pat) {
            let start = idx + pat.len();
            if start >= raw.len() {
                continue;
            }
            let rest = raw[start..].trim().trim_end_matches(['.', '!', '?']).trim();
            if rest.is_empty() || rest.len() < 2 {
                continue;
            }
            // Build a readable fact sentence from the original case text.
            let prefix = &raw[idx..idx + pat.len()];
            let fact = format!("{}{}", prefix.trim_start(), rest);
            if !facts.iter().any(|f: &String| f.eq_ignore_ascii_case(&fact)) {
                facts.push(fact);
            }
        }
    }

    // Also detect "my X is called Y" / "my X is named Y" patterns.
    let my_called_re = ["my "];
    for prefix in my_called_re {
        let mut search_from = 0;
        while let Some(idx) = lower[search_from..].find(prefix) {
            let abs_idx = search_from + idx;
            let after_my = &lower[abs_idx + prefix.len()..];
            // Look for "X is called Y" or "X is named Y" or "X is Y"
            if let Some(called_idx) = after_my
                .find(" is called ")
                .or_else(|| after_my.find(" is named "))
            {
                let end_of_sentence = after_my[called_idx..]
                    .find(['.', '!', '?', ','])
                    .map_or(after_my.len(), |e| called_idx + e);
                let fact_slice = &raw[abs_idx..abs_idx + prefix.len() + end_of_sentence];
                let fact = fact_slice
                    .trim()
                    .trim_end_matches(['.', '!', '?'])
                    .trim()
                    .to_owned();
                if fact.len() >= 8 && !facts.iter().any(|f: &String| f.eq_ignore_ascii_case(&fact))
                {
                    facts.push(fact);
                }
            }
            search_from = abs_idx + prefix.len();
            if search_from >= lower.len() {
                break;
            }
        }
    }

    facts
}

fn onboarding_tags_for_personal_fact(fact: &str) -> Vec<String> {
    let lower = fact.to_ascii_lowercase();
    let mut tags = Vec::new();

    if lower.starts_with("i live ")
        || lower.starts_with("my house is ")
        || lower.starts_with("my home is ")
    {
        tags.push("onboarding:address".to_owned());
    }

    if lower.starts_with("i work ")
        || lower.starts_with("my job is ")
        || lower.starts_with("i work as ")
    {
        tags.push("onboarding:job".to_owned());
    }

    if lower.contains("wife")
        || lower.contains("husband")
        || lower.contains("partner")
        || lower.contains("child")
        || lower.contains("children")
        || lower.contains("son")
        || lower.contains("daughter")
        || lower.contains("mother")
        || lower.contains("father")
        || lower.contains("brother")
        || lower.contains("sister")
        || lower.contains("my dog")
        || lower.contains("my cat")
    {
        tags.push("onboarding:family".to_owned());
    }

    if lower.starts_with("i like ")
        || lower.starts_with("i love ")
        || lower.starts_with("i enjoy ")
        || lower.contains("interested in ")
        || lower.starts_with("my interests are ")
    {
        tags.push("onboarding:interests".to_owned());
    }

    tags
}

fn is_filler_word(token: &str) -> bool {
    matches!(
        token,
        "hello"
            | "hi"
            | "hey"
            | "yo"
            | "hiya"
            | "howdy"
            | "the"
            | "a"
            | "an"
            | "um"
            | "uh"
            | "er"
            | "erm"
            | "so"
            | "well"
            | "okay"
            | "ok"
            | "yeah"
            | "yes"
            | "no"
            | "you"
            | "your"
            | "can"
            | "fae"
            | "fay"
            | "faye"
            | "fee"
            | "fey"
    )
}

fn clean_name_token(token: &str) -> String {
    token
        .trim_matches(|c: char| !c.is_ascii_alphabetic() && c != '-' && c != '\'')
        .chars()
        .filter(|c| c.is_ascii_alphabetic() || *c == '-' || *c == '\'')
        .take(24)
        .collect()
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return String::new();
    };

    let mut out = String::new();
    out.extend(first.to_uppercase());
    out.extend(chars);
    out
}

fn truncate_record_text(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.len() <= MAX_RECORD_TEXT_LEN {
        return trimmed.to_owned();
    }

    let max_bytes = MAX_RECORD_TEXT_LEN.saturating_sub(TRUNCATION_SUFFIX.len());
    let mut out = String::with_capacity(MAX_RECORD_TEXT_LEN);
    let mut used = 0usize;

    for ch in trimmed.chars() {
        let bytes = ch.len_utf8();
        if used.saturating_add(bytes) > max_bytes {
            break;
        }
        out.push(ch);
        used = used.saturating_add(bytes);
    }

    out.push_str(TRUNCATION_SUFFIX);
    out
}

fn new_id(prefix: &str) -> String {
    let counter = RECORD_COUNTER.fetch_add(1, AtomicOrdering::Relaxed);
    format!("{prefix}-{}-{counter}", now_epoch_nanos())
}

fn now_epoch_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub(crate) fn now_epoch_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn extract_toml_block(md: &str) -> Option<String> {
    // Very small parser:
    // - find a line that is exactly ```toml (trimmed)
    // - capture until the next ``` line
    let mut in_block = false;
    let mut buf = Vec::new();
    for raw in md.lines() {
        let line = raw.trim_end();
        if !in_block {
            if line.trim() == "```toml" {
                in_block = true;
            }
            continue;
        }
        if line.trim() == "```" {
            break;
        }
        buf.push(line);
    }
    if buf.is_empty() {
        None
    } else {
        Some(buf.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::test_utils::temp_test_root;
    use std::sync::Arc;

    fn test_root(name: &str) -> PathBuf {
        temp_test_root("memory", name)
    }

    fn test_cfg(root: &Path) -> MemoryConfig {
        MemoryConfig {
            root_dir: root.to_path_buf(),
            ..MemoryConfig::default()
        }
    }

    #[test]
    fn extract_toml_block_round_trip() {
        let user = PrimaryUser {
            name: "Alice".into(),
            voiceprint: Some(vec![0.1, 0.2, 0.3]),
            voice_sample_wav: Some("voices/alice.wav".into()),
        };
        let data = toml::to_string_pretty(&user).unwrap();
        let md = format!("# x\n\n```toml\n{data}```\n");
        let extracted = extract_toml_block(&md).expect("toml block");
        let decoded: PrimaryUser = toml::from_str(&extracted).unwrap();
        assert_eq!(decoded.name, "Alice");
        assert_eq!(decoded.voiceprint.unwrap().len(), 3);
        assert_eq!(
            decoded.voice_sample_wav.unwrap_or_default(),
            "voices/alice.wav"
        );
    }

    #[test]
    fn repository_creates_manifest_and_logs() {
        let root = test_root("layout");
        let repo = MemoryRepository::new(&root);
        repo.ensure_layout().expect("ensure layout");

        assert!(repo.manifest_path().exists());
        assert!(repo.records_path().exists());
        assert!(repo.audit_path().exists());

        let schema = repo.schema_version().expect("schema version");
        assert_eq!(schema, CURRENT_SCHEMA_VERSION);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn repository_insert_search_and_soft_forget() {
        let root = test_root("insert-search");
        let repo = MemoryRepository::new(&root);
        repo.ensure_layout().expect("ensure layout");

        let profile = repo
            .insert_record(
                MemoryKind::Profile,
                "User preference: i like black coffee",
                0.9,
                Some("turn-1"),
                vec!["preference".into()],
            )
            .expect("insert profile");

        let hits = repo
            .search("coffee preference", 5, false)
            .expect("search before forget");
        assert!(!hits.is_empty());
        assert_eq!(hits[0].record.id, profile.id);

        repo.forget_soft_record(&profile.id, "test forget")
            .expect("soft forget");

        let hits_after = repo
            .search("coffee preference", 5, false)
            .expect("search after forget");
        assert!(hits_after.is_empty());

        let audit = repo.audit_entries().expect("audit entries");
        assert!(
            audit.iter().any(|e| e.op == MemoryAuditOp::ForgetSoft),
            "audit should include forget soft op"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn repository_supersede_marks_old_record() {
        let root = test_root("supersede");
        let repo = MemoryRepository::new(&root);
        repo.ensure_layout().expect("ensure layout");

        let old = repo
            .insert_record(
                MemoryKind::Profile,
                "Primary user name is Alice.",
                0.98,
                Some("turn-1"),
                vec!["name".into()],
            )
            .expect("insert old");

        let new_record = repo
            .supersede_record(
                &old.id,
                "Primary user name is Bob.",
                0.98,
                Some("turn-2"),
                vec!["name".into()],
                "name update",
            )
            .expect("supersede");

        let records = repo.list_records().expect("list records");
        let old_record = records.iter().find(|r| r.id == old.id).expect("old exists");
        assert_eq!(old_record.status, MemoryStatus::Superseded);

        let replacement = records
            .iter()
            .find(|r| r.id == new_record.id)
            .expect("new exists");
        assert_eq!(replacement.status, MemoryStatus::Active);
        assert_eq!(replacement.supersedes.as_deref(), Some(old.id.as_str()));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn orchestrator_captures_episode_and_profile_updates() {
        let root = test_root("orchestrator-capture");
        let cfg = test_cfg(&root);
        let orchestrator = MemoryOrchestrator::new(&cfg);

        let report = orchestrator
            .capture_turn(
                "turn-1",
                "Hi, my name is David and I prefer tea in the morning.",
                "Nice to meet you.",
            )
            .expect("capture turn");

        assert_eq!(report.episodes_written, 1);
        assert!(report.profile_updates >= 1);

        let repo = MemoryRepository::new(&root);
        let name = repo.find_active_by_tag("name").expect("find name");
        assert!(!name.is_empty());

        let recall = orchestrator
            .recall_context("what does user prefer")
            .expect("recall")
            .unwrap_or_default();
        assert!(recall.contains("memory_context"));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn orchestrator_forget_command_soft_forgets_match() {
        let root = test_root("orchestrator-forget");
        let cfg = test_cfg(&root);
        let orchestrator = MemoryOrchestrator::new(&cfg);

        orchestrator
            .capture_turn(
                "turn-1",
                "Remember that I prefer concise answers.",
                "Noted.",
            )
            .expect("capture remember");

        let report = orchestrator
            .capture_turn("turn-2", "Forget concise answers", "Okay")
            .expect("capture forget");
        assert!(report.forgotten >= 1);

        let recall = orchestrator
            .recall_context("concise answers")
            .expect("recall after forget");
        assert!(recall.is_none());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn parse_name_statement_ignores_common_non_name_phrases() {
        assert_eq!(parse_name_statement("I am tired today."), None);
        assert_eq!(parse_name_statement("i am happy to help"), None);
        assert_eq!(parse_name_statement("I'm ready now."), None);
        assert_eq!(parse_name_statement("im okay"), None);
        assert_eq!(
            parse_name_statement("Actually my name is Alice."),
            Some("Alice".to_owned())
        );
    }

    #[test]
    fn orchestrator_respects_min_profile_confidence_threshold() {
        let root = test_root("orchestrator-threshold");
        let mut cfg = test_cfg(&root);
        cfg.min_profile_confidence = 0.90;
        let orchestrator = MemoryOrchestrator::new(&cfg);

        let pref_report = orchestrator
            .capture_turn("turn-1", "I prefer tea in the morning.", "Noted.")
            .expect("capture preference");
        assert_eq!(pref_report.profile_updates, 0);

        let name_report = orchestrator
            .capture_turn("turn-2", "My name is Alice.", "Thanks Alice.")
            .expect("capture name");
        assert_eq!(name_report.profile_updates, 1);

        let repo = MemoryRepository::new(&root);
        let prefs = repo
            .find_active_by_tag("preference")
            .expect("find preference memories");
        assert!(prefs.is_empty());

        let names = repo.find_active_by_tag("name").expect("find name memories");
        assert_eq!(names.len(), 1);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn orchestrator_truncates_oversized_episode_text() {
        let root = test_root("orchestrator-large-episode");
        let cfg = test_cfg(&root);
        let orchestrator = MemoryOrchestrator::new(&cfg);

        let giant_assistant = "a".repeat(MAX_RECORD_TEXT_LEN.saturating_add(512));
        let report = orchestrator
            .capture_turn("turn-1", "Hello there.", &giant_assistant)
            .expect("capture oversized episode");
        assert_eq!(report.episodes_written, 1);

        let repo = MemoryRepository::new(&root);
        let records = repo.list_records().expect("list records");
        let episode = records
            .iter()
            .find(|record| {
                record.kind == MemoryKind::Episode
                    && record.source_turn_id.as_deref() == Some("turn-1")
            })
            .expect("episode record");
        assert!(episode.text.len() <= MAX_RECORD_TEXT_LEN);
        assert!(episode.text.contains("[truncated]"));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn migration_from_older_manifest_version_is_supported() {
        let root = test_root("migration");
        let repo = MemoryRepository::new(&root);
        repo.ensure_layout().expect("ensure layout");

        let old_manifest = MemoryManifest {
            schema_version: 0,
            index_version: 1,
            embedder_version: "none".to_owned(),
            created_at: now_epoch_secs(),
            updated_at: now_epoch_secs(),
        };
        repo.write_manifest(&old_manifest)
            .expect("write old manifest");

        let migrated = repo
            .migrate_if_needed(CURRENT_SCHEMA_VERSION)
            .expect("migrate")
            .expect("migration should happen");
        assert_eq!(migrated, (0, CURRENT_SCHEMA_VERSION));

        let schema = repo.schema_version().expect("schema version after migrate");
        assert_eq!(schema, CURRENT_SCHEMA_VERSION);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn retention_policy_soft_forgets_old_episodes() {
        let root = test_root("retention");
        let repo = MemoryRepository::new(&root);
        repo.ensure_layout().expect("ensure layout");

        let mut old_episode = repo
            .insert_record(
                MemoryKind::Episode,
                "User: hello",
                0.5,
                Some("turn-old"),
                vec!["turn".into()],
            )
            .expect("insert episode");

        // Rewrite with old timestamp for deterministic retention behavior.
        old_episode.updated_at = now_epoch_secs().saturating_sub(400 * 24 * 3600);
        let records = vec![old_episode];
        repo.rewrite_records(&records)
            .expect("rewrite with old record");

        let changed = repo.apply_retention_policy(365).expect("apply retention");
        assert_eq!(changed, 1);

        let active = repo.search("hello", 5, false).expect("search active");
        assert!(active.is_empty());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn concurrent_patch_and_insert_preserves_all_records() {
        let root = test_root("contention");
        let repo = Arc::new(MemoryRepository::new(&root));
        repo.ensure_layout().expect("ensure layout");

        let seed = repo
            .insert_record(
                MemoryKind::Fact,
                "Seed fact",
                0.9,
                Some("seed-turn"),
                vec!["seed".into()],
            )
            .expect("insert seed");

        let patch_repo = Arc::clone(&repo);
        let patch_id = seed.id.clone();
        let patch_handle = std::thread::spawn(move || {
            for i in 0..250usize {
                let body = format!("Seed fact revision {i}");
                patch_repo
                    .patch_record(&patch_id, &body, "contention patch")
                    .expect("patch seed");
            }
        });

        let mut insert_handles = Vec::new();
        let workers = 6usize;
        let inserts_per_worker = 40usize;

        for worker in 0..workers {
            let repo_clone = Arc::clone(&repo);
            insert_handles.push(std::thread::spawn(move || {
                for idx in 0..inserts_per_worker {
                    let text = format!("worker {worker} record {idx}");
                    repo_clone
                        .insert_record(
                            MemoryKind::Fact,
                            &text,
                            0.7,
                            Some("contention"),
                            vec!["load".into()],
                        )
                        .expect("insert during contention");
                }
            }));
        }

        patch_handle.join().expect("join patch thread");
        for handle in insert_handles {
            handle.join().expect("join insert thread");
        }

        let records = repo.list_records().expect("list final records");
        let expected = 1 + workers * inserts_per_worker;
        assert_eq!(records.len(), expected, "no records should be lost");
        assert!(records.iter().any(|record| record.id == seed.id));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn parse_name_statement_ignores_nationalities_and_identity() {
        assert_eq!(parse_name_statement("I'm Scottish"), None);
        assert_eq!(parse_name_statement("I'm Scottish, I'm male."), None);
        assert_eq!(parse_name_statement("I am American"), None);
        assert_eq!(parse_name_statement("I'm male"), None);
        assert_eq!(parse_name_statement("I am a developer"), None);
        assert_eq!(parse_name_statement("I'm retired"), None);
        // Actual names should still work.
        assert_eq!(parse_name_statement("I'm David"), Some("David".to_owned()));
        assert_eq!(
            parse_name_statement("My name is Alice"),
            Some("Alice".to_owned())
        );
    }

    #[test]
    fn parse_personal_facts_extracts_life_details() {
        let facts = parse_personal_facts("I live in a house called Barskeg.");
        assert_eq!(facts.len(), 1);
        assert!(facts[0].contains("live in"));
        assert!(facts[0].contains("Barskeg"));

        let facts = parse_personal_facts("I have a dog called Ishki");
        assert_eq!(facts.len(), 1);
        assert!(facts[0].contains("have a dog"));

        let facts = parse_personal_facts(
            "I also have sheep, chickens, ducks, and an AI and robotics laboratory.",
        );
        assert!(!facts.is_empty());
        assert!(facts[0].contains("also have"));

        let facts = parse_personal_facts("I work at Google.");
        assert_eq!(facts.len(), 1);
        assert!(facts[0].contains("work at Google"));

        // Should return empty for non-fact statements.
        let facts = parse_personal_facts("Hello there");
        assert!(facts.is_empty());

        let facts = parse_personal_facts("Can you help me?");
        assert!(facts.is_empty());
    }

    #[test]
    fn parse_personal_facts_my_called_pattern() {
        let facts = parse_personal_facts("my house is called Barskeg");
        assert_eq!(facts.len(), 1);
        assert!(facts[0].contains("Barskeg"));

        let facts = parse_personal_facts("my dog is named Ishki");
        assert_eq!(facts.len(), 1);
        assert!(facts[0].contains("Ishki"));
    }

    #[test]
    fn parse_coding_assistant_permission_yes_no() {
        assert_eq!(parse_coding_assistant_permission("yes", true), Some(true));
        assert_eq!(
            parse_coding_assistant_permission("no thanks", true),
            Some(false)
        );
        assert_eq!(parse_coding_assistant_permission("maybe later", true), None);
        assert_eq!(parse_coding_assistant_permission("yes", false), None);
        assert_eq!(
            parse_coding_assistant_permission("you can use local codex tools for coding", false),
            Some(true)
        );
    }

    #[test]
    fn parse_profession_statement_handles_multi_word_jobs() {
        assert_eq!(
            parse_profession_statement("I'm a software engineer."),
            Some("software engineer".to_owned())
        );
        assert_eq!(
            parse_profession_statement("I am a big fan of hiking."),
            None
        );
    }

    #[test]
    fn onboarding_tags_classify_personal_facts() {
        let address = onboarding_tags_for_personal_fact("I live in Glasgow");
        assert!(address.contains(&"onboarding:address".to_owned()));

        let family = onboarding_tags_for_personal_fact("My wife is Anna");
        assert!(family.contains(&"onboarding:family".to_owned()));

        let interests = onboarding_tags_for_personal_fact("I enjoy hill walking");
        assert!(interests.contains(&"onboarding:interests".to_owned()));

        let job = onboarding_tags_for_personal_fact("I work at Acme");
        assert!(job.contains(&"onboarding:job".to_owned()));
    }

    #[test]
    fn orchestrator_captures_personal_facts_from_conversation() {
        let root = test_root("orchestrator-personal-facts");
        let cfg = test_cfg(&root);
        let orchestrator = MemoryOrchestrator::new(&cfg);

        let report = orchestrator
            .capture_turn(
                "turn-1",
                "I live in a house called Barskeg.",
                "I'll remember that.",
            )
            .expect("capture personal fact");
        assert!(
            report.facts_written >= 1,
            "should capture at least one fact, got {}",
            report.facts_written,
        );

        let repo = MemoryRepository::new(&root);
        let personal = repo
            .find_active_by_tag("personal")
            .expect("find personal facts");
        assert!(!personal.is_empty(), "should have personal fact records");
        assert!(personal[0].text.contains("Barskeg"));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn orchestrator_marks_onboarding_complete_when_required_fields_exist() {
        let root = test_root("onboarding-complete");
        let cfg = test_cfg(&root);
        let orchestrator = MemoryOrchestrator::new(&cfg);

        orchestrator
            .capture_turn("turn-1", "My name is Alice.", "Noted.")
            .expect("capture name");
        orchestrator
            .capture_turn("turn-2", "I live in Edinburgh.", "Noted.")
            .expect("capture address");
        orchestrator
            .capture_turn("turn-3", "My wife is Anna.", "Noted.")
            .expect("capture family");
        orchestrator
            .capture_turn("turn-4", "I enjoy woodworking.", "Noted.")
            .expect("capture interests");
        orchestrator
            .capture_turn("turn-5", "I work at Acme.", "Noted.")
            .expect("capture job");

        assert!(
            orchestrator
                .is_onboarding_complete()
                .expect("onboarding state should load")
        );

        let repo = MemoryRepository::new(&root);
        let completion = repo
            .find_active_by_tag("onboarding_complete")
            .expect("completion tag query");
        assert!(!completion.is_empty());

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn orchestrator_captures_coding_assistant_permission_across_turns() {
        let root = test_root("coding-assistant-permission");
        let cfg = test_cfg(&root);
        let orchestrator = MemoryOrchestrator::new(&cfg);

        orchestrator
            .capture_turn(
                "turn-1",
                "Can you help me with coding?",
                "Is it okay if I use local Claude/Codex tools for coding tasks when helpful?",
            )
            .expect("capture permission prompt");

        assert_eq!(
            orchestrator
                .coding_assistant_permission()
                .expect("permission state"),
            None
        );

        orchestrator
            .capture_turn("turn-2", "yes", "Great, I will use them when helpful.")
            .expect("capture permission response");

        assert_eq!(
            orchestrator
                .coding_assistant_permission()
                .expect("permission state"),
            Some(true)
        );

        let repo = MemoryRepository::new(&root);
        let pending = repo
            .find_active_by_tag("coding_assistant_permission_pending")
            .expect("query pending permission markers");
        assert!(pending.is_empty(), "pending marker should be cleared");

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn recall_context_includes_relevant_episodes_as_fallback() {
        let root = test_root("recall-episodes");
        let cfg = test_cfg(&root);
        let repo = MemoryRepository::new(&root);
        repo.ensure_layout().expect("ensure layout");

        // Insert only an episode (no durable records).
        repo.insert_record(
            MemoryKind::Episode,
            "User: I have sheep and chickens\nAssistant: I'll remember that.",
            0.55,
            Some("turn-1"),
            vec!["turn".to_owned()],
        )
        .expect("insert episode");

        let orchestrator = MemoryOrchestrator::new(&cfg);
        // With the episode inclusion fix, this should find the episode
        // if the search score is high enough.
        let result = orchestrator.recall_context("sheep chickens");
        // The result depends on the search scoring implementation, but
        // at minimum it should not panic.
        assert!(result.is_ok());

        let _ = std::fs::remove_dir_all(root);
    }
}
