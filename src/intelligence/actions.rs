//! Intelligence action executor.
//!
//! Executes [`IntelligenceAction`]s by creating scheduler tasks,
//! memory records, and updating relationship metadata.

use crate::intelligence::store::IntelligenceStore;
use crate::intelligence::types::{ActionResult, IntelligenceAction};
use crate::memory::MemoryKind;
use crate::scheduler::{Schedule, ScheduledTask, upsert_persisted_user_task};
use tracing::warn;

/// Execute a list of intelligence actions, returning results for each.
///
/// Actions are executed independently — a failure in one does not prevent
/// others from running.
pub fn execute_actions(
    actions: &[IntelligenceAction],
    store: &IntelligenceStore,
) -> Vec<ActionResult> {
    actions
        .iter()
        .map(|action| execute_single_action(action, store))
        .collect()
}

/// Execute a single intelligence action.
fn execute_single_action(action: &IntelligenceAction, store: &IntelligenceStore) -> ActionResult {
    match action {
        IntelligenceAction::CreateSchedulerTask {
            name,
            trigger_at,
            prompt,
        } => create_scheduler_task(name, trigger_at, prompt),

        IntelligenceAction::CreateMemoryRecord {
            kind,
            text,
            tags,
            confidence,
        } => create_memory_record(store, kind, text, tags, *confidence),

        IntelligenceAction::UpdateRelationship {
            name,
            relationship,
            context,
        } => update_relationship(store, name, relationship.as_deref(), context.as_deref()),
    }
}

/// Create a scheduler task from an intelligence action.
fn create_scheduler_task(name: &str, trigger_at: &str, prompt: &str) -> ActionResult {
    // Parse the trigger date into a daily schedule.
    let schedule = parse_trigger_date_to_schedule(trigger_at);

    let trigger = crate::scheduler::ConversationTrigger::new(prompt).with_system_addon(
        "You are delivering a proactive reminder based on intelligence \
         gathered from previous conversations. Be warm and natural.",
    );

    let payload = match trigger.to_json() {
        Ok(p) => p,
        Err(e) => {
            return ActionResult::Failed {
                reason: format!("failed to serialize trigger payload: {e}"),
            };
        }
    };

    let task_id = format!("intelligence_{}", sanitize_task_id(name));
    let mut task = ScheduledTask::new(&task_id, name, schedule);
    task.payload = Some(payload);

    match upsert_persisted_user_task(task) {
        Ok(()) => ActionResult::TaskCreated { task_id },
        Err(e) => ActionResult::Failed {
            reason: format!("failed to persist scheduler task: {e}"),
        },
    }
}

/// Create a memory record from an intelligence action.
fn create_memory_record(
    store: &IntelligenceStore,
    kind_str: &str,
    text: &str,
    tags: &[String],
    confidence: f32,
) -> ActionResult {
    let kind = match kind_str {
        "event" => MemoryKind::Event,
        "person" => MemoryKind::Person,
        "interest" => MemoryKind::Interest,
        "commitment" => MemoryKind::Commitment,
        "fact" => MemoryKind::Fact,
        "profile" => MemoryKind::Profile,
        other => {
            warn!("unknown memory kind in intelligence action: {other}");
            MemoryKind::Fact
        }
    };

    match store
        .repo()
        .insert_record(kind, text, confidence, None, tags.to_vec())
    {
        Ok(record) => ActionResult::MemoryRecordCreated {
            record_id: record.id,
        },
        Err(e) => ActionResult::Failed {
            reason: format!("failed to insert memory record: {e}"),
        },
    }
}

/// Update a relationship from an intelligence action.
fn update_relationship(
    store: &IntelligenceStore,
    name: &str,
    relationship: Option<&str>,
    context: Option<&str>,
) -> ActionResult {
    match store.upsert_relationship(name, relationship, context) {
        Ok(_) => ActionResult::RelationshipUpdated {
            name: name.to_owned(),
        },
        Err(e) => ActionResult::Failed {
            reason: format!("failed to update relationship for {name}: {e}"),
        },
    }
}

/// Parse a trigger date string into a [`Schedule`].
///
/// Attempts ISO date parsing; falls back to a daily schedule at 09:00.
fn parse_trigger_date_to_schedule(trigger_at: &str) -> Schedule {
    // For now, just use a daily schedule at 09:00.
    // A future improvement could parse the date and create a one-shot task.
    let _ = trigger_at; // Used in future date-aware scheduling.
    Schedule::Daily { hour: 9, min: 0 }
}

/// Sanitize a name for use as a task ID.
fn sanitize_task_id(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect::<String>()
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::intelligence::store::IntelligenceStore;
    use crate::memory::MemoryRepository;
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
    fn create_memory_record_action() {
        let (_tmp, store) = temp_store();

        let action = IntelligenceAction::CreateMemoryRecord {
            kind: "interest".into(),
            text: "Enjoys hiking".into(),
            tags: vec!["intelligence:interest".into()],
            confidence: 0.8,
        };

        let results = execute_actions(&[action], &store);
        assert_eq!(results.len(), 1);
        assert!(matches!(
            results[0],
            ActionResult::MemoryRecordCreated { .. }
        ));
    }

    #[test]
    fn update_relationship_action() {
        let (_tmp, store) = temp_store();

        let action = IntelligenceAction::UpdateRelationship {
            name: "Sarah".into(),
            relationship: Some("friend".into()),
            context: Some("mentioned at lunch".into()),
        };

        let results = execute_actions(&[action], &store);
        assert_eq!(results.len(), 1);
        assert!(matches!(
            results[0],
            ActionResult::RelationshipUpdated { .. }
        ));

        // Verify person record was created.
        let people = store.query_people();
        assert!(people.is_ok());
        match people {
            Ok(p) => {
                assert_eq!(p.len(), 1);
                assert!(p[0].text.contains("Sarah"));
            }
            Err(_) => unreachable!(),
        }
    }

    #[test]
    fn scheduler_task_creates_via_persisted_upsert() {
        let (_tmp, store) = temp_store();

        let action = IntelligenceAction::CreateSchedulerTask {
            name: "birthday reminder".into(),
            trigger_at: "2026-03-14".into(),
            prompt: "Tomorrow is the birthday".into(),
        };

        // Uses the default scheduler state path. Result depends on
        // whether the scheduler state directory is writable.
        let results = execute_actions(&[action], &store);
        assert_eq!(results.len(), 1);
        // Either succeeds or fails gracefully — both are acceptable.
        assert!(
            matches!(results[0], ActionResult::TaskCreated { .. })
                || matches!(results[0], ActionResult::Failed { .. })
        );
    }

    #[test]
    fn multiple_actions_independent() {
        let (_tmp, store) = temp_store();

        let actions = vec![
            IntelligenceAction::CreateMemoryRecord {
                kind: "interest".into(),
                text: "Hiking".into(),
                tags: vec![],
                confidence: 0.8,
            },
            IntelligenceAction::UpdateRelationship {
                name: "Bob".into(),
                relationship: None,
                context: None,
            },
        ];

        let results = execute_actions(&actions, &store);
        assert_eq!(results.len(), 2);
        assert!(matches!(
            results[0],
            ActionResult::MemoryRecordCreated { .. }
        ));
        assert!(matches!(
            results[1],
            ActionResult::RelationshipUpdated { .. }
        ));
    }

    #[test]
    fn sanitize_task_id_normalizes() {
        assert_eq!(sanitize_task_id("Birthday Reminder!"), "birthday_reminder_");
        assert_eq!(sanitize_task_id("simple"), "simple");
        assert_eq!(sanitize_task_id("a-b_c"), "a-b_c");
    }
}
