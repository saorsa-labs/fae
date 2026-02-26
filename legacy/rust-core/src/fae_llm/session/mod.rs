//! Session persistence and replay for agent conversations.
//!
//! This module provides session storage, validation, and context management
//! for persisting multi-turn agent conversations across restarts.
//!
//! # Submodules
//!
//! - [`types`] — Core types: [`Session`], [`SessionMeta`], [`SessionResumeError`]
//! - [`store`] — Storage trait and in-memory implementation
//! - [`fs_store`] — Filesystem-backed session store
//! - [`validation`] — Session validation for safe resume
//! - [`context`] — Conversation context with auto-persistence

pub mod context;
pub mod fs_store;
pub mod store;
pub mod types;
pub mod validation;

pub use context::ConversationContext;
pub use fs_store::FsSessionStore;
pub use store::{MemorySessionStore, SessionStore};
pub use types::{CURRENT_SCHEMA_VERSION, Session, SessionId, SessionMeta, SessionResumeError};
pub use validation::{validate_message_sequence, validate_session};

#[cfg(test)]
mod integration_tests {
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use futures_util::stream;

    use super::*;
    use crate::fae_llm::agent::types::AgentConfig;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::error::FaeLlmError;
    use crate::fae_llm::events::{FinishReason, LlmEvent};
    use crate::fae_llm::provider::{LlmEventStream, ProviderAdapter, ToolDefinition};
    use crate::fae_llm::providers::message::{Message, Role};
    use crate::fae_llm::tools::registry::ToolRegistry;
    use crate::fae_llm::tools::types::{Tool, ToolResult};
    use crate::fae_llm::types::{ModelRef, RequestOptions};

    // ── Mock Infrastructure ─────────────────────────────────

    struct MockProvider {
        responses: Mutex<Vec<Vec<LlmEvent>>>,
    }

    impl MockProvider {
        fn new(responses: Vec<Vec<LlmEvent>>) -> Self {
            Self {
                responses: Mutex::new(responses),
            }
        }

        fn text(text: &str) -> Vec<LlmEvent> {
            vec![
                LlmEvent::StreamStart {
                    request_id: "req-1".into(),
                    model: ModelRef::new("mock"),
                },
                LlmEvent::TextDelta { text: text.into() },
                LlmEvent::StreamEnd {
                    finish_reason: FinishReason::Stop,
                },
            ]
        }

        fn tool_call(call_id: &str, fn_name: &str, args: &str) -> Vec<LlmEvent> {
            vec![
                LlmEvent::StreamStart {
                    request_id: "req-1".into(),
                    model: ModelRef::new("mock"),
                },
                LlmEvent::ToolCallStart {
                    call_id: call_id.into(),
                    function_name: fn_name.into(),
                },
                LlmEvent::ToolCallArgsDelta {
                    call_id: call_id.into(),
                    args_fragment: args.into(),
                },
                LlmEvent::ToolCallEnd {
                    call_id: call_id.into(),
                },
                LlmEvent::StreamEnd {
                    finish_reason: FinishReason::ToolCalls,
                },
            ]
        }
    }

    #[async_trait]
    impl ProviderAdapter for MockProvider {
        fn name(&self) -> &str {
            "mock"
        }
        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> Result<LlmEventStream, FaeLlmError> {
            let events = {
                let mut responses = self.responses.lock().unwrap_or_else(|e| e.into_inner());
                if responses.is_empty() {
                    vec![
                        LlmEvent::StreamStart {
                            request_id: "req-empty".into(),
                            model: ModelRef::new("mock"),
                        },
                        LlmEvent::StreamEnd {
                            finish_reason: FinishReason::Stop,
                        },
                    ]
                } else {
                    responses.remove(0)
                }
            };
            Ok(Box::pin(stream::iter(events)))
        }
    }

    struct EchoTool;

