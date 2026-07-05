//! External MCP (Model Context Protocol) servers as a governed tool tier (Phase G3).
//!
//! An MCP server is a separate, owner-declared subprocess that exposes tools over
//! stdio JSON-RPC. Fae adopts them as a THIRD tool source alongside the host and
//! jailed fluers registries, but with an honest and deliberately narrow trust
//! model: **the OS jail does NOT confine an MCP server**. The server is an
//! external trusted subprocess with the daemon's ambient authority; nothing here
//! sandboxes what it can read or write on the machine. The entire gate is
//! therefore *declaration + allowlist + scope + origin*:
//!
//! * **Declaration** - only servers named in `FAE_MCP_CONFIG` are spawned. No
//!   config (or no env) => MCP is silently absent (`catalog.is_empty()`), and
//!   every `mcp:` invocation denies `mcp_not_configured`.
//! * **Allowlist** - only tools listed in a server's `allowed_tools` enter the
//!   catalog. A tool the server offers but the owner did not allowlist is never
//!   registered, so an invoke of it denies `mcp_tool_not_declared`.
//! * **Scope** - the ToolHost re-checks `Scope::McpInvoke` per call (the inner
//!   gate behind the `toolhost.execute -> ToolExecuteSafe` envelope).
//! * **Origin** - only `OwnerInteractive` and `Delegated` origins may invoke; a
//!   proactive/scheduler/auto-skill/script-block origin denies fail-closed (an
//!   autonomous loop must not reach an unconfined external process).
//!
//! Wire client: the vendored `mistralrs-mcp` crate (already in the build graph
//! via `mistralrs-core`), consumed at its low level - a `ProcessMcpConnection`
//! (stdio transport) per server plus its `list_tools()` / `call_tool()`
//! primitives. Its automatic tool-call loop is NOT used; dispatch stays inside
//! the governed `ToolHost::execute_governed`.
//!
//! v1 has no reconnect loop: if a server fails to spawn or its `tools/list`
//! fails, its tools simply do not enter the catalog and a health note records
//! why (surfaced by the `mcp.list` command). A server that dies AFTER startup
//! makes its `invoke` return a typed [`McpError::Invoke`]; the catalog is not
//! re-listed until the daemon restarts.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use mistralrs_mcp::client::ProcessMcpConnection;
use mistralrs_mcp::McpServerConnection;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;

/// The namespace prefix marking a tool name as an MCP tool: `mcp:<server>:<tool>`.
/// The ToolHost routes any tool name starting with this to the MCP gate.
pub const MCP_TOOL_PREFIX: &str = "mcp:";

/// Env var naming the TOML declaration file. Absent => MCP is silently disabled.
pub const MCP_CONFIG_ENV: &str = "FAE_MCP_CONFIG";

/// The control-plane command the ToolHost authorizes per `mcp:` invocation
/// (the inner `Scope::McpInvoke` gate). Not a wire command.
pub const MCP_INVOKE_COMMAND: &str = "mcp.invoke";

/// The honest isolation label stamped on MCP audit rows: the call ran in an
/// EXTERNAL trusted subprocess, NOT the OS jail (`host`/`jailed`).
pub const MCP_ISOLATION_LABEL: &str = "external";

/// Per-call timeout for an MCP tool invocation. External servers can hang; a
/// bounded wait keeps one wedged tool from stalling the turn indefinitely.
const DEFAULT_CALL_TIMEOUT_SECS: u64 = 30;

/// A typed MCP failure. Every non-`Ok` path is fail-closed at the call site.
#[derive(Debug, thiserror::Error)]
pub enum McpError {
    /// `FAE_MCP_CONFIG` named a file that could not be read.
    #[error("mcp config read failed: {0}")]
    ConfigRead(String),
    /// The config file was not valid TOML for the declared schema.
    #[error("mcp config parse failed: {0}")]
    ConfigParse(String),
    /// The invoked `mcp:<server>:<tool>` name is not in the catalog (undeclared
    /// server or non-allowlisted tool).
    #[error("mcp tool not declared: {0}")]
    NotDeclared(String),
    /// The server did not respond within the per-call timeout.
    #[error("mcp invocation timed out after {0}ms")]
    Timeout(u64),
    /// The server returned an error or the transport failed mid-call.
    #[error("mcp server error: {0}")]
    Invoke(String),
}

