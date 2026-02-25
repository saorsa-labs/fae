#[derive(Debug, Clone, Copy)]
pub struct ToolTimeouts {
    pub applescript_exec_secs: u64,
    pub fetch_url_secs: u64,
    pub web_search_secs: u64,
    pub apple_availability_jit_wait_ms: u64,
    pub apple_availability_poll_ms: u64,
}

static TOOL_TIMEOUTS: ToolTimeouts = ToolTimeouts {
    applescript_exec_secs: 15,
    fetch_url_secs: 15,
    web_search_secs: 15,
    apple_availability_jit_wait_ms: 1200,
    apple_availability_poll_ms: 25,
};

pub fn tool_timeouts() -> &'static ToolTimeouts {
    &TOOL_TIMEOUTS
}
