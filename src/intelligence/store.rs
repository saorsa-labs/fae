//! Intelligence persistence layer.
//!
//! Wraps [`MemoryRepository`] for intelligence-specific storage and queries.
//! Intelligence items are stored as enriched [`MemoryRecord`]s with appropriate
//! kinds, tags, and metadata.

use crate::error::{Result, SpeechError};
use crate::intelligence::types::{IntelligenceItem, IntelligenceKind};
use crate::memory::{MemoryKind, MemoryRecord, MemoryRepository};

/// Intelligence-focused query and storage layer.
///
/// Wraps a [`MemoryRepository`] and provides convenience methods for
/// intelligence-specific operations (store items, query by kind, detect
/// duplicates, track relationships).
#[derive(Debug, Clone)]
pub struct IntelligenceStore {
    repo: MemoryRepository,
}

/// A relationship metadata record parsed from memory.
#[derive(Debug, Clone)]
pub struct RelationshipMeta {
    /// Person's name.
    pub name: String,
    /// Relationship type (friend, colleague, family, etc).
    pub relationship: Option<String>,
    /// Epoch seconds of last mention.
    pub last_mentioned_at: u64,
    /// Total number of mentions.
    pub mention_count: u32,
    /// Accumulated context notes.
    pub context_notes: Vec<String>,
}

impl IntelligenceStore {
    /// Create a new intelligence store wrapping the given repository.
    pub fn new(repo: MemoryRepository) -> Self {
        Self { repo }
    }

    /// Returns a reference to the underlying repository.
    #[must_use]
    pub fn repo(&self) -> &MemoryRepository {
        &self.repo
    }

    /// Store an intelligence item as a memory record.
    ///
    /// Maps the `IntelligenceKind` to the corresponding `MemoryKind` and
    /// stores metadata as JSON in the record tags.
    pub fn store_item(
        &self,
        item: &IntelligenceItem,
        source_turn_id: Option<&str>,
    ) -> Result<MemoryRecord> {
        let kind = intelligence_kind_to_memory_kind(item.kind);
        let mut tags = vec![format!("intelligence:{}", item.kind)];

        // Add metadata-derived tags.
        if let Some(ref meta) = item.metadata {
            if let Some(date) = meta.get("date_iso").and_then(|v| v.as_str()) {
                tags.push(format!("date:{date}"));
            }
            if let Some(name) = meta.get("name").and_then(|v| v.as_str()) {
                tags.push(format!("person:{name}"));
            }
            if let Some(topic) = meta.get("topic").and_then(|v| v.as_str()) {
                tags.push(format!("topic:{topic}"));
            }
        }

        // Store metadata JSON as a tag for retrieval.
        if let Some(ref meta) = item.metadata
            && let Ok(json_str) = serde_json::to_string(meta)
        {
            tags.push(format!("meta:{json_str}"));
        }

        self.repo
            .insert_record(kind, &item.text, item.confidence, source_turn_id, tags)
    }

    /// Query upcoming events within the given number of days.
    pub fn query_events(&self, within_days: u32) -> Result<Vec<MemoryRecord>> {
        let records = self.repo.list_records()?;
        let now = now_epoch_secs();
        let horizon = now + u64::from(within_days) * 86_400;

        let mut events: Vec<MemoryRecord> = records
            .into_iter()
            .filter(|r| {
                r.kind == MemoryKind::Event
                    && r.status == crate::memory::MemoryStatus::Active
                    && has_tag_prefix(&r.tags, "intelligence:date_event")
            })
            .filter(|r| {
                // Check if event date falls within horizon.
                if let Some(date_str) = extract_date_tag(&r.tags)
                    && let Some(event_epoch) = parse_date_to_epoch(&date_str)
                {
                    return event_epoch <= horizon && event_epoch >= now.saturating_sub(86_400);
                }
                // Include events without parseable dates (let caller filter further).
                true
            })
            .collect();

        events.sort_by_key(|r| r.created_at);
        Ok(events)
    }

