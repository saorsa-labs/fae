//! Budget governance primitive for M2 cloud-bound conductor role-calls.
//!
//! This module is deliberately **dormant** in M1. The executor will consult the
//! [`BudgetGovernor`] before every cloud-backed role-call once M2 egress wiring
//! lands. Until then it is an isolated primitive with no runtime side effects.
//!
//! Privacy posture: budget state is stored only in the isolated conductor store
//! (never `fae.db`) and contains structured routing/cost tokens only — no raw
//! prompts, user text, memory text, file contents, or secrets.

// TODO(M2, 2026-06-23): remove this scoped dormant allowance when executor
// wiring calls `BudgetGovernor::check`/`record` around cloud-bound role-calls.
#![allow(dead_code)]

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::conductor::error::ConductorError;
use crate::conductor::recipe::{
    ConductorTaskClass, ConductorTopology, OwnedRouteDecision, RouteFailure,
};
use crate::conductor::store::ConductorStore;

/// Rolling spend window for the per-day cap: 24 hours in milliseconds.
pub const DEFAULT_DAILY_WINDOW_MS: u64 = 24 * 60 * 60 * 1_000;

/// Which budget cap blocked a route.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BudgetDimension {
    /// Estimated per-role-call spend exceeded the cap.
    CostMicros,
    /// Estimated per-role-call wall-clock latency exceeded the cap.
    WallClockMs,
    /// Rolling per-day aggregate spend would exceed the cap, or the persisted
    /// rolling state could not be trusted (fail-closed).
    DailyCostMicros,
}

/// Operator-configured caps for cloud-backed role-calls.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BudgetLimits {
    /// Maximum estimated spend for one role-call, in micro-currency units.
    pub max_cost_micros_per_call: u64,
    /// Maximum estimated wall-clock latency for one role-call.
    pub max_wall_clock_ms_per_call: u64,
    /// Maximum aggregate spend across the rolling daily window.
    pub max_daily_cost_micros: u64,
    /// Rolling window used for the per-day cap. Defaults to 24 hours.
    pub daily_window: Duration,
}

impl BudgetLimits {
    pub fn daily_window_ms(self) -> u64 {
        duration_ms(self.daily_window)
    }
}

/// Caller-supplied pre-flight estimate. Token counts are recorded for telemetry
/// parity but are intentionally **never** used as a blocking dimension in v1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CostEstimate {
    pub cost_micros: u64,
    pub wall_clock_ms: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

impl CostEstimate {
    pub fn total_tokens(self) -> u64 {
        self.input_tokens.saturating_add(self.output_tokens)
    }
}

/// Measured outcome after a role-call finishes. Token counts are persisted as
/// telemetry-only budget state and never gate future calls.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActualCost {
    pub cost_micros: u64,
    pub wall_clock_ms: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

impl ActualCost {
    pub fn total_tokens(self) -> u64 {
        self.input_tokens.saturating_add(self.output_tokens)
    }
}

/// Pre-flight decision returned by [`BudgetGovernor::check`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BudgetVerdict {
    Allow,
    Block {
        dimension: BudgetDimension,
        limit: u64,
        attempted: u64,
        used: u64,
        window_ms: u64,
    },
}

impl BudgetVerdict {
    pub fn is_allow(&self) -> bool {
        matches!(self, BudgetVerdict::Allow)
    }

    /// Convert a blocking verdict into the executor's structured route failure.
    pub fn into_route_failure(self) -> Option<RouteFailure> {
        match self {
            BudgetVerdict::Allow => None,
            BudgetVerdict::Block {
                dimension,
                limit,
                attempted,
                used,
                window_ms,
            } => Some(RouteFailure::BudgetExceeded {
                dimension,
                limit,
                attempted,
                used,
                window_ms,
            }),
        }
    }
}

/// Fail-closed budget governor for cloud-backed conductor role-calls.
#[derive(Clone)]
pub struct BudgetGovernor {
    store: ConductorStore,
    limits: BudgetLimits,
    now_ms: Arc<dyn Fn() -> u64 + Send + Sync>,
}

