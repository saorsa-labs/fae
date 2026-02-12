//! Conversation context with automatic session persistence.
//!
//! [`ConversationContext`] wraps a session store and agent loop to provide
//! ergonomic multi-turn conversations with automatic persistence after
//! each interaction.
//!
//! # Examples
//!
//! ```no_run
//! use std::sync::Arc;
//! use fae::fae_llm::session::context::ConversationContext;
//! use fae::fae_llm::session::store::MemorySessionStore;
//! use fae::fae_llm::agent::types::AgentConfig;
//!
//! // ConversationContext::new() creates a fresh session and persists it.
//! // ConversationContext::resume() loads and validates an existing session.
//! // context.send("message") runs the agent loop and persists the result.
//! ```

use std::sync::Arc;

use super::store::SessionStore;
use super::types::Session;
use super::validation::validate_session;
use crate::fae_llm::agent::loop_engine::{AgentLoop, build_messages_from_result};
use crate::fae_llm::agent::types::{AgentConfig, AgentLoopResult};
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::provider::ProviderAdapter;
use crate::fae_llm::providers::message::{Message, Role};
use crate::fae_llm::tools::registry::ToolRegistry;

/// Manages a conversation session with automatic persistence.
///
/// Each call to [`send()`](Self::send) appends the user message, runs the
/// agent loop, appends the response messages, updates metadata, and
/// persists the session to the store.
///
/// # Lifecycle
///
/// 1. Create via [`new()`](Self::new) for a fresh session, or
///    [`resume()`](Self::resume) for an existing one.
/// 2. Call [`send()`](Self::send) for each user message.
/// 3. The session is automatically persisted after each send.
pub struct ConversationContext {
    session: Session,
    store: Arc<dyn SessionStore>,
    config: AgentConfig,
    provider: Arc<dyn ProviderAdapter>,
    registry: Arc<ToolRegistry>,
}

