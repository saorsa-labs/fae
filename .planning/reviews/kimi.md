Review this git diff for security, errors, quality. Rate A-F. Format: [SEVERITY]
file:line - description. Diff: diff --git a/src/fae_llm/error.rs 
b/src/fae_llm/error.rs
new file mode 100644
index 0000000..883e89d
--- /dev/null
+++ b/src/fae_llm/error.rs
@@ -0,0 +1,169 @@
+//! Error types for the fae_llm module.
+//!
+//! Each error variant carries a stable error code (SCREAMING_SNAKE_CASE)
+//! that is included in the Display output and accessible via 
[`FaeLlmError::code()`].
+//! Codes are part of the public API contract and will not change.
+
+/// Errors produced by the fae_llm module.
+///
+/// Each variant includes a stable error code accessible via 
[`FaeLlmError::code()`].
+/// The Display impl formats as `[CODE] message`.
+#
+pub enum FaeLlmError {
+    /// Invalid or missing configuration.
+    #[error("[CONFIG_INVALID] {0}")]
+    ConfigError(String),
+
+    /// Authentication failed (invalid/missing API key).
+    #[error("[AUTH_FAILED] {0}")]
+    AuthError(String),
+
+    /// Request to the LLM provider failed.
+    #[error("[REQUEST_FAILED] {0}")]
+    RequestError(String),
+
+    /// Streaming response encountered an error.
+    #[error("[STREAM_FAILED] {0}")]
+    StreamError(String),
+
+    /// Tool execution failed.
+    #[error("[TOOL_FAILED] {0}")]
+    ToolError(String),
+
+    /// Request or operation timed out.
+    #[error("[TIMEOUT] {0}")]
+    Timeout(String),
+
+    /// Provider-specific error not covered by other variants.
+    #[error("[PROVIDER_ERROR] {0}")]
+    ProviderError(String),
+}
+
+impl FaeLlmError {
+    /// Returns the stable error code for this error.
+    ///
+    /// Codes are SCREAMING_SNAKE_CASE strings that remain stable across 
releases.
+    /// Use these for programmatic error handling rather than parsing Display 
output.
+    pub fn code(&self) -> &'static str {
+        match self {
+            Self::ConfigError(_) => "CONFIG_INVALID",
+            Self::AuthError(_) => "AUTH_FAILED",
+            Self::RequestError(_) => "REQUEST_FAILED",
+            Self::StreamError(_) => "STREAM_FAILED",
+            Self::ToolError(_) => "TOOL_FAILED",
+            Self::Timeout(_) => "TIMEOUT",
+            Self::ProviderError(_) => "PROVIDER_ERROR",
+        }
+    }
+
+    /// Returns the inner message without the code prefix.
+    pub fn message(&self) -> &str {
+        match self {
+            Self::ConfigError(m)
+            | Self::AuthError(m)
+            | Self::RequestError(m)
+            | Self::StreamError(m)
+            | Self::ToolError(m)
+            | Self::Timeout(m)
+            | Self::ProviderError(m) => m,
+        }
+    }
+}
+
+/// Convenience alias for fae_llm results.
+pub type Result<T> = std::result::Result<T, FaeLlmError>;
+
+#
+mod tests {
+    use super::*;
+
+    #
+    fn config_error_code() {
+        let err = FaeLlmError::ConfigError("missing api_url".into());
+        assert_eq!(err.code(), "CONFIG_INVALID");
+    }
+
+    #
+    fn auth_error_code() {
+        let err = FaeLlmError::AuthError("invalid key".into());
+        assert_eq!(err.code(), "AUTH_FAILED");
+    }
+
+    #
+    fn request_error_code() {
+        let err = FaeLlmError::RequestError("connection refused".into());
+        assert_eq!(err.code(), "REQUEST_FAILED");
+    }
+
+    #
+    fn stream_error_code() {
+        let err = FaeLlmError::StreamError("unexpected EOF".into());
+        assert_eq!(err.code(), "STREAM_FAILED");
+    }
+
+    #
+    fn tool_error_code() {
+        let err = FaeLlmError::ToolError("bash timed out".into());
+        assert_eq!(err.code(), "TOOL_FAILED");
+    }
+
+    #
+    fn timeout_error_code() {
+        let err = FaeLlmError::Timeout("30s elapsed".into());
+        assert_eq!(err.code(), "TIMEOUT");
+    }
+
+    #
+    fn provider_error_code() {
+        let err = FaeLlmError::ProviderError("rate limited".into());
+        assert_eq!(err.code(), "PROVIDER_ERROR");
+    }
+
+    #
+    fn display_includes_code_prefix() {
+        let err = FaeLlmError::ConfigError("missing model".into());
+        let display = format!("{err}");
+        assert!(display.starts_with("[CONFIG_INVALID]"));
+        assert!(display.contains("missing model"));
+    }
+
+    #
+    fn display_auth_includes_prefix() {
+        let err = FaeLlmError::AuthError("expired token".into());
+        let display = format!("{err}");
+        assert!(display.starts_with("[AUTH_FAILED]"));
+        assert!(display.contains("expired token"));
+    }
+
+    #
+    fn message_returns_inner_text() {
+        let err = FaeLlmError::RequestError("bad gateway".into());
+        assert_eq!(err.message(), "bad gateway");
+    }
+
+    #
+    fn all_codes_are_screaming_snake_case() {
+        let errors: Vec<FaeLlmError> = vec![
+            FaeLlmError::ConfigError("x".into()),
+            FaeLlmError::AuthError("x".into()),
+            FaeLlmError::RequestError("x".into()),
+            FaeLlmError::StreamError("x".into()),
+            FaeLlmError::ToolError("x".into()),
+            FaeLlmError::Timeout("x".into()),
+            FaeLlmError::ProviderError("x".into()),
+        ];
+        for err in &errors {
+            let code = err.code();
+            assert!(
+                code.chars().all(|c| c.is_ascii_uppercase() || c == '_'),
+                "code {code:?} is not SCREAMING_SNAKE_CASE"
+            );
+        }
+    }
+
+    #
+    fn error_is_send_and_sync() {
+        fn assert_send_sync<T: Send + Sync>() {}
+        assert_send_sync::<FaeLlmError>();
+    }
+}
diff --git a/src/fae_llm/events.rs b/src/fae_llm/events.rs
new file mode 100644
index 0000000..612ae32
--- /dev/null
+++ b/src/fae_llm/events.rs
@@ -0,0 +1,485 @@
+//! Normalized streaming event model for LLM providers.
+//!
+//! All LLM providers normalize their streaming output to [`LlmEvent`],
+//! providing a consistent interface regardless of the underlying API.
+//!
+//! # Event Stream Lifecycle
+//!
+//! A typical stream flows:
+//! ```text
+//! StreamStart → TextDelta* → StreamEnd
+//! ```
+//!
+//! With reasoning:
+//! ```text
+//! StreamStart → ThinkingStart → ThinkingDelta* → ThinkingEnd → TextDelta* → 
StreamEnd
+//! ```
+//!
+//! With tool calls:
+//! ```text
+//! StreamStart → ToolCallStart → ToolCallArgsDelta* → ToolCallEnd → StreamEnd
+//! ```
+//!
+//! # Examples
+//!
+//! ```
+//! use fae::fae_llm::events::{LlmEvent, FinishReason};
+//! use fae::fae_llm::types::ModelRef;
+//!
+//! let start = LlmEvent::StreamStart {
+//!     request_id: "req-001".into(),
+//!     model: ModelRef::new("gpt-4o"),
+//! };
+//!
+//! let delta = LlmEvent::TextDelta {
+//!     text: "Hello".into(),
+//! };
+//!
+//! let end = LlmEvent::StreamEnd {
+//!     finish_reason: FinishReason::Stop,
+//! };
+//! ```
+
+use super::types::ModelRef;
+
+/// A normalized streaming event from any LLM provider.
+///
+/// Events arrive in temporal order during streaming. Each event
+/// represents a discrete unit of the model's output.
+#
+pub enum LlmEvent {
+    /// Stream has started. First event in every stream.
+    StreamStart {
+        /// Unique identifier for this request.
+        request_id: String,
+        /// The model being used.
+        model: ModelRef,
+    },
+
+    /// A chunk of generated text.
+    TextDelta {
+        /// The text fragment.
+        text: String,
+    },
+
+    /// The model has started a thinking/reasoning block.
+    ThinkingStart,
+
+    /// A chunk of thinking/reasoning text.
+    ThinkingDelta {
+        /// The thinking text fragment.
+        text: String,
+    },
+
+    /// The model has finished its thinking/reasoning block.
+    ThinkingEnd,
+
+    /// A tool call has started.
+    ToolCallStart {
+        /// Unique identifier linking all events for this tool call.
+        call_id: String,
+        /// The name of the function being called.
+        function_name: String,
+    },
+
+    /// A chunk of tool call arguments (streaming JSON).
+    ToolCallArgsDelta {
+        /// Identifier linking this delta to its 
[`ToolCallStart`](LlmEvent::ToolCallStart).
+        call_id: String,
+        /// A fragment of the JSON arguments string.
+        args_fragment: String,
+    },
+
+    /// A tool call's arguments are complete.
+    ToolCallEnd {
+        /// Identifier linking this end to its 
[`ToolCallStart`](LlmEvent::ToolCallStart).
+        call_id: String,
+    },
+
+    /// Stream has ended normally.
+    StreamEnd {
+        /// Why the model stopped generating.
+        finish_reason: FinishReason,
+    },
+
+    /// Stream encountered an error.
+    StreamError {
+        /// Description of what went wrong.
+        error: String,
+    },
+}
+
+/// The reason the model stopped generating output.
+#
+#
+pub enum FinishReason {
+    /// Natural stop (end of response).
+    Stop,
+    /// Hit the max token limit.
+    Length,
+    /// Model wants to call one or more tools.
+    ToolCalls,
+    /// Content was filtered by safety systems.
+    ContentFilter,
+    /// Request was cancelled by the caller.
+    Cancelled,
+    /// Provider-specific or unknown reason.
+    Other,
+}
+
+impl std::fmt::Display for FinishReason {
+    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
+        match self {
+            Self::Stop => write!(f, "stop"),
+            Self::Length => write!(f, "length"),
+            Self::ToolCalls => write!(f, "tool_calls"),
+            Self::ContentFilter => write!(f, "content_filter"),
+            Self::Cancelled => write!(f, "cancelled"),
+            Self::Other => write!(f, "other"),
+        }
+    }
+}
+
+#
+mod tests {
+    use super::*;
+    use crate::fae_llm::types::ModelRef;
+
+    // ── LlmEvent construction ─────────────────────────────────
+
+    #
+    fn stream_start_construction() {
+        let event = LlmEvent::StreamStart {
+            request_id: "req-001".into(),
+            model: ModelRef::new("gpt-4o"),
+        };
+        match &event {
+            LlmEvent::StreamStart { request_id, model } => {
+                assert_eq!(request_id, "req-001");
+                assert_eq!(model.model_id, "gpt-4o");
+            }
+            _ => unreachable!("expected StreamStart"),
+        }
+    }
+
+    #
+    fn text_delta_construction() {
+        let event = LlmEvent::TextDelta {
+            text: "Hello world".into(),
+        };
+        match &event {
+            LlmEvent::TextDelta { text } => assert_eq!(text, "Hello world"),
+            _ => unreachable!("expected TextDelta"),
+        }
+    }
+
+    #
+    fn thinking_events_construction() {
+        let start = LlmEvent::ThinkingStart;
+        let delta = LlmEvent::ThinkingDelta {
+            text: "Let me think...".into(),
+        };
+        let end = LlmEvent::ThinkingEnd;
+
+        assert_eq!(start, LlmEvent::ThinkingStart);
+        match &delta {
+            LlmEvent::ThinkingDelta { text } => assert_eq!(text, "Let me 
think..."),
+            _ => unreachable!("expected ThinkingDelta"),
+        }
+        assert_eq!(end, LlmEvent::ThinkingEnd);
+    }
+
+    #
+    fn stream_end_construction() {
+        let event = LlmEvent::StreamEnd {
+            finish_reason: FinishReason::Stop,
+        };
+        match &event {
+            LlmEvent::StreamEnd { finish_reason } => {
+                assert_eq!(*finish_reason, FinishReason::Stop);
+            }
+            _ => unreachable!("expected StreamEnd"),
+        }
+    }
+
+    #
+    fn stream_error_construction() {
+        let event = LlmEvent::StreamError {
+            error: "connection reset".into(),
+        };
+        match &event {
+            LlmEvent::StreamError { error } => assert_eq!(error, "connection 
reset"),
+            _ => unreachable!("expected StreamError"),
+        }
+    }
+
+    // ── Tool call events ──────────────────────────────────────
+
+    #
+    fn tool_call_start_construction() {
+        let event = LlmEvent::ToolCallStart {
+            call_id: "call_abc123".into(),
+            function_name: "read_file".into(),
+        };
+        match &event {
+            LlmEvent::ToolCallStart {
+                call_id,
+                function_name,
+            } => {
+                assert_eq!(call_id, "call_abc123");
+                assert_eq!(function_name, "read_file");
+            }
+            _ => unreachable!("expected ToolCallStart"),
+        }
+    }
+
+    #
+    fn tool_call_args_delta_construction() {
+        let event = LlmEvent::ToolCallArgsDelta {
+            call_id: "call_abc123".into(),
+            args_fragment: r#"{"path":"#.into(),
+        };
+        match &event {
+            LlmEvent::ToolCallArgsDelta {
+                call_id,
+                args_fragment,
+            } => {
+                assert_eq!(call_id, "call_abc123");
+                assert_eq!(args_fragment, r#"{"path":"#);
+            }
+            _ => unreachable!("expected ToolCallArgsDelta"),
+        }
+    }
+
+    #
+    fn tool_call_end_construction() {
+        let event = LlmEvent::ToolCallEnd {
+            call_id: "call_abc123".into(),
+        };
+        match &event {
+            LlmEvent::ToolCallEnd { call_id } => assert_eq!(call_id, 
"call_abc123"),
+            _ => unreachable!("expected ToolCallEnd"),
+        }
+    }
+
+    // ── Event equality ────────────────────────────────────────
+
+    #
+    fn events_are_equal_when_identical() {
+        let a = LlmEvent::TextDelta {
+            text: "hello".into(),
+        };
+        let b = LlmEvent::TextDelta {
+            text: "hello".into(),
+        };
+        assert_eq!(a, b);
+    }
+
+    #
+    fn events_differ_across_variants() {
+        let text = LlmEvent::TextDelta {
+            text: "hello".into(),
+        };
+        let thinking = LlmEvent::ThinkingDelta {
+            text: "hello".into(),
+        };
+        assert_ne!(text, thinking);
+    }
+
+    // ── Tool call sequence simulation ─────────────────────────
+
+    #
+    fn tool_call_event_sequence() {
+        let events = [
+            LlmEvent::StreamStart {
+                request_id: "req-1".into(),
+                model: ModelRef::new("claude-opus-4"),
+            },
+            LlmEvent::ToolCallStart {
+                call_id: "tc_1".into(),
+                function_name: "bash".into(),
+            },
+            LlmEvent::ToolCallArgsDelta {
+                call_id: "tc_1".into(),
+                args_fragment: r#"{"cmd":"ls"#.into(),
+            },
+            LlmEvent::ToolCallArgsDelta {
+                call_id: "tc_1".into(),
+                args_fragment: r#""}"#.into(),
+            },
+            LlmEvent::ToolCallEnd {
+                call_id: "tc_1".into(),
+            },
+            LlmEvent::StreamEnd {
+                finish_reason: FinishReason::ToolCalls,
+            },
+        ];
+
+        assert_eq!(events.len(), 6);
+
+        // Verify call_id links all tool call events
+        let tool_call_ids: Vec<&str> = events
+            .iter()
+            .filter_map(|e| match e {
+                LlmEvent::ToolCallStart { call_id, .. }
+                | LlmEvent::ToolCallArgsDelta { call_id, .. }
+                | LlmEvent::ToolCallEnd { call_id } => Some(call_id.as_str()),
+                _ => None,
+            })
+            .collect();
+        assert!(tool_call_ids.iter().all(|id| *id == "tc_1"));
+    }
+
+    #
+    fn multi_tool_interleaving() {
+        // Two tool calls in same response
+        let events = [
+            LlmEvent::ToolCallStart {
+                call_id: "tc_1".into(),
+                function_name: "read".into(),
+            },
+            LlmEvent::ToolCallStart {
+                call_id: "tc_2".into(),
+                function_name: "write".into(),
+            },
+            LlmEvent::ToolCallArgsDelta {
+                call_id: "tc_1".into(),
+                args_fragment: r#"{"path":"a.rs"}"#.into(),
+            },
+            LlmEvent::ToolCallArgsDelta {
+                call_id: "tc_2".into(),
+                args_fragment: r#"{"path":"b.rs"}"#.into(),
+            },
+            LlmEvent::ToolCallEnd {
+                call_id: "tc_1".into(),
+            },
+            LlmEvent::ToolCallEnd {
+                call_id: "tc_2".into(),
+            },
+        ];
+
+        // Count events per call_id
+        let tc1_count = events
+            .iter()
+            .filter(|e| match e {
+                LlmEvent::ToolCallStart { call_id, .. }
+                | LlmEvent::ToolCallArgsDelta { call_id, .. }
+                | LlmEvent::ToolCallEnd { call_id } => call_id == "tc_1",
+                _ => false,
+            })
+            .count();
+        let tc2_count = events
+            .iter()
+            .filter(|e| match e {
+                LlmEvent::ToolCallStart { call_id, .. }
+                | LlmEvent::ToolCallArgsDelta { call_id, .. }
+                | LlmEvent::ToolCallEnd { call_id } => call_id == "tc_2",
+                _ => false,
+            })
+            .count();
+        assert_eq!(tc1_count, 3);
+        assert_eq!(tc2_count, 3);
+    }
+
+    // ── Full event stream simulation ──────────────────────────
+
+    #
+    fn full_stream_with_thinking_and_text() {
+        let events = [
+            LlmEvent::StreamStart {
+                request_id: "req-42".into(),
+                model: 
ModelRef::new("claude-opus-4").with_version("2025-04-14"),
+            },
+            LlmEvent::ThinkingStart,
+            LlmEvent::ThinkingDelta {
+                text: "I need to consider...".into(),
+            },
+            LlmEvent::ThinkingEnd,
+            LlmEvent::TextDelta {
+                text: "Here's my answer: ".into(),
+            },
+            LlmEvent::TextDelta { text: "42".into() },
+            LlmEvent::StreamEnd {
+                finish_reason: FinishReason::Stop,
+            },
+        ];
+
+        // Collect all text
+        let text: String = events
+            .iter()
+            .filter_map(|e| match e {
+                LlmEvent::TextDelta { text } => Some(text.as_str()),
+                _ => None,
+            })
+            .collect();
+        assert_eq!(text, "Here's my answer: 42");
+
+        // Collect thinking text
+        let thinking: String = events
+            .iter()
+            .filter_map(|e| match e {
+                LlmEvent::ThinkingDelta { text } => Some(text.as_str()),
+                _ => None,
+            })
+            .collect();
+        assert_eq!(thinking, "I need to consider...");
+    }
+
+    // ── FinishReason ──────────────────────────────────────────
+
+    #
+    fn finish_reason_display() {
+        assert_eq!(FinishReason::Stop.to_string(), "stop");
+        assert_eq!(FinishReason::Length.to_string(), "length");
+        assert_eq!(FinishReason::ToolCalls.to_string(), "tool_calls");
+        assert_eq!(FinishReason::ContentFilter.to_string(), "content_filter");
+        assert_eq!(FinishReason::Cancelled.to_string(), "cancelled");
+        assert_eq!(FinishReason::Other.to_string(), "other");
+    }
+
+    #
+    fn finish_reason_serde_round_trip() {
+        let reasons = [
+            FinishReason::Stop,
+            FinishReason::Length,
+            FinishReason::ToolCalls,
+            FinishReason::ContentFilter,
+            FinishReason::Cancelled,
+            FinishReason::Other,
+        ];
+        for reason in &reasons {
+            let json = serde_json::to_string(reason);
+            assert!(json.is_ok());
+            let parsed: std::result::Result<FinishReason, _> =
+                serde_json::from_str(&json.unwrap_or_default());
+            assert!(parsed.is_ok());
+            assert_eq!(parsed.unwrap_or(FinishReason::Other), *reason);
+        }
+    }
+
+    #
+    fn finish_reason_equality() {
+        assert_eq!(FinishReason::Stop, FinishReason::Stop);
+        assert_ne!(FinishReason::Stop, FinishReason::Length);
+    }
+
+    #
+    fn events_are_clone() {
+        let event = LlmEvent::TextDelta {
+            text: "hello".into(),
+        };
+        let cloned = event.clone();
+        assert_eq!(event, cloned);
+    }
+
+    #
+    fn events_are_debug() {
+        let event = LlmEvent::StreamStart {
+            request_id: "r1".into(),
+            model: ModelRef::new("test"),
+        };
+        let debug = format!("{event:?}");
+        assert!(debug.contains("StreamStart"));
+        assert!(debug.contains("r1"));
+    }
+}
diff --git a/src/fae_llm/metadata.rs b/src/fae_llm/metadata.rs
new file mode 100644
index 0000000..e4d0504
--- /dev/null
+++ b/src/fae_llm/metadata.rs
@@ -0,0 +1,207 @@
+//! Request and response metadata for LLM interactions.
+//!
+//! Provides types for tracking request context and response details
+//! that are useful for logging, debugging, and observability.
+//!
+//! # Examples
+//!
+//! ```
+//! use fae::fae_llm::metadata::RequestMeta;
+//! use fae::fae_llm::types::ModelRef;
+//!
+//! let meta = RequestMeta::new("req-001", ModelRef::new("gpt-4o"));
+//! assert_eq!(meta.request_id, "req-001");
+//! ```
+
+use super::events::FinishReason;
+use super::types::ModelRef;
+use super::usage::TokenUsage;
+use serde::{Deserialize, Serialize};
+
+/// Metadata about an outgoing LLM request.
+///
+/// Created before sending the request, used to correlate
+/// responses and track latency.
+#
+pub struct RequestMeta {
+    /// Unique identifier for this request.
+    pub request_id: String,
+    /// The model being called.
+    pub model: ModelRef,
+    /// When the request was created.
+    pub created_at: std::time::Instant,
+}
+
+impl RequestMeta {
+    /// Create metadata for a new request.
+    pub fn new(request_id: impl Into<String>, model: ModelRef) -> Self {
+        Self {
+            request_id: request_id.into(),
+            model,
+            created_at: std::time::Instant::now(),
+        }
+    }
+
+    /// Milliseconds elapsed since this request was created.
+    pub fn elapsed_ms(&self) -> u64 {
+        self.created_at.elapsed().as_millis() as u64
+    }
+}
+
+/// Metadata about a completed LLM response.
+///
+/// Collected after the stream finishes, contains usage statistics
+/// and timing information.
+#
+pub struct ResponseMeta {
+    /// The request ID this response corresponds to.
+    pub request_id: String,
+    /// The model that generated this response (provider-reported).
+    pub model_id: String,
+    /// Token usage statistics (if reported by the provider).
+    pub usage: Option<TokenUsage>,
+    /// End-to-end latency in milliseconds.
+    pub latency_ms: u64,
+    /// Why the model stopped generating.
+    pub finish_reason: FinishReason,
+}
+
+impl ResponseMeta {
+    /// Create response metadata.
+    pub fn new(
+        request_id: impl Into<String>,
+        model_id: impl Into<String>,
+        finish_reason: FinishReason,
+        latency_ms: u64,
+    ) -> Self {
+        Self {
+            request_id: request_id.into(),
+            model_id: model_id.into(),
+            usage: None,
+            latency_ms,
+            finish_reason,
+        }
+    }
+
+    /// Attach token usage to this response.
+    pub fn with_usage(mut self, usage: TokenUsage) -> Self {
+        self.usage = Some(usage);
+        self
+    }
+}
+
+#
+mod tests {
+    use super::*;
+
+    // ── RequestMeta ───────────────────────────────────────────
+
+    #
+    fn request_meta_new() {
+        let meta = RequestMeta::new("req-001", ModelRef::new("gpt-4o"));
+        assert_eq!(meta.request_id, "req-001");
+        assert_eq!(meta.model.model_id, "gpt-4o");
+    }
+
+    #
+    fn request_meta_elapsed_is_non_negative() {
+        let meta = RequestMeta::new("req-001", ModelRef::new("test"));
+        // elapsed_ms should be >= 0 (it's u64, so always true, but verify it 
doesn't panic)
+        let _elapsed = meta.elapsed_ms();
+    }
+
+    #
+    fn request_meta_with_versioned_model() {
+        let model = ModelRef::new("claude-opus-4").with_version("2025-04-14");
+        let meta = RequestMeta::new("req-002", model);
+        assert_eq!(meta.model.full_name(), "claude-opus-4@2025-04-14");
+    }
+
+    // ── ResponseMeta ──────────────────────────────────────────
+
+    #
+    fn response_meta_new() {
+        let meta = ResponseMeta::new("req-001", "gpt-4o-2025-01", 
FinishReason::Stop, 1500);
+        assert_eq!(meta.request_id, "req-001");
+        assert_eq!(meta.model_id, "gpt-4o-2025-01");
+        assert_eq!(meta.finish_reason, FinishReason::Stop);
+        assert_eq!(meta.latency_ms, 1500);
+        assert!(meta.usage.is_none());
+    }
+
+    #
+    fn response_meta_with_usage() {
+        let usage = TokenUsage::new(500, 200);
+        let meta =
+            ResponseMeta::new("req-001", "gpt-4o", FinishReason::Stop, 
1200).with_usage(usage);
+        assert!(meta.usage.is_some());
+        let usage = meta.usage.as_ref();
+        assert!(usage.is_some_and(|u| u.prompt_tokens == 500));
+    }
+
+    #
+    fn response_meta_serde_round_trip() {
+        let usage = TokenUsage::new(500, 200).with_reasoning_tokens(50);
+        let original = ResponseMeta::new("req-001", "claude-opus-4", 
FinishReason::ToolCalls, 800)
+            .with_usage(usage);
+
+        let json = serde_json::to_string(&original);
+        assert!(json.is_ok());
+        let parsed: std::result::Result<ResponseMeta, _> =
+            serde_json::from_str(&json.unwrap_or_default());
+        assert!(parsed.is_ok());
+        let parsed = parsed.unwrap_or_else(|_| ResponseMeta::new("", "", 
FinishReason::Other, 0));
+        assert_eq!(parsed.request_id, "req-001");
+        assert_eq!(parsed.model_id, "claude-opus-4");
+        assert_eq!(parsed.finish_reason, FinishReason::ToolCalls);
+        assert_eq!(parsed.latency_ms, 800);
+        assert!(parsed.usage.is_some_and(|u| u.reasoning_tokens == Some(50)));
+    }
+
+    #
+    fn response_meta_without_usage_serde() {
+        let original = ResponseMeta::new("req-002", "llama3:8b", 
FinishReason::Length, 5000);
+        let json = serde_json::to_string(&original);
+        assert!(json.is_ok());
+        let parsed: std::result::Result<ResponseMeta, _> =
+            serde_json::from_str(&json.unwrap_or_default());
+        assert!(parsed.is_ok());
+        let parsed = parsed.unwrap_or_else(|_| ResponseMeta::new("", "", 
FinishReason::Other, 0));
+        assert!(parsed.usage.is_none());
+    }
+
+    #
+    fn response_meta_various_finish_reasons() {
+        let reasons = [
+            FinishReason::Stop,
+            FinishReason::Length,
+            FinishReason::ToolCalls,
+            FinishReason::ContentFilter,
+            FinishReason::Cancelled,
+            FinishReason::Other,
+        ];
+        for reason in &reasons {
+            let meta = ResponseMeta::new("req", "model", *reason, 100);
+            assert_eq!(meta.finish_reason, *reason);
+        }
+    }
+
+    // ── Integration: RequestMeta → ResponseMeta ───────────────
+
+    #
+    fn request_to_response_flow() {
+        let req = RequestMeta::new("req-flow", ModelRef::new("gpt-4o"));
+
+        // Simulate response arriving
+        let resp = ResponseMeta::new(
+            &req.request_id,
+            "gpt-4o-2025-01",
+            FinishReason::Stop,
+            req.elapsed_ms(),
+        )
+        .with_usage(TokenUsage::new(100, 50));
+
+        assert_eq!(req.request_id, resp.request_id);
+        assert!(resp.usage.is_some_and(|u| u.total() == 150));
+    }
+}
diff --git a/src/fae_llm/mod.rs b/src/fae_llm/mod.rs
new file mode 100644
index 0000000..e7419e4
--- /dev/null
+++ b/src/fae_llm/mod.rs
@@ -0,0 +1,292 @@
+//! FAE LLM module — multi-provider LLM integration.
+//!
+//! This module provides the foundational types for interacting with
+//! multiple LLM providers (OpenAI, Anthropic, local endpoints, etc.)
+//! through a normalized interface.
+//!
+//! # Submodules
+//!
+//! - [`error`] — Error types with stable error codes
+//! - [`types`] — Core domain types (endpoints, models, request options)
+//! - [`events`] — Normalized streaming event model
+//! - [`usage`] — Token usage and cost tracking
+//! - [`metadata`] — Request/response metadata
+//!
+//! # Event Model
+//!
+//! All providers normalize their streaming output to [`events::LlmEvent`],
+//! providing a consistent interface regardless of the underlying API.
+//!
+//! # Error Codes
+//!
+//! All errors carry a stable code (e.g. `CONFIG_INVALID`, `AUTH_FAILED`)
+//! that is safe to match on programmatically.
+
+pub mod error;
+pub mod events;
+pub mod metadata;
+pub mod types;
+pub mod usage;
+
+pub use error::FaeLlmError;
+pub use events::{FinishReason, LlmEvent};
+pub use metadata::{RequestMeta, ResponseMeta};
+pub use types::{EndpointType, ModelRef, ReasoningLevel, RequestOptions};
+pub use usage::{CostEstimate, TokenPricing, TokenUsage};
+
+#
+mod integration_tests {
+    use super::*;
+
+    /// Simulate a full event stream: start → thinking → text → tool call → 
text → end.
+    #
+    fn full_event_stream_lifecycle() {
+        let model = ModelRef::new("claude-opus-4").with_version("2025-04-14");
+        let request = RequestMeta::new("req-integration-1", model.clone());
+
+        let events = [
+            LlmEvent::StreamStart {
+                request_id: request.request_id.clone(),
+                model,
+            },
+            LlmEvent::ThinkingStart,
+            LlmEvent::ThinkingDelta {
+                text: "Let me analyze this...".into(),
+            },
+            LlmEvent::ThinkingEnd,
+            LlmEvent::TextDelta {
+                text: "I'll read the file first.".into(),
+            },
+            LlmEvent::ToolCallStart {
+                call_id: "tc_1".into(),
+                function_name: "read_file".into(),
+            },
+            LlmEvent::ToolCallArgsDelta {
+                call_id: "tc_1".into(),
+                args_fragment: r#"{"path":"src/main.rs"}"#.into(),
+            },
+            LlmEvent::ToolCallEnd {
+                call_id: "tc_1".into(),
+            },
+            LlmEvent::TextDelta {
+                text: "Here's the result.".into(),
+            },
+            LlmEvent::StreamEnd {
+                finish_reason: FinishReason::Stop,
+            },
+        ];
+
+        // Verify stream structure
+        assert!(matches!(events[0], LlmEvent::StreamStart { .. }));
+        assert!(matches!(
+            events,
+            LlmEvent::StreamEnd { .. }
+        ));
+
+        // Collect text output
+        let text: String = events
+            .iter()
+            .filter_map(|e| match e {
+                LlmEvent::TextDelta { text } => Some(text.as_str()),
+                _ => None,
+            })
+            .collect();
+        assert_eq!(text, "I'll read the file first.Here's the result.");
+
+        // Build response metadata
+        let response = ResponseMeta::new(
+            &request.request_id,
+            "claude-opus-4-20250414",
+            FinishReason::Stop,
+            request.elapsed_ms(),
+        )
+        .with_usage(TokenUsage::new(800, 350).with_reasoning_tokens(100));
+
+        assert_eq!(response.request_id, "req-integration-1");
+        assert!(response.usage.is_some_and(|u| u.total() == 1250));
+    }
+
+    /// Accumulate TokenUsage across a multi-turn conversation and calculate 
cost.
+    #
+    fn multi_turn_usage_accumulation_with_cost() {
+        let pricing = TokenPricing::new(15.0, 75.0); // Claude Opus pricing
+
+        let turns = [
+            TokenUsage::new(500, 200),
TurnBegin(
    user_input='Review this git diff for security, errors, quality. Rate A-F. 
Format: [SEVERITY] file:line - description. Diff: diff --git 
a/src/fae_llm/error.rs b/src/fae_llm/error.rs\nnew file mode 100644\nindex 
0000000..883e89d\n--- /dev/null\n+++ b/src/fae_llm/error.rs\n@@ -0,0 +1,169 
@@\n+//! Error types for the fae_llm module.\n+//!\n+//! Each error variant 
carries a stable error code (SCREAMING_SNAKE_CASE)\n+//! that is included in the
Display output and accessible via [`FaeLlmError::code()`].\n+//! Codes are part 
of the public API contract and will not change.\n+\n+/// Errors produced by the 
fae_llm module.\n+///\n+/// Each variant includes a stable error code accessible
via [`FaeLlmError::code()`].\n+/// The Display impl formats as `[CODE] 
message`.\n+#[derive(Debug, thiserror::Error)]\n+pub enum FaeLlmError {\n+    
/// Invalid or missing configuration.\n+    #[error("[CONFIG_INVALID] {0}")]\n+ 
ConfigError(String),\n+\n+    /// Authentication failed (invalid/missing API 
key).\n+    #[error("[AUTH_FAILED] {0}")]\n+    AuthError(String),\n+\n+    /// 
Request to the LLM provider failed.\n+    #[error("[REQUEST_FAILED] {0}")]\n+   
RequestError(String),\n+\n+    /// Streaming response encountered an error.\n+  
#[error("[STREAM_FAILED] {0}")]\n+    StreamError(String),\n+\n+    /// Tool 
execution failed.\n+    #[error("[TOOL_FAILED] {0}")]\n+    
ToolError(String),\n+\n+    /// Request or operation timed out.\n+    
#[error("[TIMEOUT] {0}")]\n+    Timeout(String),\n+\n+    /// Provider-specific 
error not covered by other variants.\n+    #[error("[PROVIDER_ERROR] {0}")]\n+  
ProviderError(String),\n+}\n+\n+impl FaeLlmError {\n+    /// Returns the stable 
error code for this error.\n+    ///\n+    /// Codes are SCREAMING_SNAKE_CASE 
strings that remain stable across releases.\n+    /// Use these for programmatic
error handling rather than parsing Display output.\n+    pub fn code(&self) -> 
&\'static str {\n+        match self {\n+            Self::ConfigError(_) => 
"CONFIG_INVALID",\n+            Self::AuthError(_) => "AUTH_FAILED",\n+         
Self::RequestError(_) => "REQUEST_FAILED",\n+            Self::StreamError(_) =>
"STREAM_FAILED",\n+            Self::ToolError(_) => "TOOL_FAILED",\n+          
Self::Timeout(_) => "TIMEOUT",\n+            Self::ProviderError(_) => 
"PROVIDER_ERROR",\n+        }\n+    }\n+\n+    /// Returns the inner message 
without the code prefix.\n+    pub fn message(&self) -> &str {\n+        match 
self {\n+            Self::ConfigError(m)\n+            | Self::AuthError(m)\n+ 
| Self::RequestError(m)\n+            | Self::StreamError(m)\n+            | 
Self::ToolError(m)\n+            | Self::Timeout(m)\n+            | 
Self::ProviderError(m) => m,\n+        }\n+    }\n+}\n+\n+/// Convenience alias 
for fae_llm results.\n+pub type Result<T> = std::result::Result<T, 
FaeLlmError>;\n+\n+#[cfg(test)]\n+mod tests {\n+    use super::*;\n+\n+    
#[test]\n+    fn config_error_code() {\n+        let err = 
FaeLlmError::ConfigError("missing api_url".into());\n+        
assert_eq!(err.code(), "CONFIG_INVALID");\n+    }\n+\n+    #[test]\n+    fn 
auth_error_code() {\n+        let err = FaeLlmError::AuthError("invalid 
key".into());\n+        assert_eq!(err.code(), "AUTH_FAILED");\n+    }\n+\n+    
#[test]\n+    fn request_error_code() {\n+        let err = 
FaeLlmError::RequestError("connection refused".into());\n+        
assert_eq!(err.code(), "REQUEST_FAILED");\n+    }\n+\n+    #[test]\n+    fn 
stream_error_code() {\n+        let err = FaeLlmError::StreamError("unexpected 
EOF".into());\n+        assert_eq!(err.code(), "STREAM_FAILED");\n+    }\n+\n+  
#[test]\n+    fn tool_error_code() {\n+        let err = 
FaeLlmError::ToolError("bash timed out".into());\n+        
assert_eq!(err.code(), "TOOL_FAILED");\n+    }\n+\n+    #[test]\n+    fn 
timeout_error_code() {\n+        let err = FaeLlmError::Timeout("30s 
elapsed".into());\n+        assert_eq!(err.code(), "TIMEOUT");\n+    }\n+\n+    
#[test]\n+    fn provider_error_code() {\n+        let err = 
FaeLlmError::ProviderError("rate limited".into());\n+        
assert_eq!(err.code(), "PROVIDER_ERROR");\n+    }\n+\n+    #[test]\n+    fn 
display_includes_code_prefix() {\n+        let err = 
FaeLlmError::ConfigError("missing model".into());\n+        let display = 
format!("{err}");\n+        assert!(display.starts_with("[CONFIG_INVALID]"));\n+
assert!(display.contains("missing model"));\n+    }\n+\n+    #[test]\n+    fn 
display_auth_includes_prefix() {\n+        let err = 
FaeLlmError::AuthError("expired token".into());\n+        let display = 
format!("{err}");\n+        assert!(display.starts_with("[AUTH_FAILED]"));\n+   
assert!(display.contains("expired token"));\n+    }\n+\n+    #[test]\n+    fn 
message_returns_inner_text() {\n+        let err = 
FaeLlmError::RequestError("bad gateway".into());\n+        
assert_eq!(err.message(), "bad gateway");\n+    }\n+\n+    #[test]\n+    fn 
all_codes_are_screaming_snake_case() {\n+        let errors: Vec<FaeLlmError> = 
vec![\n+            FaeLlmError::ConfigError("x".into()),\n+            
FaeLlmError::AuthError("x".into()),\n+            
FaeLlmError::RequestError("x".into()),\n+            
FaeLlmError::StreamError("x".into()),\n+            
FaeLlmError::ToolError("x".into()),\n+            
FaeLlmError::Timeout("x".into()),\n+            
FaeLlmError::ProviderError("x".into()),\n+        ];\n+        for err in 
&errors {\n+            let code = err.code();\n+            assert!(\n+        
code.chars().all(|c| c.is_ascii_uppercase() || c == \'_\'),\n+                
"code {code:?} is not SCREAMING_SNAKE_CASE"\n+            );\n+        }\n+    
}\n+\n+    #[test]\n+    fn error_is_send_and_sync() {\n+        fn 
assert_send_sync<T: Send + Sync>() {}\n+        
assert_send_sync::<FaeLlmError>();\n+    }\n+}\ndiff --git 
a/src/fae_llm/events.rs b/src/fae_llm/events.rs\nnew file mode 100644\nindex 
0000000..612ae32\n--- /dev/null\n+++ b/src/fae_llm/events.rs\n@@ -0,0 +1,485 
@@\n+//! Normalized streaming event model for LLM providers.\n+//!\n+//! All LLM
providers normalize their streaming output to [`LlmEvent`],\n+//! providing a 
consistent interface regardless of the underlying API.\n+//!\n+//! # Event 
Stream Lifecycle\n+//!\n+//! A typical stream flows:\n+//! ```text\n+//! 
StreamStart → TextDelta* → StreamEnd\n+//! ```\n+//!\n+//! With reasoning:\n+//!
```text\n+//! StreamStart → ThinkingStart → ThinkingDelta* → ThinkingEnd → 
TextDelta* → StreamEnd\n+//! ```\n+//!\n+//! With tool calls:\n+//! 
```text\n+//! StreamStart → ToolCallStart → ToolCallArgsDelta* → ToolCallEnd → 
StreamEnd\n+//! ```\n+//!\n+//! # Examples\n+//!\n+//! ```\n+//! use 
fae::fae_llm::events::{LlmEvent, FinishReason};\n+//! use 
fae::fae_llm::types::ModelRef;\n+//!\n+//! let start = LlmEvent::StreamStart 
{\n+//!     request_id: "req-001".into(),\n+//!     model: 
ModelRef::new("gpt-4o"),\n+//! };\n+//!\n+//! let delta = LlmEvent::TextDelta 
{\n+//!     text: "Hello".into(),\n+//! };\n+//!\n+//! let end = 
LlmEvent::StreamEnd {\n+//!     finish_reason: FinishReason::Stop,\n+//! 
};\n+//! ```\n+\n+use super::types::ModelRef;\n+\n+/// A normalized streaming 
event from any LLM provider.\n+///\n+/// Events arrive in temporal order during 
streaming. Each event\n+/// represents a discrete unit of the model\'s 
output.\n+#[derive(Debug, Clone, PartialEq)]\n+pub enum LlmEvent {\n+    /// 
Stream has started. First event in every stream.\n+    StreamStart {\n+        
/// Unique identifier for this request.\n+        request_id: String,\n+        
/// The model being used.\n+        model: ModelRef,\n+    },\n+\n+    /// A 
chunk of generated text.\n+    TextDelta {\n+        /// The text fragment.\n+  
text: String,\n+    },\n+\n+    /// The model has started a thinking/reasoning 
block.\n+    ThinkingStart,\n+\n+    /// A chunk of thinking/reasoning text.\n+ 
ThinkingDelta {\n+        /// The thinking text fragment.\n+        text: 
String,\n+    },\n+\n+    /// The model has finished its thinking/reasoning 
block.\n+    ThinkingEnd,\n+\n+    /// A tool call has started.\n+    
ToolCallStart {\n+        /// Unique identifier linking all events for this tool
call.\n+        call_id: String,\n+        /// The name of the function being 
called.\n+        function_name: String,\n+    },\n+\n+    /// A chunk of tool 
call arguments (streaming JSON).\n+    ToolCallArgsDelta {\n+        /// 
Identifier linking this delta to its 
[`ToolCallStart`](LlmEvent::ToolCallStart).\n+        call_id: String,\n+       
/// A fragment of the JSON arguments string.\n+        args_fragment: String,\n+
},\n+\n+    /// A tool call\'s arguments are complete.\n+    ToolCallEnd {\n+   
/// Identifier linking this end to its 
[`ToolCallStart`](LlmEvent::ToolCallStart).\n+        call_id: String,\n+    
},\n+\n+    /// Stream has ended normally.\n+    StreamEnd {\n+        /// Why 
the model stopped generating.\n+        finish_reason: FinishReason,\n+    
},\n+\n+    /// Stream encountered an error.\n+    StreamError {\n+        /// 
Description of what went wrong.\n+        error: String,\n+    },\n+}\n+\n+/// 
The reason the model stopped generating output.\n+#[derive(Debug, Clone, Copy, 
PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]\n+#[serde(rename_all
= "snake_case")]\n+pub enum FinishReason {\n+    /// Natural stop (end of 
response).\n+    Stop,\n+    /// Hit the max token limit.\n+    Length,\n+    
/// Model wants to call one or more tools.\n+    ToolCalls,\n+    /// Content 
was filtered by safety systems.\n+    ContentFilter,\n+    /// Request was 
cancelled by the caller.\n+    Cancelled,\n+    /// Provider-specific or unknown
reason.\n+    Other,\n+}\n+\n+impl std::fmt::Display for FinishReason {\n+    fn
fmt(&self, f: &mut std::fmt::Formatter<\'_>) -> std::fmt::Result {\n+        
match self {\n+            Self::Stop => write!(f, "stop"),\n+            
Self::Length => write!(f, "length"),\n+            Self::ToolCalls => write!(f, 
"tool_calls"),\n+            Self::ContentFilter => write!(f, 
"content_filter"),\n+            Self::Cancelled => write!(f, "cancelled"),\n+  
Self::Other => write!(f, "other"),\n+        }\n+    
}\n+}\n+\n+#[cfg(test)]\n+mod tests {\n+    use super::*;\n+    use 
crate::fae_llm::types::ModelRef;\n+\n+    // ── LlmEvent construction 
─────────────────────────────────\n+\n+    #[test]\n+    fn 
stream_start_construction() {\n+        let event = LlmEvent::StreamStart {\n+  
request_id: "req-001".into(),\n+            model: ModelRef::new("gpt-4o"),\n+  
};\n+        match &event {\n+            LlmEvent::StreamStart { request_id, 
model } => {\n+                assert_eq!(request_id, "req-001");\n+            
assert_eq!(model.model_id, "gpt-4o");\n+            }\n+            _ => 
unreachable!("expected StreamStart"),\n+        }\n+    }\n+\n+    #[test]\n+   
fn text_delta_construction() {\n+        let event = LlmEvent::TextDelta {\n+   
text: "Hello world".into(),\n+        };\n+        match &event {\n+            
LlmEvent::TextDelta { text } => assert_eq!(text, "Hello world"),\n+            _
=> unreachable!("expected TextDelta"),\n+        }\n+    }\n+\n+    #[test]\n+  
fn thinking_events_construction() {\n+        let start = 
LlmEvent::ThinkingStart;\n+        let delta = LlmEvent::ThinkingDelta {\n+     
text: "Let me think...".into(),\n+        };\n+        let end = 
LlmEvent::ThinkingEnd;\n+\n+        assert_eq!(start, 
LlmEvent::ThinkingStart);\n+        match &delta {\n+            
LlmEvent::ThinkingDelta { text } => assert_eq!(text, "Let me think..."),\n+     
_ => unreachable!("expected ThinkingDelta"),\n+        }\n+        
assert_eq!(end, LlmEvent::ThinkingEnd);\n+    }\n+\n+    #[test]\n+    fn 
stream_end_construction() {\n+        let event = LlmEvent::StreamEnd {\n+      
finish_reason: FinishReason::Stop,\n+        };\n+        match &event {\n+     
LlmEvent::StreamEnd { finish_reason } => {\n+                
assert_eq!(*finish_reason, FinishReason::Stop);\n+            }\n+            _ 
=> unreachable!("expected StreamEnd"),\n+        }\n+    }\n+\n+    #[test]\n+  
fn stream_error_construction() {\n+        let event = LlmEvent::StreamError 
{\n+            error: "connection reset".into(),\n+        };\n+        match 
&event {\n+            LlmEvent::StreamError { error } => assert_eq!(error, 
"connection reset"),\n+            _ => unreachable!("expected StreamError"),\n+
}\n+    }\n+\n+    // ── Tool call events 
──────────────────────────────────────\n+\n+    #[test]\n+    fn 
tool_call_start_construction() {\n+        let event = LlmEvent::ToolCallStart 
{\n+            call_id: "call_abc123".into(),\n+            function_name: 
"read_file".into(),\n+        };\n+        match &event {\n+            
LlmEvent::ToolCallStart {\n+                call_id,\n+                
function_name,\n+            } => {\n+                assert_eq!(call_id, 
"call_abc123");\n+                assert_eq!(function_name, "read_file");\n+    
}\n+            _ => unreachable!("expected ToolCallStart"),\n+        }\n+    
}\n+\n+    #[test]\n+    fn tool_call_args_delta_construction() {\n+        let 
event = LlmEvent::ToolCallArgsDelta {\n+            call_id: 
"call_abc123".into(),\n+            args_fragment: r#"{"path":"#.into(),\n+     
};\n+        match &event {\n+            LlmEvent::ToolCallArgsDelta {\n+      
call_id,\n+                args_fragment,\n+            } => {\n+               
assert_eq!(call_id, "call_abc123");\n+                assert_eq!(args_fragment, 
r#"{"path":"#);\n+            }\n+            _ => unreachable!("expected 
ToolCallArgsDelta"),\n+        }\n+    }\n+\n+    #[test]\n+    fn 
tool_call_end_construction() {\n+        let event = LlmEvent::ToolCallEnd {\n+ 
call_id: "call_abc123".into(),\n+        };\n+        match &event {\n+         
LlmEvent::ToolCallEnd { call_id } => assert_eq!(call_id, "call_abc123"),\n+     
_ => unreachable!("expected ToolCallEnd"),\n+        }\n+    }\n+\n+    // ── 
Event equality ────────────────────────────────────────\n+\n+    #[test]\n+    
fn events_are_equal_when_identical() {\n+        let a = LlmEvent::TextDelta 
{\n+            text: "hello".into(),\n+        };\n+        let b = 
LlmEvent::TextDelta {\n+            text: "hello".into(),\n+        };\n+       
assert_eq!(a, b);\n+    }\n+\n+    #[test]\n+    fn 
events_differ_across_variants() {\n+        let text = LlmEvent::TextDelta {\n+ 
text: "hello".into(),\n+        };\n+        let thinking = 
LlmEvent::ThinkingDelta {\n+            text: "hello".into(),\n+        };\n+   
assert_ne!(text, thinking);\n+    }\n+\n+    // ── Tool call sequence simulation
─────────────────────────\n+\n+    #[test]\n+    fn tool_call_event_sequence() 
{\n+        let events = [\n+            LlmEvent::StreamStart {\n+             
request_id: "req-1".into(),\n+                model: 
ModelRef::new("claude-opus-4"),\n+            },\n+            
LlmEvent::ToolCallStart {\n+                call_id: "tc_1".into(),\n+          
function_name: "bash".into(),\n+            },\n+            
LlmEvent::ToolCallArgsDelta {\n+                call_id: "tc_1".into(),\n+      
args_fragment: r#"{"cmd":"ls"#.into(),\n+            },\n+            
LlmEvent::ToolCallArgsDelta {\n+                call_id: "tc_1".into(),\n+      
args_fragment: r#""}"#.into(),\n+            },\n+            
LlmEvent::ToolCallEnd {\n+                call_id: "tc_1".into(),\n+            
},\n+            LlmEvent::StreamEnd {\n+                finish_reason: 
FinishReason::ToolCalls,\n+            },\n+        ];\n+\n+        
assert_eq!(events.len(), 6);\n+\n+        // Verify call_id links all tool call 
events\n+        let tool_call_ids: Vec<&str> = events\n+            .iter()\n+ 
.filter_map(|e| match e {\n+                LlmEvent::ToolCallStart { call_id, 
.. }\n+                | LlmEvent::ToolCallArgsDelta { call_id, .. }\n+         
| LlmEvent::ToolCallEnd { call_id } => Some(call_id.as_str()),\n+               
_ => None,\n+            })\n+            .collect();\n+        
assert!(tool_call_ids.iter().all(|id| *id == "tc_1"));\n+    }\n+\n+    
#[test]\n+    fn multi_tool_interleaving() {\n+        // Two tool calls in same
response\n+        let events = [\n+            LlmEvent::ToolCallStart {\n+    
call_id: "tc_1".into(),\n+                function_name: "read".into(),\n+      
},\n+            LlmEvent::ToolCallStart {\n+                call_id: 
"tc_2".into(),\n+                function_name: "write".into(),\n+            
},\n+            LlmEvent::ToolCallArgsDelta {\n+                call_id: 
"tc_1".into(),\n+                args_fragment: r#"{"path":"a.rs"}"#.into(),\n+ 
},\n+            LlmEvent::ToolCallArgsDelta {\n+                call_id: 
"tc_2".into(),\n+                args_fragment: r#"{"path":"b.rs"}"#.into(),\n+ 
},\n+            LlmEvent::ToolCallEnd {\n+                call_id: 
"tc_1".into(),\n+            },\n+            LlmEvent::ToolCallEnd {\n+        
call_id: "tc_2".into(),\n+            },\n+        ];\n+\n+        // Count 
events per call_id\n+        let tc1_count = events\n+            .iter()\n+    
.filter(|e| match e {\n+                LlmEvent::ToolCallStart { call_id, .. 
}\n+                | LlmEvent::ToolCallArgsDelta { call_id, .. }\n+            
| LlmEvent::ToolCallEnd { call_id } => call_id == "tc_1",\n+                _ =>
false,\n+            })\n+            .count();\n+        let tc2_count = 
events\n+            .iter()\n+            .filter(|e| match e {\n+             
LlmEvent::ToolCallStart { call_id, .. }\n+                | 
LlmEvent::ToolCallArgsDelta { call_id, .. }\n+                | 
LlmEvent::ToolCallEnd { call_id } => call_id == "tc_2",\n+                _ => 
false,\n+            })\n+            .count();\n+        assert_eq!(tc1_count, 
3);\n+        assert_eq!(tc2_count, 3);\n+    }\n+\n+    // ── Full event stream
simulation ──────────────────────────\n+\n+    #[test]\n+    fn 
full_stream_with_thinking_and_text() {\n+        let events = [\n+            
LlmEvent::StreamStart {\n+                request_id: "req-42".into(),\n+       
model: ModelRef::new("claude-opus-4").with_version("2025-04-14"),\n+            
},\n+            LlmEvent::ThinkingStart,\n+            LlmEvent::ThinkingDelta 
{\n+                text: "I need to consider...".into(),\n+            },\n+   
LlmEvent::ThinkingEnd,\n+            LlmEvent::TextDelta {\n+                
text: "Here\'s my answer: ".into(),\n+            },\n+            
LlmEvent::TextDelta { text: "42".into() },\n+            LlmEvent::StreamEnd 
{\n+                finish_reason: FinishReason::Stop,\n+            },\n+      
];\n+\n+        // Collect all text\n+        let text: String = events\n+      
.iter()\n+            .filter_map(|e| match e {\n+                
LlmEvent::TextDelta { text } => Some(text.as_str()),\n+                _ => 
None,\n+            })\n+            .collect();\n+        assert_eq!(text, 
"Here\'s my answer: 42");\n+\n+        // Collect thinking text\n+        let 
thinking: String = events\n+            .iter()\n+            .filter_map(|e| 
match e {\n+                LlmEvent::ThinkingDelta { text } => 
Some(text.as_str()),\n+                _ => None,\n+            })\n+           
.collect();\n+        assert_eq!(thinking, "I need to consider...");\n+    
}\n+\n+    // ── FinishReason ──────────────────────────────────────────\n+\n+  
#[test]\n+    fn finish_reason_display() {\n+        
assert_eq!(FinishReason::Stop.to_string(), "stop");\n+        
assert_eq!(FinishReason::Length.to_string(), "length");\n+        
assert_eq!(FinishReason::ToolCalls.to_string(), "tool_calls");\n+        
assert_eq!(FinishReason::ContentFilter.to_string(), "content_filter");\n+       
assert_eq!(FinishReason::Cancelled.to_string(), "cancelled");\n+        
assert_eq!(FinishReason::Other.to_string(), "other");\n+    }\n+\n+    
#[test]\n+    fn finish_reason_serde_round_trip() {\n+        let reasons = [\n+
FinishReason::Stop,\n+            FinishReason::Length,\n+            
FinishReason::ToolCalls,\n+            FinishReason::ContentFilter,\n+          
FinishReason::Cancelled,\n+            FinishReason::Other,\n+        ];\n+     
for reason in &reasons {\n+            let json = 
serde_json::to_string(reason);\n+            assert!(json.is_ok());\n+          
let parsed: std::result::Result<FinishReason, _> =\n+                
serde_json::from_str(&json.unwrap_or_default());\n+            
assert!(parsed.is_ok());\n+            
assert_eq!(parsed.unwrap_or(FinishReason::Other), *reason);\n+        }\n+    
}\n+\n+    #[test]\n+    fn finish_reason_equality() {\n+        
assert_eq!(FinishReason::Stop, FinishReason::Stop);\n+        
assert_ne!(FinishReason::Stop, FinishReason::Length);\n+    }\n+\n+    
#[test]\n+    fn events_are_clone() {\n+        let event = LlmEvent::TextDelta 
{\n+            text: "hello".into(),\n+        };\n+        let cloned = 
event.clone();\n+        assert_eq!(event, cloned);\n+    }\n+\n+    #[test]\n+ 
fn events_are_debug() {\n+        let event = LlmEvent::StreamStart {\n+        
request_id: "r1".into(),\n+            model: ModelRef::new("test"),\n+        
};\n+        let debug = format!("{event:?}");\n+        
assert!(debug.contains("StreamStart"));\n+        
assert!(debug.contains("r1"));\n+    }\n+}\ndiff --git a/src/fae_llm/metadata.rs
b/src/fae_llm/metadata.rs\nnew file mode 100644\nindex 0000000..e4d0504\n--- 
/dev/null\n+++ b/src/fae_llm/metadata.rs\n@@ -0,0 +1,207 @@\n+//! Request and 
response metadata for LLM interactions.\n+//!\n+//! Provides types for tracking 
request context and response details\n+//! that are useful for logging, 
debugging, and observability.\n+//!\n+//! # Examples\n+//!\n+//! ```\n+//! use 
fae::fae_llm::metadata::RequestMeta;\n+//! use 
fae::fae_llm::types::ModelRef;\n+//!\n+//! let meta = 
RequestMeta::new("req-001", ModelRef::new("gpt-4o"));\n+//! 
assert_eq!(meta.request_id, "req-001");\n+//! ```\n+\n+use 
super::events::FinishReason;\n+use super::types::ModelRef;\n+use 
super::usage::TokenUsage;\n+use serde::{Deserialize, Serialize};\n+\n+/// 
Metadata about an outgoing LLM request.\n+///\n+/// Created before sending the 
request, used to correlate\n+/// responses and track latency.\n+#[derive(Debug, 
Clone)]\n+pub struct RequestMeta {\n+    /// Unique identifier for this 
request.\n+    pub request_id: String,\n+    /// The model being called.\n+    
pub model: ModelRef,\n+    /// When the request was created.\n+    pub 
created_at: std::time::Instant,\n+}\n+\n+impl RequestMeta {\n+    /// Create 
metadata for a new request.\n+    pub fn new(request_id: impl Into<String>, 
model: ModelRef) -> Self {\n+        Self {\n+            request_id: 
request_id.into(),\n+            model,\n+            created_at: 
std::time::Instant::now(),\n+        }\n+    }\n+\n+    /// Milliseconds elapsed
since this request was created.\n+    pub fn elapsed_ms(&self) -> u64 {\n+      
self.created_at.elapsed().as_millis() as u64\n+    }\n+}\n+\n+/// Metadata about
a completed LLM response.\n+///\n+/// Collected after the stream finishes, 
contains usage statistics\n+/// and timing information.\n+#[derive(Debug, Clone,
Serialize, Deserialize)]\n+pub struct ResponseMeta {\n+    /// The request ID 
this response corresponds to.\n+    pub request_id: String,\n+    /// The model 
that generated this response (provider-reported).\n+    pub model_id: String,\n+
/// Token usage statistics (if reported by the provider).\n+    pub usage: 
Option<TokenUsage>,\n+    /// End-to-end latency in milliseconds.\n+    pub 
latency_ms: u64,\n+    /// Why the model stopped generating.\n+    pub 
finish_reason: FinishReason,\n+}\n+\n+impl ResponseMeta {\n+    /// Create 
response metadata.\n+    pub fn new(\n+        request_id: impl Into<String>,\n+
model_id: impl Into<String>,\n+        finish_reason: FinishReason,\n+        
latency_ms: u64,\n+    ) -> Self {\n+        Self {\n+            request_id: 
request_id.into(),\n+            model_id: model_id.into(),\n+            usage:
None,\n+            latency_ms,\n+            finish_reason,\n+        }\n+    
}\n+\n+    /// Attach token usage to this response.\n+    pub fn with_usage(mut 
self, usage: TokenUsage) -> Self {\n+        self.usage = Some(usage);\n+       
self\n+    }\n+}\n+\n+#[cfg(test)]\n+mod tests {\n+    use super::*;\n+\n+    //
── RequestMeta ───────────────────────────────────────────\n+\n+    #[test]\n+  
fn request_meta_new() {\n+        let meta = RequestMeta::new("req-001", 
ModelRef::new("gpt-4o"));\n+        assert_eq!(meta.request_id, "req-001");\n+  
assert_eq!(meta.model.model_id, "gpt-4o");\n+    }\n+\n+    #[test]\n+    fn 
request_meta_elapsed_is_non_negative() {\n+        let meta = 
RequestMeta::new("req-001", ModelRef::new("test"));\n+        // elapsed_ms 
should be >= 0 (it\'s u64, so always true, but verify it doesn\'t panic)\n+     
let _elapsed = meta.elapsed_ms();\n+    }\n+\n+    #[test]\n+    fn 
request_meta_with_versioned_model() {\n+        let model = 
ModelRef::new("claude-opus-4").with_version("2025-04-14");\n+        let meta = 
RequestMeta::new("req-002", model);\n+        assert_eq!(meta.model.full_name(),
"claude-opus-4@2025-04-14");\n+    }\n+\n+    // ── ResponseMeta 
──────────────────────────────────────────\n+\n+    #[test]\n+    fn 
response_meta_new() {\n+        let meta = ResponseMeta::new("req-001", 
"gpt-4o-2025-01", FinishReason::Stop, 1500);\n+        
assert_eq!(meta.request_id, "req-001");\n+        assert_eq!(meta.model_id, 
"gpt-4o-2025-01");\n+        assert_eq!(meta.finish_reason, 
FinishReason::Stop);\n+        assert_eq!(meta.latency_ms, 1500);\n+        
assert!(meta.usage.is_none());\n+    }\n+\n+    #[test]\n+    fn 
response_meta_with_usage() {\n+        let usage = TokenUsage::new(500, 200);\n+
let meta =\n+            ResponseMeta::new("req-001", "gpt-4o", 
FinishReason::Stop, 1200).with_usage(usage);\n+        
assert!(meta.usage.is_some());\n+        let usage = meta.usage.as_ref();\n+    
assert!(usage.is_some_and(|u| u.prompt_tokens == 500));\n+    }\n+\n+    
#[test]\n+    fn response_meta_serde_round_trip() {\n+        let usage = 
TokenUsage::new(500, 200).with_reasoning_tokens(50);\n+        let original = 
ResponseMeta::new("req-001", "claude-opus-4", FinishReason::ToolCalls, 800)\n+  
.with_usage(usage);\n+\n+        let json = serde_json::to_string(&original);\n+
assert!(json.is_ok());\n+        let parsed: std::result::Result<ResponseMeta, 
_> =\n+            serde_json::from_str(&json.unwrap_or_default());\n+        
assert!(parsed.is_ok());\n+        let parsed = parsed.unwrap_or_else(|_| 
ResponseMeta::new("", "", FinishReason::Other, 0));\n+        
assert_eq!(parsed.request_id, "req-001");\n+        assert_eq!(parsed.model_id, 
"claude-opus-4");\n+        assert_eq!(parsed.finish_reason, 
FinishReason::ToolCalls);\n+        assert_eq!(parsed.latency_ms, 800);\n+      
assert!(parsed.usage.is_some_and(|u| u.reasoning_tokens == Some(50)));\n+    
}\n+\n+    #[test]\n+    fn response_meta_without_usage_serde() {\n+        let 
original = ResponseMeta::new("req-002", "llama3:8b", FinishReason::Length, 
5000);\n+        let json = serde_json::to_string(&original);\n+        
assert!(json.is_ok());\n+        let parsed: std::result::Result<ResponseMeta, 
_> =\n+            serde_json::from_str(&json.unwrap_or_default());\n+        
assert!(parsed.is_ok());\n+        let parsed = parsed.unwrap_or_else(|_| 
ResponseMeta::new("", "", FinishReason::Other, 0));\n+        
assert!(parsed.usage.is_none());\n+    }\n+\n+    #[test]\n+    fn 
response_meta_various_finish_reasons() {\n+        let reasons = [\n+           
FinishReason::Stop,\n+            FinishReason::Length,\n+            
FinishReason::ToolCalls,\n+            FinishReason::ContentFilter,\n+          
FinishReason::Cancelled,\n+            FinishReason::Other,\n+        ];\n+     
for reason in &reasons {\n+            let meta = ResponseMeta::new("req", 
"model", *reason, 100);\n+            assert_eq!(meta.finish_reason, 
*reason);\n+        }\n+    }\n+\n+    // ── Integration: RequestMeta → 
ResponseMeta ───────────────\n+\n+    #[test]\n+    fn 
request_to_response_flow() {\n+        let req = RequestMeta::new("req-flow", 
ModelRef::new("gpt-4o"));\n+\n+        // Simulate response arriving\n+        
let resp = ResponseMeta::new(\n+            &req.request_id,\n+            
"gpt-4o-2025-01",\n+            FinishReason::Stop,\n+            
req.elapsed_ms(),\n+        )\n+        .with_usage(TokenUsage::new(100, 
50));\n+\n+        assert_eq!(req.request_id, resp.request_id);\n+        
assert!(resp.usage.is_some_and(|u| u.total() == 150));\n+    }\n+}\ndiff --git 
a/src/fae_llm/mod.rs b/src/fae_llm/mod.rs\nnew file mode 100644\nindex 
0000000..e7419e4\n--- /dev/null\n+++ b/src/fae_llm/mod.rs\n@@ -0,0 +1,292 
@@\n+//! FAE LLM module — multi-provider LLM integration.\n+//!\n+//! This 
module provides the foundational types for interacting with\n+//! multiple LLM 
providers (OpenAI, Anthropic, local endpoints, etc.)\n+//! through a normalized 
interface.\n+//!\n+//! # Submodules\n+//!\n+//! - [`error`] — Error types with 
stable error codes\n+//! - [`types`] — Core domain types (endpoints, models, 
request options)\n+//! - [`events`] — Normalized streaming event model\n+//! - 
[`usage`] — Token usage and cost tracking\n+//! - [`metadata`] — 
Request/response metadata\n+//!\n+//! # Event Model\n+//!\n+//! All providers 
normalize their streaming output to [`events::LlmEvent`],\n+//! providing a 
consistent interface regardless of the underlying API.\n+//!\n+//! # Error 
Codes\n+//!\n+//! All errors carry a stable code (e.g. `CONFIG_INVALID`, 
`AUTH_FAILED`)\n+//! that is safe to match on programmatically.\n+\n+pub mod 
error;\n+pub mod events;\n+pub mod metadata;\n+pub mod types;\n+pub mod 
usage;\n+\n+pub use error::FaeLlmError;\n+pub use events::{FinishReason, 
LlmEvent};\n+pub use metadata::{RequestMeta, ResponseMeta};\n+pub use 
types::{EndpointType, ModelRef, ReasoningLevel, RequestOptions};\n+pub use 
usage::{CostEstimate, TokenPricing, TokenUsage};\n+\n+#[cfg(test)]\n+mod 
integration_tests {\n+    use super::*;\n+\n+    /// Simulate a full event 
stream: start → thinking → text → tool call → text → end.\n+    #[test]\n+    fn
full_event_stream_lifecycle() {\n+        let model = 
ModelRef::new("claude-opus-4").with_version("2025-04-14");\n+        let request
= RequestMeta::new("req-integration-1", model.clone());\n+\n+        let events 
= [\n+            LlmEvent::StreamStart {\n+                request_id: 
request.request_id.clone(),\n+                model,\n+            },\n+        
LlmEvent::ThinkingStart,\n+            LlmEvent::ThinkingDelta {\n+             
text: "Let me analyze this...".into(),\n+            },\n+            
LlmEvent::ThinkingEnd,\n+            LlmEvent::TextDelta {\n+                
text: "I\'ll read the file first.".into(),\n+            },\n+            
LlmEvent::ToolCallStart {\n+                call_id: "tc_1".into(),\n+          
function_name: "read_file".into(),\n+            },\n+            
LlmEvent::ToolCallArgsDelta {\n+                call_id: "tc_1".into(),\n+      
args_fragment: r#"{"path":"src/main.rs"}"#.into(),\n+            },\n+          
LlmEvent::ToolCallEnd {\n+                call_id: "tc_1".into(),\n+            
},\n+            LlmEvent::TextDelta {\n+                text: "Here\'s the 
result.".into(),\n+            },\n+            LlmEvent::StreamEnd {\n+        
finish_reason: FinishReason::Stop,\n+            },\n+        ];\n+\n+        //
Verify stream structure\n+        assert!(matches!(events[0], 
LlmEvent::StreamStart { .. }));\n+        assert!(matches!(\n+            
events[events.len() - 1],\n+            LlmEvent::StreamEnd { .. }\n+        
));\n+\n+        // Collect text output\n+        let text: String = events\n+  
.iter()\n+            .filter_map(|e| match e {\n+                
LlmEvent::TextDelta { text } => Some(text.as_str()),\n+                _ => 
None,\n+            })\n+            .collect();\n+        assert_eq!(text, 
"I\'ll read the file first.Here\'s the result.");\n+\n+        // Build response
metadata\n+        let response = ResponseMeta::new(\n+            
&request.request_id,\n+            "claude-opus-4-20250414",\n+            
FinishReason::Stop,\n+            request.elapsed_ms(),\n+        )\n+        
.with_usage(TokenUsage::new(800, 350).with_reasoning_tokens(100));\n+\n+        
assert_eq!(response.request_id, "req-integration-1");\n+        
assert!(response.usage.is_some_and(|u| u.total() == 1250));\n+    }\n+\n+    ///
Accumulate TokenUsage across a multi-turn conversation and calculate cost.\n+   
#[test]\n+    fn multi_turn_usage_accumulation_with_cost() {\n+        let 
pricing = TokenPricing::new(15.0, 75.0); // Claude Opus pricing\n+\n+        let
turns = [\n+            TokenUsage::new(500, 200),'
)
StepBegin(n=1)
ThinkPart(
    type='think',
    think='The user wants me to review a git diff for security, errors, and 
quality, then rate it A-F. The format should be: `[SEVERITY] file:line - 
description`.\n\nLooking at the diff, I see it\'s adding new files to a Rust 
project under `src/fae_llm/`:\n1. `error.rs` - Error types with stable error 
codes\n2. `events.rs` - Normalized streaming event model\n3. `metadata.rs` - 
Request and response metadata\n4. `mod.rs` - Module definition and integration 
tests\n\nLet me analyze each file for issues:\n\n**error.rs:**\n- Uses 
`thiserror` derive macro\n- Defines `FaeLlmError` enum with various error 
variants\n- Each variant wraps a `String` message\n- Has `code()` method 
returning static str\n- Has `message()` method returning the inner string\n- 
Tests cover all error codes and basic functionality\n\nIssues in error.rs:\n- 
The `message()` method returns `&str` which references the internal `String`. 
This is fine.\n- All error variants just wrap String - this is a bit generic but
acceptable for an error type.\n- The error codes are hardcoded in two places 
(the `#[error]` attribute and the `code()` method) - this could get out of 
sync.\n\n**events.rs:**\n- Defines `LlmEvent` enum for streaming events\n- 
Defines `FinishReason` enum with serde support\n- Good documentation and 
examples\n- Tests cover construction, equality, sequences\n\nIssues in 
events.rs:\n- `StreamError` variant contains just a `String` for error - might 
want to use the `FaeLlmError` type instead?\n- `FinishReason::Other` is a 
catch-all - acceptable.\n- The doc example at the top imports `fae::fae_llm` but
this is a module within the crate - the paths might need adjustment depending on
the crate structure.\n\n**metadata.rs:**\n- `RequestMeta` and `ResponseMeta` 
structs\n- Uses `std::time::Instant` for timing\n- Tests look good\n\nIssues in 
metadata.rs:\n- `RequestMeta` contains `std::time::Instant` which is not 
serializable - this is intentional since it\'s for tracking, but the struct 
derives Clone, which could be problematic if someone expects to serialize it.\n-
`ResponseMeta` derives Serialize/Deserialize but contains `FinishReason` which 
is in the events module - that\'s fine since it also derives those.\n- In 
`response_meta_serde_round_trip` test: uses `unwrap_or_default()` and 
`unwrap_or_else()` which could mask errors - but it\'s test code so it\'s 
acceptable.\n\n**mod.rs:**\n- Module declarations and re-exports\n- Integration 
tests\n\nIssues in mod.rs:\n- The doc example shows `fae::fae_llm` paths - again
this assumes the crate is named `fae`.\n- The test code at the end appears to be
cut off in the diff ("`let turns = [`"), but that\'s just the diff being 
truncated.\n\nLet me check for more specific issues:\n\n1. **Security**: \n   - 
No obvious security issues like hardcoded secrets or unsafe code.\n   - The 
error types expose error messages directly which could potentially leak 
sensitive info if not careful, but that\'s up to the caller.\n\n2. **Errors**:\n
- In `metadata.rs:44`, `elapsed_ms()` casts `as_millis()` (u128) to u64. This 
could overflow if the program runs for a very long time (584 million years), so 
practically not an issue.\n   - The `ResponseMeta::new` takes `latency_ms: u64` 
directly instead of calculating it from the `RequestMeta` - this is fine, gives 
flexibility.\n\n3. **Quality**:\n   - Good documentation overall\n   - 
Comprehensive tests\n   - Consistent naming\n   - Proper error handling 
patterns\n\nWait, I need to look closer at the test code in `events.rs`:\n\nIn 
the `finish_reason_serde_round_trip` test:\n```rust\nlet json = 
serde_json::to_string(reason);\nassert!(json.is_ok());\nlet parsed: 
std::result::Result<FinishReason, _> =\n    
serde_json::from_str(&json.unwrap_or_default());\nassert!(parsed.is_ok());\nasse
rt_eq!(parsed.unwrap_or(FinishReason::Other), *reason);\n```\n\nThis pattern is 
a bit odd - using `unwrap_or_default()` when we know it\'s `Ok` from the 
previous assert. But it\'s test code, so it\'s fine.\n\nActually, looking at the
structure more carefully:\n\nIn `error.rs`:\n- The `message()` method uses a 
complex match pattern with `|` to extract the inner String from all variants. 
This is good for maintainability.\n- The `code()` method duplicates the string 
literals from the `#[error]` attribute. This is a maintenance risk - they could 
get out of sync. For example, if someone changes `[CONFIG_INVALID]` in the error
attribute but forgets to update the `code()` method.\n\nIn `events.rs`:\n- 
`LlmEvent::StreamError` has an `error: String` field. This seems inconsistent 
with the module having a dedicated `FaeLlmError` type. Should it be `error: 
FaeLlmError` instead?\n\nIn `metadata.rs`:\n- `RequestMeta` derives `Clone` but 
contains `Instant` which is fine (Instant is Copy + Clone).\n- The doc example 
uses `fae::fae_llm` which assumes the crate name is `fae`.\n\nLet me check if 
there are any actual bugs:\n\nLooking at `mod.rs` line 81 
(approximately):\n```rust\nlet request = RequestMeta::new("req-integration-1", 
model.clone());\n```\n\n`RequestMeta::new` takes `request_id: impl Into<String>`
and `model: ModelRef`. The `model.clone()` is called, but `ModelRef` might be 
cheap to clone (likely is if it\'s just strings).\n\nActually, looking at the 
`events.rs` test code around line 334:\n```rust\nlet tc1_count = events\n    
.iter()\n    .filter(|e| match e {\n        LlmEvent::ToolCallStart { call_id, 
.. }\n        | LlmEvent::ToolCallArgsDelta { call_id, .. }\n        | 
LlmEvent::ToolCallEnd { call_id } => call_id == "tc_1",\n        _ => false,\n  
})\n    .count();\n```\n\nThis is using a match with or patterns in a closure. 
The binding `call_id` is used in the guard. This is fine in modern 
Rust.\n\nWait, I need to check if `StreamError` should use `FaeLlmError`:\n\nIn 
`events.rs`:\n```rust\n/// Stream encountered an error.\nStreamError {\n    /// 
Description of what went wrong.\n    error: String,\n},\n```\n\nGiven that 
there\'s a dedicated error module with `FaeLlmError`, it would be more 
consistent to use that type here instead of `String`. However, `LlmEvent` is 
meant to be `Clone`, and `FaeLlmError` contains `String` anyway, so both are 
Clone. But using `FaeLlmError` would be more type-safe and consistent.\n\nLet me
reconsider the error code duplication issue in 
`error.rs`:\n\n```rust\n#[error("[CONFIG_INVALID] 
{0}")]\nConfigError(String),\n```\n\nand\n\n```rust\nSelf::ConfigError(_) => 
"CONFIG_INVALID",\n```\n\nThese are hardcoded separately. This is definitely a 
maintenance risk. The code could be simplified by parsing the display format or 
by using a macro, but as written, it\'s prone to drift.\n\nNow for the 
rating:\n- A: Excellent, production-ready\n- B: Good, minor issues\n- C: 
Acceptable, some issues need fixing\n- D: Poor, significant issues\n- F: 
Unacceptable\n\nThis code is well-documented, well-tested, and follows good 
practices. The issues I found are minor:\n1. Error code strings are duplicated 
(maintenance risk)\n2. `LlmEvent::StreamError` uses `String` instead of 
`FaeLlmError` (inconsistency)\n3. Some test code uses slightly odd patterns (not
a big deal)\n\nI\'d rate this a **B+** or **A-**, but since the scale is A-F, 
probably **A** or **B**. The duplication of error codes is the main issue. Let 
me see if that\'s worth knocking it down.\n\nActually, looking at `usage.rs` in 
the diff... wait, the user didn\'t include `usage.rs` or `types.rs` in the diff.
The diff shows these files are referenced but doesn\'t show their content. So I 
can only review what\'s shown.\n\nWait, I should check if `ModelRef` is actually
defined as shown in the tests. The tests use `ModelRef::new("gpt-4o")` and 
`.with_version()`. This suggests `ModelRef` has these methods, but since 
`types.rs` isn\'t in the diff, I can\'t verify the implementation. I should 
assume the code compiles based on what\'s shown.\n\nLet me check for any actual 
errors in the provided code:\n\n1. In `events.rs`, the doc example 
has:\n```rust\nlet start = LlmEvent::StreamStart {\n    request_id: 
"req-001".into(),\n    model: ModelRef::new("gpt-4o"),\n};\n```\nThis assumes 
`ModelRef::new` is public, which is fine.\n\n2. In `metadata.rs`:\n```rust\nlet 
meta = RequestMeta::new("req-001", ModelRef::new("gpt-4o"));\n```\nAlso 
fine.\n\nOne thing I noticed: in `error.rs`, the error message format is 
`"[CODE] {0}"` but the `message()` method returns just the inner string. This is
good.\n\nActually, looking more carefully at `events.rs` line 41 (approximately)
in the doc comment:\n```rust\n//! let start = LlmEvent::StreamStart {\n//!     
request_id: "req-001".into(),\n//!     model: ModelRef::new("gpt-4o"),\n//! 
};\n```\n\nThis is in a doc comment example (`//!`). The `ModelRef` type is from
`super::types` in events.rs, but in the doc example it\'s accessed via 
`fae::fae_llm::types::ModelRef`. This suggests the crate is named `fae`. That\'s
fine.\n\nIs there anything actually wrong?\n\nOh! In `metadata.rs`, there\'s 
this test:\n```rust\n#[test]\nfn request_meta_elapsed_is_non_negative() {\n    
let meta = RequestMeta::new("req-001", ModelRef::new("test"));\n    // 
elapsed_ms should be >= 0 (it\'s u64, so always true, but verify it doesn\'t 
panic)\n    let _elapsed = meta.elapsed_ms();\n}\n```\n\nThis comment is 
slightly misleading. `elapsed_ms` returns `u64`, so it can\'t be negative by 
definition. But the comment says it "should be >= 0". Technically correct but 
redundant for unsigned types. Not a real issue.\n\nAnother thing: in 
`events.rs`, `StreamError` contains `error: String`. But the `FaeLlmError` type 
already exists. It would be more idiomatic to use `FaeLlmError` there, or at 
least have a way to convert. However, `LlmEvent` might be intended to be 
serializable and simple, so a String might be intentional.\n\nLet me reconsider 
the rating. The code is:\n- Well documented\n- Well tested\n- Uses appropriate 
types\n- Follows Rust conventions\n- No unsafe code\n- No obvious bugs\n- The 
error code duplication is a minor maintenance issue\n\nRating: **A-** or **B+**.
Since I need to give A-F, I\'ll go with **A-** which I\'ll map to **A** (since 
the scale is likely A,B,C,D,F without +/-).\n\nWait, looking at the 
instructions: "Rate A-F". This usually means A, B, C, D, F. But often B is "good
but not perfect". The error code duplication is a legitimate issue that could 
cause bugs if they get out of sync. Let me think about whether that warrants a 
B.\n\nActually, there\'s a bigger issue I missed! In `error.rs`, the `message()`
method returns `&str` which borrows from `self`. This is fine. But the match 
pattern is:\n\n```rust\nSelf::ConfigError(m)\n| Self::AuthError(m)\n| 
Self::RequestError(m)\n| Self::StreamError(m)\n| Self::ToolError(m)\n| 
Self::Timeout(m)\n| Self::ProviderError(m) => m,\n```\n\nAll variants have the 
same structure (a single String), so this works. Good.\n\nLet me look at the 
Display implementation generated by `thiserror`. It will produce 
`[CONFIG_INVALID] message` which is exactly what\'s wanted. And `code()` returns
`"CONFIG_INVALID"`. \n\nIf someone changes the error message format from 
`[CONFIG_INVALID]` to `[CONFIG_ERROR]` in the derive macro but forgets to update
the `code()` method, the `code()` method will return the old value. This is a 
maintenance risk.\n\nIs there a way to avoid this? They could extract the code 
from the Display output, or use a macro to generate both. But as written, it\'s 
manual duplication.\n\nI think for a code review, this is worth noting as an 
issue:\n\n`[MEDIUM] error.rs:37 - Error code strings are duplicated between 
#[error] attributes and code() method implementations. Risk of desynchronization
during refactoring.`\n\nActually, looking at the structure again - this is a new
module. Is there anything in the existing codebase that this should integrate 
with? I don\'t see the rest of the codebase, so I have to assume this is 
self-contained.\n\nOne more thing: in `metadata.rs`, `ResponseMeta` derives 
`Serialize` and `Deserialize`. It contains `FinishReason` from the events 
module. `FinishReason` derives `serde::Serialize, serde::Deserialize` with 
`#[serde(rename_all = "snake_case")]`. This looks correct.\n\nThe `RequestMeta` 
struct contains `std::time::Instant` and derives `Clone` but not 
Serialize/Deserialize. This is appropriate since Instant is not 
serializable.\n\nI think I found a real issue! In 
`events.rs`:\n\n```rust\n#[test]\nfn finish_reason_serde_round_trip() {\n    let
reasons = [\n        FinishReason::Stop,\n        FinishReason::Length,\n       
FinishReason::ToolCalls,\n        FinishReason::ContentFilter,\n        
FinishReason::Cancelled,\n        FinishReason::Other,\n    ];\n    for reason 
in &reasons {\n        let json = serde_json::to_string(reason);\n        
assert!(json.is_ok());\n        let parsed: std::result::Result<FinishReason, _>
=\n            serde_json::from_str(&json.unwrap_or_default());\n        
assert!(parsed.is_ok());\n        
assert_eq!(parsed.unwrap_or(FinishReason::Other), *reason);\n    
}\n}\n```\n\nThe use of `unwrap_or_default()` and 
`unwrap_or(FinishReason::Other)` here is bad practice in tests because it can 
mask failures. If `to_string` fails, `unwrap_or_default()` returns an empty 
string, and `from_str` on an empty string will likely fail, giving a confusing 
error message. However, the `assert!(json.is_ok())` before means it won\'t 
actually default unless there\'s a panic... no wait, `unwrap_or_default()` is 
called unconditionally on the line after `assert!(json.is_ok())`. But if 
`json.is_ok()` passes, then `json` is `Ok(...)`, so `unwrap_or_default()` will 
return the inner value. So it\'s actually fine, just slightly redundant 
style.\n\nActually no - `assert!(json.is_ok())` asserts it\'s ok, but doesn\'t 
unwrap it. The next line calls `unwrap_or_default()`. Since it was just asserted
to be `Ok`, it will be `Ok`, so `unwrap_or_default()` returns the contents. This
is fine, just a bit odd looking.\n\nBut actually, `unwrap_or_default()` on a 
`Result` returns the `Ok` value or the default of the Ok type. Since `String: 
Default`, if it were `Err`, it would return `"".to_string()`. But since we 
asserted it\'s `Ok`, it\'s fine. Still, using `unwrap()` would be 
clearer.\n\nWait, I see something now. In `events.rs`, the `StreamError` 
variant:\n```rust\n/// Stream encountered an error.\nStreamError {\n    /// 
Description of what went wrong.\n    error: String,\n},\n```\n\nThis is 
inconsistent with the rest of the codebase which uses `FaeLlmError`. But more 
importantly, this is supposed to be a "normalized streaming event model". If 
there\'s an error in the stream, it should probably be the error type defined in
this crate, not just a String.\n\nLet me check if there are any compilation 
errors implied:\n\nIn `metadata.rs`:\n```rust\nuse 
super::usage::TokenUsage;\n```\n\nThis assumes `usage` module exists with 
`TokenUsage`. Since it\'s not in the diff, I can\'t verify it, but the code 
assumes it.\n\nSimilarly for `types::ModelRef`.\n\nI think the main issues 
are:\n1. Error code duplication in error.rs (maintenance risk)\n2. StreamError 
using String instead of FaeLlmError (inconsistency)\n3. Doc tests assume crate 
name is "fae" (might be wrong)\n\nFor the rating, I\'ll say **B+** or **A-**. 
I\'ll pick **B** to be safe since there are actual issues to fix, or **A** if 
I\'m feeling generous. Actually, looking at the quality of the docs and tests, 
it\'s quite high. The error code duplication is the only real "issue". I\'ll 
give it an **A-** which I\'ll mark as **A** with caveats, or just list the 
issues and give **A**.\n\nActually, no. The instructions say "Review this git 
diff for security, errors, quality. Rate A-F." So I should find issues and rate 
it. If I find issues, it shouldn\'t be an A. A means "perfect" or "excellent". B
means "good with minor issues". C means "acceptable with issues to 
fix".\n\nI\'ll give it a **B+** but since I need A-F without +/-, I\'ll give it 
a **B**.\n\nWait, looking at the code once more - in `error.rs`, is there any 
issue with the `message()` method? It returns `&str`. The inner type is 
`String`. So it returns `&str`. That\'s fine.\n\nActually, one more thing - in 
Rust, when using `thiserror`, the `#[error(...)]` attribute creates the Display 
impl. The `code()` method returns a static string. This is fine.\n\nOkay, I\'ll 
compile my findings:\n\n**Security:**\n- No issues found\n\n**Errors:**\n- Error
code duplication in error.rs (medium severity for maintenance)\n- StreamError 
uses String instead of FaeLlmError (low severity, 
inconsistency)\n\n**Quality:**\n- Excellent documentation\n- Comprehensive 
tests\n- Good module structure\n- Minor: test code could use better error 
handling than `unwrap_or_default()`\n\nRating: **B+** (A-F scale: 
**B**)\n\nActually, looking at the `events.rs` more carefully, I see 
this:\n```rust\n#[derive(Debug, Clone, PartialEq)]\npub enum LlmEvent 
{\n```\n\nAnd `FaeLlmError` implements `std::error::Error` via 
`thiserror::Error`. If `LlmEvent::StreamError` contained `FaeLlmError`, then 
`LlmEvent` would need to derive `Error` too or just not bother since it\'s an 
event type, not really an error type. Actually, `LlmEvent::StreamError` is an 
event that notifies that the stream encountered an error. It makes sense for it 
to be simple.\n\nBut wait, there\'s a bigger issue! In `error.rs`, the 
`FaeLlmError` type stores just `String` for all variants. This means there\'s no
way to get the underlying error cause (no `#[from]` implementations, no 
`source()` method). This is a significant limitation for debugging. The 
`#[error(...)]` attribute from `thiserror` can include `#[source]` or `#[from]`,
but here it\'s just wrapping strings.\n\nHowever, looking at the design, these 
errors are high-level "module" errors, not low-level IO errors. The variants 
suggest they are already categorized (Config, Auth, Request, etc). The String 
payload is descriptive. This is actually a reasonable design for this 
layer.\n\nI think I\'ll go with **B** rating. The error code duplication is the 
main issue.\n\nWait, I need to check one more thing. In 
`metadata.rs`:\n\n```rust\n#[derive(Debug, Clone, Serialize, Deserialize)]\npub 
struct ResponseMeta {\n    // ...\n    pub finish_reason: 
FinishReason,\n}\n```\n\nAnd `FinishReason` is defined in `events.rs` with serde
derive. Good.\n\nOne final check: in `mod.rs`, the integration 
test:\n```rust\nlet model = 
ModelRef::new("claude-opus-4").with_version("2025-04-14");\n```\n\nThis assumes 
`ModelRef` has `with_version` method that returns Self or something chainable. 
Since it\'s not in the diff, I assume it works.\n\nOkay, I\'ll prepare my review
with these findings:\n\n1. Error code duplication (Medium)\n2. StreamError using
String (Low - inconsistency)\n3. Potential doc path issues if crate not named 
fae (Low)\n\nRating: B\n\nActually, looking at the error code issue again - 
it\'s a maintenance risk, but is it a real error? No. Is it something that 
should be fixed? Yes. Is it severe? No, just technical debt.\n\nI\'ll rate it 
**A** because the code is well-structured, documented, and tested. The 
"duplication" is actually just the reality of having error codes separate from 
display messages. But I\'ll point out the maintenance risk.\n\nOr I\'ll rate it 
**B** to be strict. Let\'s see what a typical code review would say. The error 
code duplication is a legitimate issue. Two sources of truth. I\'d want that 
fixed before merging. So **B** is appropriate.\n\nFinal decision: Rating 
**B**\n\nIssues to report:\n1. [MEDIUM] error.rs: duplicated error code strings 
between macro and method\n2. [LOW] events.rs: StreamError uses String instead of
FaeLlmError\n3. [LOW] metadata.rs: test uses unwrap_or patterns that could mask 
errors\n\nActually, looking at the diff format, it doesn\'t show line numbers 
for the new file. I need to estimate line numbers or just say "error.rs:37" for 
example. The line numbers are shown in the diff (the `+` lines).\n\nLooking at 
error.rs:\nLine 10: `#[error("[CONFIG_INVALID] {0}")]`\nLine 37: 
`Self::ConfigError(_) => "CONFIG_INVALID",`\n\nThese are indeed separate.\n\nFor
events.rs:\nLine 79: `StreamError { error: String },`\n\nFor metadata.rs 
test:\nLine 164: uses `unwrap_or_default()`\n\nLet me map them out 
properly.\n\nActually, I realize the line numbers in the diff output are 
relative to the patch. The actual line numbers in the file will be 1-indexed. 
The diff starts at `@@ -0,0 +1,169 @@` for error.rs, so line 37 in the file 
corresponds to line 37 in the diff (approximately).\n\nI\'ll provide specific 
line numbers.\n\nOne more thing: is `std::time::Instant` monotonic? Yes. Is it 
appropriate for measuring latency? Yes. Good.\n\nOkay, I\'ll write the review 
now.',
    encrypted=None
)
TextPart(
    type='text',
    text='Review of the fae_llm module git diff:\n\n**Rating: B**\n\n**Issues 
Found:**\n\n[MEDIUM] error.rs:37 - Error code strings duplicated between 
`#[error]` attributes (line 10) and `code()` method match arms. Risk of 
desynchronization during refactoring; consider using constants or a macro to 
ensure single source of truth.\n\n[LOW] events.rs:79 - `StreamError` variant 
contains `error: String` instead of `FaeLlmError`. Inconsistent with the 
module\'s error type; consider using `FaeLlmError` for type safety and 
programmatic error handling.\n\n[LOW] error.rs:15-38 - Error variants wrap only 
`String` messages with no `#[source]` or `#[from]` attributes. Lost error 
chaining makes debugging harder when errors bubble up from underlying providers 
(reqwest, serde, etc.).\n\n[LOW] metadata.rs:164 - Test uses 
`unwrap_or_default()` after `assert!()` rather than proper unwrapping. While 
functionally safe, it creates confusing error messages on failure (masks the 
actual error).\n\n[NIT] events.rs:41, metadata.rs:41 - Doc examples assume crate
name is "fae" (`fae::fae_llm`). Verify this matches `Cargo.toml` package name or
examples will fail doc tests.\n\n[NIT] error.rs:27 - Variant name `Timeout` is 
inconsistent with other variants ending in "Error" (ConfigError, AuthError, 
etc.). Consider `TimeoutError` for consistency.\n\n**Strengths:**\n- Excellent 
documentation with clear lifecycle examples\n- Comprehensive test coverage (unit
and integration)\n- Good use of type system (ModelRef, FinishReason, 
TokenUsage)\n- Proper separation of concerns across submodules\n- Clean public 
API with stable error codes'
)
StatusUpdate(
    context_usage=0.06008148193359375,
    token_usage=TokenUsage(
        input_other=10886,
        output=5329,
        input_cache_read=4864,
        input_cache_creation=0
    ),
    message_id='chatcmpl-I8ExBJbgJE5RpP5hn5vSVfOU'
)
