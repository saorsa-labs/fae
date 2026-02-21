//! JSON-RPC 2.0 protocol types for Python skill communication.
//!
//! Skills communicate with the Fae core via newline-delimited JSON-RPC 2.0
//! messages on stdin/stdout. This module defines the message types and
//! parsing logic.
//!
//! # Handshake protocol
//!
//! After spawning, Fae sends a `skill.handshake` request:
//!
//! ```json
//! {"jsonrpc":"2.0","method":"skill.handshake","params":{"expected_name":"my-skill","fae_version":"0.8.1"},"id":1}
//! ```
//!
//! The skill must respond with its name and version:
//!
//! ```json
//! {"jsonrpc":"2.0","result":{"name":"my-skill","version":"1.0.0"},"id":1}
//! ```
//!
//! # Health check protocol
//!
//! Fae periodically sends `skill.health` requests:
//!
//! ```json
//! {"jsonrpc":"2.0","method":"skill.health","id":2}
//! ```
//!
//! The skill must respond with a status:
//!
//! ```json
//! {"jsonrpc":"2.0","result":{"status":"ok"},"id":2}
//! ```

use super::error::PythonSkillError;
use serde::{Deserialize, Serialize};

/// The JSON-RPC version string. Always `"2.0"`.
const JSONRPC_VERSION: &str = "2.0";

/// Method name for the handshake request.
pub const METHOD_HANDSHAKE: &str = "skill.handshake";

/// Method name for the health-check request.
pub const METHOD_HEALTH: &str = "skill.health";

/// A JSON-RPC 2.0 request (sent from Fae to a skill).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    /// Protocol version, always `"2.0"`.
    pub jsonrpc: String,
    /// The method name to invoke.
    pub method: String,
    /// Optional parameters for the method.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
    /// Request identifier for correlating responses.
    pub id: u64,
}

impl JsonRpcRequest {
    /// Creates a new JSON-RPC 2.0 request.
    pub fn new(method: &str, params: Option<serde_json::Value>, id: u64) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.to_owned(),
            method: method.to_owned(),
            params,
            id,
        }
    }

    /// Serializes this request to a JSON line (with trailing newline).
    pub fn to_line(&self) -> Result<String, PythonSkillError> {
        let mut line = serde_json::to_string(self)?;
        line.push('\n');
        Ok(line)
    }
}

/// A JSON-RPC 2.0 success response (sent from skill to Fae).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    /// Protocol version, always `"2.0"`.
    pub jsonrpc: String,
    /// The result value.
    pub result: serde_json::Value,
    /// Correlation identifier matching the request.
    pub id: u64,
}

/// A JSON-RPC 2.0 error object.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    /// Error code (negative for standard errors).
    pub code: i32,
    /// Human-readable error message.
    pub message: String,
    /// Optional additional error data.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

/// A JSON-RPC 2.0 error response (sent from skill to Fae).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcErrorResponse {
    /// Protocol version, always `"2.0"`.
    pub jsonrpc: String,
    /// The error object.
    pub error: JsonRpcError,
    /// Correlation identifier matching the request.
    pub id: u64,
}

/// A JSON-RPC 2.0 notification (no id, no response expected).
///
/// Skills send notifications for events like incoming messages,
/// status updates, etc.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcNotification {
    /// Protocol version, always `"2.0"`.
    pub jsonrpc: String,
    /// The notification method name.
    pub method: String,
    /// Optional parameters.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

/// An incoming message from a skill (either response, error, or notification).
#[derive(Debug, Clone)]
pub enum SkillMessage {
    /// A successful response to a request.
    Response(JsonRpcResponse),
    /// An error response to a request.
    Error(JsonRpcErrorResponse),
    /// A notification (no correlation id).
    Notification(JsonRpcNotification),
}

impl SkillMessage {
    /// Parses a JSON line into a skill message.
    ///
    /// Determines the variant by checking for the presence of `result`,
    /// `error`, or absence of `id` fields.
    pub fn parse(line: &str) -> Result<Self, PythonSkillError> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Err(PythonSkillError::ProtocolError {
                message: "empty message line".to_owned(),
            });
        }

        let value: serde_json::Value = serde_json::from_str(trimmed)?;

        // Validate jsonrpc version
        let version = value.get("jsonrpc").and_then(|v| v.as_str());
        if version != Some(JSONRPC_VERSION) {
            return Err(PythonSkillError::ProtocolError {
                message: format!(
                    "expected jsonrpc version \"{JSONRPC_VERSION}\", got {:?}",
                    version
                ),
            });
        }

        // Determine message type by field presence
        let has_id = value.get("id").is_some();
        let has_result = value.get("result").is_some();
        let has_error = value.get("error").is_some();

        if has_id && has_result {
            let response: JsonRpcResponse = serde_json::from_value(value)?;
            Ok(Self::Response(response))
        } else if has_id && has_error {
            let error: JsonRpcErrorResponse = serde_json::from_value(value)?;
            Ok(Self::Error(error))
        } else if !has_id {
            let notification: JsonRpcNotification = serde_json::from_value(value)?;
            Ok(Self::Notification(notification))
        } else {
            Err(PythonSkillError::ProtocolError {
                message: "message has id but neither result nor error field".to_owned(),
            })
        }
    }
}

