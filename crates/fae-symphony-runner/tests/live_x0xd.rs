//! Live x0xd integration — `#[ignore]`, env-gated. Mirrors x0x-symphony's own
//! `live_create_claim_heartbeat_handoff_against_x0xd` shape, including
//! self-seeding: the test creates a unique TaskList + KV store and seeds one
//! task, so no out-of-band setup is needed beyond a running x0xd.
//!
//! What this proves (with a live x0xd on `FAE_SYMPHONY_X0XD_URL` and its bearer
//! token in `X0X_API_TOKEN`):
//!   1. the **signer leg** — x0xd `/agent` is reachable and returns our
//!      ML-DSA agent identity (this is exactly the fail-closed check `main`
//!      runs before it will claim any work);
//!   2. the **tracker leg** — an `X0xCrdtTracker` built with `required_signing`
//!      fetches trust-gated candidates from a live TaskList; and
//!   3. the **signed-handoff leg** — claim → heartbeat → `handoff` (ML-DSA
//!      signed via x0xd `/agent/sign`) → the issue leaves the todo pool.
//!
//! The RUNNER leg (driving a real fae-daemon delegation) is intentionally NOT
//! exercised here — that needs a live daemon + a real model and is the manual
//! two-Fae live path documented in the README. The runner leg is covered
//! headlessly (mock daemon socket) in `runner_headless.rs`.
//!
//! Run: `X0X_API_TOKEN=$(cat "$HOME/Library/Application Support/x0x/api-token") \
//!       FAE_SYMPHONY_X0XD_URL=http://127.0.0.1:12700 \
//!       cargo test -p fae-symphony-runner --test live_x0xd -- --ignored --nocapture`

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use x0x_symphony_core::{AgentId, Handoff, IssueState, PollContext, Tracker};
use x0x_symphony_signing::{SigningClient, TrustedKeyResolver, X0xdClient as SigningX0xdClient};
use x0x_symphony_tracker_x0x_crdt::{
    client::{AddTaskDraft, X0xdApi, X0xdClient},
    mapping::store_id_for_list,
    X0xCrdtTracker,
};

#[tokio::test]
#[ignore = "requires a live x0xd; set FAE_SYMPHONY_X0XD_URL + X0X_API_TOKEN"]
async fn live_signer_tracker_and_signed_handoff_against_x0xd() {
    let base_url = std::env::var("FAE_SYMPHONY_X0XD_URL")
        .expect("FAE_SYMPHONY_X0XD_URL is required for the ignored live test");

    // 1. Signer leg (fail-closed check): /agent reachable + returns our id.
    let signing = Arc::new(SigningX0xdClient::new(&base_url).expect("construct signing client"));
    let agent = AgentId::new(
        signing
            .agent_identity()
            .await
            .expect("x0xd /agent must be reachable")
            .agent_id,
    )
    .expect("agent id");
    eprintln!("live x0xd: signer verified, agent_id = {}", agent.as_str());

    // Seed a unique TaskList + KV store + one todo task (self-contained run,
    // same pattern as symphony's own live test).
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock after epoch")
        .as_millis();
    let task_list = format!("fae-symphony-live-{suffix}");
    let store_id = store_id_for_list(&task_list);
    let rest = Arc::new(X0xdClient::new(&base_url).expect("construct x0xd REST client"));
    rest.create_task_list(&task_list, &task_list)
        .await
        .expect("create live task list");
    rest.create_kv_store(&store_id, &store_id)
        .await
        .expect("create live kv store");
    let task_id = rest
        .add_task(
            &task_list,
            AddTaskDraft::new("fae-symphony-runner live leg")
                .with_description("seeded by the F3 live test"),
        )
        .await
        .expect("seed live task");
    eprintln!("live x0xd: seeded task {task_id} on list {task_list}");

    // 2. Tracker leg: required signing wired, live candidate fetch.
    let signing_client: Arc<dyn SigningClient> = signing.clone();
    let resolver: Arc<dyn TrustedKeyResolver> = signing.clone();
    let tracker = X0xCrdtTracker::builder(&base_url, &task_list, agent.clone())
        .required_signing(signing_client, resolver)
        .build()
        .expect("build tracker");

    let ctx = PollContext::new(
        vec![IssueState::new("todo").expect("todo state")],
        vec![IssueState::new("done").expect("done state")],
    );
    let candidates = tracker
        .fetch_candidates(&ctx)
        .await
        .expect("fetch_candidates against live x0xd");
    eprintln!("live x0xd: {} trust-gated candidate(s)", candidates.len());
    let candidate = candidates
        .into_iter()
        .next()
        .expect("the seeded task must be a dispatch candidate");

    // 3. Signed-handoff leg: claim → heartbeat → signed handoff.
    let claim = tracker
        .claim(&candidate.id, &agent)
        .await
        .expect("claim the live candidate");
    tracker
        .heartbeat(&claim)
        .await
        .expect("heartbeat the claim");
    let handoff =
        Handoff::new("fae-symphony-runner live signed-handoff leg").with_file("tracked.txt");
    tracker
        .handoff(&claim, handoff)
        .await
        .expect("publish signed handoff to live x0xd");
    eprintln!(
        "live x0xd: claimed {} + published a signed handoff",
        candidate.id.as_str()
    );

    // The handed-off issue must have left the todo pool.
    let remaining = tracker
        .fetch_candidates(&ctx)
        .await
        .expect("re-fetch candidates");
    assert!(
        remaining.iter().all(|issue| issue.id != candidate.id),
        "a handed-off issue must not remain a todo candidate"
    );
    eprintln!("live x0xd: issue left the todo pool after handoff — all legs green");
}
