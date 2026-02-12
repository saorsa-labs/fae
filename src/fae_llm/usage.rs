//! Token usage and cost tracking for LLM requests.
//!
//! Provides types for tracking token consumption and estimating costs
//! across multi-turn conversations and different providers.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::usage::{TokenUsage, TokenPricing, CostEstimate};
//!
//! let usage = TokenUsage::new(500, 200);
//! assert_eq!(usage.total(), 700);
//!
//! let pricing = TokenPricing::new(3.0, 15.0); // $3/1M input, $15/1M output
//! let cost = CostEstimate::calculate(&usage, &pricing);
//! assert!(cost.usd > 0.0);
//! ```

use serde::{Deserialize, Serialize};

/// Token counts for a single LLM request/response.
///
/// Tracks prompt (input) tokens, completion (output) tokens, and
/// optionally reasoning tokens for models that support extended thinking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenUsage {
    /// Number of tokens in the prompt/input.
    pub prompt_tokens: u64,
    /// Number of tokens in the completion/output.
    pub completion_tokens: u64,
    /// Number of reasoning/thinking tokens (if the model reports them).
    pub reasoning_tokens: Option<u64>,
}

impl TokenUsage {
    /// Create a new token usage record.
    pub fn new(prompt_tokens: u64, completion_tokens: u64) -> Self {
        Self {
            prompt_tokens,
            completion_tokens,
            reasoning_tokens: None,
        }
    }

    /// Set reasoning tokens.
    pub fn with_reasoning_tokens(mut self, tokens: u64) -> Self {
        self.reasoning_tokens = Some(tokens);
        self
    }

    /// Total tokens consumed (prompt + completion + reasoning).
    pub fn total(&self) -> u64 {
        self.prompt_tokens
            .saturating_add(self.completion_tokens)
            .saturating_add(self.reasoning_tokens.unwrap_or(0))
    }

    /// Accumulate token counts from another usage record.
    ///
    /// Adds all token counts. If either record has reasoning tokens,
    /// they are summed; if only one has them, that value is used.
    pub fn add(&mut self, other: &TokenUsage) {
        self.prompt_tokens = self.prompt_tokens.saturating_add(other.prompt_tokens);
        self.completion_tokens = self
            .completion_tokens
            .saturating_add(other.completion_tokens);
        self.reasoning_tokens = match (self.reasoning_tokens, other.reasoning_tokens) {
            (Some(a), Some(b)) => Some(a.saturating_add(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        };
    }
}

impl Default for TokenUsage {
    fn default() -> Self {
        Self::new(0, 0)
    }
}

/// Pricing rates for token-based billing.
///
/// Prices are expressed in USD per 1 million tokens.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TokenPricing {
    /// USD per 1 million input/prompt tokens.
    pub input_per_1m: f64,
    /// USD per 1 million output/completion tokens.
    pub output_per_1m: f64,
}

impl TokenPricing {
    /// Create a new pricing configuration.
    ///
    /// # Arguments
    ///
    /// * `input_per_1m` — USD cost per 1 million input tokens
    /// * `output_per_1m` — USD cost per 1 million output tokens
    pub fn new(input_per_1m: f64, output_per_1m: f64) -> Self {
        Self {
            input_per_1m,
            output_per_1m,
        }
    }
}

/// An estimated cost for a set of token usage.
///
/// Calculated from [`TokenUsage`] and [`TokenPricing`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CostEstimate {
    /// Estimated cost in USD.
    pub usd: f64,
    /// The pricing used for this estimate.
    pub pricing: TokenPricing,
}