    impl Tool for EchoTool {
        fn name(&self) -> &str {
            "echo"
        }
        fn description(&self) -> &str {
            "Echo input"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": { "message": { "type": "string" } }
            })
        }
        fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            let msg = args["message"].as_str().unwrap_or("empty");
            Ok(ToolResult::success(msg.to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    fn mock_registry() -> Arc<ToolRegistry> {
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(EchoTool));
        Arc::new(reg)
    }

    fn empty_registry() -> Arc<ToolRegistry> {
        Arc::new(ToolRegistry::new(ToolMode::Full))
    }

    // ── Integration Test 1: Create → send → persist → resume → send ─────

    #[tokio::test]
    async fn integration_create_send_resume_send() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());

        // Create context and send first message
        let provider1: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("First answer.")]));
        let config = AgentConfig::new().with_system_prompt("Be helpful.");

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config.clone(),
            provider1,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let r1 = ctx.send("Hello").await;
        assert!(r1.is_ok());
        let r1 = match r1 {
            Ok(r) => r,
            Err(_) => unreachable!("send succeeded"),
        };
        assert_eq!(r1.final_text, "First answer.");

        let session_id = ctx.session_id().to_string();
        let msg_count_before = ctx.message_count();

        // Resume with a new provider
        let provider2: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text(
                "Second answer.",
            )]));
        let resumed = ConversationContext::resume(
            &session_id,
            Arc::clone(&store),
            config,
            provider2,
            empty_registry(),
        )
        .await;
        assert!(resumed.is_ok());
        let mut resumed = match resumed {
            Ok(c) => c,
            Err(_) => unreachable!("resume succeeded"),
        };

        // Verify state preserved
        assert_eq!(resumed.session_id(), session_id);
        assert_eq!(resumed.message_count(), msg_count_before);

        // Send follow-up
        let r2 = resumed.send("Follow up").await;
        assert!(r2.is_ok());
        let r2 = match r2 {
            Ok(r) => r,
            Err(_) => unreachable!("send succeeded"),
        };
        assert_eq!(r2.final_text, "Second answer.");

        // Should have more messages now
        assert!(resumed.message_count() > msg_count_before);
        assert_eq!(resumed.session().meta.turn_count, 2);
    }

    // ── Integration Test 2: Filesystem round-trip ────────────────────────

    #[tokio::test]
    async fn integration_fs_round_trip() {
        let dir = tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir succeeded"));
        let store1: Arc<dyn SessionStore> = Arc::new(
            FsSessionStore::new(dir.path()).unwrap_or_else(|_| unreachable!("store succeeded")),
        );

        // Create context and send
        let provider1: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text(
                "Persisted answer.",
            )]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store1),
            config.clone(),
            provider1,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let r1 = ctx.send("Save this").await;
        assert!(r1.is_ok());
        let session_id = ctx.session_id().to_string();

        // Create a NEW store instance on the same directory (simulates restart)
        let store2: Arc<dyn SessionStore> = Arc::new(
            FsSessionStore::new(dir.path()).unwrap_or_else(|_| unreachable!("store succeeded")),
        );

        // Resume from the new store
        let provider2: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text(
                "After restart.",
            )]));
        let resumed =
            ConversationContext::resume(&session_id, store2, config, provider2, empty_registry())
                .await;
        assert!(resumed.is_ok());
        let resumed = match resumed {
            Ok(c) => c,
            Err(_) => unreachable!("resume succeeded"),
        };

        // Messages should be intact from disk
        assert!(resumed.message_count() >= 2);
        assert_eq!(resumed.session_id(), session_id);
    }

    // ── Integration Test 3: Corrupted session recovery ───────────────────

    #[tokio::test]
    async fn integration_corrupted_session_recovery() {
        let dir = tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir succeeded"));
        let store: Arc<dyn SessionStore> = Arc::new(
            FsSessionStore::new(dir.path()).unwrap_or_else(|_| unreachable!("store succeeded")),
        );

        // Create a session file with corrupted content
        let bad_path = dir.path().join("bad_session.json");
        std::fs::write(&bad_path, "{{{{not valid json}}}}")
            .unwrap_or_else(|_| unreachable!("write succeeded"));

        let provider: Arc<dyn ProviderAdapter> = Arc::new(MockProvider::new(vec![]));
        let config = AgentConfig::new();

        let result =
            ConversationContext::resume("bad_session", store, config, provider, empty_registry())
                .await;

        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("resume should fail"),
        };
        assert_eq!(err.code(), "SESSION_ERROR");
    }

    // ── Integration Test 4: Multiple concurrent sessions ─────────────────

    #[tokio::test]
    async fn integration_multiple_concurrent_sessions() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let config = AgentConfig::new();

        // Create 3 sessions
        let mut contexts = Vec::new();
        for i in 0..3 {
            let provider: Arc<dyn ProviderAdapter> =
                Arc::new(MockProvider::new(vec![MockProvider::text(&format!(
                    "Answer {i}"
                ))]));
            let ctx = ConversationContext::new(
                Arc::clone(&store),
                config.clone(),
                provider,
                empty_registry(),
            )
            .await;
            assert!(ctx.is_ok());
            contexts.push(match ctx {
                Ok(c) => c,
                Err(_) => unreachable!("context creation succeeded"),
            });
        }

        // Send to each
        for (i, ctx) in contexts.iter_mut().enumerate() {
            let r = ctx.send(&format!("Question {i}")).await;
            assert!(r.is_ok());
        }

        // List sessions — should be 3
        let metas = store.list().await;
        assert!(metas.is_ok());
        let metas = match metas {
            Ok(m) => m,
            Err(_) => unreachable!("list succeeded"),
        };
        assert_eq!(metas.len(), 3);

        // Delete one
        let id_to_delete = contexts[0].session_id().to_string();
        let del = store.delete(&id_to_delete).await;
        assert!(del.is_ok());

        // Should be 2 now
        let metas = store.list().await;
        assert!(metas.is_ok());
        let metas = match metas {
            Ok(m) => m,
            Err(_) => unreachable!("list succeeded"),
        };
        assert_eq!(metas.len(), 2);
    }

    // ── Integration Test 5: Session with tool calls ──────────────────────

    #[tokio::test]
    async fn integration_session_with_tool_calls() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());

        // Provider returns a tool call then a text response
        let provider: Arc<dyn ProviderAdapter> = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "echo", r#"{"message":"world"}"#),
            MockProvider::text("Echo: world"),
        ]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config.clone(),
            provider,
            mock_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let result = ctx.send("Echo something").await;
        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("send succeeded"),
        };
        assert_eq!(result.final_text, "Echo: world");
        assert_eq!(result.turns.len(), 2);

        let session_id = ctx.session_id().to_string();

        // Resume and verify tool call messages are preserved
        let provider2: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text(
                "Continued after tool call.",
            )]));
        let resumed = ConversationContext::resume(
            &session_id,
            Arc::clone(&store),
            config,
            provider2,
            mock_registry(),
        )
        .await;
        assert!(resumed.is_ok());
        let mut resumed = match resumed {
            Ok(c) => c,
            Err(_) => unreachable!("resume succeeded"),
        };

        // Should have: user + assistant(tool) + tool_result + assistant(text) = 4+
        assert!(resumed.message_count() >= 4);

        // Verify tool call messages are present
        let has_tool_msg = resumed
            .session()
            .messages
            .iter()
            .any(|m| m.role == Role::Tool);
        assert!(has_tool_msg);

        // Send follow-up to verify conversation continues
        let r2 = resumed.send("Continue").await;
        assert!(r2.is_ok());
    }

    // ── Integration Test 6: All session types accessible from fae_llm ────

    #[test]
    fn integration_session_types_accessible() {
        // Verify types are re-exported and usable
        fn _uses_session(_s: Session) {}
        fn _uses_meta(_m: SessionMeta) {}
        fn _uses_id(_id: SessionId) {}
        fn _uses_resume_err(_e: SessionResumeError) {}
        fn _uses_context(_c: ConversationContext) {}
        fn _uses_fs_store(_s: FsSessionStore) {}
        fn _uses_mem_store(_s: MemorySessionStore) {}
    }

    #[test]
    fn integration_all_session_types_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Session>();
        assert_send_sync::<SessionMeta>();
        assert_send_sync::<SessionResumeError>();
        assert_send_sync::<FsSessionStore>();
        assert_send_sync::<MemorySessionStore>();
        // ConversationContext contains Arc<dyn ProviderAdapter> which is Send+Sync
        assert_send_sync::<ConversationContext>();
    }
}
