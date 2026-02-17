//! Pipeline-to-canvas bridge.
//!
//! Subscribes to [`RuntimeEvent`]s and converts them into
//! [`CanvasMessage`]s pushed to a [`CanvasBackend`].

use std::collections::HashMap;

use tracing::info;

use crate::pipeline::messages::ControlEvent;
use crate::runtime::{ConversationSnapshotEntryRole, RuntimeEvent};

use super::backend::CanvasBackend;
use super::session::CanvasSession;
use super::types::{CanvasMessage, MessageRole};

const MEMORY_WRITE_SUMMARY_THRESHOLD: usize = 5;

/// Bridges fae's pipeline events to the canvas scene graph.
pub struct CanvasBridge {
    session: Box<dyn CanvasBackend>,
    /// Accumulates assistant sentence chunks into a single message.
    pending_assistant_text: String,
    /// Whether the assistant is currently generating a response.
    generating: bool,
    /// Last message role pushed (for grouping tracking).
    last_role: Option<MessageRole>,
    /// Consecutive same-role message count.
    group_count: usize,
    /// Monotonic timestamp counter (ms) for message ordering.
    next_ts: u64,
    /// Pending tool inputs keyed by tool call ID (captured on ToolCall,
    /// consumed on ToolResult).
    pending_tool_inputs: HashMap<String, String>,
    /// Number of routine memory-write events suppressed from direct display.
    suppressed_memory_writes: usize,
}

impl CanvasBridge {
    /// Create a new bridge with a local canvas session.
    pub fn new(session_id: impl Into<String>, width: f32, height: f32) -> Self {
        Self::with_backend(Box::new(CanvasSession::new(session_id, width, height)))
    }

    /// Create a new bridge with an arbitrary backend.
    pub fn with_backend(backend: Box<dyn CanvasBackend>) -> Self {
        Self {
            session: backend,
            pending_assistant_text: String::new(),
            generating: false,
            last_role: None,
            group_count: 0,
            next_ts: 0,
            pending_tool_inputs: HashMap::new(),
            suppressed_memory_writes: 0,
        }
    }

    /// Reference to the underlying canvas backend.
    pub fn backend(&self) -> &dyn CanvasBackend {
        &*self.session
    }

    /// Mutable reference to the underlying canvas backend.
    pub fn backend_mut(&mut self) -> &mut dyn CanvasBackend {
        &mut *self.session
    }

    /// Reference to the underlying canvas session (backward compatibility).
    pub fn session(&self) -> &dyn CanvasBackend {
        &*self.session
    }

    /// Mutable reference to the underlying canvas session (backward compatibility).
    pub fn session_mut(&mut self) -> &mut dyn CanvasBackend {
        &mut *self.session
    }

    /// Number of consecutive messages with the same role.
    pub fn group_count(&self) -> usize {
        self.group_count
    }