impl BudgetGovernor {
    pub fn new(store: ConductorStore, limits: BudgetLimits) -> Self {
        Self {
            store,
            limits,
            now_ms: Arc::new(system_now_ms),
        }
    }

    /// Pre-flight budget check. Any unreadable or corrupt persisted rolling
    /// spend state blocks the route rather than risking uncapped spend.
    pub fn check(&self, _route: &OwnedRouteDecision, estimate: &CostEstimate) -> BudgetVerdict {
        let window_ms = self.limits.daily_window_ms();
        let used_daily = match self.rolling_cost_micros(window_ms) {
            Ok(used) => used,
            Err(error) => {
                eprintln!("fae-daemon: budget state unavailable/corrupt; blocking route: {error}");
                return BudgetVerdict::Block {
                    dimension: BudgetDimension::DailyCostMicros,
                    limit: self.limits.max_daily_cost_micros,
                    attempted: estimate.cost_micros,
                    used: 0,
                    window_ms,
                };
            }
        };

        if estimate.cost_micros > self.limits.max_cost_micros_per_call {
            return BudgetVerdict::Block {
                dimension: BudgetDimension::CostMicros,
                limit: self.limits.max_cost_micros_per_call,
                attempted: estimate.cost_micros,
                used: 0,
                window_ms: 0,
            };
        }

        if estimate.wall_clock_ms > self.limits.max_wall_clock_ms_per_call {
            return BudgetVerdict::Block {
                dimension: BudgetDimension::WallClockMs,
                limit: self.limits.max_wall_clock_ms_per_call,
                attempted: estimate.wall_clock_ms,
                used: 0,
                window_ms: 0,
            };
        }

        if used_daily.saturating_add(estimate.cost_micros) > self.limits.max_daily_cost_micros {
            return BudgetVerdict::Block {
                dimension: BudgetDimension::DailyCostMicros,
                limit: self.limits.max_daily_cost_micros,
                attempted: estimate.cost_micros,
                used: used_daily,
                window_ms,
            };
        }

        BudgetVerdict::Allow
    }

    /// Persist actual role-call usage. This best-effort record path never
    /// panics and never stores user text; a later `check` fails closed if the
    /// persisted state cannot be read back faithfully.
    pub fn record(&self, route: &OwnedRouteDecision, actual: &ActualCost) {
        let record = BudgetUsageRecord::from_route(route, actual, (self.now_ms)());
        if let Err(error) = self.store.append_budget_usage_line(&record) {
            eprintln!("fae-daemon: budget usage write failed: {error}");
        }
    }

    fn rolling_cost_micros(&self, window_ms: u64) -> Result<u64, ConductorError> {
        let now_ms = (self.now_ms)();
        let cutoff_ms = now_ms.saturating_sub(window_ms);
        let mut used = 0_u64;
        for line in self.store.read_budget_usage_lines()? {
            let record: BudgetUsageRecord = serde_json::from_str(&line)?;
            if record.timestamp_ms >= cutoff_ms {
                used = used.saturating_add(record.cost_micros);
            }
        }
        Ok(used)
    }

    #[cfg(test)]
    fn with_now_ms(store: ConductorStore, limits: BudgetLimits, now_ms: u64) -> Self {
        Self {
            store,
            limits,
            now_ms: Arc::new(move || now_ms),
        }
    }
}

/// Persisted JSONL row for budget governance. Structured tokens only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct BudgetUsageRecord {
    pub timestamp_ms: u64,
    pub recipe_id: String,
    pub worker_id: String,
    pub task_class: ConductorTaskClass,
    pub topology: ConductorTopology,
    pub cost_micros: u64,
    pub wall_clock_ms: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub total_tokens: u64,
}

