//! Health monitoring and self-healing for Python skills.
//!
//! The health monitor periodically checks running skills, tracks failure
//! history, and generates corrective actions (restart, quarantine, notify).
//! It also maintains a store of fix patterns so recurring errors can be
//! matched against known solutions.
//!
//! # Design
//!
//! The monitor is **pure logic** — no async I/O. It accepts check results
//! and produces [`HealthAction`] values for the caller to execute.

use std::collections::HashMap;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

// ── Health status per skill ──────────────────────────────────────────────────

/// Coarse health status of a single skill.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "status")]
pub enum SkillHealthStatus {
    /// Skill is responding normally.
    Healthy,
    /// Skill responded but reported degraded operation.
    Degraded {
        /// Human-readable reason for degradation.
        reason: String,
    },
    /// Skill has failed one or more consecutive health checks.
    Failing {
        /// Number of consecutive failures.
        consecutive: u32,
    },
    /// Skill has been quarantined after exceeding the failure threshold.
    Quarantined {
        /// Why the skill was quarantined.
        reason: String,
    },
}

impl std::fmt::Display for SkillHealthStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Healthy => write!(f, "healthy"),
            Self::Degraded { reason } => write!(f, "degraded: {reason}"),
            Self::Failing { consecutive } => {
                write!(f, "failing ({consecutive} consecutive)")
            }
            Self::Quarantined { reason } => write!(f, "quarantined: {reason}"),
        }
    }
}

// ── Health record ────────────────────────────────────────────────────────────

/// Tracks health-check history for a single skill.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillHealthRecord {
    /// Skill identifier.
    pub skill_id: String,
    /// Timestamp of the most recent health check.
    pub last_check: Option<SystemTime>,
    /// Number of consecutive failures (resets on success).
    pub consecutive_failures: u32,
    /// Lifetime total failures.
    pub total_failures: u32,
    /// Lifetime total checks.
    pub total_checks: u32,
    /// Error message from the most recent failure, if any.
    pub last_error: Option<String>,
    /// Current health status.
    pub status: SkillHealthStatus,
}

impl SkillHealthRecord {
    /// Create a new record for `skill_id` with zero history.
    pub fn new(skill_id: impl Into<String>) -> Self {
        Self {
            skill_id: skill_id.into(),
            last_check: None,
            consecutive_failures: 0,
            total_failures: 0,
            total_checks: 0,
            last_error: None,
            status: SkillHealthStatus::Healthy,
        }
    }
}

// ── Health check outcome (input to the monitor) ──────────────────────────────

/// Result of a single health check sent to a running skill.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthCheckOutcome {
    /// Skill responded with `"ok"`.
    Healthy,
    /// Skill responded but reported degraded status.
    Degraded {
        /// Detail string from the skill's health response.
        detail: String,
    },
    /// Skill failed to respond or returned an error.
    Failed {
        /// Error message describing the failure.
        error: String,
    },
    /// Skill process is not running / unreachable.
    Unreachable {
        /// Why the skill could not be reached.
        reason: String,
    },
}

// ── Health action (output from the monitor) ──────────────────────────────────

/// Corrective action the monitor recommends after evaluating check results.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthAction {
    /// Restart the skill process.
    RestartSkill {
        /// Skill to restart.
        skill_id: String,
        /// Which restart attempt this is.
        attempt: u32,
    },
    /// Quarantine the skill (disable after repeated failures).
    QuarantineSkill {
        /// Skill to quarantine.
        skill_id: String,
        /// Human-readable reason.
        reason: String,
    },
    /// Notify the user about a skill issue.
    NotifyUser {
        /// Skill that is having issues.
        skill_id: String,
        /// Message to display.
        message: String,
    },
}

// ── Health ledger ────────────────────────────────────────────────────────────

/// In-memory ledger tracking health records for all monitored skills.
#[derive(Debug, Default)]
pub struct HealthLedger {
    records: HashMap<String, SkillHealthRecord>,
}