    /// Query all active person records.
    pub fn query_people(&self) -> Result<Vec<MemoryRecord>> {
        let records = self.repo.list_records()?;
        let people: Vec<MemoryRecord> = records
            .into_iter()
            .filter(|r| {
                r.kind == MemoryKind::Person && r.status == crate::memory::MemoryStatus::Active
            })
            .collect();
        Ok(people)
    }

    /// Query all active interest records.
    pub fn query_interests(&self) -> Result<Vec<MemoryRecord>> {
        let records = self.repo.list_records()?;
        let interests: Vec<MemoryRecord> = records
            .into_iter()
            .filter(|r| {
                r.kind == MemoryKind::Interest && r.status == crate::memory::MemoryStatus::Active
            })
            .collect();
        Ok(interests)
    }

    /// Query all active commitment records.
    pub fn query_commitments(&self) -> Result<Vec<MemoryRecord>> {
        let records = self.repo.list_records()?;
        let commitments: Vec<MemoryRecord> = records
            .into_iter()
            .filter(|r| {
                r.kind == MemoryKind::Commitment && r.status == crate::memory::MemoryStatus::Active
            })
            .collect();
        Ok(commitments)
    }

    /// Find relationships that haven't been mentioned in a while.
    pub fn query_stale_relationships(
        &self,
        threshold_days: u32,
    ) -> Result<Vec<(MemoryRecord, u64)>> {
        let records = self.repo.list_records()?;
        let now = now_epoch_secs();
        let threshold_secs = u64::from(threshold_days) * 86_400;

        let stale: Vec<(MemoryRecord, u64)> = records
            .into_iter()
            .filter(|r| {
                r.kind == MemoryKind::Person && r.status == crate::memory::MemoryStatus::Active
            })
            .filter_map(|r| {
                let days_since = now.saturating_sub(r.updated_at) / 86_400;
                if now.saturating_sub(r.updated_at) >= threshold_secs {
                    Some((r, days_since))
                } else {
                    None
                }
            })
            .collect();

        Ok(stale)
    }

    /// Check if an intelligence item is a duplicate of an existing record.
    ///
    /// Uses text similarity and kind matching. For DateEvents, also checks
    /// date metadata. For PersonMentions, also checks person name.
    pub fn is_duplicate_intelligence(&self, item: &IntelligenceItem) -> Result<bool> {
        let records = self.repo.list_records()?;
        let target_kind = intelligence_kind_to_memory_kind(item.kind);
        let normalized_text = item.text.trim().to_lowercase();

        for record in &records {
            if record.kind != target_kind || record.status != crate::memory::MemoryStatus::Active {
                continue;
            }

            // Text similarity check (exact match after normalization).
            let record_text = record.text.trim().to_lowercase();
            if record_text == normalized_text {
                return Ok(true);
            }

            // Kind-specific checks.
            match item.kind {
                IntelligenceKind::DateEvent => {
                    if let Some(ref item_meta) = item.metadata
                        && let Some(item_date) = item_meta.get("date_iso").and_then(|v| v.as_str())
                        && let Some(record_date) = extract_date_tag(&record.tags)
                        && item_date == record_date
                    {
                        return Ok(true);
                    }
                }
                IntelligenceKind::PersonMention => {
                    if let Some(ref item_meta) = item.metadata
                        && let Some(item_name) = item_meta.get("name").and_then(|v| v.as_str())
                        && let Some(record_name) = extract_person_tag(&record.tags)
                        && item_name.to_lowercase() == record_name.to_lowercase()
                    {
                        return Ok(true);
                    }
                }
                _ => {}
            }
        }

        Ok(false)
    }

