//! Tool argument validation against JSON schemas.
//!
//! Validates that tool call arguments from the LLM conform to the
//! tool's declared JSON schema. Checks required fields, type constraints,
//! and basic structural correctness.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::agent::validation::validate_tool_args;
//!
//! let schema = serde_json::json!({
//!     "type": "object",
//!     "properties": {
//!         "path": { "type": "string" }
//!     },
//!     "required": ["path"]
//! });
//!
//! let result = validate_tool_args("read", r#"{"path": "main.rs"}"#, &schema);
//! assert!(result.is_ok());
//! ```

use crate::fae_llm::error::FaeLlmError;

/// Validate tool arguments JSON against a JSON schema.
///
/// Parses `args_json` as JSON, then validates against `schema`:
/// - All fields listed in `"required"` must be present
/// - Field types must match those declared in `"properties"`
/// - Extra fields not in the schema are allowed (open schema)
///
/// # Arguments
///
/// * `tool_name` — Name of the tool (for error messages)
/// * `args_json` — Raw JSON string from the LLM
/// * `schema` — JSON Schema for the tool's parameters
///
/// # Errors
///
/// Returns [`FaeLlmError::ToolError`] if:
/// - `args_json` is not valid JSON
/// - A required field is missing
/// - A field has the wrong type
pub fn validate_tool_args(
    tool_name: &str,
    args_json: &str,
    schema: &serde_json::Value,
) -> Result<serde_json::Value, FaeLlmError> {
    // Parse JSON
    let value: serde_json::Value = serde_json::from_str(args_json).map_err(|e| {
        FaeLlmError::ToolError(format!("tool '{tool_name}': invalid JSON arguments: {e}"))
    })?;

    // Schema must describe an object
    let schema_type = schema.get("type").and_then(|t| t.as_str()).unwrap_or("");
    if schema_type != "object" {
        // Non-object schemas — just return the parsed value
        return Ok(value);
    }

    // Arguments must be an object
    let obj = value.as_object().ok_or_else(|| {
        FaeLlmError::ToolError(format!(
            "tool '{tool_name}': expected object arguments, got {}",
            json_type_name(&value)
        ))
    })?;

    // Check required fields
    if let Some(required) = schema.get("required").and_then(|r| r.as_array()) {
        for req_field in required {
            if let Some(field_name) = req_field.as_str()
                && !obj.contains_key(field_name)
            {
                return Err(FaeLlmError::ToolError(format!(
                    "tool '{tool_name}': missing required field '{field_name}'"
                )));
            }
        }
    }

    // Validate field types against properties schema
    if let Some(properties) = schema.get("properties").and_then(|p| p.as_object()) {
        for (key, val) in obj {
            if let Some(prop_schema) = properties.get(key) {
                validate_field_type(tool_name, key, val, prop_schema)?;
            }
            // Extra fields not in schema are allowed (open schema)
        }
    }

    Ok(value)
}

/// Validate that a single field's value matches its schema type.
fn validate_field_type(
    tool_name: &str,
    field_name: &str,
    value: &serde_json::Value,
    prop_schema: &serde_json::Value,
) -> Result<(), FaeLlmError> {
    let expected_type = match prop_schema.get("type").and_then(|t| t.as_str()) {
        Some(t) => t,
        None => return Ok(()), // No type constraint — anything goes
    };

    let matches = match expected_type {
        "string" => value.is_string(),
        "number" => value.is_number(),
        "integer" => value.is_i64() || value.is_u64(),
        "boolean" => value.is_boolean(),
        "object" => value.is_object(),
        "array" => value.is_array(),
        "null" => value.is_null(),
        _ => true, // Unknown type — don't reject
    };

    if !matches {
        return Err(FaeLlmError::ToolError(format!(
            "tool '{tool_name}': field '{field_name}' expected {expected_type}, got {}",
            json_type_name(value)
        )));
    }

    Ok(())
}