impl HealthLedger {
    /// Create an empty ledger.
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a successful health check.
    pub fn record_success(&mut self, skill_id: &str) {
        let rec = self.get_or_create(skill_id);
        rec.total_checks += 1;
        rec.consecutive_failures = 0;
        rec.last_check = Some(SystemTime::now());
        rec.last_error = None;
        rec.status = SkillHealthStatus::Healthy;
    }

    /// Record a degraded health check.
    pub fn record_degraded(&mut self, skill_id: &str, reason: &str) {
        let rec = self.get_or_create(skill_id);
        rec.total_checks += 1;
        rec.consecutive_failures = 0;
        rec.last_check = Some(SystemTime::now());
        rec.last_error = None;
        rec.status = SkillHealthStatus::Degraded {
            reason: reason.to_owned(),
        };
    }

    /// Record a failed health check.
    pub fn record_failure(&mut self, skill_id: &str, error: &str) {
        let rec = self.get_or_create(skill_id);
        rec.total_checks += 1;
        rec.total_failures += 1;
        rec.consecutive_failures += 1;
        rec.last_check = Some(SystemTime::now());
        rec.last_error = Some(error.to_owned());
        rec.status = SkillHealthStatus::Failing {
            consecutive: rec.consecutive_failures,
        };
    }

    /// Mark a skill as quarantined in the ledger.
    pub fn mark_quarantined(&mut self, skill_id: &str, reason: &str) {
        let rec = self.get_or_create(skill_id);
        rec.status = SkillHealthStatus::Quarantined {
            reason: reason.to_owned(),
        };
    }

    /// Check whether a skill has exceeded the quarantine threshold.
    pub fn should_quarantine(&self, skill_id: &str, threshold: u32) -> bool {
        self.records
            .get(skill_id)
            .is_some_and(|r| r.consecutive_failures >= threshold)
    }

    /// Get a health record by skill ID.
    pub fn get(&self, skill_id: &str) -> Option<&SkillHealthRecord> {
        self.records.get(skill_id)
    }

    /// Return all health records.
    pub fn all_records(&self) -> Vec<&SkillHealthRecord> {
        self.records.values().collect()
    }

    /// Number of tracked skills.
    pub fn len(&self) -> usize {
        self.records.len()
    }

    /// Whether the ledger is empty.
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    fn get_or_create(&mut self, skill_id: &str) -> &mut SkillHealthRecord {
        self.records
            .entry(skill_id.to_owned())
            .or_insert_with(|| SkillHealthRecord::new(skill_id))
    }
}

// ── Health monitor config ────────────────────────────────────────────────────

/// Configuration for the health monitoring system.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthMonitorConfig {
    /// Interval between health checks in seconds (default: 300 = 5 min).
    pub check_interval_secs: u64,
    /// Timeout for each health check request in seconds (default: 10).
    pub health_timeout_secs: u64,
    /// Maximum consecutive failures before quarantine (default: 5).
    pub max_consecutive_failures: u32,
    /// Whether to automatically restart failed skills (default: true).
    pub auto_restart: bool,
    /// Whether to automatically quarantine after threshold (default: true).
    pub auto_quarantine: bool,
}

impl Default for HealthMonitorConfig {
    fn default() -> Self {
        Self {
            check_interval_secs: 300,
            health_timeout_secs: 10,
            max_consecutive_failures: 5,
            auto_restart: true,
            auto_quarantine: true,
        }
    }
}

// ── Health monitor ───────────────────────────────────────────────────────────

/// Pure-logic health monitor that accepts check results and produces actions.
///
/// The monitor does not perform I/O — callers execute the returned
/// [`HealthAction`] values.
pub struct HealthMonitor {
    config: HealthMonitorConfig,
    ledger: HealthLedger,
}

impl HealthMonitor {
    /// Create a new monitor with the given configuration.
    pub fn new(config: HealthMonitorConfig) -> Self {
        Self {
            config,
            ledger: HealthLedger::new(),
        }
    }

