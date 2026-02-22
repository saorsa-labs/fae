//! Adaptive skill proposal detection and lifecycle.
//!
//! When Fae detects repeated patterns in intelligence items (frequent
//! calendar mentions, recurring topics, similar requests), she proposes
//! new skills that could help the user. Proposals go through a lifecycle:
//! Proposed → Accepted/Rejected → Installed.

use serde::{Deserialize, Serialize};
use std::path::Path;
use tracing::warn;

/// Proposal lifecycle status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProposalStatus {
    /// Proposed but not yet reviewed by user.
    Proposed,
    /// User accepted the proposal.
    Accepted,
    /// User rejected the proposal.
    Rejected,
    /// Skill has been installed.
    Installed,
}

/// A skill proposal generated from intelligence patterns.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillProposal {
    /// Unique identifier.
    pub id: String,
    /// Skill name (e.g. "Calendar Integration").
    pub name: String,
    /// Description of what the skill would do.
    pub description: String,
    /// Pattern that triggered this proposal.
    pub trigger_pattern: String,
    /// Current lifecycle status.
    pub status: ProposalStatus,
    /// Epoch seconds when proposed.
    pub proposed_at: u64,
    /// Epoch seconds of last status change.
    pub updated_at: u64,
}

/// Persistent store for skill proposals.
///
/// Proposals are saved to `~/.fae/skill_proposals.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SkillProposalStore {
    /// All proposals (active and historical).
    pub proposals: Vec<SkillProposal>,
}

/// Rejection cooldown in seconds (30 days).
const REJECTION_COOLDOWN_SECS: u64 = 30 * 86_400;
/// Relative location for the mutable skill-opportunity policy pack.
const SKILL_OPPORTUNITY_POLICY_RELATIVE_PATH: &str =
    "skills/intelligence/skill-opportunity-policy.toml";

/// Policy thresholds for adaptive skill opportunity detection.
///
/// This policy is designed to live in the mutable self-authored layer so users
/// or skills can tune proposal sensitivity and match patterns without changing
/// Rust code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct SkillOpportunityPolicy {
    /// Minimum active event records before proposing calendar integration.
    pub calendar_min_event_mentions: usize,
    /// Record kinds that count as calendar-related signals.
    pub calendar_kinds: Vec<crate::memory::MemoryKind>,
    /// Case-insensitive substrings matched against record text.
    pub calendar_text_keywords: Vec<String>,
    /// Case-insensitive substrings matched against record tags.
    pub calendar_tag_keywords: Vec<String>,
    /// Minimum active email mentions before proposing email integration.
    pub email_min_mentions: usize,
    /// Case-insensitive substrings matched against record text.
    pub email_text_keywords: Vec<String>,
    /// Case-insensitive substrings matched against record tags.
    pub email_tag_keywords: Vec<String>,
    /// Minimum research-topic repeats before proposing a topic expert skill.
    pub topic_min_research_mentions: usize,
    /// Record kinds considered for topic opportunity detection.
    pub topic_kinds: Vec<crate::memory::MemoryKind>,
    /// Case-insensitive tag terms; at least one must match when non-empty.
    pub topic_required_tags_any: Vec<String>,
    /// Prefixes used to extract topic identifiers from tags.
    pub topic_tag_prefixes: Vec<String>,
}

impl Default for SkillOpportunityPolicy {
    fn default() -> Self {
        Self {
            calendar_min_event_mentions: 3,
            calendar_kinds: vec![crate::memory::MemoryKind::Event],
            calendar_text_keywords: vec![
                "calendar".to_owned(),
                "meeting".to_owned(),
                "appointment".to_owned(),
                "deadline".to_owned(),
            ],
            calendar_tag_keywords: vec![
                "calendar".to_owned(),
                "event".to_owned(),
                "date".to_owned(),
            ],
            email_min_mentions: 3,
            email_text_keywords: vec![
                "email".to_owned(),
                "e-mail".to_owned(),
                "inbox".to_owned(),
                "mail".to_owned(),
            ],
            email_tag_keywords: vec!["email".to_owned(), "inbox".to_owned(), "mail".to_owned()],
            topic_min_research_mentions: 3,
            topic_kinds: vec![crate::memory::MemoryKind::Fact],
            topic_required_tags_any: vec!["research".to_owned()],
            topic_tag_prefixes: vec!["topic:".to_owned()],
        }
    }
}

