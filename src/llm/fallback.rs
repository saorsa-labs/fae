//! Network-resilience fallback chain for external LLM providers.
//!
//! [`FallbackChain`] holds an ordered list of provider names and tracks which
//! ones have failed during the current request. The pipeline consults it to
//! decide which provider to try next when a transient error occurs.
//!
//! # Retry policy
//!
//! - **Transient errors** (timeout, 5xx HTTP, connection refused): retry up to
//!   [`RETRY_ATTEMPTS`] times with [`RETRY_BACKOFF_MS`] delay, then move to
//!   the next provider in the chain.
//! - **Permanent errors** (auth failure, 4xx HTTP): skip to the next provider
//!   immediately without retrying.
//!
//! # Example
//!
//! ```rust
//! use fae::llm::fallback::{FallbackChain, ProviderError};
//!
//! let mut chain = FallbackChain::new(vec!["anthropic".into(), "openai".into(), "local".into()]);
//!
//! // First provider fails transiently — exhausts retries, moves to next.
//! assert_eq!(chain.next_provider(), Some("anthropic".to_string()));
//! chain.report_failure("anthropic", ProviderError::Transient("timeout".into()));
//! chain.report_failure("anthropic", ProviderError::Transient("timeout".into()));
//! chain.report_failure("anthropic", ProviderError::Transient("timeout".into()));
//!
//! // Second provider fails permanently — skip immediately.
//! assert_eq!(chain.next_provider(), Some("openai".to_string()));
//! chain.report_failure("openai", ProviderError::Permanent("auth failure".into()));
//!
//! // Fall through to local.
//! assert_eq!(chain.next_provider(), Some("local".to_string()));
//! chain.report_success("local");
//! assert!(chain.current_provider().is_some());
//! ```

use std::collections::HashMap;
use tracing::{info, warn};

/// Number of retry attempts for a transient error before trying the next provider.
pub const RETRY_ATTEMPTS: u32 = 3;

/// Delay in milliseconds between transient-error retries.
pub const RETRY_BACKOFF_MS: u64 = 500;

/// Errors reported by a provider attempt.
#[derive(Debug, Clone)]
pub enum ProviderError {
    /// A transient error (timeout, 5xx, connection refused).
    ///
    /// The chain will retry up to [`RETRY_ATTEMPTS`] times before skipping to
    /// the next provider.
    Transient(String),
    /// A permanent error (auth failure, 4xx).
    ///
    /// The chain skips this provider immediately without retrying.
    Permanent(String),
}

/// Per-provider failure tracking.
#[derive(Debug, Default)]
struct ProviderState {
    /// Number of consecutive transient failures for this provider.
    transient_failures: u32,
    /// Whether this provider has a permanent failure and should be skipped.
    permanently_failed: bool,
}

/// Ordered fallback chain for LLM providers.
///
/// Providers are tried in order. Transient failures trigger retries (up to
/// [`RETRY_ATTEMPTS`]); after exhausting retries the next provider is used.
/// Permanent failures skip the provider immediately.
#[derive(Debug)]
pub struct FallbackChain {
    /// Ordered list of provider names.
    providers: Vec<String>,
    /// Per-provider failure state.
    state: HashMap<String, ProviderState>,
    /// Index of the currently active provider in `providers`.
    current_index: usize,
    /// Whether any provider has succeeded in this chain's lifetime.
    any_success: bool,
}

impl FallbackChain {
    /// Create a new chain with the given ordered provider names.
    ///
    /// The first provider in the list is tried first.
    pub fn new(providers: Vec<String>) -> Self {
        Self {
            state: providers
                .iter()
                .map(|p| (p.clone(), ProviderState::default()))
                .collect(),
            providers,
            current_index: 0,
            any_success: false,
        }
    }

    /// Return the name of the currently active provider, if any.
    ///
    /// Returns `None` when all providers have been exhausted.
    pub fn current_provider(&self) -> Option<&str> {
        self.providers.get(self.current_index).map(String::as_str)
    }

    /// Return the next provider to try, advancing past exhausted ones.
    ///
    /// This is the main entry point: call before each attempt. Returns `None`
    /// when the chain is fully exhausted.
    pub fn next_provider(&mut self) -> Option<String> {
        while self.current_index < self.providers.len() {
            let name = &self.providers[self.current_index];
            let state = self
                .state
                .get(name)
                .map(|s| (s.permanently_failed, s.transient_failures))
                .unwrap_or_default();
            let (permanently_failed, transient_failures) = state;

            if permanently_failed || transient_failures >= RETRY_ATTEMPTS {
                // This provider is exhausted — skip to the next.
                info!(
                    provider = name.as_str(),
                    "fallback chain: skipping exhausted provider"
                );
                self.current_index += 1;
                continue;
            }

            return Some(name.clone());
        }
        None
    }

