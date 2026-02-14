//! Per-engine circuit breaker for adaptive engine selection.
//!
//! Tracks success/failure counts per search engine and temporarily disables
//! engines that fail repeatedly. After a cooldown period, a tripped engine
//! enters a half-open state where a single probe request determines whether
//! to restore or re-trip the circuit.
//!
//! # State Machine
//!
//! ```text
//! ┌────────┐  N failures   ┌────────┐  cooldown   ┌──────────┐
//! │ Closed ├──────────────►│  Open  ├────────────►│ HalfOpen │
//! └───▲────┘               └────────┘             └────┬─────┘
//!     │                         ▲                      │
//!     │  success                │  failure              │
//!     └─────────────────────────┴──────────────────────┘
//! ```

use crate::types::SearchEngine;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Circuit breaker state for a single engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitState {
    /// Engine is healthy — all requests are allowed through.
    Closed,
    /// Engine has failed too many times — requests are blocked until cooldown expires.
    Open,
    /// Cooldown has elapsed — one probe request is allowed to test recovery.
    HalfOpen,
}

/// Health tracking data for a single search engine.
#[derive(Debug, Clone)]
pub struct EngineHealth {
    /// Current circuit state.
    pub state: CircuitState,
    /// Number of consecutive failures since the last success.
    pub consecutive_failures: u32,
    /// When the last failure occurred (if any).
    pub last_failure_at: Option<Instant>,
    /// When the last success occurred (if any).
    pub last_success_at: Option<Instant>,
}

impl Default for EngineHealth {
    fn default() -> Self {
        Self {
            state: CircuitState::Closed,
            consecutive_failures: 0,
            last_failure_at: None,
            last_success_at: None,
        }
    }
}

/// Configuration for circuit breaker behaviour.
#[derive(Debug, Clone)]
pub struct CircuitBreakerConfig {
    /// Number of consecutive failures before tripping the circuit to Open.
    pub failure_threshold: u32,
    /// Seconds to wait in Open state before transitioning to HalfOpen.
    pub cooldown_secs: u64,
}

impl Default for CircuitBreakerConfig {
    fn default() -> Self {
        Self {
            failure_threshold: 3,
            cooldown_secs: 60,
        }
    }
}

/// Per-engine circuit breaker that tracks health and controls request flow.
///
/// Each search engine has independent health tracking. When an engine
/// accumulates enough consecutive failures, it is temporarily disabled
/// (Open state). After a cooldown period, one probe request is allowed
/// (HalfOpen). Success restores the engine; failure re-trips the circuit.
#[derive(Debug)]
pub struct CircuitBreaker {
    config: CircuitBreakerConfig,
    engines: HashMap<SearchEngine, EngineHealth>,
}

impl CircuitBreaker {
    /// Create a new circuit breaker with the given configuration.
    pub fn new(config: CircuitBreakerConfig) -> Self {
        Self {
            config,
            engines: HashMap::new(),
        }
    }

    /// Record a successful request for the given engine.
    ///
    /// Resets the consecutive failure count and transitions the engine
    /// to [`CircuitState::Closed`] regardless of previous state.
    pub fn record_success(&mut self, engine: SearchEngine) {
        let health = self.engines.entry(engine).or_default();
        health.state = CircuitState::Closed;
        health.consecutive_failures = 0;
        health.last_success_at = Some(Instant::now());
    }

    /// Record a failed request for the given engine.
    ///
    /// Increments the consecutive failure count. If the count reaches
    /// the configured threshold, transitions to [`CircuitState::Open`].
    pub fn record_failure(&mut self, engine: SearchEngine) {
        let health = self.engines.entry(engine).or_default();
        health.consecutive_failures += 1;
        health.last_failure_at = Some(Instant::now());

        if health.consecutive_failures >= self.config.failure_threshold {
            health.state = CircuitState::Open;
        }
    }

    /// Check whether a request to the given engine should be attempted.
    ///
    /// - [`CircuitState::Closed`]: always returns `true`
    /// - [`CircuitState::Open`]: returns `true` only if the cooldown has elapsed
    ///   (transitions to [`CircuitState::HalfOpen`])
    /// - [`CircuitState::HalfOpen`]: returns `true` (one probe allowed)
    pub fn should_attempt(&mut self, engine: SearchEngine) -> bool {
        let health = self.engines.entry(engine).or_default();

        match health.state {
            CircuitState::Closed | CircuitState::HalfOpen => true,
            CircuitState::Open => {
                // Check if cooldown has elapsed.
                let cooldown_elapsed = health
                    .last_failure_at
                    .is_none_or(|t| t.elapsed().as_secs() >= self.config.cooldown_secs);

                if cooldown_elapsed {
                    health.state = CircuitState::HalfOpen;
                    true
                } else {
                    false
                }
            }
        }
    }