    /// Create a monitor with default configuration.
    pub fn with_defaults() -> Self {
        Self::new(HealthMonitorConfig::default())
    }

    /// Process a health check result and return any corrective actions.
    pub fn process_check_result(
        &mut self,
        skill_id: &str,
        outcome: HealthCheckOutcome,
    ) -> Vec<HealthAction> {
        let mut actions = Vec::new();

        match &outcome {
            HealthCheckOutcome::Healthy => {
                self.ledger.record_success(skill_id);
            }
            HealthCheckOutcome::Degraded { detail } => {
                self.ledger.record_degraded(skill_id, detail);
                actions.push(HealthAction::NotifyUser {
                    skill_id: skill_id.to_owned(),
                    message: format!("Skill '{skill_id}' is degraded: {detail}"),
                });
            }
            HealthCheckOutcome::Failed { error } => {
                self.ledger.record_failure(skill_id, error);
                self.append_failure_actions(skill_id, error, &mut actions);
            }
            HealthCheckOutcome::Unreachable { reason } => {
                self.ledger.record_failure(skill_id, reason);
                self.append_failure_actions(skill_id, reason, &mut actions);
            }
        }

        actions
    }

    /// Read-only access to the underlying ledger.
    pub fn ledger(&self) -> &HealthLedger {
        &self.ledger
    }

    /// Read-only access to the configuration.
    pub fn config(&self) -> &HealthMonitorConfig {
        &self.config
    }

    fn append_failure_actions(
        &mut self,
        skill_id: &str,
        error: &str,
        actions: &mut Vec<HealthAction>,
    ) {
        let consecutive = self
            .ledger
            .get(skill_id)
            .map_or(0, |r| r.consecutive_failures);

        if self.config.auto_quarantine
            && self
                .ledger
                .should_quarantine(skill_id, self.config.max_consecutive_failures)
        {
            let reason = format!(
                "exceeded {} consecutive failures (last: {error})",
                self.config.max_consecutive_failures
            );
            self.ledger.mark_quarantined(skill_id, &reason);
            actions.push(HealthAction::QuarantineSkill {
                skill_id: skill_id.to_owned(),
                reason: reason.clone(),
            });
            actions.push(HealthAction::NotifyUser {
                skill_id: skill_id.to_owned(),
                message: format!("Skill '{skill_id}' quarantined: {reason}"),
            });
        } else if self.config.auto_restart {
            actions.push(HealthAction::RestartSkill {
                skill_id: skill_id.to_owned(),
                attempt: consecutive,
            });
        }
    }
}

// ── Fix pattern storage ──────────────────────────────────────────────────────

/// A recorded pattern linking an error signature to a known fix.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixPattern {
    /// Normalised error signature for matching.
    pub error_signature: String,
    /// Description of what was done to fix the error.
    pub fix_description: String,
    /// Optional skill ID if the pattern is skill-specific.
    pub skill_id: Option<String>,
    /// How many times this pattern has been successfully applied.
    pub success_count: u32,
    /// When the pattern was first recorded.
    pub created_at: SystemTime,
}

/// In-memory store of known fix patterns.
#[derive(Debug, Default)]
pub struct FixPatternStore {
    patterns: Vec<FixPattern>,
}

impl FixPatternStore {
    /// Create an empty store.
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a new fix pattern.
    pub fn record_fix(
        &mut self,
        error_signature: &str,
        fix_description: &str,
        skill_id: Option<&str>,
    ) {
        // Check if we already have a pattern for this signature.
        if let Some(existing) = self
            .patterns
            .iter_mut()
            .find(|p| p.error_signature == error_signature)
        {
            existing.success_count += 1;
            existing.fix_description = fix_description.to_owned();
            return;
        }
        self.patterns.push(FixPattern {
            error_signature: error_signature.to_owned(),
            fix_description: fix_description.to_owned(),
            skill_id: skill_id.map(ToOwned::to_owned),
            success_count: 1,
            created_at: SystemTime::now(),
        });
    }

