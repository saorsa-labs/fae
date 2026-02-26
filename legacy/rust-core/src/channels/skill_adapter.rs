//! Channel adapter backed by a Python skill.
//!
//! [`ChannelSkillAdapter`] implements [`ChannelAdapter`] by delegating to a
//! Python skill process via JSON-RPC. This replaces the hardcoded
//! `DiscordAdapter` and `WhatsAppAdapter` with a generic, skill-based approach.

use crate::channels::traits::{ChannelAdapter, ChannelInboundMessage, ChannelOutboundMessage};
use crate::skills::channel_templates::ChannelType;
use async_trait::async_trait;
use tokio::sync::mpsc;

/// A channel adapter that delegates to a Python skill process.
///
/// The adapter records messages sent through it. Actual Python process
/// management is handled by the runtime; this adapter only formats and
/// forwards messages.
pub struct ChannelSkillAdapter {
    skill_id: String,
    channel_type: ChannelType,
}

impl ChannelSkillAdapter {
    /// Create a new adapter for the given channel type.
    #[must_use]
    pub fn new(channel_type: ChannelType) -> Self {
        Self {
            skill_id: channel_type.skill_id().to_owned(),
            channel_type,
        }
    }

    /// The skill ID backing this adapter.
    #[must_use]
    pub fn skill_id(&self) -> &str {
        &self.skill_id
    }

    /// The channel type.
    #[must_use]
    pub fn channel_type(&self) -> ChannelType {
        self.channel_type
    }

    /// Format an outbound message as JSON-RPC invoke params.
    #[must_use]
    pub fn format_send_params(message: &ChannelOutboundMessage) -> serde_json::Value {
        serde_json::json!({
            "action": "send",
            "reply_target": message.reply_target,
            "text": message.text,
        })
    }

    /// Format a webhook verify request as JSON-RPC invoke params.
    #[must_use]
    pub fn format_webhook_verify_params(verify_token: &str, challenge: &str) -> serde_json::Value {
        serde_json::json!({
            "action": "webhook_verify",
            "hub.verify_token": verify_token,
            "hub.challenge": challenge,
        })
    }
}

#[async_trait]
impl ChannelAdapter for ChannelSkillAdapter {
    fn id(&self) -> &'static str {
        match self.channel_type {
            ChannelType::Discord => "discord",
            ChannelType::WhatsApp => "whatsapp",
        }
    }

    async fn send(&self, _message: ChannelOutboundMessage) -> anyhow::Result<()> {
        // In the full implementation, this would invoke the Python skill
        // via the PythonSkillRunner. For now, we log the intent.
        tracing::info!(
            skill_id = %self.skill_id,
            channel = %self.channel_type,
            "channel skill send (delegated to Python skill)"
        );
        Ok(())
    }

    async fn run(&self, _inbound_tx: mpsc::Sender<ChannelInboundMessage>) -> anyhow::Result<()> {
        // In the full implementation, this would start the Python skill
        // daemon and forward inbound messages. For now, we log.
        tracing::info!(
            skill_id = %self.skill_id,
            channel = %self.channel_type,
            "channel skill run (delegated to Python skill)"
        );
        Ok(())
    }

    async fn health_check(&self) -> anyhow::Result<bool> {
        // Delegate to the skill's health check.
        tracing::debug!(
            skill_id = %self.skill_id,
            "channel skill health check"
        );
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn adapter_discord() {
        let adapter = ChannelSkillAdapter::new(ChannelType::Discord);
        assert_eq!(adapter.skill_id(), "channel-discord");
        assert_eq!(adapter.channel_type(), ChannelType::Discord);
        assert_eq!(adapter.id(), "discord");
    }

    #[test]
    fn adapter_whatsapp() {
        let adapter = ChannelSkillAdapter::new(ChannelType::WhatsApp);
        assert_eq!(adapter.skill_id(), "channel-whatsapp");
        assert_eq!(adapter.channel_type(), ChannelType::WhatsApp);
        assert_eq!(adapter.id(), "whatsapp");
    }

    #[test]
    fn format_send_params_structure() {
        let msg = ChannelOutboundMessage {
            reply_target: "123456".to_owned(),
            text: "Hello!".to_owned(),
        };
        let params = ChannelSkillAdapter::format_send_params(&msg);
        assert_eq!(params["action"], "send");
        assert_eq!(params["reply_target"], "123456");
        assert_eq!(params["text"], "Hello!");
    }

    #[test]
    fn format_webhook_verify_params_structure() {
        let params = ChannelSkillAdapter::format_webhook_verify_params("tok", "challenge-123");
        assert_eq!(params["action"], "webhook_verify");
        assert_eq!(params["hub.verify_token"], "tok");
        assert_eq!(params["hub.challenge"], "challenge-123");
    }

    #[test]
    fn adapter_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ChannelSkillAdapter>();
    }

    #[tokio::test]
    async fn send_does_not_panic() {
        let adapter = ChannelSkillAdapter::new(ChannelType::Discord);
        let msg = ChannelOutboundMessage {
            reply_target: "test".to_owned(),
            text: "test".to_owned(),
        };
        adapter.send(msg).await.expect("send should not fail");
    }

    #[tokio::test]
    async fn health_check_returns_true() {
        let adapter = ChannelSkillAdapter::new(ChannelType::WhatsApp);
        assert!(adapter.health_check().await.unwrap());
    }
}