/// The owner's MCP declaration file (`FAE_MCP_CONFIG`, TOML):
///
/// ```toml
/// [servers.filesystem]
/// command = "mcp-server-filesystem"
/// args = ["--root", "/tmp/shared"]
/// allowed_tools = ["read_file", "list_directory"]
/// ```
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpConfig {
    /// Declared servers, keyed by the short name used in `mcp:<name>:<tool>`.
    #[serde(default)]
    pub servers: BTreeMap<String, McpServerDecl>,
}

/// One declared MCP server. Only allowlisted tools are ever registered.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpServerDecl {
    /// The executable to spawn (stdio JSON-RPC MCP server).
    pub command: String,
    /// Arguments passed to the command.
    #[serde(default)]
    pub args: Vec<String>,
    /// The subset of the server's tools the owner permits. A tool absent from
    /// this list is never registered (fail-closed by omission).
    #[serde(default)]
    pub allowed_tools: Vec<String>,
}

impl McpConfig {
    /// Load the declaration file named by `FAE_MCP_CONFIG`.
    ///
    /// Returns `None` when the env var is unset or empty (MCP silently absent);
    /// `Some(Err(..))` when the file is present but unreadable/malformed (loud
    /// fail so a typo does not silently disable a declared server).
    #[must_use]
    pub fn from_env() -> Option<Result<Self, McpError>> {
        let path = std::env::var_os(MCP_CONFIG_ENV).filter(|p| !p.is_empty())?;
        Some(Self::from_path(std::path::Path::new(&path)))
    }

    /// Parse a declaration file at `path`.
    ///
    /// # Errors
    /// [`McpError::ConfigRead`] if the file cannot be read; [`McpError::ConfigParse`]
    /// if it is not valid TOML for the schema.
    pub fn from_path(path: &std::path::Path) -> Result<Self, McpError> {
        let text =
            std::fs::read_to_string(path).map_err(|e| McpError::ConfigRead(e.to_string()))?;
        Self::from_toml(&text)
    }

    /// Parse a declaration from a TOML string.
    ///
    /// # Errors
    /// [`McpError::ConfigParse`] if the string is not valid TOML for the schema.
    pub fn from_toml(text: &str) -> Result<Self, McpError> {
        toml::from_str(text).map_err(|e| McpError::ConfigParse(e.to_string()))
    }
}

/// One registered, allowlisted MCP tool bound to its server connection.
#[derive(Clone)]
pub struct McpTool {
    /// The declared server name (the `<server>` in `mcp:<server>:<tool>`).
    pub server: String,
    /// The raw tool name as the server reports it (the `<tool>`).
    pub tool: String,
    /// The tool's human description, if the server provided one.
    pub description: Option<String>,
    /// The tool's raw JSON Schema for inputs. Stored verbatim (NOT forced
    /// through fluers' typed `ParameterSchema`, which cannot round-trip every
    /// MCP schema) so an LLM-facing spec builder can emit it directly.
    pub input_schema: Value,
    /// The live connection used to invoke the tool.
    conn: Arc<dyn McpServerConnection>,
}

