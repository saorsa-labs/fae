//! Conversation turn tracking and snapshot building.
//!
//! Extracted from `coordinator.rs` — these are pure helpers for managing
//! the in-memory conversation history during a pipeline run.

use tracing::warn;

use crate::memory::MemoryOrchestrator;
use crate::runtime::{ConversationSnapshotEntry, ConversationSnapshotEntryRole, RuntimeEvent};
use tokio::sync::broadcast;

/// A single user/assistant exchange in the current conversation.
#[derive(Debug, Clone)]
pub(crate) struct ConversationTurn {
    pub(crate) user_text: String,
    pub(crate) assistant_text: String,
}

/// Append a new conversation turn to the history.
pub(crate) fn append_conversation_turn(
    turns: &mut Vec<ConversationTurn>,
    user_text: String,
    assistant_text: String,
) {
    turns.push(ConversationTurn {
        user_text,
        assistant_text,
    });
}

/// Convert conversation turns into snapshot entries for the runtime event bus.
pub(crate) fn build_conversation_snapshot_entries(
    turns: &[ConversationTurn],
) -> Vec<ConversationSnapshotEntry> {
    let mut entries = Vec::with_capacity(turns.len().saturating_mul(2));
    for turn in turns {
        if !turn.user_text.trim().is_empty() {
            entries.push(ConversationSnapshotEntry {
                role: ConversationSnapshotEntryRole::User,
                text: turn.user_text.clone(),
            });
        }
        if !turn.assistant_text.trim().is_empty() {
            entries.push(ConversationSnapshotEntry {
                role: ConversationSnapshotEntryRole::Assistant,
                text: turn.assistant_text.clone(),
            });
        }
    }
    entries
}

/// Build a short conversation context for the background agent.
///
/// Takes the last `max_turns` turns and formats them as a readable summary
/// so the background agent has continuity with the voice conversation.
pub(crate) fn build_background_context(turns: &[ConversationTurn], max_turns: usize) -> String {
    let recent = if turns.len() > max_turns {
        &turns[turns.len() - max_turns..]
    } else {
        turns
    };
    if recent.is_empty() {
        return String::new();
    }
    let mut ctx = String::from("Recent conversation:\n");
    for turn in recent {
        if !turn.user_text.trim().is_empty() {
            ctx.push_str(&format!("User: {}\n", turn.user_text.trim()));
        }
        if !turn.assistant_text.trim().is_empty() {
            ctx.push_str(&format!("Fae: {}\n", turn.assistant_text.trim()));
        }
    }
    ctx
}

/// Capture a completed turn into the memory system and emit runtime events.
pub(crate) fn capture_memory_turn(
    memory_orchestrator: Option<&MemoryOrchestrator>,
    runtime_tx: Option<&broadcast::Sender<RuntimeEvent>>,
    turn_id: &str,
    user_text: &str,
    assistant_text: &str,
) {
    if let Some(memory) = memory_orchestrator {
        match memory.capture_turn(turn_id, user_text, assistant_text) {
            Ok(report) => {
                if let Some(rt) = runtime_tx {
                    for write in &report.writes {
                        let _ = rt.send(RuntimeEvent::MemoryWrite {
                            op: write.op.clone(),
                            target_id: write.target_id.clone(),
                        });
                    }
                    for conflict in &report.conflicts {
                        let _ = rt.send(RuntimeEvent::MemoryConflict {
                            existing_id: conflict.existing_id.clone(),
                            replacement_id: conflict.replacement_id.clone(),
                        });
                    }
                }
            }
            Err(e) => warn!("memory capture failed: {e}"),
        }
    }
}
