//! Fallback provider adapter.
//!
//! Wraps a primary (remote) provider with a local fallback. When the primary
//! provider returns a retryable error (network failure, timeout, rate limit),
//! the request is transparently retried against the local model.

use async_trait::async_trait;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::fae_llm::LlmEventStream;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::provider::{ProviderAdapter, ToolDefinition};
use crate::fae_llm::providers::message::Message;
use crate::fae_llm::types::{EndpointType, RequestOptions};

/// A provider adapter that falls back to a local model on retryable errors.
///
/// The adapter tries the primary provider first. If the primary returns a
/// retryable error (network, timeout, rate-limit), the same request is
/// forwarded to the fallback (local) provider. Non-retryable errors
/// (auth, config) are propagated immediately.
pub struct FallbackProvider {
    primary: Arc<dyn ProviderAdapter>,
    fallback: Arc<dyn ProviderAdapter>,
    /// Count of fallback activations (for observability).
    fallback_count: AtomicU32,
}

impl FallbackProvider {
    /// Create a new fallback-enabled provider.
    ///
    /// - `primary`: the preferred provider (typically a remote API).
    /// - `fallback`: the backup provider (typically local mistralrs).
    pub fn new(primary: Arc<dyn ProviderAdapter>, fallback: Arc<dyn ProviderAdapter>) -> Self {
        Self {
            primary,
            fallback,
            fallback_count: AtomicU32::new(0),
        }
    }

    /// Number of times the fallback provider has been activated.
    pub fn fallback_count(&self) -> u32 {
        self.fallback_count.load(Ordering::Relaxed)
    }
}

impl std::fmt::Debug for FallbackProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FallbackProvider")
            .field("primary", &self.primary.name())
            .field("fallback", &self.fallback.name())
            .field("fallback_count", &self.fallback_count())
            .finish()
    }
}

#[async_trait]
impl ProviderAdapter for FallbackProvider {
    fn name(&self) -> &str {
        "fallback"
    }

    fn endpoint_type(&self) -> EndpointType {
        self.primary.endpoint_type()
    }

    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> std::result::Result<LlmEventStream, FaeLlmError> {
        match self.primary.send(messages, options, tools).await {
            Ok(stream) => Ok(stream),
            Err(e) if e.is_retryable() => {
                self.fallback_count.fetch_add(1, Ordering::Relaxed);
                tracing::warn!(
                    primary = self.primary.name(),
                    fallback = self.fallback.name(),
                    error = %e,
                    "primary provider failed with retryable error, falling back to local model"
                );
                self.fallback.send(messages, options, tools).await
            }
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::events::{FinishReason, LlmEvent};

    /// A test provider that always succeeds with a single StreamEnd event.
    struct SuccessProvider {
        label: &'static str,
    }

    #[async_trait]
    impl ProviderAdapter for SuccessProvider {
        fn name(&self) -> &str {
            self.label
        }

        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> std::result::Result<LlmEventStream, FaeLlmError> {
            Ok(Box::pin(futures_util::stream::iter(vec![
                LlmEvent::StreamEnd {
                    finish_reason: FinishReason::Stop,
                },
            ])))
        }
    }

    /// A test provider that always returns a retryable error.
    struct RetryableErrorProvider;

    #[async_trait]
    impl ProviderAdapter for RetryableErrorProvider {
        fn name(&self) -> &str {
            "retryable-error"
        }

        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> std::result::Result<LlmEventStream, FaeLlmError> {
            Err(FaeLlmError::RequestError("connection refused".to_string()))
        }
    }

    /// A test provider that always returns a non-retryable error.
    struct NonRetryableErrorProvider;

    #[async_trait]
    impl ProviderAdapter for NonRetryableErrorProvider {
        fn name(&self) -> &str {
            "non-retryable-error"
        }

        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> std::result::Result<LlmEventStream, FaeLlmError> {
            Err(FaeLlmError::AuthError("invalid API key".to_string()))
        }
    }

    #[tokio::test]
    async fn primary_success_does_not_use_fallback() {
        let provider = FallbackProvider::new(
            Arc::new(SuccessProvider { label: "primary" }),
            Arc::new(SuccessProvider { label: "fallback" }),
        );

        let result = provider.send(&[], &RequestOptions::new(), &[]).await;
        assert!(result.is_ok());
        assert_eq!(provider.fallback_count(), 0);
    }

    #[tokio::test]
    async fn retryable_error_triggers_fallback() {
        let provider = FallbackProvider::new(
            Arc::new(RetryableErrorProvider),
            Arc::new(SuccessProvider { label: "fallback" }),
        );

        let result = provider.send(&[], &RequestOptions::new(), &[]).await;
        assert!(result.is_ok());
        assert_eq!(provider.fallback_count(), 1);
    }

    #[tokio::test]
    async fn non_retryable_error_propagates() {
        let provider = FallbackProvider::new(
            Arc::new(NonRetryableErrorProvider),
            Arc::new(SuccessProvider { label: "fallback" }),
        );

        let result = provider.send(&[], &RequestOptions::new(), &[]).await;
        assert!(result.is_err());
        assert_eq!(provider.fallback_count(), 0);
    }

    #[tokio::test]
    async fn fallback_count_increments_across_calls() {
        let provider = FallbackProvider::new(
            Arc::new(RetryableErrorProvider),
            Arc::new(SuccessProvider { label: "fallback" }),
        );

        for _ in 0..3 {
            let _ = provider.send(&[], &RequestOptions::new(), &[]).await;
        }
        assert_eq!(provider.fallback_count(), 3);
    }

    #[test]
    fn debug_impl_shows_provider_names() {
        let provider = FallbackProvider::new(
            Arc::new(SuccessProvider { label: "openai" }),
            Arc::new(SuccessProvider { label: "mistralrs" }),
        );
        let debug = format!("{provider:?}");
        assert!(debug.contains("openai"));
        assert!(debug.contains("mistralrs"));
    }

    #[test]
    fn name_returns_fallback() {
        let provider = FallbackProvider::new(
            Arc::new(SuccessProvider { label: "primary" }),
            Arc::new(SuccessProvider { label: "local" }),
        );
        assert_eq!(provider.name(), "fallback");
    }
}