/// Per-server health as observed at catalog build time (surfaced by `mcp.list`).
#[derive(Debug, Clone, Serialize)]
pub struct McpServerHealth {
    /// The declared server name.
    pub server: String,
    /// `true` if the server spawned and its tools listed successfully.
    pub healthy: bool,
    /// How many allowlisted tools entered the catalog from this server.
    pub tool_count: usize,
    /// Why the server is unhealthy (spawn/list failure), if applicable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// The live catalog of external MCP tools, namespaced `mcp:<server>:<tool>`.
///
/// Built once at daemon startup ([`spawn`](McpCatalog::spawn)) and shared across
/// connections. The ToolHost holds an `Arc<McpCatalog>` and routes `mcp:`-prefixed
/// calls through [`invoke`](McpCatalog::invoke) after its own scope/origin gate.
pub struct McpCatalog {
    tools: HashMap<String, McpTool>,
    health: Vec<McpServerHealth>,
    call_timeout: Duration,
}

impl McpCatalog {
    /// Spawn every declared server (stdio), list + allowlist-filter its tools,
    /// and build the namespaced catalog. A server that fails to spawn or list is
    /// dropped with a health note (no reconnect loop in v1). Never errors: an
    /// unreachable server degrades the catalog, it does not fail startup.
    #[must_use]
    pub async fn spawn(config: &McpConfig) -> Self {
        let mut connected: Vec<(String, Arc<dyn McpServerConnection>, Vec<String>)> = Vec::new();
        let mut spawn_failures: Vec<McpServerHealth> = Vec::new();
        for (name, decl) in &config.servers {
            match ProcessMcpConnection::new(
                name.clone(),
                name.clone(),
                decl.command.clone(),
                decl.args.clone(),
                None,
                // C1: MCP servers are un-jailed and network-open. Hand the child a
                // scrubbed env (vetted allowlist) instead of `None` (inherit-all),
                // so the daemon's provider secrets never reach a declared server.
                // The transport treats a `Some(env)` as the child's COMPLETE env
                // (it `env_clear()`s first), so this map is authoritative.
                Some(crate::child_env::scrubbed_child_env()),
            )
            .await
            {
                Ok(conn) => connected.push((
                    name.clone(),
                    Arc::new(conn) as Arc<dyn McpServerConnection>,
                    decl.allowed_tools.clone(),
                )),
                Err(e) => {
                    tracing::warn!(server = %name, error = %e, "mcp server spawn failed");
                    spawn_failures.push(McpServerHealth {
                        server: name.clone(),
                        healthy: false,
                        tool_count: 0,
                        note: Some(format!("spawn failed: {e}")),
                    });
                }
            }
        }
        Self::build(connected, spawn_failures).await
    }

    /// Build a catalog from already-connected servers (the shared core of
    /// [`spawn`](McpCatalog::spawn); tests inject mock connections here). Each
    /// connection's `list_tools` is filtered to its allowlist; a list failure
    /// drops the server with a health note.
    async fn build(
        servers: Vec<(String, Arc<dyn McpServerConnection>, Vec<String>)>,
        mut health: Vec<McpServerHealth>,
    ) -> Self {
        let mut tools: HashMap<String, McpTool> = HashMap::new();
        for (name, conn, allowed) in servers {
            match conn.list_tools().await {
                Ok(list) => {
                    let allow: HashSet<&str> = allowed.iter().map(String::as_str).collect();
                    let mut count = 0usize;
                    for info in list {
                        if !allow.contains(info.name.as_str()) {
                            continue;
                        }
                        let key = format!("{MCP_TOOL_PREFIX}{name}:{}", info.name);
                        tools.insert(
                            key,
                            McpTool {
                                server: name.clone(),
                                tool: info.name,
                                description: info.description,
                                input_schema: info.input_schema,
                                conn: Arc::clone(&conn),
                            },
                        );
                        count += 1;
                    }
                    health.push(McpServerHealth {
                        server: name,
                        healthy: true,
                        tool_count: count,
                        note: None,
                    });
                }
                Err(e) => {
                    tracing::warn!(server = %name, error = %e, "mcp tools/list failed");
                    health.push(McpServerHealth {
                        server: name,
                        healthy: false,
                        tool_count: 0,
                        note: Some(format!("tools/list failed: {e}")),
                    });
                }
            }
        }
        Self {
            tools,
            health,
            call_timeout: Duration::from_secs(DEFAULT_CALL_TIMEOUT_SECS),
        }
    }

    /// No registered tools (the catalog is inert — MCP absent or every server
    /// unhealthy). A live catalog with `is_empty()` still surfaces health.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.tools.is_empty()
    }

    /// Look up a registered tool by its namespaced name (`mcp:<server>:<tool>`).
    #[must_use]
    pub fn get(&self, name: &str) -> Option<&McpTool> {
        self.tools.get(name)
    }

    /// Per-server health notes (for `mcp.list`).
    #[must_use]
    pub fn health(&self) -> &[McpServerHealth] {
        &self.health
    }