impl SkillProposalStore {
    /// Load proposals from disk, returning an empty store on error.
    pub fn load(path: &Path) -> Self {
        let file = path.join("skill_proposals.json");
        if !file.exists() {
            return Self::default();
        }
        match std::fs::read_to_string(&file) {
            Ok(contents) => serde_json::from_str(&contents).unwrap_or_default(),
            Err(e) => {
                warn!("failed to load skill proposals: {e}");
                Self::default()
            }
        }
    }

    /// Save proposals to disk.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        let file = path.join("skill_proposals.json");
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create proposals dir: {e}"))?;
        }
        let json =
            serde_json::to_string_pretty(self).map_err(|e| format!("serialize error: {e}"))?;
        std::fs::write(&file, json).map_err(|e| format!("write error: {e}"))
    }

    /// Propose a new skill, respecting dedup and rejection cooldown.
    ///
    /// Returns `Some(id)` if the proposal was created, `None` if suppressed.
    pub fn propose(
        &mut self,
        name: &str,
        description: &str,
        trigger_pattern: &str,
    ) -> Option<String> {
        let now = now_epoch_secs();
        let normalized_name = name.trim().to_lowercase();

        // Check for existing proposal with same name.
        let existing = self
            .proposals
            .iter()
            .find(|p| p.name.trim().to_lowercase() == normalized_name);

        if let Some(existing) = existing {
            match existing.status {
                // Already proposed, accepted, or installed — don't re-propose.
                ProposalStatus::Proposed | ProposalStatus::Accepted | ProposalStatus::Installed => {
                    return None;
                }
                // Rejected — check cooldown.
                ProposalStatus::Rejected => {
                    if now.saturating_sub(existing.updated_at) < REJECTION_COOLDOWN_SECS {
                        return None;
                    }
                }
            }
        }

        let id = format!("proposal-{}", now);
        let proposal = SkillProposal {
            id: id.clone(),
            name: name.to_owned(),
            description: description.to_owned(),
            trigger_pattern: trigger_pattern.to_owned(),
            status: ProposalStatus::Proposed,
            proposed_at: now,
            updated_at: now,
        };
        self.proposals.push(proposal);
        Some(id)
    }

    /// Accept a proposal by ID.
    pub fn accept(&mut self, id: &str) -> bool {
        if let Some(p) = self.proposals.iter_mut().find(|p| p.id == id) {
            p.status = ProposalStatus::Accepted;
            p.updated_at = now_epoch_secs();
            true
        } else {
            false
        }
    }

    /// Reject a proposal by ID.
    pub fn reject(&mut self, id: &str) -> bool {
        if let Some(p) = self.proposals.iter_mut().find(|p| p.id == id) {
            p.status = ProposalStatus::Rejected;
            p.updated_at = now_epoch_secs();
            true
        } else {
            false
        }
    }

    /// Mark a proposal as installed.
    pub fn mark_installed(&mut self, id: &str) -> bool {
        if let Some(p) = self.proposals.iter_mut().find(|p| p.id == id) {
            p.status = ProposalStatus::Installed;
            p.updated_at = now_epoch_secs();
            true
        } else {
            false
        }
    }

    /// Get all pending (proposed) proposals.
    #[must_use]
    pub fn pending(&self) -> Vec<&SkillProposal> {
        self.proposals
            .iter()
            .filter(|p| p.status == ProposalStatus::Proposed)
            .collect()
    }
}