impl CostEstimate {
    /// Calculate the cost for the given usage and pricing.
    ///
    /// Reasoning tokens are charged at the output rate since they
    /// consume output capacity.
    pub fn calculate(usage: &TokenUsage, pricing: &TokenPricing) -> Self {
        // Multiply before dividing to preserve floating-point precision
        let input_cost = (usage.prompt_tokens as f64 * pricing.input_per_1m) / 1_000_000.0;
        let output_tokens = usage
            .completion_tokens
            .saturating_add(usage.reasoning_tokens.unwrap_or(0));
        let output_cost = (output_tokens as f64 * pricing.output_per_1m) / 1_000_000.0;

        Self {
            usd: input_cost + output_cost,
            pricing: pricing.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── TokenUsage ────────────────────────────────────────────

    #[test]
    fn token_usage_new() {
        let usage = TokenUsage::new(100, 50);
        assert_eq!(usage.prompt_tokens, 100);
        assert_eq!(usage.completion_tokens, 50);
        assert!(usage.reasoning_tokens.is_none());
    }

    #[test]
    fn token_usage_with_reasoning() {
        let usage = TokenUsage::new(100, 50).with_reasoning_tokens(25);
        assert_eq!(usage.reasoning_tokens, Some(25));
    }

    #[test]
    fn token_usage_total_without_reasoning() {
        let usage = TokenUsage::new(500, 200);
        assert_eq!(usage.total(), 700);
    }

    #[test]
    fn token_usage_total_with_reasoning() {
        let usage = TokenUsage::new(500, 200).with_reasoning_tokens(100);
        assert_eq!(usage.total(), 800);
    }

    #[test]
    fn token_usage_default_is_zero() {
        let usage = TokenUsage::default();
        assert_eq!(usage.prompt_tokens, 0);
        assert_eq!(usage.completion_tokens, 0);
        assert!(usage.reasoning_tokens.is_none());
        assert_eq!(usage.total(), 0);
    }

    #[test]
    fn token_usage_add_basic() {
        let mut a = TokenUsage::new(100, 50);
        let b = TokenUsage::new(200, 100);
        a.add(&b);
        assert_eq!(a.prompt_tokens, 300);
        assert_eq!(a.completion_tokens, 150);
        assert!(a.reasoning_tokens.is_none());
    }

    #[test]
    fn token_usage_add_with_reasoning_both() {
        let mut a = TokenUsage::new(100, 50).with_reasoning_tokens(10);
        let b = TokenUsage::new(200, 100).with_reasoning_tokens(20);
        a.add(&b);
        assert_eq!(a.prompt_tokens, 300);
        assert_eq!(a.completion_tokens, 150);
        assert_eq!(a.reasoning_tokens, Some(30));
    }

    #[test]
    fn token_usage_add_reasoning_one_side_only() {
        let mut a = TokenUsage::new(100, 50);
        let b = TokenUsage::new(200, 100).with_reasoning_tokens(20);
        a.add(&b);
        assert_eq!(a.reasoning_tokens, Some(20));

        let mut c = TokenUsage::new(100, 50).with_reasoning_tokens(10);
        let d = TokenUsage::new(200, 100);
        c.add(&d);
        assert_eq!(c.reasoning_tokens, Some(10));
    }

    #[test]
    fn token_usage_add_neither_reasoning() {
        let mut a = TokenUsage::new(100, 50);
        let b = TokenUsage::new(200, 100);
        a.add(&b);
        assert!(a.reasoning_tokens.is_none());
    }

    #[test]
    fn token_usage_serde_round_trip() {
        let original = TokenUsage::new(500, 200).with_reasoning_tokens(50);
        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<TokenUsage, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
        assert_eq!(parsed.unwrap_or_default(), original);
    }

    // ── TokenPricing ──────────────────────────────────────────

    #[test]
    fn token_pricing_new() {
        let pricing = TokenPricing::new(3.0, 15.0);
        assert_eq!(pricing.input_per_1m, 3.0);
        assert_eq!(pricing.output_per_1m, 15.0);
    }

    #[test]
    fn token_pricing_serde_round_trip() {
        let original = TokenPricing::new(2.5, 10.0);
        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<TokenPricing, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
        let parsed = parsed.unwrap_or_else(|_| TokenPricing::new(0.0, 0.0));
        assert_eq!(parsed, original);
    }

    // ── CostEstimate ──────────────────────────────────────────

    #[test]
    fn cost_estimate_basic() {
        // 1M input tokens at $3/1M = $3
        // 1M output tokens at $15/1M = $15
        let usage = TokenUsage::new(1_000_000, 1_000_000);
        let pricing = TokenPricing::new(3.0, 15.0);
        let cost = CostEstimate::calculate(&usage, &pricing);
        assert!((cost.usd - 18.0).abs() < 0.001);
    }

    #[test]
    fn cost_estimate_with_reasoning_tokens() {
        // Reasoning tokens charged at output rate
        let usage = TokenUsage::new(1_000_000, 500_000).with_reasoning_tokens(500_000);
        let pricing = TokenPricing::new(3.0, 15.0);
        let cost = CostEstimate::calculate(&usage, &pricing);
        // Input: 1M * $3/1M = $3
        // Output: (500k + 500k) * $15/1M = $15
        assert!((cost.usd - 18.0).abs() < 0.001);
    }

    #[test]
    fn cost_estimate_zero_usage() {
        let usage = TokenUsage::default();
        let pricing = TokenPricing::new(3.0, 15.0);
        let cost = CostEstimate::calculate(&usage, &pricing);
        assert!((cost.usd).abs() < 0.001);
    }

    #[test]
    fn cost_estimate_small_usage() {
        // 500 input, 200 output at GPT-4o pricing
        let usage = TokenUsage::new(500, 200);
        let pricing = TokenPricing::new(2.50, 10.0);
        let cost = CostEstimate::calculate(&usage, &pricing);
        // Input: 500/1M * $2.50 = $0.00125
        // Output: 200/1M * $10 = $0.002
        let expected = 0.00125 + 0.002;
        assert!((cost.usd - expected).abs() < 0.000001);
    }

    #[test]
    fn cost_estimate_stores_pricing() {
        let usage = TokenUsage::new(100, 100);
        let pricing = TokenPricing::new(5.0, 20.0);
        let cost = CostEstimate::calculate(&usage, &pricing);
        assert_eq!(cost.pricing.input_per_1m, 5.0);
        assert_eq!(cost.pricing.output_per_1m, 20.0);
    }

    #[test]
    fn cost_estimate_serde_round_trip() {
        let usage = TokenUsage::new(1000, 500);
        let pricing = TokenPricing::new(3.0, 15.0);
        let original = CostEstimate::calculate(&usage, &pricing);
        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<CostEstimate, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
    }

    // ── Multi-turn accumulation ───────────────────────────────

    #[test]
    fn multi_turn_accumulation() {
        let turns = vec![
            TokenUsage::new(500, 200),
            TokenUsage::new(700, 300).with_reasoning_tokens(50),
            TokenUsage::new(1200, 400),
        ];

        let mut total = TokenUsage::default();
        for turn in &turns {
            total.add(turn);
        }

        assert_eq!(total.prompt_tokens, 2400);
        assert_eq!(total.completion_tokens, 900);
        assert_eq!(total.reasoning_tokens, Some(50));
        assert_eq!(total.total(), 3350);
    }
}
