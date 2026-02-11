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

static RECORD_COUNTER: AtomicU64 = AtomicU64::new(1);
const CURRENT_SCHEMA_VERSION: u32 = 1;
const MANIFEST_FILE: &str = "manifest.toml";
const RECORDS_FILE: &str = "records.jsonl";
const AUDIT_FILE: &str = "audit.jsonl";

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
    }

    pub fn patch_record(&self, id: &str, new_text: &str, note: &str) -> Result<()> {
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
    }

    fn set_status(
        &self,
        id: &str,
        status: MemoryStatus,
        op: MemoryAuditOp,
        note: &str,
    ) -> Result<()> {
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

    pub fn recall_context(&self, query: &str) -> Result<Option<String>> {
        if !self.config.enabled || !self.config.auto_recall {
            return Ok(None);
        }

        self.ensure_ready()?;
        let hits = self
            .repo
            .search(query, self.config.recall_max_items.max(1), false)?;
        let durable_hits: Vec<MemorySearchHit> = hits
            .into_iter()
            .filter(|h| h.record.kind != MemoryKind::Episode)
            .collect();

        if durable_hits.is_empty() {
            return Ok(None);
        }

        let max_chars = self.config.recall_max_chars.max(200);
        let mut body = String::from("<memory_context>\n");
        let mut injected = 0usize;

        for hit in durable_hits {
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

        if let Some(remember) = parse_remember_command(user_trimmed)
            && !remember.is_empty()
            && !self.is_duplicate_memory(&remember)?
        {
            let record = self.repo.insert_record(
                MemoryKind::Fact,
                &remember,
                0.80,
                Some(turn_id),
                vec!["remembered".to_owned()],
            )?;
            report.facts_written = report.facts_written.saturating_add(1);
            report.writes.push(MemoryWriteSummary {
                op: "insert_fact".to_owned(),
                target_id: Some(record.id.clone()),
            });
        }

        if let Some(name) = parse_name_statement(user_trimmed) {
            let profile = format!("Primary user name is {name}.");
            let existing = self.repo.find_active_by_tag("name")?;
            if let Some(previous) = existing.first() {
                if !previous.text.eq_ignore_ascii_case(&profile) {
                    let new_record = self.repo.supersede_record(
                        &previous.id,
                        &profile,
                        0.98,
                        Some(turn_id),
                        vec!["name".to_owned(), "identity".to_owned()],
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
                    0.98,
                    Some(turn_id),
                    vec!["name".to_owned(), "identity".to_owned()],
                )?;
                report.profile_updates = report.profile_updates.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "update_profile".to_owned(),
                    target_id: Some(new_record.id.clone()),
                });
            }
        }

        if let Some(pref) = parse_preference_statement(user_trimmed) {
            let profile = format!("User preference: {pref}");
            let existing = self.repo.find_active_by_tag("preference")?;
            if let Some(previous) = existing.first() {
                if !previous.text.eq_ignore_ascii_case(&profile) {
                    let new_record = self.repo.supersede_record(
                        &previous.id,
                        &profile,
                        0.86,
                        Some(turn_id),
                        vec!["preference".to_owned()],
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
                    0.86,
                    Some(turn_id),
                    vec!["preference".to_owned()],
                )?;
                report.profile_updates = report.profile_updates.saturating_add(1);
                report.writes.push(MemoryWriteSummary {
                    op: "update_profile".to_owned(),
                    target_id: Some(new_record.id.clone()),
                });
            }
        }

        if self.config.retention_days > 0 {
            let _changed = self
                .repo
                .apply_retention_policy(self.config.retention_days)?;
        }

        Ok(report)
    }

    fn is_duplicate_memory(&self, text: &str) -> Result<bool> {
        let hits = self.repo.search(text, 1, false)?;
        if let Some(top) = hits.first() {
            return Ok(top.score >= 0.95);
        }
        Ok(false)
    }
}

pub fn run_memory_reflection(root_dir: &Path) -> Result<String> {
    let repo = MemoryRepository::new(root_dir);
    repo.ensure_layout()?;

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
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae")
    } else {
        PathBuf::from("/tmp").join(".fae")
    }
}

fn display_kind(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::Profile => "profile",
        MemoryKind::Episode => "episode",
        MemoryKind::Fact => "fact",
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
            if !cleaned.is_empty() && !is_filler_word(&cleaned) {
                return Some(capitalize_first(&cleaned));
            }
        }
    }

    None
}

fn parse_preference_statement(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    let patterns = [
        "i prefer ",
        "i like ",
        "i love ",
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
            return Some(format!("{}{}", pat.trim(), rest));
        }
    }

    None
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
}