/// Detect skill opportunities from memory patterns.
///
/// Scans for repeated patterns and returns `(name, description, trigger_pattern)` tuples
/// for skills that could be proposed.
///
/// Current detection patterns:
/// - Repeated calendar/date mentions → "Calendar Integration"
/// - Repeated email mentions → "Email Integration"
/// - Frequent same-topic research → topic-specific skill
#[must_use]
pub fn detect_skill_opportunities(memory_path: &Path) -> Vec<(String, String, String)> {
    detect_skill_opportunities_with_policy(memory_path, SkillOpportunityPolicy::default())
}

/// Detect skill opportunities using a provided policy pack.
///
/// Policy controls both thresholds and pattern matching signals in mutable
/// data that can be tuned in the self-authored layer.
#[must_use]
pub fn detect_skill_opportunities_with_policy(
    memory_path: &Path,
    policy: SkillOpportunityPolicy,
) -> Vec<(String, String, String)> {
    let repo = match crate::memory::SqliteMemoryRepository::new(memory_path) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let records = match repo.list_records() {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };

    let mut opportunities = Vec::new();

    let calendar_text_keywords = normalized_terms(&policy.calendar_text_keywords);
    let calendar_tag_keywords = normalized_terms(&policy.calendar_tag_keywords);
    let email_text_keywords = normalized_terms(&policy.email_text_keywords);
    let email_tag_keywords = normalized_terms(&policy.email_tag_keywords);
    let topic_required_tags_any = normalized_terms(&policy.topic_required_tags_any);
    let topic_tag_prefixes = normalized_terms(&policy.topic_tag_prefixes);

    let mut calendar_mentions = 0usize;
    let mut email_mentions = 0usize;
    let mut topic_counts: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();

    for record in &records {
        if record.status != crate::memory::MemoryStatus::Active {
            continue;
        }

        let lower_text = record.text.to_lowercase();
        let lower_tags: Vec<String> = record.tags.iter().map(|tag| tag.to_lowercase()).collect();

        let calendar_kind_match = policy.calendar_kinds.contains(&record.kind);
        let calendar_text_match = contains_any_keyword(&lower_text, &calendar_text_keywords);
        let calendar_tag_match = tags_match_keywords(&lower_tags, &calendar_tag_keywords);
        if calendar_kind_match || calendar_text_match || calendar_tag_match {
            calendar_mentions = calendar_mentions.saturating_add(1);
        }

        let email_text_match = contains_any_keyword(&lower_text, &email_text_keywords);
        let email_tag_match = tags_match_keywords(&lower_tags, &email_tag_keywords);
        if email_text_match || email_tag_match {
            email_mentions = email_mentions.saturating_add(1);
        }

        let topic_kind_match = policy.topic_kinds.contains(&record.kind);
        let topic_required_match = topic_required_tags_any.is_empty()
            || tags_match_keywords(&lower_tags, &topic_required_tags_any);
        if topic_kind_match && topic_required_match {
            for tag in &lower_tags {
                if let Some(topic) = extract_topic_from_tag(tag, &topic_tag_prefixes) {
                    *topic_counts.entry(topic).or_insert(0) += 1;
                }
            }
        }
    }

    if calendar_mentions >= policy.calendar_min_event_mentions.max(1) {
        opportunities.push((
            "Calendar Integration".to_owned(),
            "Sync with your calendar to automatically track events and send reminders".to_owned(),
            format!("Detected {calendar_mentions} calendar-related mentions"),
        ));
    }

    if email_mentions >= policy.email_min_mentions.max(1) {
        opportunities.push((
            "Email Integration".to_owned(),
            "Connect to your email to help manage inbox, draft responses, and track threads"
                .to_owned(),
            format!("Detected {email_mentions} email-related mentions"),
        ));
    }

    for (topic, count) in &topic_counts {
        if *count >= policy.topic_min_research_mentions.max(1) {
            opportunities.push((
                format!("{} Expert", capitalize_first(topic)),
                format!(
                    "Create a specialized skill for {topic} with curated resources and workflows"
                ),
                format!("Researched {topic} {count} times"),
            ));
        }
    }

    opportunities
}

fn normalized_terms(values: &[String]) -> Vec<String> {
    values
        .iter()
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty())
        .collect()
}