    /// Upsert a relationship record.
    ///
    /// If a Person record with matching name exists, updates its timestamp
    /// and appends context. Otherwise creates a new Person record.
    pub fn upsert_relationship(
        &self,
        name: &str,
        relationship: Option<&str>,
        context: Option<&str>,
    ) -> Result<MemoryRecord> {
        let records = self.repo.list_records()?;
        let normalized_name = name.trim().to_lowercase();

        // Look for existing person record.
        let existing = records.iter().find(|r| {
            r.kind == MemoryKind::Person
                && r.status == crate::memory::MemoryStatus::Active
                && extract_person_tag(&r.tags).is_some_and(|n| n.to_lowercase() == normalized_name)
        });

        if let Some(existing_record) = existing {
            // Update: increment mention count and append context.
            let mut new_text = existing_record.text.clone();
            if let Some(ctx) = context
                && !ctx.trim().is_empty()
            {
                new_text = format!("{new_text}; {ctx}");
            }
            self.repo.patch_record(
                &existing_record.id,
                &new_text,
                &format!("relationship update for {name}"),
            )?;
            // Return the updated record (re-read to get updated_at).
            let updated_records = self.repo.list_records()?;
            let updated = updated_records
                .into_iter()
                .find(|r| r.id == existing_record.id);
            match updated {
                Some(r) => Ok(r),
                None => Err(SpeechError::Memory(format!(
                    "lost record after patch: {}",
                    existing_record.id
                ))),
            }
        } else {
            // Create new person record.
            let text = match (relationship, context) {
                (Some(rel), Some(ctx)) => format!("{name} ({rel}): {ctx}"),
                (Some(rel), None) => format!("{name} ({rel})"),
                (None, Some(ctx)) => format!("{name}: {ctx}"),
                (None, None) => name.to_owned(),
            };
            let mut tags = vec![
                "intelligence:person_mention".to_owned(),
                format!("person:{name}"),
            ];
            if let Some(rel) = relationship {
                tags.push(format!("relationship:{rel}"));
            }
            self.repo
                .insert_record(MemoryKind::Person, &text, 0.80, None, tags)
        }
    }

    /// Parse relationship metadata from a person record's tags.
    #[must_use]
    pub fn parse_relationship_meta(record: &MemoryRecord) -> Option<RelationshipMeta> {
        if record.kind != MemoryKind::Person {
            return None;
        }
        let name = extract_person_tag(&record.tags)?;
        let relationship = record
            .tags
            .iter()
            .find(|t| t.starts_with("relationship:"))
            .map(|t| t.strip_prefix("relationship:").unwrap_or(t).to_owned());

        Some(RelationshipMeta {
            name,
            relationship,
            last_mentioned_at: record.updated_at,
            mention_count: 1, // Approximate; actual count from context notes.
            context_notes: vec![record.text.clone()],
        })
    }
}

/// Map intelligence kind to memory kind.
fn intelligence_kind_to_memory_kind(kind: IntelligenceKind) -> MemoryKind {
    match kind {
        IntelligenceKind::DateEvent => MemoryKind::Event,
        IntelligenceKind::PersonMention | IntelligenceKind::RelationshipSignal => {
            MemoryKind::Person
        }
        IntelligenceKind::Interest => MemoryKind::Interest,
        IntelligenceKind::Commitment => MemoryKind::Commitment,
    }
}

/// Extract a date tag value (e.g. "2026-03-15" from "date:2026-03-15").
fn extract_date_tag(tags: &[String]) -> Option<String> {
    tags.iter()
        .find(|t| t.starts_with("date:"))
        .map(|t| t.strip_prefix("date:").unwrap_or(t).to_owned())
}

/// Extract a person name tag value (e.g. "Sarah" from "person:Sarah").
fn extract_person_tag(tags: &[String]) -> Option<String> {
    tags.iter()
        .find(|t| t.starts_with("person:"))
        .map(|t| t.strip_prefix("person:").unwrap_or(t).to_owned())
}

/// Check if any tag starts with the given prefix.
fn has_tag_prefix(tags: &[String], prefix: &str) -> bool {
    tags.iter().any(|t| t.starts_with(prefix))
}