    /// The `mcp.list` payload: the namespaced tool catalog + per-server health.
    /// Swift surfaces this later; the raw input schema is emitted verbatim.
    #[must_use]
    pub fn list(&self) -> Value {
        let mut tools: Vec<Value> = self
            .tools
            .iter()
            .map(|(name, t)| {
                serde_json::json!({
                    "name": name,
                    "server": t.server,
                    "description": t.description,
                    "input_schema": t.input_schema,
                })
            })
            .collect();
        // Deterministic order (HashMap iteration is not stable).
        tools.sort_by(|a, b| {
            a.get("name")
                .and_then(Value::as_str)
                .cmp(&b.get("name").and_then(Value::as_str))
        });
        serde_json::json!({
            "tools": tools,
            "servers": self.health,
        })
    }

    /// Invoke a registered tool with `args`, bounded by the per-call timeout.
    ///
    /// # Errors
    /// [`McpError::NotDeclared`] if the name is not registered; [`McpError::Timeout`]
    /// if the server does not answer in time; [`McpError::Invoke`] if the server
    /// returns an error or the transport fails (e.g. the server has since died).
    pub async fn invoke(&self, name: &str, args: Value) -> Result<String, McpError> {
        let tool = self
            .get(name)
            .ok_or_else(|| McpError::NotDeclared(name.to_string()))?;
        match tokio::time::timeout(self.call_timeout, tool.conn.call_tool(&tool.tool, args)).await {
            Ok(Ok(text)) => Ok(text),
            Ok(Err(e)) => Err(McpError::Invoke(e.to_string())),
            Err(_) => Err(McpError::Timeout(self.call_timeout.as_millis() as u64)),
        }
    }
}

// Test scaffolding at module scope (not inside `mod tests`) so the toolhost
// gate tests can reuse the mock connection + catalog builder.
#[cfg(test)]
pub(crate) use test_support::{catalog_from_mock, MockConn};

#[cfg(test)]
mod test_support {
    use super::*;
    use anyhow::Result as AnyResult;
    use async_trait::async_trait;
    use mistralrs_mcp::rust_mcp_schema::Resource;
    use mistralrs_mcp::McpToolInfo;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A mock MCP connection: canned tool list + call result, records call count
    /// (to assert the gate denies BEFORE the connection is touched). Set `fail`
    /// to exercise the server-error path.
    pub(crate) struct MockConn {
        pub id: String,
        pub tools: Vec<(&'static str, &'static str)>, // (name, description)
        pub result: String,
        pub calls: AtomicUsize,
        pub fail: bool,
    }

    impl MockConn {
        pub fn new(id: &str, tools: Vec<(&'static str, &'static str)>, result: &str) -> Arc<Self> {
            Arc::new(Self {
                id: id.to_string(),
                tools,
                result: result.to_string(),
                calls: AtomicUsize::new(0),
                fail: false,
            })
        }

        pub fn failing(id: &str, tools: Vec<(&'static str, &'static str)>) -> Arc<Self> {
            Arc::new(Self {
                id: id.to_string(),
                tools,
                result: String::new(),
                calls: AtomicUsize::new(0),
                fail: true,
            })
        }

        pub fn call_count(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    #[async_trait]
    impl McpServerConnection for MockConn {
        fn server_id(&self) -> &str {
            &self.id
        }
        fn server_name(&self) -> &str {
            &self.id
        }
        async fn list_tools(&self) -> AnyResult<Vec<McpToolInfo>> {
            Ok(self
                .tools
                .iter()
                .map(|(n, d)| McpToolInfo {
                    name: (*n).to_string(),
                    description: Some((*d).to_string()),
                    input_schema: serde_json::json!({"type": "object"}),
                    server_id: self.id.clone(),
                    server_name: self.id.clone(),
                })
                .collect())
        }
        async fn call_tool(&self, _name: &str, _arguments: Value) -> AnyResult<String> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.fail {
                return Err(anyhow::anyhow!("mock server exploded"));
            }
            Ok(self.result.clone())
        }
        async fn list_resources(&self) -> AnyResult<Vec<Resource>> {
            Ok(Vec::new())
        }
        async fn read_resource(&self, _uri: &str) -> AnyResult<String> {
            Ok(String::new())
        }
        async fn ping(&self) -> AnyResult<()> {
            Ok(())
        }
        async fn close(&self) -> AnyResult<()> {
            Ok(())
        }
    }