    /// Find the best matching fix pattern for an error message.
    ///
    /// Returns the first pattern whose `error_signature` is a substring of the
    /// normalised error, preferring patterns with higher success counts.
    pub fn find_matching(&self, raw_error: &str) -> Option<&FixPattern> {
        let normalised = normalize_error(raw_error);
        let mut best: Option<&FixPattern> = None;
        for pattern in &self.patterns {
            if normalised.contains(&pattern.error_signature) {
                match best {
                    Some(b) if b.success_count >= pattern.success_count => {}
                    _ => best = Some(pattern),
                }
            }
        }
        best
    }

    /// Number of stored patterns.
    pub fn len(&self) -> usize {
        self.patterns.len()
    }

    /// Whether the store is empty.
    pub fn is_empty(&self) -> bool {
        self.patterns.is_empty()
    }

    /// All stored patterns.
    pub fn patterns(&self) -> &[FixPattern] {
        &self.patterns
    }
}

/// Normalise a raw error message for pattern matching.
///
/// Strips timestamps (ISO-8601), absolute paths, UUIDs, and numeric IDs so
/// that structurally similar errors produce the same signature.
pub fn normalize_error(raw: &str) -> String {
    let mut s = raw.to_lowercase();
    // Strip ISO-8601 timestamps: 2026-01-15T12:34:56Z or similar
    s = strip_pattern(&s, r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\dZ]*");
    // Strip absolute paths: /foo/bar/baz
    s = strip_pattern(&s, r"/[\w./-]+");
    // Strip UUIDs: 550e8400-e29b-41d4-a716-446655440000
    s = strip_pattern(&s, r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    // Strip standalone numbers (IDs, ports, etc.)
    s = strip_pattern(&s, r"\b\d{2,}\b");
    // Collapse whitespace
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Replace all occurrences of `pattern` with an empty string.
fn strip_pattern(input: &str, pattern: &str) -> String {
    // Use a simple char-by-char approach for patterns that would require regex.
    // Since we don't want to add regex as a dependency, use manual stripping
    // for the most common cases.
    match pattern {
        // ISO timestamps
        r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\dZ]*" => {
            strip_iso_timestamps(input)
        }
        // Absolute paths
        r"/[\w./-]+" => strip_absolute_paths(input),
        // UUIDs
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" => {
            strip_uuids(input)
        }
        // Standalone numbers
        r"\b\d{2,}\b" => strip_long_numbers(input),
        _ => input.to_owned(),
    }
}

fn strip_iso_timestamps(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut result = String::with_capacity(input.len());
    let mut i = 0;
    while i < chars.len() {
        // Look for YYYY-MM-DD pattern
        if i + 10 <= chars.len()
            && chars[i].is_ascii_digit()
            && chars[i + 1].is_ascii_digit()
            && chars[i + 2].is_ascii_digit()
            && chars[i + 3].is_ascii_digit()
            && chars[i + 4] == '-'
            && chars[i + 5].is_ascii_digit()
            && chars[i + 6].is_ascii_digit()
            && chars[i + 7] == '-'
            && chars[i + 8].is_ascii_digit()
            && chars[i + 9].is_ascii_digit()
        {
            // Skip the timestamp and any trailing time portion
            i += 10;
            // Skip T or space followed by HH:MM:SS
            if i < chars.len() && (chars[i] == 't' || chars[i] == ' ') {
                i += 1;
                while i < chars.len()
                    && (chars[i].is_ascii_digit() || chars[i] == ':' || chars[i] == '.' || chars[i] == 'z')
                {
                    i += 1;
                }
            }
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }
    result
}

fn strip_absolute_paths(input: &str) -> String {
    let mut result = String::with_capacity(input.len());
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '/' && i + 1 < chars.len() && (chars[i + 1].is_alphanumeric() || chars[i + 1] == '.') {
            // Skip the path
            while i < chars.len()
                && (chars[i].is_alphanumeric() || chars[i] == '/' || chars[i] == '.' || chars[i] == '-' || chars[i] == '_')
            {
                i += 1;
            }
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }
    result
}

fn strip_uuids(input: &str) -> String {
    let mut result = String::with_capacity(input.len());
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        // Look for 8-4-4-4-12 hex pattern
        if i + 36 <= chars.len() && is_uuid_at(&chars, i) {
            i += 36;
            continue;
        }
        result.push(chars[i]);
        i += 1;
    }
    result
}