    /// Get the current circuit state for a specific engine.
    pub fn engine_status(&self, engine: SearchEngine) -> CircuitState {
        self.engines
            .get(&engine)
            .map_or(CircuitState::Closed, |h| h.state)
    }

    /// Get a health report for all tracked engines.
    ///
    /// Returns a list of (engine, state, consecutive_failures) tuples
    /// for every engine that has been seen by the circuit breaker.
    pub fn health_report(&self) -> Vec<(SearchEngine, CircuitState, u32)> {
        self.engines
            .iter()
            .map(|(engine, health)| (*engine, health.state, health.consecutive_failures))
            .collect()
    }

    /// Reset all engine states to healthy (Closed with zero failures).
    pub fn reset(&mut self) {
        self.engines.clear();
    }
}

/// Global circuit breaker singleton.
///
/// Shared across all search operations within the process. Protected
/// by a [`Mutex`] for thread-safe access.
static GLOBAL_BREAKER: OnceLock<Mutex<CircuitBreaker>> = OnceLock::new();

/// Access the global circuit breaker instance.
///
/// Initialised lazily with default configuration on first access.
pub fn global_breaker() -> &'static Mutex<CircuitBreaker> {
    GLOBAL_BREAKER.get_or_init(|| Mutex::new(CircuitBreaker::new(CircuitBreakerConfig::default())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_breaker(threshold: u32, cooldown_secs: u64) -> CircuitBreaker {
        CircuitBreaker::new(CircuitBreakerConfig {
            failure_threshold: threshold,
            cooldown_secs,
        })
    }

    #[test]
    fn initial_state_is_closed() {
        let breaker = make_breaker(3, 60);
        assert_eq!(
            breaker.engine_status(SearchEngine::DuckDuckGo),
            CircuitState::Closed
        );
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Closed
        );
    }

    #[test]
    fn stays_closed_below_threshold() {
        let mut breaker = make_breaker(3, 60);
        breaker.record_failure(SearchEngine::DuckDuckGo);
        breaker.record_failure(SearchEngine::DuckDuckGo);
        assert_eq!(
            breaker.engine_status(SearchEngine::DuckDuckGo),
            CircuitState::Closed
        );
    }

    #[test]
    fn trips_to_open_at_threshold() {
        let mut breaker = make_breaker(3, 60);
        breaker.record_failure(SearchEngine::Google);
        breaker.record_failure(SearchEngine::Google);
        breaker.record_failure(SearchEngine::Google);
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Open
        );
    }

    #[test]
    fn open_blocks_attempts() {
        let mut breaker = make_breaker(3, 600); // Long cooldown
        for _ in 0..3 {
            breaker.record_failure(SearchEngine::Brave);
        }
        assert!(!breaker.should_attempt(SearchEngine::Brave));
    }

    #[test]
    fn open_transitions_to_half_open_after_cooldown() {
        let mut breaker = make_breaker(3, 0); // Zero cooldown = immediate
        for _ in 0..3 {
            breaker.record_failure(SearchEngine::Bing);
        }
        assert_eq!(
            breaker.engine_status(SearchEngine::Bing),
            CircuitState::Open
        );

        // With zero cooldown, should_attempt transitions to HalfOpen
        assert!(breaker.should_attempt(SearchEngine::Bing));
        assert_eq!(
            breaker.engine_status(SearchEngine::Bing),
            CircuitState::HalfOpen
        );
    }

    #[test]
    fn half_open_allows_attempt() {
        let mut breaker = make_breaker(3, 0);
        for _ in 0..3 {
            breaker.record_failure(SearchEngine::Google);
        }
        // Transition to HalfOpen
        let _ = breaker.should_attempt(SearchEngine::Google);
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::HalfOpen
        );
        assert!(breaker.should_attempt(SearchEngine::Google));
    }

    #[test]
    fn half_open_success_restores_closed() {
        let mut breaker = make_breaker(3, 0);
        for _ in 0..3 {
            breaker.record_failure(SearchEngine::Google);
        }
        let _ = breaker.should_attempt(SearchEngine::Google); // → HalfOpen
        breaker.record_success(SearchEngine::Google);
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Closed
        );
    }

    #[test]
    fn half_open_failure_retrips() {
        let mut breaker = make_breaker(1, 0); // threshold=1 for simplicity
        breaker.record_failure(SearchEngine::Brave); // → Open
        let _ = breaker.should_attempt(SearchEngine::Brave); // → HalfOpen
        breaker.record_failure(SearchEngine::Brave); // → Open again
        assert_eq!(
            breaker.engine_status(SearchEngine::Brave),
            CircuitState::Open
        );
    }

    #[test]
    fn success_resets_consecutive_failures() {
        let mut breaker = make_breaker(5, 60);
        breaker.record_failure(SearchEngine::DuckDuckGo);
        breaker.record_failure(SearchEngine::DuckDuckGo);
        breaker.record_success(SearchEngine::DuckDuckGo);

        let health = breaker.engines.get(&SearchEngine::DuckDuckGo).unwrap();
        assert_eq!(health.consecutive_failures, 0);
        assert_eq!(health.state, CircuitState::Closed);
    }

    #[test]
    fn engines_are_independent() {
        let mut breaker = make_breaker(2, 60);
        breaker.record_failure(SearchEngine::Google);
        breaker.record_failure(SearchEngine::Google);
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Open
        );
        // Other engines unaffected
        assert_eq!(
            breaker.engine_status(SearchEngine::DuckDuckGo),
            CircuitState::Closed
        );
        assert!(breaker.should_attempt(SearchEngine::DuckDuckGo));
    }

    #[test]
    fn health_report_includes_tracked_engines() {
        let mut breaker = make_breaker(3, 60);
        breaker.record_failure(SearchEngine::Google);
        breaker.record_success(SearchEngine::DuckDuckGo);

        let report = breaker.health_report();
        assert_eq!(report.len(), 2);

        let google = report.iter().find(|(e, _, _)| *e == SearchEngine::Google);
        assert!(google.is_some());
        let (_, state, failures) = google.unwrap();
        assert_eq!(*state, CircuitState::Closed);
        assert_eq!(*failures, 1);

        let ddg = report
            .iter()
            .find(|(e, _, _)| *e == SearchEngine::DuckDuckGo);
        assert!(ddg.is_some());
        let (_, state, failures) = ddg.unwrap();
        assert_eq!(*state, CircuitState::Closed);
        assert_eq!(*failures, 0);
    }

    #[test]
    fn reset_clears_all_state() {
        let mut breaker = make_breaker(3, 60);
        for _ in 0..3 {
            breaker.record_failure(SearchEngine::Google);
        }
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Open
        );

        breaker.reset();
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Closed
        );
        assert!(breaker.health_report().is_empty());
    }

    #[test]
    fn closed_always_allows_attempt() {
        let mut breaker = make_breaker(3, 60);
        assert!(breaker.should_attempt(SearchEngine::DuckDuckGo));
        assert!(breaker.should_attempt(SearchEngine::Brave));
        assert!(breaker.should_attempt(SearchEngine::Google));
        assert!(breaker.should_attempt(SearchEngine::Bing));
    }

    #[test]
    fn default_config_values() {
        let config = CircuitBreakerConfig::default();
        assert_eq!(config.failure_threshold, 3);
        assert_eq!(config.cooldown_secs, 60);
    }

    #[test]
    fn global_breaker_is_accessible() {
        let breaker = global_breaker();
        let guard = breaker.lock();
        assert!(guard.is_ok());
    }

    #[test]
    fn rapid_success_failure_alternation() {
        let mut breaker = make_breaker(3, 60);
        // Alternate success/failure — should never trip because consecutive failures reset.
        for _ in 0..10 {
            breaker.record_failure(SearchEngine::Google);
            breaker.record_success(SearchEngine::Google);
        }
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Closed
        );
    }

    #[test]
    fn multiple_engines_mixed_states() {
        let mut breaker = make_breaker(2, 0);

        // Google: trip to Open
        breaker.record_failure(SearchEngine::Google);
        breaker.record_failure(SearchEngine::Google);
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::Open
        );

        // DDG: one failure, still Closed
        breaker.record_failure(SearchEngine::DuckDuckGo);
        assert_eq!(
            breaker.engine_status(SearchEngine::DuckDuckGo),
            CircuitState::Closed
        );

        // Brave: never seen, Closed
        assert_eq!(
            breaker.engine_status(SearchEngine::Brave),
            CircuitState::Closed
        );

        // Bing: success recorded
        breaker.record_success(SearchEngine::Bing);
        assert_eq!(
            breaker.engine_status(SearchEngine::Bing),
            CircuitState::Closed
        );

        // Google: transition to HalfOpen (zero cooldown)
        let _ = breaker.should_attempt(SearchEngine::Google);
        assert_eq!(
            breaker.engine_status(SearchEngine::Google),
            CircuitState::HalfOpen
        );
    }

    #[test]
    fn circuit_state_derives() {
        // Verify Debug, Clone, Copy, PartialEq
        let state = CircuitState::Closed;
        let copied = state;
        let cloned = state;
        assert_eq!(state, copied);
        assert_eq!(state, cloned);
        assert_ne!(CircuitState::Closed, CircuitState::Open);
        // Debug
        let debug = format!("{:?}", state);
        assert!(debug.contains("Closed"));
    }
}