    /// Process a pipeline runtime event, updating the canvas session.
    pub fn on_event(&mut self, event: &RuntimeEvent) {
        match event {
            RuntimeEvent::ConversationSnapshot { entries } => {
                self.reset_with_conversation_snapshot(entries);
            }

            RuntimeEvent::Transcription(t) if t.is_final => {
                self.push(MessageRole::User, &t.text);
            }

            RuntimeEvent::AssistantSentence(chunk) => {
                if !chunk.text.trim().is_empty() {
                    if !self.pending_assistant_text.is_empty() {
                        self.pending_assistant_text.push(' ');
                    }
                    self.pending_assistant_text.push_str(&chunk.text);
                }

                if chunk.is_final {
                    self.flush_assistant();
                }
            }

            RuntimeEvent::AssistantGenerating { active } => {
                self.generating = *active;
                if !active && !self.pending_assistant_text.is_empty() {
                    // Generation ended — flush any remaining text.
                    self.flush_assistant();
                }
            }

            RuntimeEvent::ToolCall {
                id,
                name,
                input_json,
            } => {
                // If this is a canvas_render call, parse the input and render
                // the element directly into the bridge's session so it appears
                // in the canvas window.
                if name == "canvas_render" {
                    self.try_render_tool_element(input_json);
                }

                // Store the input for attachment to the ToolResult message.
                self.pending_tool_inputs
                    .insert(id.clone(), input_json.clone());
                let text = format!("{name} called");
                self.push_tool(name, &text);
            }

            RuntimeEvent::ToolResult {
                id,
                name,
                success,
                output_text,
            } => {
                let status = if *success { "success" } else { "failed" };
                let text = format!("{name} \u{2192} {status}");
                let tool_input = self.pending_tool_inputs.remove(id);
                let details = output_text.clone().or_else(|| Some(status.to_owned()));
                self.push_tool_with_details(name, &text, tool_input, details);
            }

            RuntimeEvent::Control(ControlEvent::UserSpeechStart { .. }) => {
                if self.generating {
                    // Barge-in: flush pending with interrupted suffix.
                    if !self.pending_assistant_text.is_empty() {
                        self.pending_assistant_text.push_str(" [interrupted]");
                        self.flush_assistant();
                    }
                    self.push(MessageRole::System, "interrupted");
                    self.generating = false;
                }
            }

            RuntimeEvent::ToolExecuting { name } => {
                let text = format!("{name} running\u{2026}");
                self.push_tool(name, &text);
            }

            RuntimeEvent::MemoryRecall { .. } => {}

            RuntimeEvent::MemoryWrite { op, target_id } => {
                if op.contains("fail") || op.contains("error") {
                    self.flush_suppressed_memory_writes();
                    let text = match target_id {
                        Some(id) => format!("write {op} ({id})"),
                        None => format!("write {op}"),
                    };
                    self.push_tool("memory", &text);
                } else {
                    self.suppressed_memory_writes = self.suppressed_memory_writes.saturating_add(1);
                    if self.suppressed_memory_writes >= MEMORY_WRITE_SUMMARY_THRESHOLD {
                        self.flush_suppressed_memory_writes();
                    }
                }
            }

            RuntimeEvent::MemoryConflict {
                existing_id,
                replacement_id,
            } => {
                self.flush_suppressed_memory_writes();
                let text = match replacement_id {
                    Some(new_id) => format!("conflict resolved {existing_id} -> {new_id}"),
                    None => format!("conflict on {existing_id}"),
                };
                self.push_tool("memory", &text);
            }

            RuntimeEvent::MemoryMigration { from, to, success } => {
                if !success || from != to {
                    self.flush_suppressed_memory_writes();
                    let outcome = if *success { "succeeded" } else { "failed" };
                    let text = format!("migration {from} -> {to} {outcome}");
                    self.push_tool("memory", &text);
                }
            }

            // Control events, audio levels, model selection, and voice command
            // events don't produce canvas messages (handled elsewhere).
            RuntimeEvent::Control(_)
            | RuntimeEvent::AssistantAudioLevel { .. }
            | RuntimeEvent::AssistantViseme { .. }
            | RuntimeEvent::Transcription(_)
            | RuntimeEvent::ModelSelectionPrompt { .. }
            | RuntimeEvent::ModelSelected { .. }
            | RuntimeEvent::VoiceCommandDetected { .. }
            | RuntimeEvent::PermissionsChanged { .. }
            | RuntimeEvent::ModelSwitchRequested { .. }
            | RuntimeEvent::ConversationCanvasVisibility { .. }
            | RuntimeEvent::ProviderFallback { .. }
            | RuntimeEvent::MicStatus { .. }
            | RuntimeEvent::IntelligenceExtraction { .. }
            | RuntimeEvent::ProactiveBriefingReady { .. }
            | RuntimeEvent::RelationshipUpdate { .. }
            | RuntimeEvent::SkillProposal { .. }
            | RuntimeEvent::NoiseBudgetUpdate { .. } => {}
        }
    }

    fn reset_with_conversation_snapshot(
        &mut self,
        entries: &[crate::runtime::ConversationSnapshotEntry],
    ) {
        self.session.clear();
        self.pending_assistant_text.clear();
        self.generating = false;
        self.last_role = None;
        self.group_count = 0;
        self.next_ts = 0;
        self.pending_tool_inputs.clear();
        self.suppressed_memory_writes = 0;

        for entry in entries {
            let role = match entry.role {
                ConversationSnapshotEntryRole::User => MessageRole::User,
                ConversationSnapshotEntryRole::Assistant => MessageRole::Assistant,
            };
            self.push(role, &entry.text);
        }
    }