/// Get a human-readable name for a JSON value's type.
fn json_type_name(value: &serde_json::Value) -> &'static str {
    match value {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "boolean",
        serde_json::Value::Number(n) => {
            if n.is_i64() || n.is_u64() {
                "integer"
            } else {
                "number"
            }
        }
        serde_json::Value::String(_) => "string",
        serde_json::Value::Array(_) => "array",
        serde_json::Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_schema() -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string" },
                "offset": { "type": "integer" },
                "limit": { "type": "integer" }
            },
            "required": ["path"]
        })
    }

    fn bash_schema() -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "command": { "type": "string" },
                "timeout": { "type": "number" }
            },
            "required": ["command"]
        })
    }

    // ── Valid arguments ──────────────────────────────────────

    #[test]
    fn valid_args_minimal() {
        let result = validate_tool_args("read", r#"{"path": "main.rs"}"#, &read_schema());
        assert!(result.is_ok());
        let val = match result {
            Ok(v) => v,
            Err(_) => unreachable!("validation succeeded"),
        };
        assert_eq!(val["path"], "main.rs");
    }

    #[test]
    fn valid_args_all_fields() {
        let result = validate_tool_args(
            "read",
            r#"{"path": "main.rs", "offset": 10, "limit": 50}"#,
            &read_schema(),
        );
        assert!(result.is_ok());
    }

    #[test]
    fn valid_args_extra_fields_allowed() {
        let result = validate_tool_args(
            "read",
            r#"{"path": "main.rs", "extra_field": true}"#,
            &read_schema(),
        );
        assert!(result.is_ok());
    }

    #[test]
    fn valid_args_empty_object_no_required() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "optional": { "type": "string" }
            }
        });
        let result = validate_tool_args("test", r#"{}"#, &schema);
        assert!(result.is_ok());
    }

    // ── Invalid JSON ─────────────────────────────────────────

    #[test]
    fn invalid_json() {
        let result = validate_tool_args("read", "not json at all", &read_schema());
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolError(msg)) => {
                assert!(msg.contains("invalid JSON"));
                assert!(msg.contains("read"));
            }
            _ => unreachable!("expected ToolError"),
        }
    }

    #[test]
    fn invalid_json_partial() {
        let result = validate_tool_args("bash", r#"{"command":"#, &bash_schema());
        assert!(result.is_err());
    }

    #[test]
    fn invalid_json_empty_string() {
        let result = validate_tool_args("read", "", &read_schema());
        assert!(result.is_err());
    }

    // ── Missing required fields ──────────────────────────────

    #[test]
    fn missing_required_field() {
        let result = validate_tool_args("read", r#"{"offset": 10}"#, &read_schema());
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolError(msg)) => {
                assert!(msg.contains("missing required field"));
                assert!(msg.contains("path"));
            }
            _ => unreachable!("expected ToolError"),
        }
    }

    #[test]
    fn missing_all_required_fields() {
        let result = validate_tool_args("read", r#"{}"#, &read_schema());
        assert!(result.is_err());
    }

    // ── Wrong field types ────────────────────────────────────

    #[test]
    fn wrong_type_string_expected() {
        let result = validate_tool_args("read", r#"{"path": 123}"#, &read_schema());
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolError(msg)) => {
                assert!(msg.contains("expected string"));
                assert!(msg.contains("path"));
            }
            _ => unreachable!("expected ToolError"),
        }
    }

    #[test]
    fn wrong_type_integer_expected() {
        let result = validate_tool_args(
            "read",
            r#"{"path": "a.rs", "offset": "not a number"}"#,
            &read_schema(),
        );
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolError(msg)) => {
                assert!(msg.contains("expected integer"));
                assert!(msg.contains("offset"));
            }
            _ => unreachable!("expected ToolError"),
        }
    }

    #[test]
    fn wrong_type_number_expected() {
        let result = validate_tool_args(
            "bash",
            r#"{"command": "ls", "timeout": "slow"}"#,
            &bash_schema(),
        );
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolError(msg)) => {
                assert!(msg.contains("expected number"));
                assert!(msg.contains("timeout"));
            }
            _ => unreachable!("expected ToolError"),
        }
    }

    #[test]
    fn wrong_type_boolean_expected() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "flag": { "type": "boolean" }
            },
            "required": ["flag"]
        });
        let result = validate_tool_args("test", r#"{"flag": "yes"}"#, &schema);
        assert!(result.is_err());
    }

    #[test]
    fn wrong_type_array_expected() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "items": { "type": "array" }
            },
            "required": ["items"]
        });
        let result = validate_tool_args("test", r#"{"items": "not array"}"#, &schema);
        assert!(result.is_err());
    }

    #[test]
    fn wrong_type_object_expected() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "data": { "type": "object" }
            },
            "required": ["data"]
        });
        let result = validate_tool_args("test", r#"{"data": 42}"#, &schema);
        assert!(result.is_err());
    }

    // ── Non-object arguments ─────────────────────────────────

    #[test]
    fn args_is_array_not_object() {
        let result = validate_tool_args("read", r#"[1, 2, 3]"#, &read_schema());
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolError(msg)) => {
                assert!(msg.contains("expected object"));
            }
            _ => unreachable!("expected ToolError"),
        }
    }

    #[test]
    fn args_is_string_not_object() {
        let result = validate_tool_args("read", r#""just a string""#, &read_schema());
        assert!(result.is_err());
    }

    // ── Edge cases ───────────────────────────────────────────

    #[test]
    fn empty_schema_accepts_anything() {
        let schema = serde_json::json!({});
        let result = validate_tool_args("test", r#"{"anything": "goes"}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn schema_without_properties() {
        let schema = serde_json::json!({
            "type": "object",
            "required": ["path"]
        });
        let result = validate_tool_args("read", r#"{"path": "test.rs"}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn schema_without_required() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string" }
            }
        });
        let result = validate_tool_args("read", r#"{}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn property_without_type_constraint() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "data": { "description": "any data" }
            },
            "required": ["data"]
        });
        let result = validate_tool_args("test", r#"{"data": [1, 2, 3]}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn nested_object_validation() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "config": { "type": "object" }
            },
            "required": ["config"]
        });
        let result = validate_tool_args("test", r#"{"config": {"key": "value"}}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn integer_accepts_positive_integers() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "count": { "type": "integer" }
            },
            "required": ["count"]
        });
        let result = validate_tool_args("test", r#"{"count": 42}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn integer_rejects_float() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "count": { "type": "integer" }
            },
            "required": ["count"]
        });
        let result = validate_tool_args("test", r#"{"count": 3.14}"#, &schema);
        assert!(result.is_err());
    }

    #[test]
    fn number_accepts_float() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "value": { "type": "number" }
            },
            "required": ["value"]
        });
        let result = validate_tool_args("test", r#"{"value": 3.14}"#, &schema);
        assert!(result.is_ok());
    }

    #[test]
    fn number_accepts_integer() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "value": { "type": "number" }
            },
            "required": ["value"]
        });
        let result = validate_tool_args("test", r#"{"value": 42}"#, &schema);
        assert!(result.is_ok());
    }

    // ── json_type_name ───────────────────────────────────────

    #[test]
    fn json_type_name_coverage() {
        assert_eq!(json_type_name(&serde_json::Value::Null), "null");
        assert_eq!(json_type_name(&serde_json::json!(true)), "boolean");
        assert_eq!(json_type_name(&serde_json::json!("hi")), "string");
        assert_eq!(json_type_name(&serde_json::json!([1])), "array");
        assert_eq!(json_type_name(&serde_json::json!({"k": "v"})), "object");
        assert_eq!(json_type_name(&serde_json::json!(42)), "integer");
        assert_eq!(json_type_name(&serde_json::json!(3.5)), "number");
    }
}
