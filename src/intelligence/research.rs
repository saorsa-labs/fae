//! Background research scheduling and storage.
//!
//! When Fae detects user interests, she can schedule background research
//! tasks that search the web, summarize findings, and store them as memory
//! records for later delivery in briefings.

use crate::intelligence::store::IntelligenceStore;
use crate::memory::{MemoryKind, MemoryRecord};
use serde::{Deserialize, Serialize};
use std::path::Path;
use tracing::warn;

/// A research task waiting to be executed.
#[derive(Debug, Clone)]
pub struct ResearchTask {
    /// Topic to research.
    pub topic: String,
    /// Source intelligence item that triggered this research.
    pub source_id: Option<String>,
    /// Maximum age of existing research (in days) before re-researching.
    pub freshness_days: u32,
}

impl ResearchTask {
    /// Create a new research task for the given topic.
    pub fn new(topic: impl Into<String>) -> Self {
        Self {
            topic: topic.into(),
            source_id: None,
            freshness_days: 7,
        }
    }

    /// Attach a source intelligence item ID.
    #[must_use]
    pub fn with_source(mut self, id: impl Into<String>) -> Self {
        self.source_id = Some(id.into());
        self
    }

    /// Set the freshness threshold.
    #[must_use]
    pub fn with_freshness_days(mut self, days: u32) -> Self {
        self.freshness_days = days;
        self
    }
}

/// Default freshness threshold for research (days).
const DEFAULT_FRESHNESS_DAYS: u32 = 7;

/// Maximum daily research tasks.
const MAX_DAILY_RESEARCH: usize = 3;
/// Relative location for mutable research scheduling policy.
const RESEARCH_POLICY_RELATIVE_PATH: &str = "skills/intelligence/research-policy.toml";

/// Policy thresholds for research scheduling heuristics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ResearchPolicy {
    /// Freshness horizon in days before a topic is considered stale.
    pub freshness_days: u32,
    /// Maximum number of research tasks to schedule in a pass.
    pub max_daily_tasks: usize,
}

impl Default for ResearchPolicy {
    fn default() -> Self {
        Self {
            freshness_days: DEFAULT_FRESHNESS_DAYS,
            max_daily_tasks: MAX_DAILY_RESEARCH,
        }
    }
}

/// Check if recent research exists for a topic.
///
/// Returns `true` if a Fact-kind record with the `research` and matching
/// topic tag exists and was updated within `max_age_days`.
pub fn has_recent_research(store: &IntelligenceStore, topic: &str, max_age_days: u32) -> bool {
    let records = match store.repo().list_records() {
        Ok(r) => r,
        Err(_) => return false,
    };

    let now = now_epoch_secs();
    let max_age_secs = u64::from(max_age_days) * 86_400;
    let normalized_topic = topic.trim().to_lowercase();

    records.iter().any(|r| {
        r.kind == MemoryKind::Fact
            && r.status == crate::memory::MemoryStatus::Active
            && r.tags.iter().any(|t| t == "research")
            && r.tags
                .iter()
                .any(|t| t.starts_with("topic:") && t[6..].to_lowercase() == normalized_topic)
            && now.saturating_sub(r.updated_at) < max_age_secs
    })
}

/// Store a research result as a Fact-kind memory record.
pub fn store_research_result(
    store: &IntelligenceStore,
    topic: &str,
    summary: &str,
    source_urls: &[String],
) -> Result<MemoryRecord, crate::error::SpeechError> {
    let mut tags = vec![
        "research".to_owned(),
        format!("topic:{topic}"),
        "intelligence:research".to_owned(),
    ];

    // Store source URLs as tags for retrieval.
    for url in source_urls {
        tags.push(format!("source_url:{url}"));
    }

    Ok(store
        .repo()
        .insert_record(MemoryKind::Fact, summary, 0.70, None, &tags)?)
}

