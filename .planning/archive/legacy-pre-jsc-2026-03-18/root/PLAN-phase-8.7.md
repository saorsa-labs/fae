# Phase 8.7: Self-Healing & Health Monitoring

**Goal**: Periodic health checks for running Python skills, automatic restart with backoff on failure, error capture with LLM-driven repair suggestions, memory-backed fix patterns, and quarantine on repeated failure.

**Dependencies**: Phase 8.6 (skill generator), Phase 8.1 (runner has backoff + health check primitives)

---

## Existing Infrastructure

Already implemented:
- `PythonSkillRunner` with `perform_health_check()`, daemon restart with exponential backoff, `max_restarts` cap
- `PythonSkillStatus` with `Quarantined` state + `quarantine_python_skill()` transition
- `HealthResult` protocol type with `status` + `detail` fields
- `Scheduler` with `ScheduledTask`, `Schedule::Interval`, `add_task()`
- `MemoryKind` enum (Profile, Episode, Fact, Event, Person, Interest, Commitment)

**What's missing** (this phase builds):
1. A `HealthMonitor` that periodically checks all active skills and acts on results
2. Error diagnosis + repair suggestion logic (pattern matching, not LLM-driven yet — LLM repair is Phase 8.6+ enhancement)
3. `SkillHealthRecord` for tracking failure history per skill
4. Fix pattern storage and retrieval
5. Host commands for health status reporting
6. Scheduler integration to run health checks on cadence

---

## Task 1: SkillHealthRecord and HealthLedger types

**New file**: `src/skills/health_monitor.rs`

Define types for tracking health history per skill:

```rust
pub struct SkillHealthRecord {
    pub skill_id: String,
    pub last_check: Option<SystemTime>,
    pub consecutive_failures: u32,
    pub total_failures: u32,
    pub total_checks: u32,
    pub last_error: Option<String>,
    pub status: SkillHealthStatus,
}

pub enum SkillHealthStatus {
    Healthy,
    Degraded { reason: String },
    Failing { consecutive: u32 },
    Quarantined { reason: String },
}

pub struct HealthLedger {
    records: HashMap<String, SkillHealthRecord>,
}
```

`HealthLedger` methods: `record_success()`, `record_failure()`, `get()`, `all_records()`, `should_quarantine()` (configurable threshold, default 5 consecutive failures).

**Tests**: 15+ unit tests for ledger state transitions, failure counting, quarantine threshold.

**Files**: `src/skills/health_monitor.rs`, `src/skills/mod.rs` (add `pub mod health_monitor`)

---

## Task 2: HealthMonitorConfig and check_skill_health()

**Same file**: `src/skills/health_monitor.rs`

```rust
pub struct HealthMonitorConfig {
    pub check_interval_secs: u64,      // default: 300 (5 min)
    pub health_timeout_secs: u64,      // default: 10
    pub max_consecutive_failures: u32,  // default: 5 (before quarantine)
    pub auto_restart: bool,            // default: true
    pub auto_quarantine: bool,         // default: true
}
```

`check_skill_health(runner, skill_id, config) -> HealthCheckOutcome` — sends health check to a running skill, returns outcome enum (Healthy, Degraded, Failed, Unreachable).

**Tests**: 8+ unit tests for config defaults, outcome classification.

**Files**: `src/skills/health_monitor.rs`

---

## Task 3: HealthMonitor orchestrator

**Same file**: `src/skills/health_monitor.rs`

```rust
pub struct HealthMonitor {
    config: HealthMonitorConfig,
    ledger: HealthLedger,
}
```

Methods:
- `new(config)` — create with config
- `process_check_result(skill_id, outcome)` — update ledger, decide action
- `pending_actions() -> Vec<HealthAction>` — returns actions to take

```rust
pub enum HealthAction {
    RestartSkill { skill_id: String, attempt: u32 },
    QuarantineSkill { skill_id: String, reason: String },
    NotifyUser { skill_id: String, message: String },
}
```