    /// Try to parse a `canvas_render` tool input and add the element to the
    /// bridge's session so it appears in the canvas window.
    fn try_render_tool_element(&mut self, input_json: &str) {
        use canvas_mcp::tools::RenderParams;

        // Try full RenderParams first (has session_id + content + position).
        let params: Option<RenderParams> = serde_json::from_str(input_json).ok();
        if let Some(params) = params {
            let element = crate::canvas::tools::render::render_content_to_element(&params);
            self.session.add_element(element);
            info!("bridge: rendered canvas_render element from ToolCall");
            return;
        }

        // Fallback: try parsing just as RenderContent (the content field only).
        use canvas_mcp::tools::{Position, RenderContent};
        let content: Option<RenderContent> = serde_json::from_str(input_json).ok();
        if let Some(content) = content {
            let params = RenderParams {
                session_id: "gui".to_owned(),
                content,
                position: Some(Position {
                    x: 0.0,
                    y: 0.0,
                    width: Some(600.0),
                    height: Some(400.0),
                }),
            };
            let element = crate::canvas::tools::render::render_content_to_element(&params);
            self.session.add_element(element);
            info!("bridge: rendered canvas_render element from RenderContent fallback");
        }
    }

    /// Flush accumulated assistant text as a single message.
    fn flush_assistant(&mut self) {
        let text = std::mem::take(&mut self.pending_assistant_text);
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return;
        }
        self.push(MessageRole::Assistant, trimmed);
    }

    /// Push a message and update grouping state.
    fn push(&mut self, role: MessageRole, text: &str) {
        if text.trim().is_empty() {
            return;
        }
        let ts = self.next_ts;
        self.next_ts += 1;

        if self.last_role == Some(role) {
            self.group_count += 1;
        } else {
            self.last_role = Some(role);
            self.group_count = 1;
        }

        let msg = CanvasMessage::new(role, text, ts);
        self.session.push_message(&msg);
    }

    /// Push a tool message.
    fn push_tool(&mut self, name: &str, text: &str) {
        if name.trim().is_empty() || text.trim().is_empty() {
            return;
        }
        let ts = self.next_ts;
        self.next_ts += 1;

        let role = MessageRole::Tool;
        if self.last_role == Some(role) {
            self.group_count += 1;
        } else {
            self.last_role = Some(role);
            self.group_count = 1;
        }

        let msg = CanvasMessage::tool(name, text, ts);
        self.session.push_message(&msg);
    }

    /// Push a tool message with input/result details.
    fn push_tool_with_details(
        &mut self,
        name: &str,
        text: &str,
        tool_input: Option<String>,
        tool_result_text: Option<String>,
    ) {
        let ts = self.next_ts;
        self.next_ts += 1;

        let role = MessageRole::Tool;
        if self.last_role == Some(role) {
            self.group_count += 1;
        } else {
            self.last_role = Some(role);
            self.group_count = 1;
        }

        let msg = CanvasMessage::tool_with_details(name, text, ts, tool_input, tool_result_text);
        self.session.push_message(&msg);
    }

    fn flush_suppressed_memory_writes(&mut self) {
        if self.suppressed_memory_writes == 0 {
            return;
        }
        let count = self.suppressed_memory_writes;
        self.suppressed_memory_writes = 0;
        let text = format!("maintenance writes ({count} ops, details suppressed)");
        self.push_tool("memory", &text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::messages::{SentenceChunk, Transcription};
    use std::time::Instant;

    fn make_transcription(text: &str, is_final: bool) -> RuntimeEvent {
        RuntimeEvent::Transcription(Transcription {
            text: text.to_string(),
            is_final,
            voiceprint: None,
            audio_captured_at: Instant::now(),
            transcribed_at: Instant::now(),
        })
    }

    fn make_sentence(text: &str, is_final: bool) -> RuntimeEvent {
        RuntimeEvent::AssistantSentence(SentenceChunk {
            text: text.to_string(),
            is_final,
        })
    }

    #[test]
    fn test_new_bridge() {
        let b = CanvasBridge::new("test", 800.0, 600.0);
        assert_eq!(b.session().session_id(), "test");
        assert_eq!(b.session().message_count(), 0);
    }

    #[test]
    fn test_final_transcription_creates_user_message() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_transcription("Hello world", true));
        assert_eq!(b.session().message_count(), 1);
    }

    #[test]
    fn test_partial_transcription_ignored() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_transcription("Hel", false));
        assert_eq!(b.session().message_count(), 0);
    }

    #[test]
    fn test_single_sentence_assistant() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_sentence("Hi there!", true));
        assert_eq!(b.session().message_count(), 1);
    }

    #[test]
    fn test_multi_chunk_accumulation() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_sentence("First sentence.", false));
        b.on_event(&make_sentence("Second sentence.", true));
        // Should produce a single message with both sentences.
        assert_eq!(b.session().message_count(), 1);

        let html = b.session().to_html();
        assert!(html.contains("First sentence. Second sentence."));
    }

    #[test]
    fn test_tool_call_and_result() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::ToolCall {
            id: "call-1".into(),
            name: "search".into(),
            input_json: "{}".into(),
        });
        b.on_event(&RuntimeEvent::ToolResult {
            id: "call-1".into(),
            name: "search".into(),
            success: true,
            output_text: None,
        });
        assert_eq!(b.session().message_count(), 2);

        let html = b.session().to_html();
        assert!(html.contains("[search] search called"));
        assert!(html.contains("search \u{2192} success"));
    }

    #[test]
    fn test_tool_result_failure() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::ToolResult {
            id: "call-1".into(),
            name: "fetch".into(),
            success: false,
            output_text: None,
        });
        let html = b.session().to_html();
        assert!(html.contains("fetch \u{2192} failed"));
    }

    #[test]
    fn test_barge_in_during_generation() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);

        // Start generating
        b.on_event(&RuntimeEvent::AssistantGenerating { active: true });
        b.on_event(&make_sentence("I was saying", false));

        // User speaks (barge-in)
        b.on_event(&RuntimeEvent::Control(ControlEvent::UserSpeechStart {
            captured_at: Instant::now(),
            rms: 0.5,
        }));

        // Should have: interrupted assistant text + system "interrupted"
        assert_eq!(b.session().message_count(), 2);
        let html = b.session().to_html();
        assert!(html.contains("[interrupted]"));
        assert!(html.contains("interrupted"));
    }

    #[test]
    fn test_no_barge_in_when_idle() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);

        // User speaks but assistant is NOT generating
        b.on_event(&RuntimeEvent::Control(ControlEvent::UserSpeechStart {
            captured_at: Instant::now(),
            rms: 0.5,
        }));

        // No messages should be created
        assert_eq!(b.session().message_count(), 0);
    }

    #[test]
    fn test_generation_end_flushes_pending() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::AssistantGenerating { active: true });
        b.on_event(&make_sentence("Pending text", false));

        // End generation without a final chunk
        b.on_event(&RuntimeEvent::AssistantGenerating { active: false });

        assert_eq!(b.session().message_count(), 1);
    }

    #[test]
    fn test_grouping_same_role() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_transcription("msg1", true));
        assert_eq!(b.group_count(), 1);
        b.on_event(&make_transcription("msg2", true));
        assert_eq!(b.group_count(), 2);
    }

    #[test]
    fn test_grouping_role_switch_resets() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_transcription("user", true));
        assert_eq!(b.group_count(), 1);
        b.on_event(&make_sentence("assistant", true));
        assert_eq!(b.group_count(), 1); // Reset to 1 for new role
    }

    #[test]
    fn test_full_conversation_flow() {
        let mut b = CanvasBridge::new("conv", 800.0, 600.0);

        // User speaks
        b.on_event(&make_transcription("What's the weather?", true));

        // Tool call
        b.on_event(&RuntimeEvent::ToolCall {
            id: "call-1".into(),
            name: "weather".into(),
            input_json: "{\"city\":\"London\"}".into(),
        });
        b.on_event(&RuntimeEvent::ToolResult {
            id: "call-1".into(),
            name: "weather".into(),
            success: true,
            output_text: None,
        });

        // Assistant responds
        b.on_event(&RuntimeEvent::AssistantGenerating { active: true });
        b.on_event(&make_sentence("It's sunny in London.", true));
        b.on_event(&RuntimeEvent::AssistantGenerating { active: false });

        // 1 user + 2 tool + 1 assistant = 4 messages
        assert_eq!(b.session().message_count(), 4);

        let html = b.session().to_html();
        assert!(html.contains("the weather?"));
        assert!(html.contains("[weather] weather called"));
        assert!(html.contains("sunny in London"));
    }

    #[test]
    fn test_audio_level_ignored() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::AssistantAudioLevel { rms: 0.5 });
        assert_eq!(b.session().message_count(), 0);
    }

    #[test]
    fn test_empty_session_html() {
        let b = CanvasBridge::new("t", 800.0, 600.0);
        let html = b.session().to_html();
        assert!(html.contains("canvas-messages"));
        assert!(!html.contains("canvas-tools"));
    }

    #[test]
    fn test_canvas_render_tool_call_adds_element() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);

        // Simulate a canvas_render ToolCall with valid RenderParams JSON.
        let input_json = serde_json::json!({
            "session_id": "gui",
            "content": {
                "type": "Text",
                "data": {
                    "content": "Hello from canvas",
                    "font_size": 16.0
                }
            }
        })
        .to_string();

        b.on_event(&RuntimeEvent::ToolCall {
            id: "call-1".into(),
            name: "canvas_render".into(),
            input_json,
        });

        // Should have 1 tool message + 1 scene element (the rendered text).
        assert_eq!(b.session().message_count(), 1); // The tool call message
        assert_eq!(b.session().element_count(), 2); // message + rendered element

        // The rendered element should appear in tool_elements_html.
        let tools_html = b.session().tool_elements_html();
        assert!(tools_html.contains("Hello from canvas"));
    }

    #[test]
    fn test_canvas_render_with_render_content_json() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);

        // Simulate a ToolCall with just RenderContent (no session_id wrapper).
        let input_json = serde_json::json!({
            "type": "Chart",
            "data": {
                "chart_type": "bar",
                "data": {"labels": ["A", "B"], "values": [10, 20]},
                "title": "Test Chart"
            }
        })
        .to_string();

        b.on_event(&RuntimeEvent::ToolCall {
            id: "call-1".into(),
            name: "canvas_render".into(),
            input_json,
        });

        // The chart element should be in the scene.
        assert_eq!(b.session().element_count(), 2); // message + chart
        let tools_html = b.session().tool_elements_html();
        assert!(!tools_html.is_empty());
    }

    #[test]
    fn test_non_canvas_tool_call_ignored() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);

        // A non-canvas tool call should NOT add an element.
        b.on_event(&RuntimeEvent::ToolCall {
            id: "call-1".into(),
            name: "search".into(),
            input_json: "{}".into(),
        });

        assert_eq!(b.session().message_count(), 1); // Just the tool message
        assert_eq!(b.session().element_count(), 1); // Only the message element
    }

    #[test]
    fn test_memory_write_events_are_collapsed() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        for _ in 0..5 {
            b.on_event(&RuntimeEvent::MemoryWrite {
                op: "reflect".into(),
                target_id: None,
            });
        }

        assert_eq!(b.session().message_count(), 1);
        let html = b.session().to_html();
        assert!(html.contains("[memory]"));
        assert!(html.contains("maintenance writes (5 ops, details suppressed)"));
    }

    #[test]
    fn test_memory_migration_event_adds_canvas_message() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::MemoryMigration {
            from: 0,
            to: 1,
            success: false,
        });

        assert_eq!(b.session().message_count(), 1);
        let html = b.session().to_html();
        assert!(html.contains("[memory]"));
        assert!(html.contains("migration"));
        assert!(html.contains("failed"));
    }

    #[test]
    fn test_memory_conflict_flushes_suppressed_writes() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::MemoryWrite {
            op: "reindex".into(),
            target_id: None,
        });
        b.on_event(&RuntimeEvent::MemoryWrite {
            op: "reflect".into(),
            target_id: None,
        });
        b.on_event(&RuntimeEvent::MemoryConflict {
            existing_id: "old".into(),
            replacement_id: Some("new".into()),
        });

        assert_eq!(b.session().message_count(), 2);
        let html = b.session().to_html();
        assert!(html.contains("maintenance writes (2 ops, details suppressed)"));
        assert!(html.contains("conflict resolved old"));
        assert!(html.contains("new"));
    }

    #[test]
    fn test_memory_migration_noop_success_is_suppressed() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&RuntimeEvent::MemoryMigration {
            from: 1,
            to: 1,
            success: true,
        });
        assert_eq!(b.session().message_count(), 0);
    }

    #[test]
    fn test_conversation_snapshot_replaces_canvas_messages() {
        let mut b = CanvasBridge::new("t", 800.0, 600.0);
        b.on_event(&make_transcription("old user message", true));
        b.on_event(&make_sentence("old assistant message", true));
        assert_eq!(b.session().message_count(), 2);

        let entries = vec![
            crate::runtime::ConversationSnapshotEntry {
                role: crate::runtime::ConversationSnapshotEntryRole::User,
                text: "new user".to_owned(),
            },
            crate::runtime::ConversationSnapshotEntry {
                role: crate::runtime::ConversationSnapshotEntryRole::Assistant,
                text: "new assistant".to_owned(),
            },
        ];
        b.on_event(&RuntimeEvent::ConversationSnapshot { entries });

        let html = b.session().to_html();
        assert_eq!(b.session().message_count(), 2);
        assert!(html.contains("new user"));
        assert!(html.contains("new assistant"));
        assert!(!html.contains("old user message"));
        assert!(!html.contains("old assistant message"));
    }
}