    /// Report a failure for the named provider.
    ///
    /// - [`ProviderError::Transient`] increments the retry counter.
    /// - [`ProviderError::Permanent`] marks the provider as permanently failed.
    pub fn report_failure(&mut self, provider: &str, error: ProviderError) {
        let state = self.state.entry(provider.to_owned()).or_default();
        match error {
            ProviderError::Transient(ref msg) => {
                state.transient_failures += 1;
                warn!(
                    provider,
                    failures = state.transient_failures,
                    max = RETRY_ATTEMPTS,
                    error = msg.as_str(),
                    "provider transient failure"
                );
            }
            ProviderError::Permanent(ref msg) => {
                state.permanently_failed = true;
                warn!(
                    provider,
                    error = msg.as_str(),
                    "provider permanent failure — skipping"
                );
                // Advance past this provider immediately.
                if self.providers.get(self.current_index).map(String::as_str) == Some(provider) {
                    self.current_index += 1;
                }
            }
        }
    }

    /// Report a successful completion for the named provider.
    ///
    /// Resets the transient failure counter for that provider.
    pub fn report_success(&mut self, provider: &str) {
        info!(provider, "provider request succeeded");
        if let Some(state) = self.state.get_mut(provider) {
            state.transient_failures = 0;
        }
        self.any_success = true;
    }

    /// Return `true` if the chain is fully exhausted (all providers failed).
    pub fn is_exhausted(&self) -> bool {
        self.current_index >= self.providers.len()
    }

    /// Return the number of providers in the chain.
    pub fn len(&self) -> usize {
        self.providers.len()
    }

    /// Return `true` if the chain has no providers.
    pub fn is_empty(&self) -> bool {
        self.providers.is_empty()
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn single_provider_starts_available() {
        let mut chain = FallbackChain::new(vec!["local".into()]);
        assert_eq!(chain.next_provider(), Some("local".into()));
    }

    #[test]
    fn empty_chain_returns_none() {
        let mut chain = FallbackChain::new(vec![]);
        assert_eq!(chain.next_provider(), None);
        assert!(chain.is_exhausted());
        assert!(chain.is_empty());
    }

    #[test]
    fn transient_failures_exhaust_after_max_retries() {
        let mut chain = FallbackChain::new(vec!["cloud".into(), "local".into()]);

        // Exhaust cloud with transient failures.
        for _ in 0..RETRY_ATTEMPTS {
            assert_eq!(chain.next_provider(), Some("cloud".into()));
            chain.report_failure("cloud", ProviderError::Transient("timeout".into()));
        }

        // After RETRY_ATTEMPTS failures, should advance to local.
        assert_eq!(chain.next_provider(), Some("local".into()));
    }

    #[test]
    fn permanent_failure_skips_immediately() {
        let mut chain = FallbackChain::new(vec!["cloud".into(), "local".into()]);

        assert_eq!(chain.next_provider(), Some("cloud".into()));
        chain.report_failure("cloud", ProviderError::Permanent("401 Unauthorized".into()));

        // Should skip to local without any retry attempts.
        assert_eq!(chain.next_provider(), Some("local".into()));
    }

    #[test]
    fn all_providers_exhausted_returns_none() {
        let mut chain = FallbackChain::new(vec!["a".into(), "b".into()]);

        chain.report_failure("a", ProviderError::Permanent("auth".into()));
        chain.report_failure("b", ProviderError::Permanent("auth".into()));

        assert_eq!(chain.next_provider(), None);
        assert!(chain.is_exhausted());
    }

    #[test]
    fn success_resets_transient_counter() {
        let mut chain = FallbackChain::new(vec!["cloud".into()]);

        // Fail twice (under limit).
        chain.report_failure("cloud", ProviderError::Transient("timeout".into()));
        chain.report_failure("cloud", ProviderError::Transient("timeout".into()));

        // Succeed — counter resets.
        chain.report_success("cloud");

        let state = chain.state.get("cloud").unwrap();
        assert_eq!(state.transient_failures, 0);
    }

    #[test]
    fn providers_tried_in_order() {
        let mut chain = FallbackChain::new(vec!["first".into(), "second".into(), "third".into()]);

        assert_eq!(chain.next_provider(), Some("first".into()));
        chain.report_failure("first", ProviderError::Permanent("fail".into()));

        assert_eq!(chain.next_provider(), Some("second".into()));
        chain.report_failure("second", ProviderError::Permanent("fail".into()));

        assert_eq!(chain.next_provider(), Some("third".into()));
        chain.report_success("third");
        assert!(!chain.is_exhausted());
    }

    #[test]
    fn chain_len_reflects_provider_count() {
        let chain = FallbackChain::new(vec!["a".into(), "b".into(), "c".into()]);
        assert_eq!(chain.len(), 3);
        assert!(!chain.is_empty());
    }

    #[test]
    fn provider_error_display_variants_debug() {
        let t = ProviderError::Transient("timeout".into());
        let p = ProviderError::Permanent("auth".into());
        // Verify Debug output contains the message.
        assert!(format!("{t:?}").contains("timeout"));
        assert!(format!("{p:?}").contains("auth"));
    }
}
