//! Live ACP smoke test — drives a real agent ACP server through the native
//! client and asserts a non-empty reply + a clean stop reason.
//!
//! Gated behind `RUN_ACP_SMOKE=1` because it spawns an external agent (network +
//! auth + `npx` download) and must never run in headless CI. Choose the agent
//! with `ACP_SMOKE_AGENT` (default `gemini`).
//!
//! Run it:
//! ```bash
//! RUN_ACP_SMOKE=1 ACP_SMOKE_AGENT=gemini cargo test -p fae-acp --test smoke -- --nocapture
//! ```

use std::time::Duration;

use fae_acp::{run_one_shot, ApprovalPolicy};

#[tokio::test]
async fn agent_round_trip() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var("RUN_ACP_SMOKE").ok().as_deref() != Some("1") {
        eprintln!("skipping: set RUN_ACP_SMOKE=1 to run the live ACP smoke test");
        return Ok(());
    }
    let agent = std::env::var("ACP_SMOKE_AGENT").unwrap_or_else(|_| "gemini".to_owned());
    let cwd = std::env::current_dir()?;

    let outcome = tokio::time::timeout(
        Duration::from_secs(180),
        run_one_shot(
            &agent,
            &cwd,
            "Reply with exactly the single word: pong",
            ApprovalPolicy::ApproveAll,
        ),
    )
    .await??;

    eprintln!(
        "agent={agent} stop_reason={} text={:?} tool_calls={}",
        outcome.stop_reason,
        outcome.text,
        outcome.tool_calls.len()
    );
    assert!(
        !outcome.text.trim().is_empty(),
        "agent returned empty text (stop_reason={})",
        outcome.stop_reason
    );
    assert_eq!(outcome.stop_reason, "end_turn");
    Ok(())
}