/// Parse an ISO date string ("YYYY-MM-DD") to epoch seconds (start of day UTC).
fn parse_date_to_epoch(date_str: &str) -> Option<u64> {
    let parts: Vec<&str> = date_str.split('-').collect();
    if parts.len() != 3 {
        return None;
    }
    let year: i64 = parts[0].parse().ok()?;
    let month: u32 = parts[1].parse().ok()?;
    let day: u32 = parts[2].parse().ok()?;

    // Simple days-since-epoch calculation.
    // This is approximate but sufficient for "within N days" queries.
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || year < 1970 {
        return None;
    }

    // Use a simple approximation: days from epoch.
    let days = days_from_epoch(year, month, day)?;
    Some(days as u64 * 86_400)
}

/// Approximate days from Unix epoch for a given date.
fn days_from_epoch(year: i64, month: u32, day: u32) -> Option<i64> {
    // Zeller-like calculation for days since 1970-01-01.
    let y = if month <= 2 { year - 1 } else { year };
    let m = if month <= 2 { month + 12 } else { month };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m as i64 - 3) + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days)
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

    fn temp_store() -> (TempDir, IntelligenceStore) {
        let tmp = TempDir::new().expect("tempdir");
        let repo = MemoryRepository::new(tmp.path());
        match repo.ensure_layout() {
            Ok(()) => {}
            Err(e) => panic!("ensure_layout failed: {e}"),
        }
        let store = IntelligenceStore::new(repo);
        (tmp, store)
    }

    #[test]
    fn store_and_query_event() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::DateEvent, "Birthday March 15", 0.95)
            .with_metadata(serde_json::json!({ "date_iso": "2026-03-15" }));

        let result = store.store_item(&item, Some("turn-1"));
        assert!(result.is_ok());
        match result {
            Ok(record) => {
                assert_eq!(record.kind, MemoryKind::Event);
                assert!(record.tags.iter().any(|t| t == "intelligence:date_event"));
                assert!(record.tags.iter().any(|t| t == "date:2026-03-15"));
            }
            Err(_) => unreachable!(),
        }

        // Query events.
        let events = store.query_events(365);
        assert!(events.is_ok());
        match events {
            Ok(e) => assert!(!e.is_empty()),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn store_and_query_person() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::PersonMention, "Friend Sarah", 0.85)
            .with_metadata(serde_json::json!({ "name": "Sarah" }));

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        let people = store.query_people();
        assert!(people.is_ok());
        match people {
            Ok(p) => {
                assert_eq!(p.len(), 1);
                assert!(p[0].tags.iter().any(|t| t == "person:Sarah"));
            }
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn store_and_query_interest() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::Interest, "Hiking", 0.80);

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        let interests = store.query_interests();
        assert!(interests.is_ok());
        match interests {
            Ok(i) => assert_eq!(i.len(), 1),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn store_and_query_commitment() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(
            IntelligenceKind::Commitment,
            "Promised to call dentist",
            0.75,
        );

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        let commitments = store.query_commitments();
        assert!(commitments.is_ok());
        match commitments {
            Ok(c) => assert_eq!(c.len(), 1),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn duplicate_detection_exact_text() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::Interest, "Hiking", 0.80);

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        let is_dup = store.is_duplicate_intelligence(&item);
        assert!(is_dup.is_ok());
        match is_dup {
            Ok(dup) => assert!(dup),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn duplicate_detection_date_event() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::DateEvent, "Birthday", 0.95)
            .with_metadata(serde_json::json!({ "date_iso": "2026-03-15" }));

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        // Same date, different text should be detected as duplicate.
        let similar = IntelligenceItem::new(IntelligenceKind::DateEvent, "My Birthday!", 0.90)
            .with_metadata(serde_json::json!({ "date_iso": "2026-03-15" }));
        let is_dup = store.is_duplicate_intelligence(&similar);
        assert!(is_dup.is_ok());
        match is_dup {
            Ok(dup) => assert!(dup),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn duplicate_detection_person() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::PersonMention, "Friend Sarah", 0.85)
            .with_metadata(serde_json::json!({ "name": "Sarah" }));

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        // Same person, different text.
        let similar = IntelligenceItem::new(IntelligenceKind::PersonMention, "Sarah is great", 0.8)
            .with_metadata(serde_json::json!({ "name": "Sarah" }));
        let is_dup = store.is_duplicate_intelligence(&similar);
        assert!(is_dup.is_ok());
        match is_dup {
            Ok(dup) => assert!(dup),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn not_duplicate_different_kind() {
        let (_tmp, store) = temp_store();
        let item = IntelligenceItem::new(IntelligenceKind::Interest, "Hiking", 0.80);

        let result = store.store_item(&item, None);
        assert!(result.is_ok());

        // Same text but different kind.
        let different = IntelligenceItem::new(IntelligenceKind::Commitment, "Hiking", 0.80);
        let is_dup = store.is_duplicate_intelligence(&different);
        assert!(is_dup.is_ok());
        match is_dup {
            Ok(dup) => assert!(!dup),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn upsert_relationship_new() {
        let (_tmp, store) = temp_store();

        let result = store.upsert_relationship("Sarah", Some("friend"), Some("met at coffee"));
        assert!(result.is_ok());

        let people = store.query_people();
        assert!(people.is_ok());
        match people {
            Ok(p) => {
                assert_eq!(p.len(), 1);
                assert!(p[0].text.contains("Sarah"));
                assert!(p[0].text.contains("friend"));
            }
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn upsert_relationship_update() {
        let (_tmp, store) = temp_store();

        let first = store.upsert_relationship("Sarah", Some("friend"), Some("met at coffee"));
        assert!(first.is_ok());

        let second = store.upsert_relationship("Sarah", Some("friend"), Some("lunch yesterday"));
        assert!(second.is_ok());

        let people = store.query_people();
        assert!(people.is_ok());
        match people {
            Ok(p) => {
                // Should still be one record (updated, not duplicated).
                assert_eq!(p.len(), 1);
                assert!(p[0].text.contains("lunch yesterday"));
            }
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn stale_relationships() {
        let (_tmp, store) = temp_store();

        // Create a person record.
        let result = store.upsert_relationship("Sarah", Some("friend"), None);
        assert!(result.is_ok());

        // With threshold 0 days, any record is stale.
        let stale = store.query_stale_relationships(0);
        assert!(stale.is_ok());
        match stale {
            Ok(s) => assert!(!s.is_empty()),
            Err(_) => unreachable!(),
        }

        // With threshold 9999 days, nothing is stale.
        let stale = store.query_stale_relationships(9999);
        assert!(stale.is_ok());
        match stale {
            Ok(s) => assert!(s.is_empty()),
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn parse_relationship_meta_from_record() {
        let record = MemoryRecord {
            id: "mem-1".to_owned(),
            kind: MemoryKind::Person,
            status: crate::memory::MemoryStatus::Active,
            text: "Sarah (friend): met at coffee".to_owned(),
            confidence: 0.80,
            source_turn_id: None,
            tags: vec![
                "intelligence:person_mention".to_owned(),
                "person:Sarah".to_owned(),
                "relationship:friend".to_owned(),
            ],
            supersedes: None,
            created_at: 1000,
            updated_at: 2000,
            importance_score: None,
            stale_after_secs: None,
            metadata: None,
        };

        let meta = IntelligenceStore::parse_relationship_meta(&record);
        assert!(meta.is_some());
        match meta {
            Some(m) => {
                assert_eq!(m.name, "Sarah");
                assert_eq!(m.relationship.as_deref(), Some("friend"));
                assert_eq!(m.last_mentioned_at, 2000);
            }
            None => unreachable!(),
        }
    }

    #[test]
    fn parse_date_to_epoch_valid() {
        let epoch = parse_date_to_epoch("2026-03-15");
        assert!(epoch.is_some());
    }

    #[test]
    fn parse_date_to_epoch_invalid() {
        assert!(parse_date_to_epoch("not-a-date").is_none());
        assert!(parse_date_to_epoch("2026-13-15").is_none());
        assert!(parse_date_to_epoch("2026-03-32").is_none());
    }
}
