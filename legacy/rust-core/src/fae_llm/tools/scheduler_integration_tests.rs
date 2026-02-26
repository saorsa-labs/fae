//! Integration tests for the scheduler LLM tools.
//!
//! Verifies that all five scheduler tools work correctly together:
//! schema consistency, mode gating through the registry, validation
//! error semantics, and ToolResult formatting.

use super::registry::ToolRegistry;
use super::types::Tool;
use super::{
    SchedulerCreateTool, SchedulerDeleteTool, SchedulerListTool, SchedulerTriggerTool,
    SchedulerUpdateTool,
};
use crate::fae_llm::config::types::ToolMode;
use std::sync::Arc;

// ── Helper ─────────────────────────────────────────────────────

/// Build a registry with all 5 scheduler tools registered.
fn scheduler_registry(mode: ToolMode) -> ToolRegistry {
    let mut reg = ToolRegistry::new(mode);
    reg.register(Arc::new(SchedulerListTool::new()));
    reg.register(Arc::new(SchedulerCreateTool::new()));
    reg.register(Arc::new(SchedulerUpdateTool::new()));
    reg.register(Arc::new(SchedulerDeleteTool::new()));
    reg.register(Arc::new(SchedulerTriggerTool::new()));
    reg
}

/// All scheduler tool names.
const ALL_NAMES: [&str; 5] = [
    "list_scheduled_tasks",
    "create_scheduled_task",
    "update_scheduled_task",
    "delete_scheduled_task",
    "trigger_scheduled_task",
];

/// Mutation-only scheduler tool names (not available in ReadOnly mode).
const MUTATION_NAMES: [&str; 4] = [
    "create_scheduled_task",
    "update_scheduled_task",
    "delete_scheduled_task",
    "trigger_scheduled_task",
];

// ── Schema Tests ───────────────────────────────────────────────

#[test]
fn all_scheduler_schemas_are_objects_with_properties() {
    let reg = scheduler_registry(ToolMode::Full);
    for name in &ALL_NAMES {
        let tool = reg.get(name);
        assert!(tool.is_some(), "tool '{name}' should be registered");
        let tool = match tool {
            Some(t) => t,
            None => unreachable!("already asserted"),
        };
        let schema = tool.schema();
        assert!(schema.is_object(), "{name}: schema should be an object");
        assert!(
            schema.get("type").is_some(),
            "{name}: schema should have 'type'"
        );
        assert!(
            schema.get("properties").is_some(),
            "{name}: schema should have 'properties'"
        );
    }
}

#[test]
fn all_scheduler_schemas_exported_in_full_mode() {
    let reg = scheduler_registry(ToolMode::Full);
    let schemas = reg.schemas_for_api();

    let schema_names: Vec<&str> = schemas
        .iter()
        .filter_map(|s| s.get("name").and_then(|v| v.as_str()))
        .collect();

    for name in &ALL_NAMES {
        assert!(
            schema_names.contains(name),
            "schema for '{name}' should be in API export"
        );
    }
}

#[test]
fn only_list_schema_exported_in_readonly_mode() {
    let reg = scheduler_registry(ToolMode::ReadOnly);
    let schemas = reg.schemas_for_api();

    let schema_names: Vec<&str> = schemas
        .iter()
        .filter_map(|s| s.get("name").and_then(|v| v.as_str()))
        .collect();

    assert!(
        schema_names.contains(&"list_scheduled_tasks"),
        "list tool should be in ReadOnly export"
    );
    for name in &MUTATION_NAMES {
        assert!(
            !schema_names.contains(name),
            "mutation tool '{name}' should NOT be in ReadOnly export"
        );
    }
}

#[test]
fn all_tool_names_unique() {
    let tools: Vec<Arc<dyn Tool>> = vec![
        Arc::new(SchedulerListTool::new()),
        Arc::new(SchedulerCreateTool::new()),
        Arc::new(SchedulerUpdateTool::new()),
        Arc::new(SchedulerDeleteTool::new()),
        Arc::new(SchedulerTriggerTool::new()),
    ];
    let names: Vec<&str> = tools.iter().map(|t| t.name()).collect();
    let mut unique = names.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(names.len(), unique.len(), "all tool names should be unique");
}

