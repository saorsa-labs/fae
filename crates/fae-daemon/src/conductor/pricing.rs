//! Provider pricing table for M2 Stage 1 conductor egress gates.
//!
//! The executor uses this module only for non-local role-calls, after the mode
//! cap and PII membrane pass and before any cloud-bound request is constructed.
//! A missing worker price is fail-closed by the executor: without a bounded cost
//! estimate, there is no egress.

use std::collections::HashMap;

use crate::conductor::budget::CostEstimate;

/// Per-token pricing for one cloud-backed worker, in micro-currency units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderPricing {
    pub input_micros_per_token: u64,
    pub output_micros_per_token: u64,
}

/// ADR-014: a deliberately **conservative** (over-estimating) built-in price for
/// OpenRouter remote-provider workers, so the §5.4 budget gate binds and cloud
/// egress is never silently dead for lack of a pricing entry. Micro-USD per
/// token: 15 in / 75 out bounds premium-tier models (well above GPT-4.1-mini's
/// real rate) — fail-safe, since a higher estimate can only trip the daily cap
/// sooner, never overspend. NON-AUTHORITATIVE: the provider account's own spend
/// caps are the real cost control; operator `FAE_PROVIDER_PRICING` overrides this.
pub const DEFAULT_OPENROUTER_PRICING: ProviderPricing = ProviderPricing {
    input_micros_per_token: 15,
    output_micros_per_token: 75,
};

/// Startup-loaded pricing table keyed by worker id.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProviderPricingTable {
    by_worker: HashMap<String, ProviderPricing>,
}

impl ProviderPricingTable {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, worker_id: impl Into<String>, pricing: ProviderPricing) {
        self.by_worker.insert(worker_id.into(), pricing);
    }

    pub fn contains_worker(&self, worker_id: &str) -> bool {
        self.by_worker.contains_key(worker_id)
    }

    /// Parse `FAE_PROVIDER_PRICING`-style entries:
    /// `worker_id=input_micros_per_token,output_micros_per_token;...`.
    /// Invalid entries are ignored by returning an error to the caller, which
    /// can log and fall back to an empty table (fail-closed on cloud routes).
    pub fn from_env_value(value: Option<&str>) -> Result<Self, PricingParseError> {
        let Some(raw) = value else {
            return Ok(Self::default());
        };
        if raw.trim().is_empty() {
            return Ok(Self::default());
        }

        let mut table = Self::default();
        for entry in raw.split(';').filter(|part| !part.trim().is_empty()) {
            let (worker_id, prices) = entry
                .split_once('=')
                .ok_or_else(|| PricingParseError::InvalidEntry(entry.trim().to_string()))?;
            let (input, output) = prices
                .split_once(',')
                .ok_or_else(|| PricingParseError::InvalidEntry(entry.trim().to_string()))?;
            let worker_id = worker_id.trim();
            if worker_id.is_empty() {
                return Err(PricingParseError::InvalidEntry(entry.trim().to_string()));
            }
            let input_micros_per_token = input
                .trim()
                .parse::<u64>()
                .map_err(|_| PricingParseError::InvalidEntry(entry.trim().to_string()))?;
            let output_micros_per_token = output
                .trim()
                .parse::<u64>()
                .map_err(|_| PricingParseError::InvalidEntry(entry.trim().to_string()))?;
            table.insert(
                worker_id,
                ProviderPricing {
                    input_micros_per_token,
                    output_micros_per_token,
                },
            );
        }
        Ok(table)
    }

    /// Estimate worst-case cost for a role-call. Input token count uses a
    /// conservative chars/3 ceiling heuristic; output token count is the maximum
    /// output budget. Wall-clock is advisory-only in Stage 1, so it is zero.
    pub fn estimate_cost(
        &self,
        worker_id: &str,
        prompt: &str,
        max_output_tokens: u64,
    ) -> Result<CostEstimate, PricingError> {
        let pricing = self
            .by_worker
            .get(worker_id)
            .ok_or_else(|| PricingError::MissingWorker {
                worker_id: worker_id.to_string(),
            })?;
        let input_tokens = estimate_input_tokens(prompt);
        let output_tokens = max_output_tokens;
        let input_cost = input_tokens.saturating_mul(pricing.input_micros_per_token);
        let output_cost = output_tokens.saturating_mul(pricing.output_micros_per_token);
        Ok(CostEstimate {
            cost_micros: input_cost.saturating_add(output_cost),
            wall_clock_ms: 0,
            input_tokens,
            output_tokens,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PricingError {
    #[error("missing pricing for worker {worker_id}")]
    MissingWorker { worker_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PricingParseError {
    #[error("invalid provider pricing entry {0:?}")]
    InvalidEntry(String),
}

fn estimate_input_tokens(prompt: &str) -> u64 {
    let chars = prompt.chars().count() as u64;
    chars.saturating_add(2) / 3
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn estimate_cost_uses_conservative_chars_over_three_and_worst_case_output() {
        let mut table = ProviderPricingTable::empty();
        table.insert(
            "acp:codex",
            ProviderPricing {
                input_micros_per_token: 2,
                output_micros_per_token: 5,
            },
        );

        let estimate = table
            .estimate_cost("acp:codex", "abcdefg", 10)
            .expect("cost estimate in test");
        assert_eq!(estimate.input_tokens, 3);
        assert_eq!(estimate.output_tokens, 10);
        assert_eq!(estimate.cost_micros, 3 * 2 + 10 * 5);
        assert_eq!(estimate.wall_clock_ms, 0);
    }

    #[test]
    fn missing_worker_is_uncostable() {
        let table = ProviderPricingTable::empty();
        assert!(matches!(
            table.estimate_cost("acp:missing", "hello", 10),
            Err(PricingError::MissingWorker { .. })
        ));
    }

    #[test]
    fn parses_startup_table() {
        let table = ProviderPricingTable::from_env_value(Some("acp:codex=2,5;acp:claude=3,7"))
            .expect("pricing table in test");
        assert!(table.contains_worker("acp:codex"));
        assert_eq!(
            table
                .estimate_cost("acp:claude", "abc", 1)
                .expect("estimate in test")
                .cost_micros,
            10
        );
        assert!(ProviderPricingTable::from_env_value(Some("broken")).is_err());
    }
}
