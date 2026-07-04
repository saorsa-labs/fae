//! Phase G3 integration: a REAL stdio spawn -> initialize -> tools/list ->
//! tools/call round trip against the in-repo `mock_mcp_server` binary, driven by
//! the vendored `ProcessMcpConnection` (the exact transport `McpCatalog::spawn`
//! uses). This proves the mock speaks the protocol and the stdio primitives the
//! catalog relies on actually round-trip; the catalog's allowlist/namespace/gate
//! logic is covered by the unit tests in `mcp` + `toolhost`.

use mistralrs_mcp::client::ProcessMcpConnection;
use mistralrs_mcp::McpServerConnection;

#[tokio::test]
async fn mock_mcp_server_stdio_round_trip() {
    // Cargo sets this to the built path of the `mock_mcp_server` bin target.
    let bin = env!("CARGO_BIN_EXE_mock_mcp_server");

    let conn = ProcessMcpConnection::new(
        "fs".to_string(),
        "fs".to_string(),
        bin.to_string(),
        Vec::new(),
        None,
        None,
    )
    .await
    .expect("spawn + initialize the mock MCP server");

    let tools = conn.list_tools().await.expect("tools/list");
    let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    assert!(
        names.contains(&"echo"),
        "tools/list must include echo: {names:?}"
    );
    assert!(
        names.contains(&"secret"),
        "tools/list must include secret (allowlist filtering is the catalog's job): {names:?}"
    );

    let out = conn
        .call_tool("echo", serde_json::json!({"msg": "hi"}))
        .await
        .expect("tools/call");
    assert!(out.starts_with("echo:"), "call result: {out}");
    assert!(
        out.contains("hi"),
        "call result must echo the argument: {out}"
    );

    conn.close().await.expect("close");
}
