//! Permanent regression fixture for the gap-A3 server-request round-trips.
//!
//! Real coding agents run full-auto and never ask the client for permission or
//! delegate fs, so those paths can't be covered against them. These tests drive
//! the in-repo `mock_acp_agent` binary (which always asks, and writes a file when
//! `FAE_ACP_MOCK_FS=1`) through a real [`AcpSession`], answering each request via
//! the per-turn request channel exactly as the daemon does — proving the
//! agent → client → decision → agent loop end to end for both permission (A3a)
//! and fs mediation (A3b).

use std::path::Path;

use fae_acp::{AcpPermissionDecision, AcpServerRequest, AcpSession, ApprovalPolicy};

/// Point `resolve_agent("mock")` at the freshly built mock binary.
fn use_mock_agent() {
    std::env::set_var(
        "FAE_ACP_MOCK_AGENT_BIN",
        env!("CARGO_BIN_EXE_mock_acp_agent"),
    );
}

#[tokio::test]
async fn mock_agent_permission_approved() {
    use_mock_agent();
    let session = AcpSession::start("mock", Path::new("/tmp"), ApprovalPolicy::DenyAll)
        .await
        .expect("mock session starts");
    let mut handle = session.prompt("go".to_owned()).expect("prompt accepted");

    // The mock issues exactly one permission request; approve "allow".
    match handle.requests.recv().await.expect("permission request") {
        AcpServerRequest::Permission { options, reply, .. } => {
            assert!(
                options.iter().any(|opt| opt.id == "allow"),
                "mock offered an allow option"
            );
            reply
                .send(AcpPermissionDecision::Selected("allow".to_owned()))
                .ok();
        }
        _ => panic!("expected a permission request, got an fs request"),
    }

    let outcome = handle.reply.await.expect("turn resolves").expect("turn ok");
    assert!(
        outcome.text.contains("approved"),
        "expected an approved turn, got: {}",
        outcome.text
    );
    assert_eq!(outcome.stop_reason, "end_turn");
    session.close();
}

#[tokio::test]
async fn mock_agent_permission_declined() {
    use_mock_agent();
    let session = AcpSession::start("mock", Path::new("/tmp"), ApprovalPolicy::DenyAll)
        .await
        .expect("mock session starts");
    let mut handle = session.prompt("go".to_owned()).expect("prompt accepted");

    match handle.requests.recv().await.expect("permission request") {
        AcpServerRequest::Permission { reply, .. } => {
            reply.send(AcpPermissionDecision::Cancelled).ok();
        }
        _ => panic!("expected a permission request, got an fs request"),
    }

    let outcome = handle.reply.await.expect("turn resolves").expect("turn ok");
    assert!(
        outcome.text.contains("declined"),
        "expected a declined turn, got: {}",
        outcome.text
    );
    session.close();
}

#[tokio::test]
async fn mock_agent_fs_write_mediated() {
    use_mock_agent();
    // With FS enabled, an approved turn also issues `fs/write_text_file`, which
    // the client mediates (gap A3b). Here the test plays the mediator: approve
    // the permission, then accept the write.
    std::env::set_var("FAE_ACP_MOCK_FS", "1");
    let session = AcpSession::start("mock", Path::new("/tmp"), ApprovalPolicy::DenyAll)
        .await
        .expect("mock session starts");
    let mut handle = session.prompt("go".to_owned()).expect("prompt accepted");

    let mut mediated_write = false;
    while let Some(request) = handle.requests.recv().await {
        match request {
            AcpServerRequest::Permission { reply, .. } => {
                reply
                    .send(AcpPermissionDecision::Selected("allow".to_owned()))
                    .ok();
            }
            AcpServerRequest::WriteFile {
                path,
                content,
                reply,
            } => {
                assert!(path.ends_with("a3_proof.txt"), "write path: {path}");
                assert!(content.contains("pong"), "write content: {content}");
                mediated_write = true;
                reply.send(Ok(())).ok();
                break; // the write is the agent's last request this turn
            }
            AcpServerRequest::ReadFile { reply, .. } => {
                reply.send(Err("no reads expected".to_owned())).ok();
            }
        }
    }
    std::env::remove_var("FAE_ACP_MOCK_FS");

    let outcome = handle.reply.await.expect("turn resolves").expect("turn ok");
    assert!(mediated_write, "the fs write was mediated by the client");
    assert!(
        outcome.text.contains("wrote file"),
        "expected the agent to report a successful write, got: {}",
        outcome.text
    );
    session.close();
}