/// Gather recent research results for briefing inclusion.
///
/// Returns Fact-kind records tagged with `research` that were updated
/// within the given number of days, ordered by most recent first.
pub fn gather_recent_research(store: &IntelligenceStore, within_days: u32) -> Vec<MemoryRecord> {
    let records = match store.repo().list_records() {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };

    let now = now_epoch_secs();
    let horizon = u64::from(within_days) * 86_400;

    let mut research: Vec<MemoryRecord> = records
        .into_iter()
        .filter(|r| {
            r.kind == MemoryKind::Fact
                && r.status == crate::memory::MemoryStatus::Active
                && r.tags.iter().any(|t| t == "research")
                && now.saturating_sub(r.updated_at) < horizon
        })
        .collect();

    // Most recent first.
    research.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    research
}

/// Create research tasks from detected interests, respecting freshness
/// and daily limits.
///
/// Returns research tasks that should be scheduled (topics not recently
/// researched), capped at `max_daily`.
pub fn create_research_tasks(
    store: &IntelligenceStore,
    topics: &[String],
    max_daily: Option<usize>,
) -> Vec<ResearchTask> {
    let mut policy = ResearchPolicy::default();
    if let Some(limit) = max_daily {
        policy.max_daily_tasks = limit;
    }
    create_research_tasks_with_policy(store, topics, policy)
}

/// Create research tasks using a mutable policy pack.
///
/// This keeps scheduler heuristics in data while preserving the same core
/// filtering logic.
pub fn create_research_tasks_with_policy(
    store: &IntelligenceStore,
    topics: &[String],
    policy: ResearchPolicy,
) -> Vec<ResearchTask> {
    let limit = policy.max_daily_tasks;
    topics
        .iter()
        .filter(|topic| !has_recent_research(store, topic, policy.freshness_days))
        .take(limit)
        .map(|topic| ResearchTask::new(topic.as_str()).with_freshness_days(policy.freshness_days))
        .collect()
}