#[test]
fn all_tools_have_nonempty_descriptions() {
    let tools: Vec<Arc<dyn Tool>> = vec![
        Arc::new(SchedulerListTool::new()),
        Arc::new(SchedulerCreateTool::new()),
        Arc::new(SchedulerUpdateTool::new()),
        Arc::new(SchedulerDeleteTool::new()),
        Arc::new(SchedulerTriggerTool::new()),
    ];
    for tool in &tools {
        assert!(
            !tool.description().is_empty(),
            "tool '{}' should have a description",
            tool.name()
        );
    }
}

// ── Mode Gating Tests ──────────────────────────────────────────

#[test]
fn full_mode_allows_all_scheduler_tools() {
    let reg = scheduler_registry(ToolMode::Full);
    let available = reg.list_available();
    for name in &ALL_NAMES {
        assert!(
            available.contains(name),
            "'{name}' should be available in Full mode"
        );
    }
}

#[test]
fn readonly_mode_allows_only_list() {
    let reg = scheduler_registry(ToolMode::ReadOnly);
    let available = reg.list_available();
    assert!(
        available.contains(&"list_scheduled_tasks"),
        "list should be available in ReadOnly mode"
    );
    for name in &MUTATION_NAMES {
        assert!(
            !available.contains(name),
            "mutation tool '{name}' should be blocked in ReadOnly mode"
        );
    }
}

#[test]
fn mode_switch_updates_scheduler_availability() {
    let mut reg = scheduler_registry(ToolMode::ReadOnly);

    // Initially only list visible.
    assert_eq!(
        reg.list_available().len(),
        1,
        "ReadOnly: only list should be available"
    );

    // Switch to Full — all 5 become visible.
    reg.set_mode(ToolMode::Full);
    assert_eq!(
        reg.list_available().len(),
        5,
        "Full: all 5 should be available"
    );

    // Switch back to ReadOnly.
    reg.set_mode(ToolMode::ReadOnly);
    assert_eq!(
        reg.list_available().len(),
        1,
        "ReadOnly again: only list should be available"
    );
}

// ── Validation Tests ───────────────────────────────────────────

#[test]
fn create_rejects_missing_name() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "schedule": {"type": "interval", "secs": 60}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_whitespace_only_name() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "   ",
        "schedule": {"type": "interval", "secs": 60}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_missing_schedule() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({"name": "test"}));
    assert!(result.is_err());
}

#[test]
fn create_rejects_unknown_schedule_type() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "test",
        "schedule": {"type": "monthly", "day": 1}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_interval_zero_secs() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "test",
        "schedule": {"type": "interval", "secs": 0}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_daily_hour_over_23() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "test",
        "schedule": {"type": "daily", "hour": 24, "min": 0}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_daily_min_over_59() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "test",
        "schedule": {"type": "daily", "hour": 9, "min": 60}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_weekly_empty_weekdays() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "test",
        "schedule": {"type": "weekly", "weekdays": [], "hour": 9, "min": 0}
    }));
    assert!(result.is_err());
}

#[test]
fn create_rejects_weekly_invalid_weekday() {
    let tool = SchedulerCreateTool::new();
    let result = tool.execute(serde_json::json!({
        "name": "test",
        "schedule": {"type": "weekly", "weekdays": ["funday"], "hour": 9, "min": 0}
    }));
    assert!(result.is_err());
}

#[test]
fn update_rejects_missing_task_id() {
    let tool = SchedulerUpdateTool::new();
    let result = tool.execute(serde_json::json!({"enabled": true}));
    assert!(result.is_err());
}

#[test]
fn update_rejects_missing_enabled() {
    let tool = SchedulerUpdateTool::new();
    let result = tool.execute(serde_json::json!({"task_id": "test"}));
    assert!(result.is_err());
}

#[test]
fn update_rejects_non_boolean_enabled() {
    let tool = SchedulerUpdateTool::new();
    let result = tool.execute(serde_json::json!({"task_id": "test", "enabled": "yes"}));
    assert!(result.is_err());
}

#[test]
fn delete_rejects_missing_task_id() {
    let tool = SchedulerDeleteTool::new();
    let result = tool.execute(serde_json::json!({}));
    assert!(result.is_err());
}

#[test]
fn trigger_rejects_missing_task_id() {
    let tool = SchedulerTriggerTool::new();
    let result = tool.execute(serde_json::json!({}));
    assert!(result.is_err());
}

