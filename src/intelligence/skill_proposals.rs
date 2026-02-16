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
pub fn detect_skill_opportunities(memory_path: &Path) -> Vec<(String, String, String)> {
    let repo = crate::memory::MemoryRepository::new(memory_path);
    let records = match repo.list_records() {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };

    let mut opportunities = Vec::new();

    // Count date events.
    let date_events = records
        .iter()
        .filter(|r| {
            r.kind == crate::memory::MemoryKind::Event
                && r.status == crate::memory::MemoryStatus::Active
        })
        .count();

    if date_events >= 3 {
        opportunities.push((
            "Calendar Integration".to_owned(),
            "Sync with your calendar to automatically track events and send reminders".to_owned(),
            format!("Detected {date_events} date/event mentions in conversations"),
        ));
    }

    // Count email-related mentions.
    let email_mentions = records
        .iter()
        .filter(|r| {
            r.status == crate::memory::MemoryStatus::Active
                && (r.text.to_lowercase().contains("email")
                    || r.text.to_lowercase().contains("e-mail")
                    || r.tags.iter().any(|t| t.contains("email")))
        })
        .count();

    if email_mentions >= 3 {
        opportunities.push((
            "Email Integration".to_owned(),
            "Connect to your email to help manage inbox, draft responses, and track threads"
                .to_owned(),
            format!("Detected {email_mentions} email-related mentions"),
        ));
    }

    // Count research topics with multiple entries.
    let mut topic_counts: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    for record in &records {
        if record.kind == crate::memory::MemoryKind::Fact
            && record.tags.iter().any(|t| t == "research")
        {
            for tag in &record.tags {
                if let Some(topic) = tag.strip_prefix("topic:") {
                    *topic_counts.entry(topic.to_lowercase()).or_insert(0) += 1;
                }
            }
        }
    }

    for (topic, count) in &topic_counts {
        if *count >= 3 {
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
    use tempfile::TempDir;

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
        let repo = crate::memory::MemoryRepository::new(tmp.path());
        match repo.ensure_layout() {
            Ok(()) => {}
            Err(e) => panic!("ensure_layout failed: {e}"),
        }

        let opportunities = detect_skill_opportunities(tmp.path());
        assert!(opportunities.is_empty());
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