fn contains_any_keyword(haystack_lower: &str, keywords_lower: &[String]) -> bool {
    keywords_lower
        .iter()
        .any(|keyword| haystack_lower.contains(keyword))
}

fn tags_match_keywords(tags_lower: &[String], keywords_lower: &[String]) -> bool {
    if keywords_lower.is_empty() {
        return false;
    }

    tags_lower
        .iter()
        .any(|tag| contains_any_keyword(tag.as_str(), keywords_lower))
}

fn extract_topic_from_tag(tag_lower: &str, prefixes_lower: &[String]) -> Option<String> {
    for prefix in prefixes_lower {
        if let Some(topic) = tag_lower.strip_prefix(prefix) {
            let normalized = topic.trim().to_owned();
            if !normalized.is_empty() {
                return Some(normalized);
            }
        }
    }
    None
}

/// Load a skill-opportunity policy pack from the mutable Fae root.
///
/// If the file is missing or malformed, default thresholds are returned.
#[must_use]
pub fn load_skill_opportunity_policy(fae_root: &Path) -> SkillOpportunityPolicy {
    let path = fae_root.join(SKILL_OPPORTUNITY_POLICY_RELATIVE_PATH);
    if !path.exists() {
        return SkillOpportunityPolicy::default();
    }

    let contents = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            warn!(
                path = %path.display(),
                error = %e,
                "failed to read skill opportunity policy; using defaults"
            );
            return SkillOpportunityPolicy::default();
        }
    };

    match toml::from_str::<SkillOpportunityPolicy>(&contents) {
        Ok(policy) => policy,
        Err(e) => {
            warn!(
                path = %path.display(),
                error = %e,
                "failed to parse skill opportunity policy; using defaults"
            );
            SkillOpportunityPolicy::default()
        }
    }
}

/// Capitalize the first character of a string.
fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().to_string() + chars.as_str(),
        None => String::new(),
    }
}