// ── Handshake & health types ──────────────────────────────────────────────────

/// Parameters sent by Fae in a `skill.handshake` request.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HandshakeParams {
    /// The skill name Fae expects this process to identify as.
    pub expected_name: String,
    /// Fae's own version string (for compatibility checks by the skill).
    pub fae_version: String,
}

/// Result returned by the skill in response to `skill.handshake`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HandshakeResult {
    /// The skill's self-reported name. Must match [`HandshakeParams::expected_name`].
    pub name: String,
    /// The skill's self-reported version string.
    pub version: String,
}

impl HandshakeResult {
    /// Returns `true` if the skill's reported name matches the expected name.
    pub fn name_matches(&self, expected: &str) -> bool {
        self.name == expected
    }
}

/// Result returned by the skill in response to `skill.health`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HealthResult {
    /// Health status string. `"ok"` indicates healthy; any other value is a warning.
    pub status: String,
    /// Optional human-readable detail (e.g. active connections, queue depth).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl HealthResult {
    /// Returns `true` if the skill reports status `"ok"`.
    pub fn is_ok(&self) -> bool {
        self.status == "ok"
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn request_new_and_serialize() {
        let req = JsonRpcRequest::new("skill.handshake", None, 1);
        assert_eq!(req.jsonrpc, "2.0");
        assert_eq!(req.method, "skill.handshake");
        assert!(req.params.is_none());
        assert_eq!(req.id, 1);

        let line = req.to_line().unwrap();
        assert!(line.ends_with('\n'));
        assert!(line.contains("\"jsonrpc\":\"2.0\""));
    }

    #[test]
    fn request_with_params() {
        let params = serde_json::json!({"key": "value"});
        let req = JsonRpcRequest::new("do.something", Some(params), 42);
        let line = req.to_line().unwrap();
        assert!(line.contains("\"key\":\"value\""));
        assert!(line.contains("\"id\":42"));
    }

    #[test]
    fn request_round_trip() {
        let req = JsonRpcRequest::new("test", Some(serde_json::json!({"a": 1})), 99);
        let line = req.to_line().unwrap();
        let parsed: JsonRpcRequest = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed.method, "test");
        assert_eq!(parsed.id, 99);
    }

    #[test]
    fn parse_response() {
        let json = r#"{"jsonrpc":"2.0","result":{"status":"ok"},"id":1}"#;
        let msg = SkillMessage::parse(json).unwrap();
        match msg {
            SkillMessage::Response(resp) => {
                assert_eq!(resp.id, 1);
                assert_eq!(resp.result["status"], "ok");
            }
            other => panic!("expected Response, got {other:?}"),
        }
    }

    #[test]
    fn parse_error_response() {
        let json =
            r#"{"jsonrpc":"2.0","error":{"code":-32600,"message":"invalid request"},"id":2}"#;
        let msg = SkillMessage::parse(json).unwrap();
        match msg {
            SkillMessage::Error(err) => {
                assert_eq!(err.id, 2);
                assert_eq!(err.error.code, -32600);
                assert_eq!(err.error.message, "invalid request");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn parse_error_response_with_data() {
        let json = r#"{"jsonrpc":"2.0","error":{"code":-1,"message":"fail","data":{"detail":"x"}},"id":3}"#;
        let msg = SkillMessage::parse(json).unwrap();
        match msg {
            SkillMessage::Error(err) => {
                assert_eq!(err.error.data.unwrap()["detail"], "x");
            }
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn parse_notification() {
        let json = r#"{"jsonrpc":"2.0","method":"skill.ready","params":{"skill":"discord"}}"#;
        let msg = SkillMessage::parse(json).unwrap();
        match msg {
            SkillMessage::Notification(notif) => {
                assert_eq!(notif.method, "skill.ready");
                assert_eq!(notif.params.unwrap()["skill"], "discord");
            }
            other => panic!("expected Notification, got {other:?}"),
        }
    }

    #[test]
    fn parse_notification_without_params() {
        let json = r#"{"jsonrpc":"2.0","method":"heartbeat"}"#;
        let msg = SkillMessage::parse(json).unwrap();
        match msg {
            SkillMessage::Notification(notif) => {
                assert_eq!(notif.method, "heartbeat");
                assert!(notif.params.is_none());
            }
            other => panic!("expected Notification, got {other:?}"),
        }
    }

    #[test]
    fn parse_empty_line_fails() {
        let result = SkillMessage::parse("");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("empty message line"));
    }

    #[test]
    fn parse_invalid_json_fails() {
        let result = SkillMessage::parse("not json at all");
        assert!(result.is_err());
    }

    #[test]
    fn parse_wrong_version_fails() {
        let json = r#"{"jsonrpc":"1.0","result":{},"id":1}"#;
        let result = SkillMessage::parse(json);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("expected jsonrpc version"));
    }

    #[test]
    fn parse_missing_version_fails() {
        let json = r#"{"result":{},"id":1}"#;
        let result = SkillMessage::parse(json);
        assert!(result.is_err());
    }

    #[test]
    fn parse_id_without_result_or_error_fails() {
        let json = r#"{"jsonrpc":"2.0","method":"test","id":1}"#;
        let result = SkillMessage::parse(json);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("neither result nor error"));
    }

    #[test]
    fn parse_with_extra_fields_succeeds() {
        let json = r#"{"jsonrpc":"2.0","result":"ok","id":1,"extra":"ignored"}"#;
        let msg = SkillMessage::parse(json).unwrap();
        match msg {
            SkillMessage::Response(resp) => assert_eq!(resp.id, 1),
            other => panic!("expected Response, got {other:?}"),
        }
    }

    #[test]
    fn parse_whitespace_trimmed() {
        let json = r#"  {"jsonrpc":"2.0","result":"ok","id":1}  "#;
        let msg = SkillMessage::parse(json).unwrap();
        assert!(matches!(msg, SkillMessage::Response(_)));
    }

    #[test]
    fn response_round_trip() {
        let resp = JsonRpcResponse {
            jsonrpc: "2.0".to_owned(),
            result: serde_json::json!({"count": 42}),
            id: 7,
        };
        let json = serde_json::to_string(&resp).unwrap();
        let parsed = SkillMessage::parse(&json).unwrap();
        match parsed {
            SkillMessage::Response(r) => {
                assert_eq!(r.id, 7);
                assert_eq!(r.result["count"], 42);
            }
            other => panic!("expected Response, got {other:?}"),
        }
    }

    #[test]
    fn notification_round_trip() {
        let notif = JsonRpcNotification {
            jsonrpc: "2.0".to_owned(),
            method: "event.message".to_owned(),
            params: Some(serde_json::json!({"from": "user"})),
        };
        let json = serde_json::to_string(&notif).unwrap();
        let parsed = SkillMessage::parse(&json).unwrap();
        assert!(matches!(parsed, SkillMessage::Notification(_)));
    }

    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<JsonRpcRequest>();
        assert_send_sync::<JsonRpcResponse>();
        assert_send_sync::<JsonRpcErrorResponse>();
        assert_send_sync::<JsonRpcNotification>();
        assert_send_sync::<SkillMessage>();
    }

    // ── Handshake types ──

    #[test]
    fn handshake_params_serialize() {
        let params = HandshakeParams {
            expected_name: "discord-bot".to_owned(),
            fae_version: "0.8.1".to_owned(),
        };
        let json = serde_json::to_string(&params).unwrap();
        assert!(json.contains("discord-bot"));
        assert!(json.contains("0.8.1"));
    }

    #[test]
    fn handshake_result_round_trip() {
        let result = HandshakeResult {
            name: "discord-bot".to_owned(),
            version: "1.2.0".to_owned(),
        };
        let json = serde_json::to_string(&result).unwrap();
        let parsed: HandshakeResult = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.name, "discord-bot");
        assert_eq!(parsed.version, "1.2.0");
    }

    #[test]
    fn handshake_result_name_matches() {
        let result = HandshakeResult {
            name: "my-skill".to_owned(),
            version: "1.0.0".to_owned(),
        };
        assert!(result.name_matches("my-skill"));
        assert!(!result.name_matches("other-skill"));
    }

    #[test]
    fn health_result_is_ok() {
        let ok = HealthResult {
            status: "ok".to_owned(),
            detail: None,
        };
        assert!(ok.is_ok());

        let degraded = HealthResult {
            status: "degraded".to_owned(),
            detail: Some("queue full".to_owned()),
        };
        assert!(!degraded.is_ok());
    }

    #[test]
    fn health_result_round_trip_with_detail() {
        let result = HealthResult {
            status: "ok".to_owned(),
            detail: Some("connections: 3".to_owned()),
        };
        let json = serde_json::to_string(&result).unwrap();
        let parsed: HealthResult = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.status, "ok");
        assert_eq!(parsed.detail.unwrap(), "connections: 3");
    }

    #[test]
    fn health_result_round_trip_no_detail() {
        let result = HealthResult {
            status: "ok".to_owned(),
            detail: None,
        };
        let json = serde_json::to_string(&result).unwrap();
        // detail should be omitted when None
        assert!(!json.contains("detail"));
        let parsed: HealthResult = serde_json::from_str(&json).unwrap();
        assert!(parsed.detail.is_none());
    }

    #[test]
    fn method_constants() {
        assert_eq!(METHOD_HANDSHAKE, "skill.handshake");
        assert_eq!(METHOD_HEALTH, "skill.health");
    }

    #[test]
    fn handshake_and_health_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<HandshakeParams>();
        assert_send_sync::<HandshakeResult>();
        assert_send_sync::<HealthResult>();
    }
}
