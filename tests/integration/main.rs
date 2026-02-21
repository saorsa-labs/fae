//! Integration test binary -- all integration tests consolidated into a single
//! binary to reduce link-time RAM usage (29 binaries -> 1).
//!
//! See the matklad pattern: <https://matklad.github.io/2021/02/27/delete-cargo-integration-tests.html>

// Allow unwrap/expect in test code
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod helpers;

mod apple_tool_registration;
mod canvas_integration;
mod capability_bridge_e2e;
mod e2e_host_bridge;
#[cfg(feature = "chatterbox")]
mod e2e_voice_chatterbox;
mod error_recovery;
mod fae_llm_spec_lock;
mod ffi_abi;
mod host_command_channel_v0;
mod host_contract_v0;
mod jit_permission_flow;
mod llm_config_integration;
mod llm_final_smoke;
mod llm_toml_roundtrip;
mod memory_integration;
mod native_latency_harness_v0;
mod onboarding_lifecycle;
mod permission_config_roundtrip;
mod permission_skill_gate;
mod personalization_integration;
mod phase_1_3_wired_commands;
mod python_skill_credentials;
mod python_skill_discovery;
mod python_skill_lifecycle;
mod python_skill_runner_e2e;
mod scheduler_authority_v0;
mod scheduler_ui_integration;
mod tool_judgment_eval;
mod uv_bootstrap_e2e;
