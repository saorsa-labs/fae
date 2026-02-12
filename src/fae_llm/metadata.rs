//! Request and response metadata for LLM interactions.
//!
//! Provides types for tracking request context and response details
//! that are useful for logging, debugging, and observability.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::metadata::RequestMeta;
//! use fae::fae_llm::types::ModelRef;
//!
//! let meta = RequestMeta::new("req-001", ModelRef::new("gpt-4o"));
//! assert_eq!(meta.request_id, "req-001");
//! ```

use super::events::FinishReason;
use super::types::ModelRef;
use super::usage::TokenUsage;
use serde::{Deserialize, Serialize};

/// Metadata about an outgoing LLM request.
///
/// Created before sending the request, used to correlate
/// responses and track latency.
#[derive(Debug, Clone)]
pub struct RequestMeta {
    /// Unique identifier for this request.
    pub request_id: String,
    /// The model being called.
    pub model: ModelRef,
    /// When the request was created.
    pub created_at: std::time::Instant,
}

impl RequestMeta {
    /// Create metadata for a new request.
    pub fn new(request_id: impl Into<String>, model: ModelRef) -> Self {
        Self {
            request_id: request_id.into(),
            model,
            created_at: std::time::Instant::now(),
        }
    }

    /// Milliseconds elapsed since this request was created.
    pub fn elapsed_ms(&self) -> u64 {
        self.created_at.elapsed().as_millis() as u64
    }
}

/// Metadata about a completed LLM response.
///
/// Collected after the stream finishes, contains usage statistics
/// and timing information.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResponseMeta {
    /// The request ID this response corresponds to.
    pub request_id: String,
    /// The model that generated this response (provider-reported).
    pub model_id: String,
    /// Token usage statistics (if reported by the provider).
    pub usage: Option<TokenUsage>,
    /// End-to-end latency in milliseconds.
    pub latency_ms: u64,
    /// Why the model stopped generating.
    pub finish_reason: FinishReason,
}

impl ResponseMeta {
    /// Create response metadata.
    pub fn new(
        request_id: impl Into<String>,
        model_id: impl Into<String>,
        finish_reason: FinishReason,
        latency_ms: u64,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            model_id: model_id.into(),
            usage: None,
            latency_ms,
            finish_reason,
        }
    }

    /// Attach token usage to this response.
    pub fn with_usage(mut self, usage: TokenUsage) -> Self {
        self.usage = Some(usage);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── RequestMeta ───────────────────────────────────────────

    #[test]
    fn request_meta_new() {
        let meta = RequestMeta::new("req-001", ModelRef::new("gpt-4o"));
        assert_eq!(meta.request_id, "req-001");
        assert_eq!(meta.model.model_id, "gpt-4o");
    }

    #[test]
    fn request_meta_elapsed_is_non_negative() {
        let meta = RequestMeta::new("req-001", ModelRef::new("test"));
        // elapsed_ms should be >= 0 (it's u64, so always true, but verify it doesn't panic)
        let _elapsed = meta.elapsed_ms();
    }

    #[test]
    fn request_meta_with_versioned_model() {
        let model = ModelRef::new("claude-opus-4").with_version("2025-04-14");
        let meta = RequestMeta::new("req-002", model);
        assert_eq!(meta.model.full_name(), "claude-opus-4@2025-04-14");
    }

    // ── ResponseMeta ──────────────────────────────────────────

    #[test]
    fn response_meta_new() {
        let meta = ResponseMeta::new("req-001", "gpt-4o-2025-01", FinishReason::Stop, 1500);
        assert_eq!(meta.request_id, "req-001");
        assert_eq!(meta.model_id, "gpt-4o-2025-01");
        assert_eq!(meta.finish_reason, FinishReason::Stop);
        assert_eq!(meta.latency_ms, 1500);
        assert!(meta.usage.is_none());
    }

    #[test]
    fn response_meta_with_usage() {
        let usage = TokenUsage::new(500, 200);
        let meta =
            ResponseMeta::new("req-001", "gpt-4o", FinishReason::Stop, 1200).with_usage(usage);
        assert!(meta.usage.is_some());
        let usage = meta.usage.as_ref();
        assert!(usage.is_some_and(|u| u.prompt_tokens == 500));
    }

    #[test]
    fn response_meta_serde_round_trip() {
        let usage = TokenUsage::new(500, 200).with_reasoning_tokens(50);
        let original = ResponseMeta::new("req-001", "claude-opus-4", FinishReason::ToolCalls, 800)
            .with_usage(usage);

        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<ResponseMeta, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
        let parsed = parsed.unwrap_or_else(|_| ResponseMeta::new("", "", FinishReason::Other, 0));
        assert_eq!(parsed.request_id, "req-001");
        assert_eq!(parsed.model_id, "claude-opus-4");
        assert_eq!(parsed.finish_reason, FinishReason::ToolCalls);
        assert_eq!(parsed.latency_ms, 800);
        assert!(parsed.usage.is_some_and(|u| u.reasoning_tokens == Some(50)));
    }

    #[test]
    fn response_meta_without_usage_serde() {
        let original = ResponseMeta::new("req-002", "llama3:8b", FinishReason::Length, 5000);
        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<ResponseMeta, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
        let parsed = parsed.unwrap_or_else(|_| ResponseMeta::new("", "", FinishReason::Other, 0));
        assert!(parsed.usage.is_none());
    }

    #[test]
    fn response_meta_various_finish_reasons() {
        let reasons = [
            FinishReason::Stop,
            FinishReason::Length,
            FinishReason::ToolCalls,
            FinishReason::ContentFilter,
            FinishReason::Cancelled,
            FinishReason::Other,
        ];
        for reason in &reasons {
            let meta = ResponseMeta::new("req", "model", *reason, 100);
            assert_eq!(meta.finish_reason, *reason);
        }
    }

    // ── Integration: RequestMeta → ResponseMeta ───────────────

    #[test]
    fn request_to_response_flow() {
        let req = RequestMeta::new("req-flow", ModelRef::new("gpt-4o"));

        // Simulate response arriving
        let resp = ResponseMeta::new(
            &req.request_id,
            "gpt-4o-2025-01",
            FinishReason::Stop,
            req.elapsed_ms(),
        )
        .with_usage(TokenUsage::new(100, 50));

        assert_eq!(req.request_id, resp.request_id);
        assert!(resp.usage.is_some_and(|u| u.total() == 150));
    }
}
