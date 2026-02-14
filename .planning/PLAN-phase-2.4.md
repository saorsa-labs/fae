# Phase 2.4: Circuit Breaker & Adaptive Engine Selection

Track per-engine health, disable failing engines temporarily, and automatically
retry after a cooldown period.

## Prerequisites (Done in Phase 2.1-2.3)

- Orchestrator fans out to all configured engines concurrently
- `orchestrate_search()` collects per-engine Ok/Err results
- `SearchEngine` enum with 5 variants
- `SearchConfig` controls engine selection

## Tasks

---

## Task 1: Create circuit breaker module with types

Create `fae-search/src/circuit_breaker.rs` with:

- `CircuitState` enum: `Closed` (healthy), `Open` (tripped), `HalfOpen` (probing)
- `EngineHealth` struct: state, consecutive_failures, last_failure_time, last_success_time
- `CircuitBreakerConfig`: failure_threshold (default 3), cooldown_secs (default 60)
- `CircuitBreaker` struct with `HashMap<SearchEngine, EngineHealth>`
- Constructor: `CircuitBreaker::new(config)`
- Global singleton via `std::sync::OnceLock<std::sync::Mutex<CircuitBreaker>>`

**Files:**
- Create: `fae-search/src/circuit_breaker.rs`

**Acceptance criteria:**
- All types defined with proper docs
- CircuitState is Debug, Clone, Copy, PartialEq
- EngineHealth tracks failure/success timestamps
- Global accessor function: `fn global_breaker() -> &'static Mutex<CircuitBreaker>`

---

## Task 2: Implement state transition methods

Add to `CircuitBreaker`:

- `record_success(engine)` — reset failures to 0, set state to Closed, update last_success
- `record_failure(engine)` — increment failures, trip to Open if >= threshold, update last_failure
- `should_attempt(engine)` — Closed→true, Open→check cooldown (if elapsed→HalfOpen→true, else false), HalfOpen→true
- `engine_status(engine)` → current CircuitState
- `health_report()` → Vec of (engine, state, consecutive_failures)

**Files:**
- Modify: `fae-search/src/circuit_breaker.rs`

**Acceptance criteria:**
- Closed→Open after N consecutive failures
- Open→HalfOpen after cooldown elapsed
- HalfOpen→Closed on success
- HalfOpen→Open on failure (reset cooldown)
- No unwrap/expect in production code

---

## Task 3: Integrate with orchestrator

Modify `orchestrate_search()` to use the circuit breaker.

- Before querying each engine, check `should_attempt()`
- After success, call `record_success()`
- After failure, call `record_failure()`
- If circuit breaker skips all engines, fall back to trying them all (don't fail with zero engines)

**Files:**
- Modify: `fae-search/src/orchestrator/search.rs`
- Modify: `fae-search/src/lib.rs` (add `pub mod circuit_breaker`)

**Acceptance criteria:**
- Tripped engines skipped in normal operation
- Success/failure recorded after each engine attempt
- Graceful fallback: if all engines tripped, try all anyway
- No behaviour change when all engines healthy (Closed state)

---

## Task 4: Unit tests for circuit breaker

Comprehensive tests for all state transitions and integration.

**Tests:**
- Initial state is Closed for all engines
- Transitions: Closed→Open after threshold failures
- Open remains Open during cooldown
- Open→HalfOpen after cooldown elapsed
- HalfOpen→Closed on success
- HalfOpen→Open on failure
- Record success resets consecutive failures
- Health report includes all engines
- should_attempt returns correct values per state
- Global singleton is accessible

**Files:**
- Tests in: `fae-search/src/circuit_breaker.rs`

**Acceptance criteria:**
- All state transitions tested
- Edge cases covered
- Tests pass without network access
