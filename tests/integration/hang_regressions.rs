use std::path::Path;

fn read_file(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

#[test]
fn runner_uses_recv_timeout_and_no_block_in_place() {
    let content = read_file("src/scheduler/runner.rs");
    assert!(content.contains("recv_timeout"));
    assert!(!content.contains("block_in_place("));
}

#[test]
fn executor_bridge_has_response_wait_timeout_telemetry() {
    let content = read_file("src/scheduler/executor_bridge.rs");
    assert!(
        content.contains("timeout")
            || content.contains("op=scheduler.executor_bridge.response_wait")
    );
    assert!(content.contains("op=scheduler.executor_bridge.response_wait"));
}

#[test]
fn applescript_avoids_wait_with_output_and_has_timeout_telemetry() {
    let content = read_file("src/fae_llm/tools/apple/applescript.rs");
    assert!(!content.contains("wait_with_output"));
    assert!(content.contains("timeout|op=apple.applescript.execute"));
}

#[test]
fn fetch_url_and_web_search_use_try_current() {
    let fetch = read_file("src/fae_llm/tools/fetch_url.rs");
    let web = read_file("src/fae_llm/tools/web_search.rs");
    assert!(fetch.contains("Handle::try_current"));
    assert!(web.contains("Handle::try_current"));
}

#[test]
fn tool_timeouts_exists_with_expected_fields() {
    let path = Path::new("src/fae_llm/tools/tool_timeouts.rs");
    assert!(path.exists());
    let content = read_file("src/fae_llm/tools/tool_timeouts.rs");
    assert!(content.contains("applescript_exec_secs"));
    assert!(content.contains("fetch_url_secs"));
    assert!(content.contains("web_search_secs"));
    assert!(content.contains("apple_availability_jit_wait_ms"));
    assert!(content.contains("apple_availability_poll_ms"));
}