The monitor is pure logic — no async, no I/O. It takes check results and produces actions. The caller (scheduler task or host command) executes the actions.

**Tests**: 12+ unit tests for action generation based on ledger state.

**Files**: `src/skills/health_monitor.rs`

---

## Task 4: Fix pattern storage

**Same file**: `src/skills/health_monitor.rs`

```rust
pub struct FixPattern {
    pub error_signature: String,  // normalized error pattern
    pub fix_description: String,  // what was done to fix it
    pub skill_id: Option<String>, // if skill-specific
    pub success_count: u32,
    pub created_at: SystemTime,
}

pub struct FixPatternStore {
    patterns: Vec<FixPattern>,
}
```

Methods:
- `record_fix(error_sig, description, skill_id)` — store a new fix
- `find_matching(error_msg) -> Option<&FixPattern>` — substring match on error signature
- `normalize_error(raw_error) -> String` — strip timestamps, paths, IDs for pattern matching

This is the foundation for "memory-backed fix patterns". When a skill fails and is manually or automatically fixed, the pattern is recorded. Future failures with matching signatures suggest the known fix.

**Tests**: 10+ unit tests for normalization, matching, recording.

**Files**: `src/skills/health_monitor.rs`

---

## Task 5: Host commands for health monitoring

**Files**: `src/host/contract.rs`, `src/host/channel.rs`, `src/host/handler.rs`

Add two new commands:

```rust
// contract.rs
CommandName::SkillHealthCheck,    // "skill.health.check" — trigger health check for one or all skills
CommandName::SkillHealthStatus,   // "skill.health.status" — get health ledger summary
```

Handler implementations:
- `skill_health_check(skill_id: Option<&str>)` — if skill_id given, check that skill; if None, return current ledger summary
- `skill_health_status()` — returns all health records as JSON

**Tests**: 4+ integration tests using `command_channel()` pattern.

**Files**: `src/host/contract.rs`, `src/host/channel.rs`, `src/host/handler.rs`, `tests/integration/python_skill_health_monitor.rs`, `tests/integration/main.rs`

---

## Task 6: Scheduler integration

**File**: `src/scheduler/runner.rs`

Add a `with_skill_health_checks()` method to `Scheduler` that registers a periodic health check task:

```rust
pub fn with_skill_health_checks(&mut self) {
    let task = ScheduledTask::new(
        "skill_health_check",
        "Python Skill Health Checks",
        Schedule::Interval { secs: 300 },  // every 5 minutes
    );
    self.add_task_if_missing(task);
}
```

Add the builtin task handler in `execute_builtin()` that runs health checks for all active skills.

**Tests**: 3+ unit tests for task registration and scheduling.

**Files**: `src/scheduler/runner.rs`, `src/scheduler/tasks.rs`

---

## Task 7: Integration tests and wiring

Create integration test file and ensure everything compiles together.

- Test the full flow: health check → failure recording → quarantine threshold → action generation
- Test fix pattern round-trip: record fix → match against new error → retrieve suggestion
- Verify host command routing end-to-end
- Wire `with_skill_health_checks()` into the runtime startup (handler.rs or runtime.rs)

**Files**: `tests/integration/python_skill_health_monitor.rs`, `tests/integration/main.rs`

---

## Summary

| Task | Description | Est. Lines | Files |
|------|-------------|-----------|-------|
| 1 | SkillHealthRecord + HealthLedger types | ~200 | health_monitor.rs, mod.rs |
| 2 | HealthMonitorConfig + check_skill_health() | ~120 | health_monitor.rs |
| 3 | HealthMonitor orchestrator + HealthAction | ~180 | health_monitor.rs |
| 4 | Fix pattern storage | ~150 | health_monitor.rs |
| 5 | Host commands (health.check, health.status) | ~120 | contract.rs, channel.rs, handler.rs |
| 6 | Scheduler integration | ~60 | runner.rs, tasks.rs |
| 7 | Integration tests + wiring | ~180 | tests/integration/, handler.rs |

**Total estimated**: ~1000 lines of new code + tests
