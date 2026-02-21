//! Integration tests for the Python skill health monitoring system.

use fae::skills::health_monitor::{
    FixPatternStore, HealthAction, HealthCheckOutcome, HealthLedger, HealthMonitor,
    HealthMonitorConfig, SkillHealthStatus, normalize_error,
};

#[test]
fn full_health_check_flow_healthy_to_quarantine() {
    let config = HealthMonitorConfig {
        max_consecutive_failures: 3,
        ..Default::default()
    };
    let mut monitor = HealthMonitor::new(config);

    // Healthy checks produce no actions.
    let actions = monitor.process_check_result("skill-a", HealthCheckOutcome::Healthy);
    assert!(actions.is_empty());
    assert_eq!(
        monitor.ledger().get("skill-a").unwrap().status,
        SkillHealthStatus::Healthy,
    );

    // Two failures → restarts.
    for i in 1..=2 {
        let actions = monitor.process_check_result(
            "skill-a",
            HealthCheckOutcome::Failed {
                error: "timeout".into(),
            },
        );
        assert!(
            actions.iter().any(|a| matches!(
                a,
                HealthAction::RestartSkill { skill_id, .. } if skill_id == "skill-a"
            )),
            "failure {i} should trigger restart"
        );
    }

    // Third failure → quarantine (threshold=3).
    let actions = monitor.process_check_result(
        "skill-a",
        HealthCheckOutcome::Failed {
            error: "timeout".into(),
        },
    );
    assert!(
        actions
            .iter()
            .any(|a| matches!(a, HealthAction::QuarantineSkill { .. })),
        "should quarantine after 3 consecutive failures"
    );

    // Verify ledger shows quarantined.
    let rec = monitor.ledger().get("skill-a").unwrap();
    assert!(matches!(rec.status, SkillHealthStatus::Quarantined { .. }));
    assert_eq!(rec.total_failures, 3);
    assert_eq!(rec.total_checks, 4); // 1 healthy + 3 failed
}

#[test]
fn fix_pattern_round_trip() {
    let mut store = FixPatternStore::new();

    // Record a fix.
    store.record_fix("connection refused", "restart the backend service", Some("discord-bot"));

    // Match against a new error that contains the same pattern.
    let error = "2026-01-15T12:34:56Z error: connection refused on /var/run/discord.sock";
    let normalised = normalize_error(error);
    let found = store.find_matching(&normalised);
    assert!(found.is_some(), "should match normalised error");
    assert_eq!(found.unwrap().fix_description, "restart the backend service");
    assert_eq!(found.unwrap().skill_id.as_deref(), Some("discord-bot"));
}

#[test]
fn ledger_isolation_across_skills() {
    let mut ledger = HealthLedger::new();

    ledger.record_failure("a", "err");
    ledger.record_failure("a", "err");
    ledger.record_success("b");

    assert_eq!(ledger.get("a").unwrap().consecutive_failures, 2);
    assert_eq!(ledger.get("b").unwrap().consecutive_failures, 0);
    assert!(ledger.should_quarantine("a", 2));
    assert!(!ledger.should_quarantine("b", 2));
}

#[test]
fn host_command_skill_health_check() {
    use fae::host::channel::command_channel;
    use fae::host::contract::{CommandEnvelope, CommandName};

    let (handler, _dir, _rt) = super::helpers::temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // No skills installed, so health check should return empty.
    let envelope = CommandEnvelope::new(
        "req-health-1",
        CommandName::SkillHealthCheck,
        serde_json::json!({}),
    );

    let response = server.route(&envelope).expect("route");
    assert!(response.ok);
    assert_eq!(response.payload["checked"], 0);
}

#[test]
fn host_command_skill_health_status() {
    use fae::host::channel::command_channel;
    use fae::host::contract::{CommandEnvelope, CommandName};

    let (handler, _dir, _rt) = super::helpers::temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-health-2",
        CommandName::SkillHealthStatusCmd,
        serde_json::json!({}),
    );

    let response = server.route(&envelope).expect("route");
    assert!(response.ok);
    assert_eq!(response.payload["total"], 0);
    assert!(response.payload["skills"].as_array().unwrap().is_empty());
}

#[test]
fn health_status_serde_consistency() {
    // Verify all variants round-trip through JSON.
    let statuses = vec![
        SkillHealthStatus::Healthy,
        SkillHealthStatus::Degraded {
            reason: "slow api response".into(),
        },
        SkillHealthStatus::Failing { consecutive: 3 },
        SkillHealthStatus::Quarantined {
            reason: "max failures exceeded".into(),
        },
    ];

    for status in statuses {
        let json = serde_json::to_string(&status).expect("serialize");
        let parsed: SkillHealthStatus = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed, status, "round-trip failed for: {json}");
    }
}

#[test]
fn normalize_error_consistency() {
    // Same error with different timestamps/paths should normalize identically.
    let err1 = "2026-01-15t10:00:00z failed to connect to /home/user/a.sock";
    let err2 = "2026-06-01t23:59:59z failed to connect to /opt/data/b.sock";
    assert_eq!(normalize_error(err1), normalize_error(err2));
}
