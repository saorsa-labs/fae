//! Intelligence data types for proactive intelligence extraction.
//!
//! Defines the core types for intelligence items extracted from conversations:
//! events, people, interests, commitments, and relationship signals.

use serde::{Deserialize, Serialize};

/// The kind of intelligence extracted from a conversation turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntelligenceKind {
    /// A date-based event (birthday, meeting, deadline, anniversary).
    DateEvent,
    /// A mention of a person (friend, colleague, family member).
    PersonMention,
    /// A user interest or hobby detected in conversation.
    Interest,
    /// A commitment or promise the user made.
    Commitment,
    /// A signal about a relationship (closeness, frequency, sentiment).
    RelationshipSignal,
}

impl std::fmt::Display for IntelligenceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DateEvent => write!(f, "date_event"),
            Self::PersonMention => write!(f, "person_mention"),
            Self::Interest => write!(f, "interest"),
            Self::Commitment => write!(f, "commitment"),
            Self::RelationshipSignal => write!(f, "relationship_signal"),
        }
    }
}

/// A single intelligence item extracted from a conversation turn.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntelligenceItem {
    /// What kind of intelligence this represents.
    pub kind: IntelligenceKind,
    /// Human-readable description of the intelligence.
    pub text: String,
    /// Confidence score (0.0–1.0) of the extraction.
    pub confidence: f32,
    /// Structured metadata specific to the kind (dates, names, etc).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
    /// The conversation turn ID this was extracted from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_turn_id: Option<String>,
}

impl IntelligenceItem {
    /// Create a new intelligence item with the given kind and text.
    pub fn new(kind: IntelligenceKind, text: impl Into<String>, confidence: f32) -> Self {
        Self {
            kind,
            text: text.into(),
            confidence: confidence.clamp(0.0, 1.0),
            metadata: None,
            source_turn_id: None,
        }
    }

    /// Attach structured metadata to this item.
    #[must_use]
    pub fn with_metadata(mut self, metadata: serde_json::Value) -> Self {
        self.metadata = Some(metadata);
        self
    }

    /// Attach a source turn ID.
    #[must_use]
    pub fn with_source_turn_id(mut self, turn_id: impl Into<String>) -> Self {
        self.source_turn_id = Some(turn_id.into());
        self
    }

    /// Validates that the item has non-empty text and valid confidence.
    #[must_use]
    pub fn is_valid(&self) -> bool {
        !self.text.trim().is_empty() && (0.0..=1.0).contains(&self.confidence)
    }
}

/// An action to take based on extracted intelligence.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IntelligenceAction {
    /// Create a new scheduler task (e.g. birthday reminder).
    CreateSchedulerTask {
        /// Task name.
        name: String,
        /// When to trigger (ISO date or relative description).
        trigger_at: String,
        /// The prompt to inject when the task fires.
        prompt: String,
    },
    /// Create a new memory record from extracted intelligence.
    CreateMemoryRecord {
        /// The memory kind to use.
        kind: String,
        /// The text content for the record.
        text: String,
        /// Tags to attach.
        #[serde(default)]
        tags: Vec<String>,
        /// Confidence score.
        confidence: f32,
    },
    /// Update relationship tracking metadata.
    UpdateRelationship {
        /// Person's name.
        name: String,
        /// Relationship description (friend, colleague, etc).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        relationship: Option<String>,
        /// Context note about this mention.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        context: Option<String>,
    },
}

/// The result of an intelligence extraction pass.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExtractionResult {
    /// Intelligence items found in the conversation.
    #[serde(default)]
    pub items: Vec<IntelligenceItem>,
    /// Actions to execute based on extracted intelligence.
    #[serde(default)]
    pub actions: Vec<IntelligenceAction>,
}

impl ExtractionResult {
    /// Returns `true` if no items or actions were extracted.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.items.is_empty() && self.actions.is_empty()
    }

    /// Returns the total count of items and actions.
    #[must_use]
    pub fn total_count(&self) -> usize {
        self.items.len() + self.actions.len()
    }
}

