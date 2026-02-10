//! Pipeline-to-canvas bridge.
//!
//! Subscribes to [`RuntimeEvent`]s and converts them into
//! [`CanvasMessage`]s pushed to a [`CanvasSession`].

use crate::pipeline::messages::ControlEvent;
use crate::runtime::RuntimeEvent;

use super::session::CanvasSession;
use super::types::{CanvasMessage, MessageRole};

/// Bridges fae's pipeline events to the canvas scene graph.
pub struct CanvasBridge {
    session: CanvasSession,
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
}

impl CanvasBridge {
    /// Create a new bridge with the given session dimensions.
    pub fn new(session_id: impl Into<String>, width: f32, height: f32) -> Self {
        Self {
            session: CanvasSession::new(session_id, width, height),
            pending_assistant_text: String::new(),
            generating: false,
            last_role: None,
            group_count: 0,
            next_ts: 0,
        }
    }

    /// Reference to the underlying canvas session.
    pub fn session(&self) -> &CanvasSession {
        &self.session
    }

    /// Number of consecutive messages with the same role.
    pub fn group_count(&self) -> usize {
        self.group_count
    }

    /// Process a pipeline runtime event, updating the canvas session.
    pub fn on_event(&mut self, event: &RuntimeEvent) {
        match event {
            RuntimeEvent::Transcription(t) if t.is_final => {
                self.push(MessageRole::User, &t.text);
            }

            RuntimeEvent::AssistantSentence(chunk) => {
                if !self.pending_assistant_text.is_empty() {
                    self.pending_assistant_text.push(' ');
                }
                self.pending_assistant_text.push_str(&chunk.text);

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

            RuntimeEvent::ToolCall { name, .. } => {
                let text = format!("{name} called");
                self.push_tool(name, &text);
            }

            RuntimeEvent::ToolResult { name, success } => {
                let status = if *success { "success" } else { "failed" };
                let text = format!("{name} \u{2192} {status}");
                self.push_tool(name, &text);
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

            // Control events and audio levels don't produce canvas messages.
            RuntimeEvent::Control(_)
            | RuntimeEvent::AssistantAudioLevel { .. }
            | RuntimeEvent::Transcription(_) => {}
        }
    }

    /// Flush accumulated assistant text as a single message.
    fn flush_assistant(&mut self) {
        if self.pending_assistant_text.is_empty() {
            return;
        }
        let text = std::mem::take(&mut self.pending_assistant_text);
        self.push(MessageRole::Assistant, &text);
    }

    /// Push a message and update grouping state.
    fn push(&mut self, role: MessageRole, text: &str) {
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
            name: "search".into(),
            input_json: "{}".into(),
        });
        b.on_event(&RuntimeEvent::ToolResult {
            name: "search".into(),
            success: true,
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
            name: "fetch".into(),
            success: false,
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
            name: "weather".into(),
            input_json: "{\"city\":\"London\"}".into(),
        });
        b.on_event(&RuntimeEvent::ToolResult {
            name: "weather".into(),
            success: true,
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
}