#[test]
fn list_defaults_to_all_filter() {
    // An empty args object should not error — defaults to "all" filter.
    let tool = SchedulerListTool::new();
    let result = tool.execute(serde_json::json!({}));
    // This calls load_persisted_snapshot() which may or may not succeed
    // depending on file state, but it should NOT fail validation.
    // It either succeeds or returns a ToolExecutionError (file I/O),
    // never a ToolValidationError.
    match result {
        Ok(_) => {} // success or failure ToolResult, both acceptable
        Err(crate::fae_llm::error::FaeLlmError::ToolValidationError(msg)) => {
            panic!("list with empty args should not produce a validation error: {msg}");
        }
        Err(_) => {} // I/O errors are acceptable in test env
    }
}

// ── Error Message Quality Tests ────────────────────────────────

#[test]
fn validation_errors_are_descriptive() {
    let create = SchedulerCreateTool::new();
    let update = SchedulerUpdateTool::new();
    let delete = SchedulerDeleteTool::new();
    let trigger = SchedulerTriggerTool::new();

    // Each validation error should mention the missing field.
    let err = create
        .execute(serde_json::json!({"schedule": {"type": "interval", "secs": 60}}))
        .unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.contains("name"),
        "create error should mention 'name': {msg}"
    );

    let err = update
        .execute(serde_json::json!({"task_id": "x"}))
        .unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.contains("enabled"),
        "update error should mention 'enabled': {msg}"
    );

    let err = delete.execute(serde_json::json!({})).unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.contains("task_id"),
        "delete error should mention 'task_id': {msg}"
    );

    let err = trigger.execute(serde_json::json!({})).unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.contains("task_id"),
        "trigger error should mention 'task_id': {msg}"
    );
}

// ── Schema Required Fields ─────────────────────────────────────

#[test]
fn create_schema_requires_name_and_schedule() {
    let tool = SchedulerCreateTool::new();
    let schema = tool.schema();
    let required = schema
        .get("required")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect::<Vec<&str>>());
    assert!(required.is_some());
    let required = match required {
        Some(r) => r,
        None => unreachable!(),
    };
    assert!(required.contains(&"name"));
    assert!(required.contains(&"schedule"));
}

#[test]
fn update_schema_requires_task_id_and_enabled() {
    let tool = SchedulerUpdateTool::new();
    let schema = tool.schema();
    let required = schema
        .get("required")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect::<Vec<&str>>());
    assert!(required.is_some());
    let required = match required {
        Some(r) => r,
        None => unreachable!(),
    };
    assert!(required.contains(&"task_id"));
    assert!(required.contains(&"enabled"));
}

#[test]
fn delete_schema_requires_task_id() {
    let tool = SchedulerDeleteTool::new();
    let schema = tool.schema();
    let required = schema
        .get("required")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect::<Vec<&str>>());
    assert!(required.is_some());
    let required = match required {
        Some(r) => r,
        None => unreachable!(),
    };
    assert!(required.contains(&"task_id"));
}

#[test]
fn trigger_schema_requires_task_id() {
    let tool = SchedulerTriggerTool::new();
    let schema = tool.schema();
    let required = schema
        .get("required")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).collect::<Vec<&str>>());
    assert!(required.is_some());
    let required = match required {
        Some(r) => r,
        None => unreachable!(),
    };
    assert!(required.contains(&"task_id"));
}

#[test]
fn list_schema_has_no_required_fields() {
    let tool = SchedulerListTool::new();
    let schema = tool.schema();
    // List has no required fields — the filter is optional.
    let required = schema.get("required").and_then(|v| v.as_array());
    assert!(
        required.is_none() || required.is_some_and(|arr| arr.is_empty()),
        "list schema should have no required fields"
    );
}

// ── Default Trait ──────────────────────────────────────────────

#[test]
fn all_tools_implement_default() {
    // Verify Default implementations work.
    let _list: SchedulerListTool = Default::default();
    let _create: SchedulerCreateTool = Default::default();
    let _update: SchedulerUpdateTool = Default::default();
    let _delete: SchedulerDeleteTool = Default::default();
    let _trigger: SchedulerTriggerTool = Default::default();
}