/// The result of executing a single intelligence action.
#[derive(Debug, Clone)]
pub enum ActionResult {
    /// A scheduler task was created.
    TaskCreated {
        /// The task ID that was created.
        task_id: String,
    },
    /// A memory record was created.
    MemoryRecordCreated {
        /// The record ID that was created.
        record_id: String,
    },
    /// A relationship was updated.
    RelationshipUpdated {
        /// The person's name.
        name: String,
    },
    /// The action failed.
    Failed {
        /// Error description.
        reason: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intelligence_kind_serde_round_trip() {
        let kinds = vec![
            IntelligenceKind::DateEvent,
            IntelligenceKind::PersonMention,
            IntelligenceKind::Interest,
            IntelligenceKind::Commitment,
            IntelligenceKind::RelationshipSignal,
        ];
        for kind in kinds {
            let json = serde_json::to_string(&kind);
            assert!(json.is_ok(), "failed to serialize {kind:?}");
            let json = match json {
                Ok(j) => j,
                Err(_) => unreachable!(),
            };
            let parsed: Result<IntelligenceKind, _> = serde_json::from_str(&json);
            assert!(parsed.is_ok(), "failed to deserialize {json}");
            match parsed {
                Ok(k) => assert_eq!(k, kind),
                Err(_) => unreachable!(),
            }
        }
    }

    #[test]
    fn intelligence_kind_display() {
        assert_eq!(IntelligenceKind::DateEvent.to_string(), "date_event");
        assert_eq!(
            IntelligenceKind::PersonMention.to_string(),
            "person_mention"
        );
        assert_eq!(IntelligenceKind::Interest.to_string(), "interest");
        assert_eq!(IntelligenceKind::Commitment.to_string(), "commitment");
        assert_eq!(
            IntelligenceKind::RelationshipSignal.to_string(),
            "relationship_signal"
        );
    }

    #[test]
    fn intelligence_item_new_and_validate() {
        let item = IntelligenceItem::new(IntelligenceKind::Interest, "Likes hiking", 0.85);
        assert!(item.is_valid());
        assert_eq!(item.kind, IntelligenceKind::Interest);
        assert_eq!(item.text, "Likes hiking");
        assert!((item.confidence - 0.85).abs() < f32::EPSILON);
        assert!(item.metadata.is_none());
        assert!(item.source_turn_id.is_none());
    }

    #[test]
    fn intelligence_item_empty_text_invalid() {
        let item = IntelligenceItem::new(IntelligenceKind::Interest, "  ", 0.8);
        assert!(!item.is_valid());
    }

    #[test]
    fn intelligence_item_confidence_clamped() {
        let item = IntelligenceItem::new(IntelligenceKind::Interest, "test", 1.5);
        assert!((item.confidence - 1.0).abs() < f32::EPSILON);

        let item2 = IntelligenceItem::new(IntelligenceKind::Interest, "test", -0.5);
        assert!((item2.confidence - 0.0).abs() < f32::EPSILON);
    }

    #[test]
    fn intelligence_item_with_metadata() {
        let meta = serde_json::json!({ "date_iso": "2026-03-15", "recurring": true });
        let item = IntelligenceItem::new(IntelligenceKind::DateEvent, "Birthday", 0.95)
            .with_metadata(meta.clone());
        assert!(item.metadata.is_some());
        match item.metadata {
            Some(ref m) => assert_eq!(m, &meta),
            None => unreachable!(),
        }
    }

    #[test]
    fn intelligence_item_with_source_turn_id() {
        let item = IntelligenceItem::new(IntelligenceKind::DateEvent, "Meeting", 0.9)
            .with_source_turn_id("turn-42");
        match item.source_turn_id {
            Some(ref id) => assert_eq!(id, "turn-42"),
            None => unreachable!(),
        }
    }

    #[test]
    fn intelligence_item_serde_round_trip() {
        let item = IntelligenceItem::new(IntelligenceKind::DateEvent, "Birthday March 15", 0.95)
            .with_metadata(serde_json::json!({ "date_iso": "2026-03-15" }))
            .with_source_turn_id("turn-1");

        let json = serde_json::to_string(&item);
        assert!(json.is_ok());
        let json = match json {
            Ok(j) => j,
            Err(_) => unreachable!(),
        };
        let parsed: Result<IntelligenceItem, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(ref p) => {
                assert_eq!(p.kind, item.kind);
                assert_eq!(p.text, item.text);
                assert!((p.confidence - item.confidence).abs() < f32::EPSILON);
            }
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn intelligence_action_serde_round_trip() {
        let actions = vec![
            IntelligenceAction::CreateSchedulerTask {
                name: "birthday_reminder".into(),
                trigger_at: "2026-03-14".into(),
                prompt: "Tomorrow is the user's birthday".into(),
            },
            IntelligenceAction::CreateMemoryRecord {
                kind: "event".into(),
                text: "Birthday on March 15".into(),
                tags: vec!["birthday".into()],
                confidence: 0.95,
            },
            IntelligenceAction::UpdateRelationship {
                name: "Sarah".into(),
                relationship: Some("friend".into()),
                context: Some("Mentioned at coffee chat".into()),
            },
        ];
        for action in &actions {
            let json = serde_json::to_string(action);
            assert!(json.is_ok(), "failed to serialize {action:?}");
            let json = match json {
                Ok(j) => j,
                Err(_) => unreachable!(),
            };
            let parsed: Result<IntelligenceAction, _> = serde_json::from_str(&json);
            assert!(parsed.is_ok(), "failed to deserialize: {json}");
        }
    }

    #[test]
    fn extraction_result_empty() {
        let result = ExtractionResult::default();
        assert!(result.is_empty());
        assert_eq!(result.total_count(), 0);
    }

    #[test]
    fn extraction_result_with_items_and_actions() {
        let result = ExtractionResult {
            items: vec![IntelligenceItem::new(
                IntelligenceKind::Interest,
                "hiking",
                0.8,
            )],
            actions: vec![IntelligenceAction::UpdateRelationship {
                name: "Sarah".into(),
                relationship: None,
                context: None,
            }],
        };
        assert!(!result.is_empty());
        assert_eq!(result.total_count(), 2);
    }

    #[test]
    fn extraction_result_serde_round_trip() {
        let result = ExtractionResult {
            items: vec![IntelligenceItem::new(
                IntelligenceKind::DateEvent,
                "Birthday",
                0.9,
            )],
            actions: vec![IntelligenceAction::CreateMemoryRecord {
                kind: "event".into(),
                text: "Birthday".into(),
                tags: vec![],
                confidence: 0.9,
            }],
        };
        let json = serde_json::to_string(&result);
        assert!(json.is_ok());
        let json = match json {
            Ok(j) => j,
            Err(_) => unreachable!(),
        };
        let parsed: Result<ExtractionResult, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => {
                assert_eq!(p.items.len(), 1);
                assert_eq!(p.actions.len(), 1);
            }
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn extraction_result_deserialize_empty_json() {
        let json = "{}";
        let parsed: Result<ExtractionResult, _> = serde_json::from_str(json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => assert!(p.is_empty()),
            Err(_) => unreachable!(),
        }
    }
}
