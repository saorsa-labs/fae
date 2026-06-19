//! Mock ACP agent — a deterministic test fixture (gap A3).
//!
//! Real coding agents (codex, pi) run full-auto and never ask the client for
//! permission, so the daemon's server-initiated request round-trip can't be
//! live-proven against them. This mock ALWAYS, during a prompt:
//!   1. issues `session/request_permission` (→ Fae's approval card, gap A3a), then
//!   2. if approved, issues `fs/write_text_file` (→ PathPolicy/DamageControl,
//!      gap A3b),
//!   3. streams a text chunk and ends the turn.
//!
//! It speaks the ACP **agent** side over stdio. The daemon spawns it via the
//! `mock` agent name when `FAE_ACP_MOCK_AGENT_BIN` points at this binary
//! (production never sets that env, so `mock` is inert there). Keep it as a
//! permanent regression fixture for the A3 security round-trips.

use std::path::PathBuf;

use agent_client_protocol::schema::{
    ContentBlock, ContentChunk, InitializeRequest, InitializeResponse, NewSessionRequest,
    NewSessionResponse, PermissionOption, PermissionOptionKind, PromptRequest, PromptResponse,
    ReadTextFileRequest, RequestPermissionOutcome, RequestPermissionRequest, SessionId,
    SessionNotification, SessionUpdate, StopReason, TextContent, ToolCallUpdate,
    ToolCallUpdateFields, WriteTextFileRequest,
};
use agent_client_protocol::{Agent, Stdio};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), agent_client_protocol::Error> {
    Agent
        .builder()
        .name("fae-mock-agent")
        .on_receive_request(
            async |initialize: InitializeRequest, responder, _cx| {
                responder.respond(InitializeResponse::new(initialize.protocol_version))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async |_new_session: NewSessionRequest, responder, _cx| {
                responder.respond(NewSessionResponse::new(SessionId::new("mock-session")))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async |prompt: PromptRequest, responder, cx| {
                // The turn issues reverse requests (permission, fs) and awaits
                // them, so it MUST run in a spawned task — awaiting a reverse
                // request inside the dispatch loop deadlocks (the loop can't read
                // the reply). See the crate's `concepts::ordering` docs.
                let cx = cx.clone();
                cx.clone().spawn(async move {
                    let session_id = prompt.session_id.clone();

                    // 1. Ask the client for permission (gap A3a server-request).
                    let tool_call = ToolCallUpdate::new(
                        "mock-call-1",
                        ToolCallUpdateFields::new().title(Some("write a3_proof.txt".to_owned())),
                    );
                    let options = vec![
                        PermissionOption::new("allow", "Allow", PermissionOptionKind::AllowOnce),
                        PermissionOption::new("reject", "Reject", PermissionOptionKind::RejectOnce),
                    ];
                    let permission = cx
                        .send_request(RequestPermissionRequest::new(
                            session_id.clone(),
                            tool_call,
                            options,
                        ))
                        .block_task()
                        .await;
                    let approved = matches!(
                        permission.map(|response| response.outcome),
                        Ok(RequestPermissionOutcome::Selected(_))
                    );

                    // 2. If approved, ask the client to write a file (gap A3b fs).
                    // Gated by `FAE_ACP_MOCK_FS` so A3a (permission only) doesn't
                    // wait on an fs request the client can't yet handle.
                    let mut wrote = false;
                    let mut read_back = false;
                    if approved && std::env::var("FAE_ACP_MOCK_FS").is_ok() {
                        // ACP paths are absolute; use the temp dir (PathPolicy
                        // allows it) so a real client mediator can resolve it.
                        let target: PathBuf = std::env::temp_dir().join("a3_proof.txt");
                        wrote = cx
                            .send_request(WriteTextFileRequest::new(
                                session_id.clone(),
                                target.clone(),
                                "pong\n".to_owned(),
                            ))
                            .block_task()
                            .await
                            .is_ok();
                        // 2b. Read it back (gap A3b fs read).
                        if wrote {
                            read_back = matches!(
                                cx.send_request(ReadTextFileRequest::new(
                                    session_id.clone(),
                                    target,
                                ))
                                .block_task()
                                .await,
                                Ok(response) if response.content.contains("pong")
                            );
                        }
                    }

                    // 3. Stream a text chunk reporting what happened, then finish.
                    let text = match (approved, wrote, read_back) {
                        (true, true, true) => "pong (approved, wrote and read back)",
                        (true, true, false) => "pong (approved, wrote file, read failed)",
                        (true, false, _) => "pong (approved, write refused)",
                        (false, _, _) => "declined",
                    };
                    let _ = cx.send_notification(SessionNotification::new(
                        session_id,
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new(text.to_owned()),
                        ))),
                    ));
                    let _ = responder.respond(PromptResponse::new(StopReason::EndTurn));
                    Ok(())
                })?;
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_to(Stdio::new())
        .await
}
