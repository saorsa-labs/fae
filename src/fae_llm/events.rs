//! Normalized streaming event model for LLM providers.
//!
//! All LLM providers normalize their streaming output to [`LlmEvent`],
//! providing a consistent interface regardless of the underlying API.
//!
//! # Event Stream Lifecycle
//!
//! A typical stream flows:
//! ```text
//! StreamStart → TextDelta* → StreamEnd
//! ```
//!
//! With reasoning:
//! ```text
//! StreamStart → ThinkingStart → ThinkingDelta* → ThinkingEnd → TextDelta* → StreamEnd
//! ```
//!
//! With tool calls:
//! ```text
//! StreamStart → ToolCallStart → ToolCallArgsDelta* → ToolCallEnd → StreamEnd
//! ```
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::events::{LlmEvent, FinishReason};
//! use fae::fae_llm::types::ModelRef;
//!
//! let start = LlmEvent::StreamStart {
//!     request_id: "req-001".into(),
//!     model: ModelRef::new("gpt-4o"),
//! };
//!
//! let delta = LlmEvent::TextDelta {
//!     text: "Hello".into(),
//! };
//!
//! let end = LlmEvent::StreamEnd {
//!     finish_reason: FinishReason::Stop,
//! };
//! ```

use super::types::ModelRef;

/// A normalized streaming event from any LLM provider.
///
/// Events arrive in temporal order during streaming. Each event
/// represents a discrete unit of the model's output.
#[derive(Debug, Clone, PartialEq)]
pub enum LlmEvent {
    /// Stream has started. First event in every stream.
    StreamStart {
        /// Unique identifier for this request.
        request_id: String,
        /// The model being used.
        model: ModelRef,
    },

    /// A chunk of generated text.
    TextDelta {
        /// The text fragment.
        text: String,
    },

    /// The model has started a thinking/reasoning block.
    ThinkingStart,

    /// A chunk of thinking/reasoning text.
    ThinkingDelta {
        /// The thinking text fragment.
        text: String,
    },

    /// The model has finished its thinking/reasoning block.
    ThinkingEnd,

    /// A tool call has started.
    ToolCallStart {
        /// Unique identifier linking all events for this tool call.
        call_id: String,
        /// The name of the function being called.
        function_name: String,
    },

    /// A chunk of tool call arguments (streaming JSON).
    ToolCallArgsDelta {
        /// Identifier linking this delta to its [`ToolCallStart`](LlmEvent::ToolCallStart).
        call_id: String,
        /// A fragment of the JSON arguments string.
        args_fragment: String,
    },

    /// A tool call's arguments are complete.
    ToolCallEnd {
        /// Identifier linking this end to its [`ToolCallStart`](LlmEvent::ToolCallStart).
        call_id: String,
    },

    /// Stream has ended normally.
    StreamEnd {
        /// Why the model stopped generating.
        finish_reason: FinishReason,
    },

    /// Stream encountered an error.
    StreamError {
        /// Description of what went wrong.
        error: String,
    },
}

/// The reason the model stopped generating output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    /// Natural stop (end of response).
    Stop,
    /// Hit the max token limit.
    Length,
    /// Model wants to call one or more tools.
    ToolCalls,
    /// Content was filtered by safety systems.
    ContentFilter,
    /// Request was cancelled by the caller.
    Cancelled,
    /// Provider-specific or unknown reason.
    Other,
}

