//! Shared types, constants, and helpers for the memory subsystem.
//!
//! Everything in this module is backend-agnostic — used by both the JSONL and
//! (future) SQLite backends.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};

// ---------------------------------------------------------------------------
// Global ID counter (shared across all backends)
// ---------------------------------------------------------------------------

pub(crate) static RECORD_COUNTER: AtomicU64 = AtomicU64::new(1);

// ---------------------------------------------------------------------------
// Schema / limits
// ---------------------------------------------------------------------------

pub(crate) const CURRENT_SCHEMA_VERSION: u32 = 3;

/// Maximum length (in bytes) of record text. Prevents unbounded growth from
/// excessively long LLM outputs or user input.
pub(crate) const MAX_RECORD_TEXT_LEN: usize = 32_768;
pub(crate) const TRUNCATION_SUFFIX: &str = " [truncated]";

// ---------------------------------------------------------------------------
// Confidence thresholds
// ---------------------------------------------------------------------------

pub(crate) const PROFILE_NAME_CONFIDENCE: f32 = 0.98;
pub(crate) const PROFILE_PREFERENCE_CONFIDENCE: f32 = 0.86;
pub(crate) const FACT_REMEMBER_CONFIDENCE: f32 = 0.80;
pub(crate) const FACT_CONVERSATIONAL_CONFIDENCE: f32 = 0.75;
pub(crate) const CODING_ASSISTANT_PERMISSION_CONFIDENCE: f32 = 0.92;
pub(crate) const CODING_ASSISTANT_PERMISSION_PENDING_CONFIDENCE: f32 = 0.55;
pub(crate) const ONBOARDING_COMPLETION_CONFIDENCE: f32 = 0.95;

pub(crate) const ONBOARDING_REQUIRED_FIELDS: &[(&str, &str)] = &[
    ("onboarding:name", "name / preferred form of address"),
    ("onboarding:address", "location or home context"),
    ("onboarding:family", "family or household context"),
    ("onboarding:interests", "interests or hobbies"),
    ("onboarding:job", "job or work context"),
];

// ---------------------------------------------------------------------------
// Scoring weights for `score_record()`
// ---------------------------------------------------------------------------

pub(crate) const SCORE_EMPTY_QUERY_BASELINE: f32 = 0.2;
pub(crate) const SCORE_CONFIDENCE_WEIGHT: f32 = 0.20;
pub(crate) const SCORE_FRESHNESS_WEIGHT: f32 = 0.10;
pub(crate) const SCORE_KIND_BONUS_PROFILE: f32 = 0.05;
pub(crate) const SCORE_KIND_BONUS_FACT: f32 = 0.03;
pub(crate) const SECS_PER_DAY: f32 = 86_400.0;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Serde defaults (referenced by MemoryRecord field attributes)
// ---------------------------------------------------------------------------

fn default_memory_status() -> MemoryStatus {
    MemoryStatus::Active
}

fn default_confidence() -> f32 {
    0.5
}

// ---------------------------------------------------------------------------
// Core structs
// ---------------------------------------------------------------------------

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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryAuditEntry {
    pub id: String,
    pub op: MemoryAuditOp,
    pub target_id: Option<String>,
    pub note: String,
    pub at: u64,
}

#[derive(Debug, Clone)]
pub struct MemorySearchHit {
    pub record: MemoryRecord,
    pub score: f32,
}

// ---------------------------------------------------------------------------
// Capture / write report structs
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Public API functions
// ---------------------------------------------------------------------------

#[must_use]
pub fn current_memory_schema_version() -> u32 {
    CURRENT_SCHEMA_VERSION
}

pub fn default_memory_root_dir() -> std::path::PathBuf {
    crate::fae_dirs::memory_dir()
}

// ---------------------------------------------------------------------------
// Helper functions (shared across backends)
// ---------------------------------------------------------------------------

pub(crate) fn display_kind(kind: MemoryKind) -> &'static str {
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

pub(crate) fn tokenize(text: &str) -> Vec<String> {
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

pub(crate) fn score_record(record: &MemoryRecord, query_tokens: &[String]) -> f32 {
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

pub(crate) fn truncate_record_text(text: &str) -> String {
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

pub(crate) fn new_id(prefix: &str) -> String {
    let counter = RECORD_COUNTER.fetch_add(1, AtomicOrdering::Relaxed);
    format!("{prefix}-{}-{counter}", now_epoch_nanos())
}

pub(crate) fn now_epoch_secs() -> u64 {
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
