//! Stream accumulator for collecting LLM events into structured turn data.
//!
//! The [`StreamAccumulator`] processes a sequence of [`LlmEvent`]s and
//! collects them into an [`AccumulatedTurn`] containing full text,
//! thinking output, and completed tool calls.
//!
//! # Usage
//!
//! ```
//! use fae::fae_llm::agent::accumulator::StreamAccumulator;
//! use fae::fae_llm::events::{LlmEvent, FinishReason};
//! use fae::fae_llm::types::ModelRef;
//!
//! let mut acc = StreamAccumulator::new();
//! acc.push(LlmEvent::StreamStart {
//!     request_id: "req-1".into(),
//!     model: ModelRef::new("gpt-4o"),
//! });
//! acc.push(LlmEvent::TextDelta { text: "Hello!".into() });
//! acc.push(LlmEvent::StreamEnd { finish_reason: FinishReason::Stop });
//!
//! let turn = acc.finish();
//! assert_eq!(turn.text, "Hello!");
//! ```

use std::collections::HashMap;

use crate::fae_llm::events::{FinishReason, LlmEvent};

/// A completed tool call extracted from the event stream.
///
/// Contains the accumulated call ID, function name, and full JSON
/// arguments string reassembled from streaming deltas.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccumulatedToolCall {
    /// The unique call ID from the LLM.
    pub call_id: String,
    /// The function name being called.
    pub function_name: String,
    /// The full JSON arguments string (reassembled from deltas).
    pub arguments_json: String,
}

/// The result of accumulating a complete LLM response stream.
///
/// Contains all text, thinking, tool calls, and stream metadata
/// from one provider round-trip.
#[derive(Debug, Clone)]
pub struct AccumulatedTurn {
    /// Full text output (all TextDelta concatenated).
    pub text: String,
    /// Full thinking/reasoning output (all ThinkingDelta concatenated).
    pub thinking: String,
    /// Completed tool calls with reassembled arguments.
    pub tool_calls: Vec<AccumulatedToolCall>,
    /// Why the stream ended.
    pub finish_reason: FinishReason,
    /// Error message if the stream encountered an error.
    pub error: Option<String>,
}

/// In-progress tool call being accumulated from streaming deltas.
#[derive(Debug)]
struct ToolCallInProgress {
    call_id: String,
    function_name: String,
    args_buffer: String,
}

/// Accumulates [`LlmEvent`]s into structured turn data.
///
/// Feed events one at a time with [`push()`](Self::push), then call
/// [`finish()`](Self::finish) to get the completed [`AccumulatedTurn`].
///
/// Handles parallel tool calls (multiple call_ids in the same stream)
/// by tracking each in-progress call independently.
#[derive(Debug)]
pub struct StreamAccumulator {
    text: String,
    thinking: String,
    /// In-progress tool calls indexed by call_id.
    tool_calls_in_progress: HashMap<String, ToolCallInProgress>,
    /// Completed tool calls in order of completion.
    completed_tool_calls: Vec<AccumulatedToolCall>,
    /// Order of tool call starts for deterministic completion ordering.
    call_order: Vec<String>,
    finish_reason: Option<FinishReason>,
    error: Option<String>,
}

impl StreamAccumulator {
    /// Create a new empty accumulator.
    pub fn new() -> Self {
        Self {
            text: String::new(),
            thinking: String::new(),
            tool_calls_in_progress: HashMap::new(),
            completed_tool_calls: Vec::new(),
            call_order: Vec::new(),
            finish_reason: None,
            error: None,
        }
    }

    /// Push an event into the accumulator.
    ///
    /// Events should be pushed in the order they arrive from the stream.
    pub fn push(&mut self, event: LlmEvent) {
        match event {
            LlmEvent::StreamStart { .. } => {
                // Start of stream — nothing to accumulate
            }
            LlmEvent::TextDelta { text } => {
                self.text.push_str(&text);
            }
            LlmEvent::ThinkingStart | LlmEvent::ThinkingEnd => {
                // Markers only — no content to accumulate
            }
            LlmEvent::ThinkingDelta { text } => {
                self.thinking.push_str(&text);
            }
            LlmEvent::ToolCallStart {
                call_id,
                function_name,
            } => {
                self.call_order.push(call_id.clone());
                self.tool_calls_in_progress.insert(
                    call_id.clone(),
                    ToolCallInProgress {
                        call_id,
                        function_name,
                        args_buffer: String::new(),
                    },
                );
            }
            LlmEvent::ToolCallArgsDelta {
                call_id,
                args_fragment,
            } => {
                if let Some(tc) = self.tool_calls_in_progress.get_mut(&call_id) {
                    tc.args_buffer.push_str(&args_fragment);
                }
            }
            LlmEvent::ToolCallEnd { call_id } => {
                if let Some(tc) = self.tool_calls_in_progress.remove(&call_id) {
                    self.completed_tool_calls.push(AccumulatedToolCall {
                        call_id: tc.call_id,
                        function_name: tc.function_name,
                        arguments_json: tc.args_buffer,
                    });
                }
            }
            LlmEvent::StreamEnd { finish_reason } => {
                self.finish_reason = Some(finish_reason);
            }
            LlmEvent::StreamError { error } => {
                self.error = Some(error);
            }
        }
    }

