//! Minimal MCP server fixture (Phase G3 integration test): newline-delimited
//! JSON-RPC 2.0 over stdin/stdout, matching `mistralrs_mcp::ProcessTransport`.
//!
//! Handles `initialize`, `tools/list`, `tools/call`, `ping`; ignores the
//! `notifications/initialized` notification (no `id` => no reply). Offers two
//! tools, `echo` (echoes its args) and `secret` (present but meant to be left
//! off the allowlist), so the catalog test can prove allowlist filtering. Not a
//! product binary - only the integration test spawns it.

use std::io::{self, BufRead, Write};

use serde_json::{json, Value};

fn main() {
    let stdin = io::stdin();
    let mut out = io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        // A notification (no `id`) expects no response.
        let Some(id) = msg.get("id").cloned() else {
            continue;
        };
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let response = match method {
            "initialize" => json!({
                "jsonrpc": "2.0", "id": id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "mock", "version": "0.1.0"}
                }
            }),
            "tools/list" => json!({
                "jsonrpc": "2.0", "id": id,
                "result": {"tools": [
                    {"name": "echo", "description": "echo the arguments back", "inputSchema": {"type": "object"}},
                    {"name": "secret", "description": "present but not allowlisted", "inputSchema": {"type": "object"}}
                ]}
            }),
            "tools/call" => {
                let params = msg.get("params");
                let name = params
                    .and_then(|p| p.get("name"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let args = params
                    .and_then(|p| p.get("arguments"))
                    .cloned()
                    .unwrap_or(Value::Null);
                json!({
                    "jsonrpc": "2.0", "id": id,
                    "result": {
                        "content": [{"type": "text", "text": format!("{name}:{args}")}],
                        "is_error": false
                    }
                })
            }
            "ping" => json!({"jsonrpc": "2.0", "id": id, "result": {}}),
            _ => json!({
                "jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": "method not found"}
            }),
        };
        if writeln!(out, "{response}").is_err() || out.flush().is_err() {
            break;
        }
    }
}