impl std::fmt::Display for FinishReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Stop => write!(f, "stop"),
            Self::Length => write!(f, "length"),
            Self::ToolCalls => write!(f, "tool_calls"),
            Self::ContentFilter => write!(f, "content_filter"),
            Self::Cancelled => write!(f, "cancelled"),
            Self::Other => write!(f, "other"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::types::ModelRef;

    // ── LlmEvent construction ─────────────────────────────────

    #[test]
    fn stream_start_construction() {
        let event = LlmEvent::StreamStart {
            request_id: "req-001".into(),
            model: ModelRef::new("gpt-4o"),
        };
        match &event {
            LlmEvent::StreamStart { request_id, model } => {
                assert_eq!(request_id, "req-001");
                assert_eq!(model.model_id, "gpt-4o");
            }
            _ => unreachable!("expected StreamStart"),
        }
    }

    #[test]
    fn text_delta_construction() {
        let event = LlmEvent::TextDelta {
            text: "Hello world".into(),
        };
        match &event {
            LlmEvent::TextDelta { text } => assert_eq!(text, "Hello world"),
            _ => unreachable!("expected TextDelta"),
        }
    }

    #[test]
    fn thinking_events_construction() {
        let start = LlmEvent::ThinkingStart;
        let delta = LlmEvent::ThinkingDelta {
            text: "Let me think...".into(),
        };
        let end = LlmEvent::ThinkingEnd;

        assert_eq!(start, LlmEvent::ThinkingStart);
        match &delta {
            LlmEvent::ThinkingDelta { text } => assert_eq!(text, "Let me think..."),
            _ => unreachable!("expected ThinkingDelta"),
        }
        assert_eq!(end, LlmEvent::ThinkingEnd);
    }

    #[test]
    fn stream_end_construction() {
        let event = LlmEvent::StreamEnd {
            finish_reason: FinishReason::Stop,
        };
        match &event {
            LlmEvent::StreamEnd { finish_reason } => {
                assert_eq!(*finish_reason, FinishReason::Stop);
            }
            _ => unreachable!("expected StreamEnd"),
        }
    }

    #[test]
    fn stream_error_construction() {
        let event = LlmEvent::StreamError {
            error: "connection reset".into(),
        };
        match &event {
            LlmEvent::StreamError { error } => assert_eq!(error, "connection reset"),
            _ => unreachable!("expected StreamError"),
        }
    }

    // ── Tool call events ──────────────────────────────────────

    #[test]
    fn tool_call_start_construction() {
        let event = LlmEvent::ToolCallStart {
            call_id: "call_abc123".into(),
            function_name: "read_file".into(),
        };
        match &event {
            LlmEvent::ToolCallStart {
                call_id,
                function_name,
            } => {
                assert_eq!(call_id, "call_abc123");
                assert_eq!(function_name, "read_file");
            }
            _ => unreachable!("expected ToolCallStart"),
        }
    }

    #[test]
    fn tool_call_args_delta_construction() {
        let event = LlmEvent::ToolCallArgsDelta {
            call_id: "call_abc123".into(),
            args_fragment: r#"{"path":"#.into(),
        };
        match &event {
            LlmEvent::ToolCallArgsDelta {
                call_id,
                args_fragment,
            } => {
                assert_eq!(call_id, "call_abc123");
                assert_eq!(args_fragment, r#"{"path":"#);
            }
            _ => unreachable!("expected ToolCallArgsDelta"),
        }
    }

    #[test]
    fn tool_call_end_construction() {
        let event = LlmEvent::ToolCallEnd {
            call_id: "call_abc123".into(),
        };
        match &event {
            LlmEvent::ToolCallEnd { call_id } => assert_eq!(call_id, "call_abc123"),
            _ => unreachable!("expected ToolCallEnd"),
        }
    }

    // ── Event equality ────────────────────────────────────────

    #[test]
    fn events_are_equal_when_identical() {
        let a = LlmEvent::TextDelta {
            text: "hello".into(),
        };
        let b = LlmEvent::TextDelta {
            text: "hello".into(),
        };
        assert_eq!(a, b);
    }

    #[test]
    fn events_differ_across_variants() {
        let text = LlmEvent::TextDelta {
            text: "hello".into(),
        };
        let thinking = LlmEvent::ThinkingDelta {
            text: "hello".into(),
        };
        assert_ne!(text, thinking);
    }

    // ── Tool call sequence simulation ─────────────────────────

    #[test]
    fn tool_call_event_sequence() {
        let events = [
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("claude-opus-4"),
            },
            LlmEvent::ToolCallStart {
                call_id: "tc_1".into(),
                function_name: "bash".into(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "tc_1".into(),
                args_fragment: r#"{"cmd":"ls"#.into(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "tc_1".into(),
                args_fragment: r#""}"#.into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "tc_1".into(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls,
            },
        ];

        assert_eq!(events.len(), 6);

        // Verify call_id links all tool call events
        let tool_call_ids: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::ToolCallStart { call_id, .. }
                | LlmEvent::ToolCallArgsDelta { call_id, .. }
                | LlmEvent::ToolCallEnd { call_id } => Some(call_id.as_str()),
                _ => None,
            })
            .collect();
        assert!(tool_call_ids.iter().all(|id| *id == "tc_1"));
    }

    #[test]
    fn multi_tool_interleaving() {
        // Two tool calls in same response
        let events = [
            LlmEvent::ToolCallStart {
                call_id: "tc_1".into(),
                function_name: "read".into(),
            },
            LlmEvent::ToolCallStart {
                call_id: "tc_2".into(),
                function_name: "write".into(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "tc_1".into(),
                args_fragment: r#"{"path":"a.rs"}"#.into(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "tc_2".into(),
                args_fragment: r#"{"path":"b.rs"}"#.into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "tc_1".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "tc_2".into(),
            },
        ];

        // Count events per call_id
        let tc1_count = events
            .iter()
            .filter(|e| match e {
                LlmEvent::ToolCallStart { call_id, .. }
                | LlmEvent::ToolCallArgsDelta { call_id, .. }
                | LlmEvent::ToolCallEnd { call_id } => call_id == "tc_1",
                _ => false,
            })
            .count();
        let tc2_count = events
            .iter()
            .filter(|e| match e {
                LlmEvent::ToolCallStart { call_id, .. }
                | LlmEvent::ToolCallArgsDelta { call_id, .. }
                | LlmEvent::ToolCallEnd { call_id } => call_id == "tc_2",
                _ => false,
            })
            .count();
        assert_eq!(tc1_count, 3);
        assert_eq!(tc2_count, 3);
    }

    // ── Full event stream simulation ──────────────────────────

    #[test]
    fn full_stream_with_thinking_and_text() {
        let events = [
            LlmEvent::StreamStart {
                request_id: "req-42".into(),
                model: ModelRef::new("claude-opus-4").with_version("2025-04-14"),
            },
            LlmEvent::ThinkingStart,
            LlmEvent::ThinkingDelta {
                text: "I need to consider...".into(),
            },
            LlmEvent::ThinkingEnd,
            LlmEvent::TextDelta {
                text: "Here's my answer: ".into(),
            },
            LlmEvent::TextDelta { text: "42".into() },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            },
        ];

        // Collect all text
        let text: String = events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "Here's my answer: 42");

        // Collect thinking text
        let thinking: String = events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::ThinkingDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(thinking, "I need to consider...");
    }

    // ── FinishReason ──────────────────────────────────────────

    #[test]
    fn finish_reason_display() {
        assert_eq!(FinishReason::Stop.to_string(), "stop");
        assert_eq!(FinishReason::Length.to_string(), "length");
        assert_eq!(FinishReason::ToolCalls.to_string(), "tool_calls");
        assert_eq!(FinishReason::ContentFilter.to_string(), "content_filter");
        assert_eq!(FinishReason::Cancelled.to_string(), "cancelled");
        assert_eq!(FinishReason::Other.to_string(), "other");
    }

    #[test]
    fn finish_reason_serde_round_trip() {
        let reasons = [
            FinishReason::Stop,
            FinishReason::Length,
            FinishReason::ToolCalls,
            FinishReason::ContentFilter,
            FinishReason::Cancelled,
            FinishReason::Other,
        ];
        for reason in &reasons {
            let json = serde_json::to_string(reason);
            assert!(json.is_ok());
            match json {
                Ok(json_str) => {
                    let parsed: std::result::Result<FinishReason, _> =
                        serde_json::from_str(&json_str);
                    assert!(parsed.is_ok());
                    match parsed {
                        Ok(r) => assert_eq!(r, *reason),
                        Err(_) => unreachable!("serde_json::from_str succeeded"),
                    }
                }
                Err(_) => unreachable!("serde_json::to_string succeeded"),
            }
        }
    }

    #[test]
    fn finish_reason_equality() {
        assert_eq!(FinishReason::Stop, FinishReason::Stop);
        assert_ne!(FinishReason::Stop, FinishReason::Length);
    }

    #[test]
    fn events_are_clone() {
        let event = LlmEvent::TextDelta {
            text: "hello".into(),
        };
        let cloned = event.clone();
        assert_eq!(event, cloned);
    }

    #[test]
    fn events_are_debug() {
        let event = LlmEvent::StreamStart {
            request_id: "r1".into(),
            model: ModelRef::new("test"),
        };
        let debug = format!("{event:?}");
        assert!(debug.contains("StreamStart"));
        assert!(debug.contains("r1"));
    }
}