/// Load research scheduling policy from mutable root.
///
/// Missing or malformed policy file falls back to defaults.
#[must_use]
pub fn load_research_policy(fae_root: &Path) -> ResearchPolicy {
    let path = fae_root.join(RESEARCH_POLICY_RELATIVE_PATH);
    if !path.exists() {
        return ResearchPolicy::default();
    }

    let contents = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => {
            warn!(
                path = %path.display(),
                error = %e,
                "failed to read research policy; using defaults"
            );
            return ResearchPolicy::default();
        }
    };

    match toml::from_str::<ResearchPolicy>(&contents) {
        Ok(policy) => policy,
        Err(e) => {
            warn!(
                path = %path.display(),
                error = %e,
                "failed to parse research policy; using defaults"
            );
            ResearchPolicy::default()
        }
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
    use crate::intelligence::store::IntelligenceStore;
    use crate::memory::SqliteMemoryRepository;
    use tempfile::TempDir;

    fn temp_store() -> (TempDir, IntelligenceStore) {
        let tmp = TempDir::new().expect("tempdir");
        let repo = SqliteMemoryRepository::new(tmp.path()).expect("sqlite repo");
        repo.ensure_layout().expect("ensure_layout");
        let store = IntelligenceStore::new(repo);
        (tmp, store)
    }

    #[test]
    fn research_task_builder() {
        let task = ResearchTask::new("machine learning")
            .with_source("item-1")
            .with_freshness_days(14);
        assert_eq!(task.topic, "machine learning");
        assert_eq!(task.source_id.as_deref(), Some("item-1"));
        assert_eq!(task.freshness_days, 14);
    }

    #[test]
    fn no_recent_research_by_default() {
        let (_tmp, store) = temp_store();
        assert!(!has_recent_research(&store, "hiking", 7));
    }

    #[test]
    fn store_and_detect_recent_research() {
        let (_tmp, store) = temp_store();

        let result = store_research_result(
            &store,
            "hiking",
            "Best hiking trails in Scotland",
            &["https://example.com/trails".to_owned()],
        );
        assert!(result.is_ok());

        assert!(has_recent_research(&store, "hiking", 7));
        // Different topic should not match.
        assert!(!has_recent_research(&store, "cooking", 7));
    }

    #[test]
    fn gather_recent_research_empty() {
        let (_tmp, store) = temp_store();
        let results = gather_recent_research(&store, 7);
        assert!(results.is_empty());
    }

    #[test]
    fn gather_recent_research_with_data() {
        let (_tmp, store) = temp_store();

        let result = store_research_result(
            &store,
            "rust programming",
            "Latest Rust features in 2026",
            &[],
        );
        assert!(result.is_ok());

        let results = gather_recent_research(&store, 7);
        assert_eq!(results.len(), 1);
        assert!(results[0].text.contains("Rust"));
    }

    #[test]
    fn create_research_tasks_filters_existing() {
        let (_tmp, store) = temp_store();

        // Store research for "hiking".
        let result = store_research_result(&store, "hiking", "Trail info", &[]);
        assert!(result.is_ok());

        let topics = vec!["hiking".to_owned(), "cooking".to_owned()];
        let tasks = create_research_tasks(&store, &topics, None);

        // "hiking" should be filtered out (already researched).
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].topic, "cooking");
    }

    #[test]
    fn create_research_tasks_respects_limit() {
        let (_tmp, store) = temp_store();

        let topics: Vec<String> = (0..10).map(|i| format!("topic-{i}")).collect();
        let tasks = create_research_tasks(&store, &topics, Some(2));

        assert_eq!(tasks.len(), 2);
    }

    #[test]
    fn research_case_insensitive_topic_match() {
        let (_tmp, store) = temp_store();

        let result = store_research_result(&store, "Hiking", "Trail info", &[]);
        assert!(result.is_ok());

        // Should match case-insensitively.
        assert!(has_recent_research(&store, "hiking", 7));
        assert!(has_recent_research(&store, "HIKING", 7));
    }

    #[test]
    fn create_research_tasks_with_policy_respects_freshness_days() {
        let (_tmp, store) = temp_store();
        let result = store_research_result(&store, "hiking", "Trail info", &[]);
        assert!(result.is_ok());
        let topics = vec!["hiking".to_owned()];

        let strict = create_research_tasks_with_policy(
            &store,
            &topics,
            ResearchPolicy {
                freshness_days: 365,
                max_daily_tasks: 5,
            },
        );
        assert!(strict.is_empty(), "fresh research should be filtered");

        let zero_freshness = create_research_tasks_with_policy(
            &store,
            &topics,
            ResearchPolicy {
                freshness_days: 0,
                max_daily_tasks: 5,
            },
        );
        assert_eq!(
            zero_freshness.len(),
            1,
            "zero freshness means topics are immediately eligible again"
        );
        assert_eq!(zero_freshness[0].freshness_days, 0);
    }

    #[test]
    fn create_research_tasks_with_policy_respects_max_daily_tasks() {
        let (_tmp, store) = temp_store();
        let topics: Vec<String> = (0..10).map(|i| format!("topic-{i}")).collect();
        let tasks = create_research_tasks_with_policy(
            &store,
            &topics,
            ResearchPolicy {
                freshness_days: 7,
                max_daily_tasks: 4,
            },
        );
        assert_eq!(tasks.len(), 4);
    }

    #[test]
    fn load_research_policy_defaults_when_file_missing() {
        let tmp = TempDir::new().expect("tempdir");
        let loaded = load_research_policy(tmp.path());
        assert_eq!(loaded, ResearchPolicy::default());
    }

    #[test]
    fn load_research_policy_from_file() {
        let tmp = TempDir::new().expect("tempdir");
        let policy_path = tmp.path().join(RESEARCH_POLICY_RELATIVE_PATH);
        let parent = policy_path.parent().expect("policy parent");
        std::fs::create_dir_all(parent).expect("create policy dir");
        std::fs::write(&policy_path, "freshness_days = 10\nmax_daily_tasks = 6\n")
            .expect("write policy file");

        let loaded = load_research_policy(tmp.path());
        assert_eq!(
            loaded,
            ResearchPolicy {
                freshness_days: 10,
                max_daily_tasks: 6,
            }
        );
    }
}