impl ConversationContext {
    /// Start a new conversation and persist the initial session.
    ///
    /// Creates a new session in the store with an optional system prompt.
    /// The system prompt (from `config.system_prompt`) is added as the
    /// first message if present.
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError::SessionError`] if the session cannot be created.
    pub async fn new(
        store: Arc<dyn SessionStore>,
        config: AgentConfig,
        provider: Arc<dyn ProviderAdapter>,
        registry: Arc<ToolRegistry>,
    ) -> Result<Self, FaeLlmError> {
        let id = store.create(config.system_prompt.as_deref()).await?;
        let mut session = store.load(&id).await?;

        // Add system prompt as first message if configured
        if let Some(ref prompt) = config.system_prompt {
            session.push_message(Message::system(prompt.as_str()));
            store.save(&session).await?;
        }

        Ok(Self {
            session,
            store,
            config,
            provider,
            registry,
        })
    }

    /// Resume an existing conversation from the store.
    ///
    /// Loads the session, validates it, and prepares for continuation.
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError::SessionError`] if the session cannot be loaded
    /// or fails validation (schema mismatch, corruption, etc.).
    pub async fn resume(
        id: &str,
        store: Arc<dyn SessionStore>,
        config: AgentConfig,
        provider: Arc<dyn ProviderAdapter>,
        registry: Arc<ToolRegistry>,
    ) -> Result<Self, FaeLlmError> {
        let session = store.load(id).await?;

        // Validate before resuming
        validate_session(&session).map_err(|e| FaeLlmError::SessionError(format!("{e}")))?;

        Ok(Self {
            session,
            store,
            config,
            provider,
            registry,
        })
    }

    /// Send a user message and get the agent's response.
    ///
    /// This method:
    /// 1. Appends the user message to the session
    /// 2. Runs the agent loop with the full message history
    /// 3. Appends response messages (assistant text, tool calls, tool results)
    /// 4. Updates session metadata (turn count, timestamp, tokens)
    /// 5. Persists the updated session to the store
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError`] if the agent loop or persistence fails.
    pub async fn send(&mut self, message: &str) -> Result<AgentLoopResult, FaeLlmError> {
        // 1. Append user message
        self.session.push_message(Message::user(message));

        // 2. Run agent loop with full history
        let agent = AgentLoop::new(
            self.config.clone(),
            Arc::clone(&self.provider),
            Arc::clone(&self.registry),
        );
        let result = agent.run_with_messages(self.session.messages.clone()).await?;

        // 3. Append response messages from the result
        let response_messages =
            build_messages_from_result(&result, None);

        // Only add assistant/tool messages (skip system messages from rebuild)
        for msg in response_messages {
            if msg.role != Role::System {
                self.session.push_message(msg);
            }
        }

        // 4. Update metadata
        self.session.meta.turn_count = self.session.meta.turn_count.saturating_add(1);
        self.session.meta.total_tokens = self
            .session
            .meta
            .total_tokens
            .saturating_add(result.total_usage.total());
        self.session.meta.touch();

        // 5. Persist
        self.store.save(&self.session).await?;

        Ok(result)
    }

    /// Returns a reference to the current session.
    pub fn session(&self) -> &Session {
        &self.session
    }

    /// Returns the session ID.
    pub fn session_id(&self) -> &str {
        &self.session.meta.id
    }

    /// Returns the number of messages in the conversation.
    pub fn message_count(&self) -> usize {
        self.session.messages.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::events::{FinishReason, LlmEvent};
    use crate::fae_llm::provider::{LlmEventStream, ToolDefinition};
    use crate::fae_llm::providers::message::Message;
    use crate::fae_llm::session::store::MemorySessionStore;
    use crate::fae_llm::tools::types::{Tool, ToolResult};
    use crate::fae_llm::types::{ModelRef, RequestOptions};

    use async_trait::async_trait;
    use std::sync::Mutex;

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
            Ok(Box::pin(futures_util::stream::iter(events)))
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

    // ── Tests ───────────────────────────────────────────────

    #[tokio::test]
    async fn context_new_creates_session() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("hi")]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config,
            provider,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        assert!(!ctx.session_id().is_empty());
        let exists = store.exists(ctx.session_id()).await;
        assert!(matches!(exists, Ok(true)));
    }

    #[tokio::test]
    async fn context_new_with_system_prompt() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("hi")]));
        let config = AgentConfig::new().with_system_prompt("Be helpful.");

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config,
            provider,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        // Should have system message
        assert_eq!(ctx.message_count(), 1);
        assert_eq!(ctx.session().messages[0].role, Role::System);
    }

    #[tokio::test]
    async fn context_send_appends_messages() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("Hello!")]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config,
            provider,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let result = ctx.send("Hi").await;
        assert!(result.is_ok());

        // Should have: user("Hi") + assistant("Hello!")
        assert!(ctx.message_count() >= 2);
        assert_eq!(ctx.session().meta.turn_count, 1);
    }

    #[tokio::test]
    async fn context_send_persists_session() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("Saved!")]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config,
            provider,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let id = ctx.session_id().to_string();
        let result = ctx.send("Test").await;
        assert!(result.is_ok());

        // Load from store directly — should have the messages
        let loaded = store.load(&id).await;
        assert!(loaded.is_ok());
        let loaded = match loaded {
            Ok(s) => s,
            Err(_) => unreachable!("load succeeded"),
        };
        assert!(loaded.messages.len() >= 2);
    }

    #[tokio::test]
    async fn context_resume_loads_session() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());

        // Create and populate a session
        let provider1: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("First!")]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config.clone(),
            Arc::clone(&provider1),
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let result = ctx.send("Hello").await;
        assert!(result.is_ok());
        let id = ctx.session_id().to_string();

        // Resume
        let provider2: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("Resumed!")]));
        let resumed = ConversationContext::resume(
            &id,
            Arc::clone(&store),
            config,
            provider2,
            empty_registry(),
        )
        .await;
        assert!(resumed.is_ok());
        let resumed = match resumed {
            Ok(c) => c,
            Err(_) => unreachable!("resume succeeded"),
        };

        // Should have the messages from the first interaction
        assert!(resumed.message_count() >= 2);
        assert_eq!(resumed.session_id(), id);
    }

    #[tokio::test]
    async fn context_resume_validates_session() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());

        // Create a session with no messages (empty = invalid for resume)
        let id = store.create(None).await;
        assert!(id.is_ok());
        let id = match id {
            Ok(i) => i,
            Err(_) => unreachable!("create succeeded"),
        };

        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("hi")]));
        let config = AgentConfig::new();

        let resumed = ConversationContext::resume(
            &id,
            store,
            config,
            provider,
            empty_registry(),
        )
        .await;

        // Should fail — empty session is invalid
        assert!(resumed.is_err());
        let err = match resumed {
            Err(e) => e,
            Ok(_) => unreachable!("resume should fail"),
        };
        assert_eq!(err.code(), "SESSION_ERROR");
    }

    #[tokio::test]
    async fn context_resume_not_found_returns_error() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("hi")]));
        let config = AgentConfig::new();

        let resumed = ConversationContext::resume(
            "nonexistent",
            store,
            config,
            provider,
            empty_registry(),
        )
        .await;

        assert!(resumed.is_err());
        let err = match resumed {
            Err(e) => e,
            Ok(_) => unreachable!("resume should fail"),
        };
        assert_eq!(err.code(), "SESSION_ERROR");
        assert!(err.message().contains("not found"));
    }

    #[tokio::test]
    async fn context_multi_turn_accumulates_messages() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> = Arc::new(MockProvider::new(vec![
            MockProvider::text("First answer."),
            MockProvider::text("Second answer."),
        ]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config,
            provider,
            empty_registry(),
        )
        .await;
        assert!(ctx.is_ok());
        let mut ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        let r1 = ctx.send("Question 1").await;
        assert!(r1.is_ok());
        let count_after_first = ctx.message_count();

        let r2 = ctx.send("Question 2").await;
        assert!(r2.is_ok());
        let count_after_second = ctx.message_count();

        // Second interaction should have more messages
        assert!(count_after_second > count_after_first);
        assert_eq!(ctx.session().meta.turn_count, 2);
    }

    #[tokio::test]
    async fn context_session_id_accessor() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> =
            Arc::new(MockProvider::new(vec![MockProvider::text("hi")]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(store, config, provider, empty_registry()).await;
        assert!(ctx.is_ok());
        let ctx = match ctx {
            Ok(c) => c,
            Err(_) => unreachable!("context creation succeeded"),
        };

        assert!(ctx.session_id().starts_with("sess_"));
    }

    #[tokio::test]
    async fn context_send_with_tool_calls() {
        let store: Arc<dyn SessionStore> = Arc::new(MemorySessionStore::new());
        let provider: Arc<dyn ProviderAdapter> = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "echo", r#"{"message":"world"}"#),
            MockProvider::text("Echo returned: world"),
        ]));
        let config = AgentConfig::new();

        let ctx = ConversationContext::new(
            Arc::clone(&store),
            config,
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

        assert_eq!(result.final_text, "Echo returned: world");
        assert_eq!(result.turns.len(), 2);

        // Session should have tool-related messages persisted
        assert!(ctx.message_count() > 2);
    }
}