/// Get current time as epoch seconds.
fn now_epoch_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::{MemoryKind, MemoryRecord, MemoryStatus, SqliteMemoryRepository};
    use tempfile::TempDir;

    fn seed_active_record(
        repo: &SqliteMemoryRepository,
        id: &str,
        kind: MemoryKind,
        text: &str,
        tags: Vec<String>,
    ) {
        let now = now_epoch_secs();
        let record = MemoryRecord {
            id: id.to_owned(),
            kind,
            status: MemoryStatus::Active,
            text: text.to_owned(),
            confidence: 0.9,
            source_turn_id: None,
            tags,
            supersedes: None,
            created_at: now,
            updated_at: now,
            importance_score: None,
            stale_after_secs: None,
            metadata: None,
        };
        repo.insert_record_raw(&record)
            .expect("insert seeded memory record");
    }

    #[test]
    fn proposal_lifecycle() {
        let mut store = SkillProposalStore::default();

        let id = store.propose("Calendar Integration", "Sync calendar", "3 date mentions");
        assert!(id.is_some());
        let id = match id {
            Some(id) => id,
            None => unreachable!(),
        };

        assert_eq!(store.pending().len(), 1);

        assert!(store.accept(&id));
        assert!(store.pending().is_empty());

        assert!(store.mark_installed(&id));
        let installed = store.proposals.iter().find(|p| p.id == id);
        match installed {
            Some(p) => assert_eq!(p.status, ProposalStatus::Installed),
            None => unreachable!(),
        }
    }

    #[test]
    fn proposal_dedup_prevents_reproposal() {
        let mut store = SkillProposalStore::default();

        let first = store.propose("Calendar", "desc", "pattern");
        assert!(first.is_some());

        // Same name should not create a new proposal.
        let second = store.propose("Calendar", "desc2", "pattern2");
        assert!(second.is_none());
    }

    #[test]
    fn proposal_rejection_with_cooldown() {
        let mut store = SkillProposalStore::default();

        let id = store.propose("Calendar", "desc", "pattern");
        assert!(id.is_some());
        let id = match id {
            Some(id) => id,
            None => unreachable!(),
        };

        assert!(store.reject(&id));

        // Should not re-propose within cooldown.
        let retry = store.propose("Calendar", "desc", "pattern");
        assert!(retry.is_none());
    }

    #[test]
    fn proposal_serde_round_trip() {
        let proposal = SkillProposal {
            id: "proposal-1".to_owned(),
            name: "Test Skill".to_owned(),
            description: "A test skill".to_owned(),
            trigger_pattern: "test pattern".to_owned(),
            status: ProposalStatus::Proposed,
            proposed_at: 1000,
            updated_at: 1000,
        };
        let json = serde_json::to_string(&proposal);
        assert!(json.is_ok());
        let json = match json {
            Ok(j) => j,
            Err(_) => unreachable!(),
        };
        let parsed: Result<SkillProposal, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => assert_eq!(p.name, "Test Skill"),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn proposal_store_persistence() {
        let tmp = TempDir::new().expect("tempdir");
        let mut store = SkillProposalStore::default();

        let id = store.propose("Calendar", "Sync events", "3 mentions");
        assert!(id.is_some());

        let save_result = store.save(tmp.path());
        assert!(save_result.is_ok());

        let loaded = SkillProposalStore::load(tmp.path());
        assert_eq!(loaded.proposals.len(), 1);
        assert_eq!(loaded.proposals[0].name, "Calendar");
    }

    #[test]
    fn detect_skill_opportunities_empty() {
        let tmp = TempDir::new().expect("tempdir");
        let repo = crate::memory::SqliteMemoryRepository::new(tmp.path()).expect("sqlite repo");
        repo.ensure_layout().expect("ensure_layout");

        let opportunities = detect_skill_opportunities(tmp.path());
        assert!(opportunities.is_empty());
    }

    #[test]
    fn detect_skill_opportunities_with_policy_respects_thresholds() {
        let tmp = TempDir::new().expect("tempdir");
        let repo = SqliteMemoryRepository::new(tmp.path()).expect("sqlite repo");
        repo.ensure_layout().expect("ensure_layout");

        for idx in 0..3 {
            seed_active_record(
                &repo,
                &format!("event-{idx}"),
                MemoryKind::Event,
                "meeting tomorrow",
                vec!["calendar".to_owned()],
            );
        }

        let strict = SkillOpportunityPolicy {
            calendar_min_event_mentions: 4,
            email_min_mentions: 99,
            topic_min_research_mentions: 99,
            ..SkillOpportunityPolicy::default()
        };
        let relaxed = SkillOpportunityPolicy {
            calendar_min_event_mentions: 3,
            email_min_mentions: 99,
            topic_min_research_mentions: 99,
            ..SkillOpportunityPolicy::default()
        };

        let strict_results = detect_skill_opportunities_with_policy(tmp.path(), strict);
        assert!(
            !strict_results
                .iter()
                .any(|(name, _, _)| name == "Calendar Integration")
        );

        let relaxed_results = detect_skill_opportunities_with_policy(tmp.path(), relaxed);
        assert!(
            relaxed_results
                .iter()
                .any(|(name, _, _)| name == "Calendar Integration")
        );
    }

    #[test]
    fn detect_skill_opportunities_with_policy_supports_custom_email_patterns() {
        let tmp = TempDir::new().expect("tempdir");
        let repo = SqliteMemoryRepository::new(tmp.path()).expect("sqlite repo");
        repo.ensure_layout().expect("ensure_layout");

        seed_active_record(
            &repo,
            "email-1",
            MemoryKind::Fact,
            "Please check dispatch queue delta",
            vec!["communications".to_owned()],
        );

        let without_custom_pattern = detect_skill_opportunities_with_policy(
            tmp.path(),
            SkillOpportunityPolicy {
                calendar_min_event_mentions: 99,
                email_min_mentions: 1,
                topic_min_research_mentions: 99,
                ..SkillOpportunityPolicy::default()
            },
        );
        assert!(
            !without_custom_pattern
                .iter()
                .any(|(name, _, _)| name == "Email Integration")
        );

        let with_custom_pattern = detect_skill_opportunities_with_policy(
            tmp.path(),
            SkillOpportunityPolicy {
                calendar_min_event_mentions: 99,
                email_min_mentions: 1,
                topic_min_research_mentions: 99,
                email_text_keywords: vec!["dispatch queue delta".to_owned()],
                email_tag_keywords: vec!["communications".to_owned()],
                ..SkillOpportunityPolicy::default()
            },
        );
        assert!(
            with_custom_pattern
                .iter()
                .any(|(name, _, _)| name == "Email Integration")
        );
    }

    #[test]
    fn detect_skill_opportunities_with_policy_supports_custom_topic_prefix() {
        let tmp = TempDir::new().expect("tempdir");
        let repo = SqliteMemoryRepository::new(tmp.path()).expect("sqlite repo");
        repo.ensure_layout().expect("ensure_layout");

        for idx in 0..3 {
            seed_active_record(
                &repo,
                &format!("fact-{idx}"),
                MemoryKind::Fact,
                "new gardening source",
                vec!["research".to_owned(), "subject:gardening".to_owned()],
            );
        }

        let defaults = detect_skill_opportunities_with_policy(
            tmp.path(),
            SkillOpportunityPolicy {
                calendar_min_event_mentions: 99,
                email_min_mentions: 99,
                topic_min_research_mentions: 3,
                ..SkillOpportunityPolicy::default()
            },
        );
        assert!(
            !defaults
                .iter()
                .any(|(name, _, _)| name == "Gardening Expert")
        );

        let custom = detect_skill_opportunities_with_policy(
            tmp.path(),
            SkillOpportunityPolicy {
                calendar_min_event_mentions: 99,
                email_min_mentions: 99,
                topic_min_research_mentions: 3,
                topic_tag_prefixes: vec!["subject:".to_owned()],
                ..SkillOpportunityPolicy::default()
            },
        );
        assert!(
            custom.iter().any(|(name, _, _)| name == "Gardening Expert"),
            "custom topic prefix should drive topic extraction"
        );
    }

    #[test]
    fn load_skill_opportunity_policy_defaults_when_file_missing() {
        let tmp = TempDir::new().expect("tempdir");
        let loaded = load_skill_opportunity_policy(tmp.path());
        assert_eq!(loaded, SkillOpportunityPolicy::default());
    }

    #[test]
    fn load_skill_opportunity_policy_from_file() {
        let tmp = TempDir::new().expect("tempdir");
        let policy_path = tmp.path().join(SKILL_OPPORTUNITY_POLICY_RELATIVE_PATH);
        let parent = policy_path.parent().expect("policy parent directory");
        std::fs::create_dir_all(parent).expect("create policy directory");
        std::fs::write(
            &policy_path,
            r#"
calendar_min_event_mentions = 5
email_min_mentions = 4
topic_min_research_mentions = 7
calendar_text_keywords = ["agenda"]
email_text_keywords = ["mailbox"]
topic_tag_prefixes = ["subject:"]
"#,
        )
        .expect("write policy file");

        let loaded = load_skill_opportunity_policy(tmp.path());
        let expected = SkillOpportunityPolicy {
            calendar_min_event_mentions: 5,
            email_min_mentions: 4,
            topic_min_research_mentions: 7,
            calendar_text_keywords: vec!["agenda".to_owned()],
            email_text_keywords: vec!["mailbox".to_owned()],
            topic_tag_prefixes: vec!["subject:".to_owned()],
            ..SkillOpportunityPolicy::default()
        };
        assert_eq!(loaded, expected);
    }

    #[test]
    fn capitalize_first_works() {
        assert_eq!(capitalize_first("hello"), "Hello");
        assert_eq!(capitalize_first(""), "");
        assert_eq!(capitalize_first("a"), "A");
    }

    #[test]
    fn accept_nonexistent_returns_false() {
        let mut store = SkillProposalStore::default();
        assert!(!store.accept("nonexistent"));
    }

    #[test]
    fn reject_nonexistent_returns_false() {
        let mut store = SkillProposalStore::default();
        assert!(!store.reject("nonexistent"));
    }
}