    /// Consume the accumulator and return the completed turn.
    ///
    /// Any tool calls still in progress are completed with whatever
    /// arguments have been accumulated so far.
    pub fn finish(mut self) -> AccumulatedTurn {
        // Complete any remaining in-progress tool calls (in order of start)
        for call_id in &self.call_order {
            if let Some(tc) = self.tool_calls_in_progress.remove(call_id) {
                self.completed_tool_calls.push(AccumulatedToolCall {
                    call_id: tc.call_id,
                    function_name: tc.function_name,
                    arguments_json: tc.args_buffer,
                });
            }
        }

        // Sort completed tool calls by their start order
        let order_map: HashMap<&str, usize> = self
            .call_order
            .iter()
            .enumerate()
            .map(|(i, id)| (id.as_str(), i))
            .collect();
        self.completed_tool_calls.sort_by_key(|tc| {
            order_map
                .get(tc.call_id.as_str())
                .copied()
                .unwrap_or(usize::MAX)
        });

        AccumulatedTurn {
            text: self.text,
            thinking: self.thinking,
            tool_calls: self.completed_tool_calls,
            finish_reason: self.finish_reason.unwrap_or(FinishReason::Other),
            error: self.error,
        }
    }
}

impl Default for StreamAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::types::ModelRef;

    fn stream_start() -> LlmEvent {
        LlmEvent::StreamStart {
            request_id: "req-1".into(),
            model: ModelRef::new("test-model"),
        }
    }

    // ── Text-only stream ─────────────────────────────────────

    #[test]
    fn accumulate_text_only() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::TextDelta {
            text: "Hello ".into(),
        });
        acc.push(LlmEvent::TextDelta {
            text: "world!".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::Stop,
        });

        let turn = acc.finish();
        assert_eq!(turn.text, "Hello world!");
        assert!(turn.thinking.is_empty());
        assert!(turn.tool_calls.is_empty());
        assert_eq!(turn.finish_reason, FinishReason::Stop);
        assert!(turn.error.is_none());
    }

    // ── Thinking + text stream ───────────────────────────────

    #[test]
    fn accumulate_thinking_and_text() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::ThinkingStart);
        acc.push(LlmEvent::ThinkingDelta {
            text: "Step 1. ".into(),
        });
        acc.push(LlmEvent::ThinkingDelta {
            text: "Step 2.".into(),
        });
        acc.push(LlmEvent::ThinkingEnd);
        acc.push(LlmEvent::TextDelta {
            text: "The answer is 42.".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::Stop,
        });

        let turn = acc.finish();
        assert_eq!(turn.thinking, "Step 1. Step 2.");
        assert_eq!(turn.text, "The answer is 42.");
        assert!(turn.tool_calls.is_empty());
    }

    // ── Single tool call ─────────────────────────────────────

    #[test]
    fn accumulate_single_tool_call() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::TextDelta {
            text: "Let me read that.".into(),
        });
        acc.push(LlmEvent::ToolCallStart {
            call_id: "call_1".into(),
            function_name: "read".into(),
        });
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "call_1".into(),
            args_fragment: r#"{"path":"#.into(),
        });
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "call_1".into(),
            args_fragment: r#""src/main.rs"}"#.into(),
        });
        acc.push(LlmEvent::ToolCallEnd {
            call_id: "call_1".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::ToolCalls,
        });

        let turn = acc.finish();
        assert_eq!(turn.text, "Let me read that.");
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.tool_calls[0].call_id, "call_1");
        assert_eq!(turn.tool_calls[0].function_name, "read");
        assert_eq!(
            turn.tool_calls[0].arguments_json,
            r#"{"path":"src/main.rs"}"#
        );
        assert_eq!(turn.finish_reason, FinishReason::ToolCalls);
    }

    // ── Parallel tool calls ──────────────────────────────────

    #[test]
    fn accumulate_parallel_tool_calls() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::ToolCallStart {
            call_id: "call_1".into(),
            function_name: "read".into(),
        });
        acc.push(LlmEvent::ToolCallStart {
            call_id: "call_2".into(),
            function_name: "bash".into(),
        });
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "call_1".into(),
            args_fragment: r#"{"path":"a.rs"}"#.into(),
        });
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "call_2".into(),
            args_fragment: r#"{"command":"ls"}"#.into(),
        });
        acc.push(LlmEvent::ToolCallEnd {
            call_id: "call_1".into(),
        });
        acc.push(LlmEvent::ToolCallEnd {
            call_id: "call_2".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::ToolCalls,
        });

        let turn = acc.finish();
        assert_eq!(turn.tool_calls.len(), 2);
        // Preserved in start order
        assert_eq!(turn.tool_calls[0].call_id, "call_1");
        assert_eq!(turn.tool_calls[0].function_name, "read");
        assert_eq!(turn.tool_calls[1].call_id, "call_2");
        assert_eq!(turn.tool_calls[1].function_name, "bash");
    }

    // ── Stream error ─────────────────────────────────────────

    #[test]
    fn accumulate_stream_error() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::TextDelta {
            text: "partial".into(),
        });
        acc.push(LlmEvent::StreamError {
            error: "connection reset".into(),
        });

        let turn = acc.finish();
        assert_eq!(turn.text, "partial");
        assert_eq!(turn.error.as_deref(), Some("connection reset"));
        assert_eq!(turn.finish_reason, FinishReason::Other);
    }

    // ── Empty stream ─────────────────────────────────────────

    #[test]
    fn accumulate_empty_stream() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::Stop,
        });

        let turn = acc.finish();
        assert!(turn.text.is_empty());
        assert!(turn.thinking.is_empty());
        assert!(turn.tool_calls.is_empty());
        assert_eq!(turn.finish_reason, FinishReason::Stop);
    }

    // ── No events at all ─────────────────────────────────────

    #[test]
    fn accumulate_no_events() {
        let acc = StreamAccumulator::new();
        let turn = acc.finish();
        assert!(turn.text.is_empty());
        assert_eq!(turn.finish_reason, FinishReason::Other);
    }

    // ── Incomplete tool call (no ToolCallEnd) ────────────────

    #[test]
    fn accumulate_incomplete_tool_call() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::ToolCallStart {
            call_id: "call_1".into(),
            function_name: "read".into(),
        });
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "call_1".into(),
            args_fragment: r#"{"path":"partial"#.into(),
        });
        // No ToolCallEnd — stream ended abruptly
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::Other,
        });

        let turn = acc.finish();
        // Incomplete tool call should still be included
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.tool_calls[0].call_id, "call_1");
        assert_eq!(turn.tool_calls[0].arguments_json, r#"{"path":"partial"#);
    }

    // ── Args delta for unknown call_id ───────────────────────

    #[test]
    fn args_delta_unknown_call_id_ignored() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "nonexistent".into(),
            args_fragment: "ignored".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::Stop,
        });

        let turn = acc.finish();
        assert!(turn.tool_calls.is_empty());
    }

    // ── Tool call end for unknown call_id ────────────────────

    #[test]
    fn tool_call_end_unknown_call_id_ignored() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::ToolCallEnd {
            call_id: "nonexistent".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::Stop,
        });

        let turn = acc.finish();
        assert!(turn.tool_calls.is_empty());
    }

    // ── Full multi-block stream ──────────────────────────────

    #[test]
    fn accumulate_thinking_text_and_tool() {
        let mut acc = StreamAccumulator::new();
        acc.push(stream_start());
        acc.push(LlmEvent::ThinkingStart);
        acc.push(LlmEvent::ThinkingDelta {
            text: "Planning...".into(),
        });
        acc.push(LlmEvent::ThinkingEnd);
        acc.push(LlmEvent::TextDelta {
            text: "Let me check.".into(),
        });
        acc.push(LlmEvent::ToolCallStart {
            call_id: "call_1".into(),
            function_name: "bash".into(),
        });
        acc.push(LlmEvent::ToolCallArgsDelta {
            call_id: "call_1".into(),
            args_fragment: r#"{"command":"ls"}"#.into(),
        });
        acc.push(LlmEvent::ToolCallEnd {
            call_id: "call_1".into(),
        });
        acc.push(LlmEvent::StreamEnd {
            finish_reason: FinishReason::ToolCalls,
        });

        let turn = acc.finish();
        assert_eq!(turn.thinking, "Planning...");
        assert_eq!(turn.text, "Let me check.");
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.finish_reason, FinishReason::ToolCalls);
    }

    // ── Clone and Debug ──────────────────────────────────────

    #[test]
    fn accumulated_tool_call_clone() {
        let tc = AccumulatedToolCall {
            call_id: "c1".into(),
            function_name: "read".into(),
            arguments_json: "{}".into(),
        };
        let cloned = tc.clone();
        assert_eq!(tc, cloned);
    }

    #[test]
    fn accumulated_turn_clone() {
        let turn = AccumulatedTurn {
            text: "test".into(),
            thinking: String::new(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            error: None,
        };
        let cloned = turn.clone();
        assert_eq!(cloned.text, "test");
    }

    #[test]
    fn stream_accumulator_debug() {
        let acc = StreamAccumulator::new();
        let debug = format!("{acc:?}");
        assert!(debug.contains("StreamAccumulator"));
    }

    #[test]
    fn accumulated_turn_debug() {
        let turn = AccumulatedTurn {
            text: "hi".into(),
            thinking: String::new(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            error: None,
        };
        let debug = format!("{turn:?}");
        assert!(debug.contains("AccumulatedTurn"));
    }

    #[test]
    fn stream_accumulator_default() {
        let acc = StreamAccumulator::default();
        let turn = acc.finish();
        assert!(turn.text.is_empty());
    }

    // ── Send + Sync ──────────────────────────────────────────

    #[test]
    fn accumulator_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AccumulatedToolCall>();
        assert_send_sync::<AccumulatedTurn>();
        assert_send_sync::<StreamAccumulator>();
    }
}