    /// Build a catalog from a single mock server (reused by the toolhost gate tests).
    pub(crate) async fn catalog_from_mock(
        server: &str,
        conn: Arc<MockConn>,
        allowed: &[&str],
    ) -> McpCatalog {
        let allowed = allowed.iter().map(|s| (*s).to_string()).collect();
        McpCatalog::build(
            vec![(
                server.to_string(),
                conn as Arc<dyn McpServerConnection>,
                allowed,
            )],
            Vec::new(),
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_parses_declared_servers() {
        let cfg = McpConfig::from_toml(
            r#"
            [servers.fs]
            command = "mcp-fs"
            args = ["--root", "/tmp"]
            allowed_tools = ["read_file", "list_dir"]
            "#,
        )
        .expect("valid config");
        let fs = cfg.servers.get("fs").expect("fs server");
        assert_eq!(fs.command, "mcp-fs");
        assert_eq!(fs.args, vec!["--root", "/tmp"]);
        assert_eq!(fs.allowed_tools, vec!["read_file", "list_dir"]);
    }

    #[test]
    fn config_rejects_unknown_fields() {
        // deny_unknown_fields is the fail-closed guard against typo'd keys.
        let err = McpConfig::from_toml("[servers.fs]\ncommand=\"x\"\nbogus=1\n").unwrap_err();
        assert!(matches!(err, McpError::ConfigParse(_)), "{err:?}");
    }

    #[test]
    fn empty_config_is_valid_and_inert() {
        let cfg = McpConfig::from_toml("").expect("empty ok");
        assert!(cfg.servers.is_empty());
    }

    #[tokio::test]
    async fn catalog_registers_only_allowlisted_tools() {
        // The server offers read_file + delete_all; only read_file is allowlisted.
        let conn = MockConn::new(
            "fs",
            vec![("read_file", "read"), ("delete_all", "danger")],
            "file contents",
        );
        let cat = catalog_from_mock("fs", conn, &["read_file"]).await;
        assert!(cat.get("mcp:fs:read_file").is_some());
        assert!(
            cat.get("mcp:fs:delete_all").is_none(),
            "a non-allowlisted tool must never enter the catalog"
        );
        assert_eq!(cat.health()[0].tool_count, 1);
        assert!(cat.health()[0].healthy);
    }

    #[tokio::test]
    async fn invoke_round_trip_returns_server_text() {
        let conn = MockConn::new("fs", vec![("read_file", "read")], "hello from mcp");
        let cat = catalog_from_mock("fs", Arc::clone(&conn), &["read_file"]).await;
        let out = cat
            .invoke("mcp:fs:read_file", serde_json::json!({"path": "a.txt"}))
            .await
            .expect("invoke ok");
        assert_eq!(out, "hello from mcp");
        assert_eq!(conn.call_count(), 1);
    }

    #[tokio::test]
    async fn invoke_undeclared_denies_without_calling() {
        let conn = MockConn::new("fs", vec![("read_file", "read")], "x");
        let cat = catalog_from_mock("fs", Arc::clone(&conn), &["read_file"]).await;
        // Undeclared tool name (not allowlisted / wrong server).
        let err = cat
            .invoke("mcp:fs:delete_all", serde_json::json!({}))
            .await
            .expect_err("undeclared must deny");
        assert!(matches!(err, McpError::NotDeclared(_)), "{err:?}");
        assert_eq!(
            conn.call_count(),
            0,
            "an undeclared invoke must never reach the server"
        );
    }

    #[tokio::test]
    async fn server_error_maps_to_typed_invoke_error() {
        let conn = MockConn::failing("fs", vec![("read_file", "read")]);
        let cat = catalog_from_mock("fs", conn, &["read_file"]).await;
        let err = cat
            .invoke("mcp:fs:read_file", serde_json::json!({}))
            .await
            .expect_err("server error must surface");
        assert!(matches!(err, McpError::Invoke(_)), "{err:?}");
    }
}