fn is_uuid_at(chars: &[char], start: usize) -> bool {
    let groups = [8, 4, 4, 4, 12];
    let mut pos = start;
    for (gi, &len) in groups.iter().enumerate() {
        for _ in 0..len {
            if pos >= chars.len() || !chars[pos].is_ascii_hexdigit() {
                return false;
            }
            pos += 1;
        }
        if gi < 4 {
            if pos >= chars.len() || chars[pos] != '-' {
                return false;
            }
            pos += 1;
        }
    }
    true
}

fn strip_long_numbers(input: &str) -> String {
    let mut result = String::with_capacity(input.len());
    let mut num_buf = String::new();
    for ch in input.chars() {
        if ch.is_ascii_digit() {
            num_buf.push(ch);
        } else {
            if num_buf.len() < 2 {
                result.push_str(&num_buf);
            }
            num_buf.clear();
            result.push(ch);
        }
    }
    if num_buf.len() < 2 {
        result.push_str(&num_buf);
    }
    result
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    // ── SkillHealthRecord ──

    #[test]
    fn new_record_starts_healthy() {
        let rec = SkillHealthRecord::new("test-skill");
        assert_eq!(rec.skill_id, "test-skill");
        assert_eq!(rec.consecutive_failures, 0);
        assert_eq!(rec.total_failures, 0);
        assert_eq!(rec.total_checks, 0);
        assert!(rec.last_check.is_none());
        assert!(rec.last_error.is_none());
        assert_eq!(rec.status, SkillHealthStatus::Healthy);
    }

    // ── SkillHealthStatus display ──

    #[test]
    fn health_status_display() {
        assert_eq!(SkillHealthStatus::Healthy.to_string(), "healthy");
        assert_eq!(
            SkillHealthStatus::Degraded {
                reason: "slow".into()
            }
            .to_string(),
            "degraded: slow"
        );
        assert_eq!(
            SkillHealthStatus::Failing { consecutive: 3 }.to_string(),
            "failing (3 consecutive)"
        );
        assert_eq!(
            SkillHealthStatus::Quarantined {
                reason: "too many failures".into()
            }
            .to_string(),
            "quarantined: too many failures"
        );
    }

    #[test]
    fn health_status_serde_round_trip() {
        let statuses = vec![
            SkillHealthStatus::Healthy,
            SkillHealthStatus::Degraded {
                reason: "slow api".into(),
            },
            SkillHealthStatus::Failing { consecutive: 3 },
            SkillHealthStatus::Quarantined {
                reason: "max failures".into(),
            },
        ];
        for status in statuses {
            let json = serde_json::to_string(&status).expect("serialize");
            let parsed: SkillHealthStatus = serde_json::from_str(&json).expect("deserialize");
            assert_eq!(parsed, status);
        }
    }

    // ── HealthLedger ──

    #[test]
    fn ledger_starts_empty() {
        let ledger = HealthLedger::new();
        assert!(ledger.is_empty());
        assert_eq!(ledger.len(), 0);
    }

    #[test]
    fn ledger_record_success() {
        let mut ledger = HealthLedger::new();
        ledger.record_success("s1");
        let rec = ledger.get("s1").expect("should exist");
        assert_eq!(rec.total_checks, 1);
        assert_eq!(rec.consecutive_failures, 0);
        assert_eq!(rec.status, SkillHealthStatus::Healthy);
        assert!(rec.last_check.is_some());
    }

    #[test]
    fn ledger_record_failure_increments() {
        let mut ledger = HealthLedger::new();
        ledger.record_failure("s1", "timeout");
        ledger.record_failure("s1", "timeout again");
        let rec = ledger.get("s1").unwrap();
        assert_eq!(rec.total_checks, 2);
        assert_eq!(rec.total_failures, 2);
        assert_eq!(rec.consecutive_failures, 2);
        assert_eq!(
            rec.status,
            SkillHealthStatus::Failing { consecutive: 2 }
        );
        assert_eq!(rec.last_error.as_deref(), Some("timeout again"));
    }

    #[test]
    fn ledger_success_resets_consecutive_failures() {
        let mut ledger = HealthLedger::new();
        ledger.record_failure("s1", "err");
        ledger.record_failure("s1", "err");
        assert_eq!(ledger.get("s1").unwrap().consecutive_failures, 2);

        ledger.record_success("s1");
        let rec = ledger.get("s1").unwrap();
        assert_eq!(rec.consecutive_failures, 0);
        assert_eq!(rec.total_failures, 2); // lifetime total unchanged
        assert_eq!(rec.total_checks, 3);
        assert_eq!(rec.status, SkillHealthStatus::Healthy);
    }

    #[test]
    fn ledger_record_degraded() {
        let mut ledger = HealthLedger::new();
        ledger.record_degraded("s1", "slow response");
        let rec = ledger.get("s1").unwrap();
        assert_eq!(rec.total_checks, 1);
        assert_eq!(rec.consecutive_failures, 0);
        assert_eq!(
            rec.status,
            SkillHealthStatus::Degraded {
                reason: "slow response".into()
            }
        );
    }

    #[test]
    fn ledger_should_quarantine() {
        let mut ledger = HealthLedger::new();
        for _ in 0..5 {
            ledger.record_failure("s1", "err");
        }
        assert!(ledger.should_quarantine("s1", 5));
        assert!(!ledger.should_quarantine("s1", 6));
        assert!(!ledger.should_quarantine("nonexistent", 5));
    }

    #[test]
    fn ledger_mark_quarantined() {
        let mut ledger = HealthLedger::new();
        ledger.record_failure("s1", "err");
        ledger.mark_quarantined("s1", "too many failures");
        assert_eq!(
            ledger.get("s1").unwrap().status,
            SkillHealthStatus::Quarantined {
                reason: "too many failures".into()
            }
        );
    }

    #[test]
    fn ledger_all_records() {
        let mut ledger = HealthLedger::new();
        ledger.record_success("a");
        ledger.record_success("b");
        ledger.record_success("c");
        assert_eq!(ledger.all_records().len(), 3);
        assert_eq!(ledger.len(), 3);
    }

    #[test]
    fn ledger_multiple_skills_isolated() {
        let mut ledger = HealthLedger::new();
        ledger.record_failure("s1", "err");
        ledger.record_success("s2");
        assert_eq!(ledger.get("s1").unwrap().consecutive_failures, 1);
        assert_eq!(ledger.get("s2").unwrap().consecutive_failures, 0);
    }

    // ── HealthMonitorConfig ──

    #[test]
    fn config_defaults() {
        let config = HealthMonitorConfig::default();
        assert_eq!(config.check_interval_secs, 300);
        assert_eq!(config.health_timeout_secs, 10);
        assert_eq!(config.max_consecutive_failures, 5);
        assert!(config.auto_restart);
        assert!(config.auto_quarantine);
    }

    #[test]
    fn config_serde_round_trip() {
        let config = HealthMonitorConfig::default();
        let json = serde_json::to_string(&config).expect("serialize");
        let parsed: HealthMonitorConfig = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed.check_interval_secs, config.check_interval_secs);
        assert_eq!(parsed.max_consecutive_failures, config.max_consecutive_failures);
    }

    // ── HealthMonitor ──

    #[test]
    fn monitor_healthy_check_no_actions() {
        let mut monitor = HealthMonitor::with_defaults();
        let actions = monitor.process_check_result("s1", HealthCheckOutcome::Healthy);
        assert!(actions.is_empty());
        assert_eq!(
            monitor.ledger().get("s1").unwrap().status,
            SkillHealthStatus::Healthy
        );
    }

    #[test]
    fn monitor_degraded_notifies_user() {
        let mut monitor = HealthMonitor::with_defaults();
        let actions = monitor.process_check_result(
            "s1",
            HealthCheckOutcome::Degraded {
                detail: "slow".into(),
            },
        );
        assert_eq!(actions.len(), 1);
        assert!(matches!(
            &actions[0],
            HealthAction::NotifyUser { skill_id, message }
            if skill_id == "s1" && message.contains("degraded")
        ));
    }

    #[test]
    fn monitor_failure_triggers_restart() {
        let mut monitor = HealthMonitor::with_defaults();
        let actions = monitor.process_check_result(
            "s1",
            HealthCheckOutcome::Failed {
                error: "timeout".into(),
            },
        );
        assert_eq!(actions.len(), 1);
        assert!(matches!(
            &actions[0],
            HealthAction::RestartSkill { skill_id, attempt: 1 }
            if skill_id == "s1"
        ));
    }

    #[test]
    fn monitor_repeated_failures_quarantine() {
        let mut monitor = HealthMonitor::with_defaults();
        // 4 failures → restart actions
        for _ in 0..4 {
            let actions = monitor.process_check_result(
                "s1",
                HealthCheckOutcome::Failed {
                    error: "err".into(),
                },
            );
            assert!(
                actions.iter().any(|a| matches!(a, HealthAction::RestartSkill { .. })),
                "should get restart action"
            );
        }
        // 5th failure → quarantine (threshold is 5)
        let actions = monitor.process_check_result(
            "s1",
            HealthCheckOutcome::Failed {
                error: "err".into(),
            },
        );
        assert!(
            actions.iter().any(|a| matches!(a, HealthAction::QuarantineSkill { .. })),
            "should quarantine after 5 consecutive failures"
        );
        assert!(
            actions.iter().any(|a| matches!(a, HealthAction::NotifyUser { .. })),
            "should notify user about quarantine"
        );
    }

    #[test]
    fn monitor_success_resets_failure_path() {
        let mut monitor = HealthMonitor::with_defaults();
        // 4 failures
        for _ in 0..4 {
            monitor.process_check_result(
                "s1",
                HealthCheckOutcome::Failed {
                    error: "err".into(),
                },
            );
        }
        // 1 success resets
        monitor.process_check_result("s1", HealthCheckOutcome::Healthy);
        // Next failure is only #1, not #5
        let actions = monitor.process_check_result(
            "s1",
            HealthCheckOutcome::Failed {
                error: "err".into(),
            },
        );
        assert!(matches!(
            &actions[0],
            HealthAction::RestartSkill { attempt: 1, .. }
        ));
    }

    #[test]
    fn monitor_unreachable_treated_as_failure() {
        let mut monitor = HealthMonitor::with_defaults();
        let actions = monitor.process_check_result(
            "s1",
            HealthCheckOutcome::Unreachable {
                reason: "process dead".into(),
            },
        );
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], HealthAction::RestartSkill { .. }));
    }

    #[test]
    fn monitor_auto_restart_disabled() {
        let config = HealthMonitorConfig {
            auto_restart: false,
            ..Default::default()
        };
        let mut monitor = HealthMonitor::new(config);
        let actions = monitor.process_check_result(
            "s1",
            HealthCheckOutcome::Failed {
                error: "err".into(),
            },
        );
        assert!(actions.is_empty(), "should not restart when disabled");
    }

    #[test]
    fn monitor_auto_quarantine_disabled() {
        let config = HealthMonitorConfig {
            auto_quarantine: false,
            auto_restart: true,
            max_consecutive_failures: 2,
            ..Default::default()
        };
        let mut monitor = HealthMonitor::new(config);
        for _ in 0..5 {
            let actions = monitor.process_check_result(
                "s1",
                HealthCheckOutcome::Failed {
                    error: "err".into(),
                },
            );
            // Should only get restart, never quarantine
            assert!(actions.iter().all(|a| !matches!(a, HealthAction::QuarantineSkill { .. })));
        }
    }

    // ── Fix pattern store ──

    #[test]
    fn fix_store_starts_empty() {
        let store = FixPatternStore::new();
        assert!(store.is_empty());
        assert_eq!(store.len(), 0);
    }

    #[test]
    fn fix_store_record_and_find() {
        let mut store = FixPatternStore::new();
        store.record_fix("connection refused", "restart the service", None);
        assert_eq!(store.len(), 1);

        let found = store.find_matching("error: connection refused on port 8080");
        assert!(found.is_some());
        assert_eq!(found.unwrap().fix_description, "restart the service");
    }

    #[test]
    fn fix_store_no_match() {
        let mut store = FixPatternStore::new();
        store.record_fix("connection refused", "restart", None);
        assert!(store.find_matching("authentication failed").is_none());
    }

    #[test]
    fn fix_store_duplicate_increments_count() {
        let mut store = FixPatternStore::new();
        store.record_fix("timeout", "increase timeout", None);
        store.record_fix("timeout", "increase timeout v2", None);
        assert_eq!(store.len(), 1);
        assert_eq!(store.patterns()[0].success_count, 2);
        assert_eq!(store.patterns()[0].fix_description, "increase timeout v2");
    }

    #[test]
    fn fix_store_prefers_higher_success_count() {
        let mut store = FixPatternStore::new();
        store.record_fix("error", "fix a", None);
        store.record_fix("error", "fix a", None); // count=2
        store.record_fix("error occurred", "fix b", None); // count=1

        // Both match "error occurred", but "error" has count=2
        let found = store.find_matching("some error occurred here");
        assert!(found.is_some());
        assert_eq!(found.unwrap().success_count, 2);
    }

    #[test]
    fn fix_store_skill_specific() {
        let mut store = FixPatternStore::new();
        store.record_fix("api error", "update api key", Some("discord-bot"));
        let found = store.find_matching("api error: unauthorized");
        assert!(found.is_some());
        assert_eq!(found.unwrap().skill_id.as_deref(), Some("discord-bot"));
    }

    // ── normalize_error ──

    #[test]
    fn normalize_strips_timestamps() {
        let raw = "error at 2026-01-15t12:34:56z: connection failed";
        let normalized = normalize_error(raw);
        assert!(!normalized.contains("2026"));
        assert!(normalized.contains("connection failed"));
    }

    #[test]
    fn normalize_strips_paths() {
        let raw = "failed to read /home/user/.fae/skills/my-skill/skill.py";
        let normalized = normalize_error(raw);
        assert!(!normalized.contains("/home"));
        assert!(normalized.contains("failed to read"));
    }

    #[test]
    fn normalize_strips_uuids() {
        let raw = "request 550e8400-e29b-41d4-a716-446655440000 failed";
        let normalized = normalize_error(raw);
        assert!(!normalized.contains("550e8400"));
        assert!(normalized.contains("request"));
        assert!(normalized.contains("failed"));
    }

    #[test]
    fn normalize_strips_long_numbers() {
        let raw = "error on port 8080 with id 123456";
        let normalized = normalize_error(raw);
        assert!(!normalized.contains("8080"));
        assert!(!normalized.contains("123456"));
    }

    #[test]
    fn normalize_collapses_whitespace() {
        let raw = "  error    in    module  ";
        let normalized = normalize_error(raw);
        assert_eq!(normalized, "error in module");
    }

    #[test]
    fn normalize_lowercases() {
        let raw = "ConnectionRefused: HOST unreachable";
        let normalized = normalize_error(raw);
        assert_eq!(normalized, "connectionrefused: host unreachable");
    }

    // ── Type assertions ──

    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SkillHealthRecord>();
        assert_send_sync::<SkillHealthStatus>();
        assert_send_sync::<HealthMonitorConfig>();
        assert_send_sync::<FixPattern>();
    }
}