impl BudgetUsageRecord {
    fn from_route(route: &OwnedRouteDecision, actual: &ActualCost, timestamp_ms: u64) -> Self {
        Self {
            timestamp_ms,
            recipe_id: route.recipe_id.clone(),
            worker_id: route.worker_id.clone(),
            task_class: route.task_class,
            topology: route.topology,
            cost_micros: actual.cost_micros,
            wall_clock_ms: actual.wall_clock_ms,
            input_tokens: actual.input_tokens,
            output_tokens: actual.output_tokens,
            total_tokens: actual.total_tokens(),
        }
    }
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}

fn system_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(duration_ms)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::recipe::{ApprovalClass, ConductorTaskClass, ConductorTopology};
    use std::error::Error;
    use std::io;
    use tempfile::TempDir;

    const NOW_MS: u64 = 1_800_000_000_000;

    fn limits() -> BudgetLimits {
        BudgetLimits {
            max_cost_micros_per_call: 100,
            max_wall_clock_ms_per_call: 500,
            max_daily_cost_micros: 1_000,
            daily_window: Duration::from_millis(DEFAULT_DAILY_WINDOW_MS),
        }
    }

    fn route() -> OwnedRouteDecision {
        OwnedRouteDecision {
            request_id: "req-budget-test".to_string(),
            recipe_id: "recipe-cloud-backed".to_string(),
            topology: ConductorTopology::Direct,
            worker_id: "acp:codex".to_string(),
            task_class: ConductorTaskClass::Coding,
            approval: ApprovalClass::StandingGrant("grant-acp-codex".to_string()),
            reason: "budget-test".to_string(),
        }
    }

    fn estimate(cost_micros: u64, wall_clock_ms: u64) -> CostEstimate {
        CostEstimate {
            cost_micros,
            wall_clock_ms,
            input_tokens: 1_000,
            output_tokens: 2_000,
        }
    }

    fn actual(cost_micros: u64, wall_clock_ms: u64) -> ActualCost {
        ActualCost {
            cost_micros,
            wall_clock_ms,
            input_tokens: 100,
            output_tokens: 200,
        }
    }

    fn governor() -> Result<(TempDir, BudgetGovernor), Box<dyn Error>> {
        let dir = tempfile::tempdir()?;
        let store = ConductorStore::open(dir.path())?;
        Ok((dir, BudgetGovernor::with_now_ms(store, limits(), NOW_MS)))
    }

    fn budget_file(dir: &TempDir) -> std::path::PathBuf {
        dir.path().join("conductor_budget_usage.jsonl")
    }

    fn first_budget_record(dir: &TempDir) -> Result<BudgetUsageRecord, Box<dyn Error>> {
        let content = std::fs::read_to_string(budget_file(dir))?;
        match content.lines().next() {
            Some(line) => Ok(serde_json::from_str(line)?),
            None => Err(io::Error::new(io::ErrorKind::InvalidData, "missing budget record").into()),
        }
    }

    #[test]
    fn cost_cap_blocks_when_exceeded_and_allows_when_under() -> Result<(), Box<dyn Error>> {
        let (_dir, governor) = governor()?;
        assert!(governor.check(&route(), &estimate(100, 500)).is_allow());
        assert_eq!(
            governor.check(&route(), &estimate(101, 500)),
            BudgetVerdict::Block {
                dimension: BudgetDimension::CostMicros,
                limit: 100,
                attempted: 101,
                used: 0,
                window_ms: 0,
            }
        );
        Ok(())
    }

    #[test]
    fn wall_clock_cap_blocks_when_exceeded_and_allows_when_under() -> Result<(), Box<dyn Error>> {
        let (_dir, governor) = governor()?;
        assert!(governor.check(&route(), &estimate(100, 500)).is_allow());
        assert_eq!(
            governor.check(&route(), &estimate(100, 501)),
            BudgetVerdict::Block {
                dimension: BudgetDimension::WallClockMs,
                limit: 500,
                attempted: 501,
                used: 0,
                window_ms: 0,
            }
        );
        Ok(())
    }

    #[test]
    fn per_day_cap_blocks_when_exceeded_and_allows_when_under() -> Result<(), Box<dyn Error>> {
        let (_dir, governor) = governor()?;
        let route = route();
        governor.record(&route, &actual(980, 120));

        assert!(governor.check(&route, &estimate(20, 500)).is_allow());
        assert_eq!(
            governor.check(&route, &estimate(21, 500)),
            BudgetVerdict::Block {
                dimension: BudgetDimension::DailyCostMicros,
                limit: 1_000,
                attempted: 21,
                used: 980,
                window_ms: DEFAULT_DAILY_WINDOW_MS,
            }
        );
        Ok(())
    }

    #[test]
    fn corrupt_state_fails_closed() -> Result<(), Box<dyn Error>> {
        let (dir, governor) = governor()?;
        std::fs::write(budget_file(&dir), "not-json\n")?;

        assert_eq!(
            governor.check(&route(), &estimate(1, 1)),
            BudgetVerdict::Block {
                dimension: BudgetDimension::DailyCostMicros,
                limit: 1_000,
                attempted: 1,
                used: 0,
                window_ms: DEFAULT_DAILY_WINDOW_MS,
            }
        );
        Ok(())
    }

    #[test]
    fn unavailable_state_fails_closed() -> Result<(), Box<dyn Error>> {
        let (dir, governor) = governor()?;
        std::fs::remove_dir_all(dir.path())?;

        assert_eq!(
            governor.check(&route(), &estimate(1, 1)),
            BudgetVerdict::Block {
                dimension: BudgetDimension::DailyCostMicros,
                limit: 1_000,
                attempted: 1,
                used: 0,
                window_ms: DEFAULT_DAILY_WINDOW_MS,
            }
        );
        Ok(())
    }

    #[test]
    fn token_usage_is_recorded_but_never_blocks() -> Result<(), Box<dyn Error>> {
        let (dir, governor) = governor()?;
        let route = route();
        let high_token_estimate = CostEstimate {
            cost_micros: 1,
            wall_clock_ms: 1,
            input_tokens: u64::MAX,
            output_tokens: u64::MAX,
        };
        assert!(governor.check(&route, &high_token_estimate).is_allow());

        let high_token_actual = ActualCost {
            cost_micros: 1,
            wall_clock_ms: 1,
            input_tokens: 12_345,
            output_tokens: 67_890,
        };
        governor.record(&route, &high_token_actual);
        let record = first_budget_record(&dir)?;

        assert_eq!(record.input_tokens, 12_345);
        assert_eq!(record.output_tokens, 67_890);
        assert_eq!(record.total_tokens, 80_235);
        assert!(governor.check(&route, &high_token_estimate).is_allow());
        Ok(())
    }

    #[test]
    fn old_spend_outside_rolling_window_is_ignored() -> Result<(), Box<dyn Error>> {
        let dir = tempfile::tempdir()?;
        let store = ConductorStore::open(dir.path())?;
        let old_governor = BudgetGovernor::with_now_ms(
            store.clone(),
            limits(),
            NOW_MS.saturating_sub(DEFAULT_DAILY_WINDOW_MS + 1),
        );
        let route = route();
        old_governor.record(&route, &actual(1_000, 10));

        let current_governor = BudgetGovernor::with_now_ms(store, limits(), NOW_MS);
        assert!(current_governor
            .check(&route, &estimate(100, 10))
            .is_allow());
        Ok(())
    }

    #[test]
    fn blocking_verdict_maps_to_structured_route_failure() {
        let verdict = BudgetVerdict::Block {
            dimension: BudgetDimension::DailyCostMicros,
            limit: 1_000,
            attempted: 50,
            used: 975,
            window_ms: DEFAULT_DAILY_WINDOW_MS,
        };

        assert!(matches!(
            verdict.into_route_failure(),
            Some(RouteFailure::BudgetExceeded {
                dimension: BudgetDimension::DailyCostMicros,
                limit: 1_000,
                attempted: 50,
                used: 975,
                window_ms: DEFAULT_DAILY_WINDOW_MS,
            })
        ));
    }
}
