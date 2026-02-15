use async_trait::async_trait;
use tokio::sync::mpsc;

/// Inbound message received from an external communication channel.
#[derive(Debug, Clone)]
pub struct ChannelInboundMessage {
    pub channel: String,
    pub sender: String,
    pub reply_target: String,
    pub text: String,
}

/// Outbound message sent back to a communication channel.
#[derive(Debug, Clone)]
pub struct ChannelOutboundMessage {
    pub reply_target: String,
    pub text: String,
}

/// Channel adapter contract. New channels only need to implement this trait.
#[async_trait]
pub trait ChannelAdapter: Send + Sync {
    /// Stable channel identifier (e.g. `discord`, `whatsapp`).
    fn id(&self) -> &'static str;

    /// Send a reply to the channel-specific target.
    async fn send(&self, message: ChannelOutboundMessage) -> anyhow::Result<()>;

    /// Start receiving inbound messages and forwarding them to the manager.
    async fn run(&self, inbound_tx: mpsc::Sender<ChannelInboundMessage>) -> anyhow::Result<()>;

    /// Best-effort health probe.
    async fn health_check(&self) -> anyhow::Result<bool>;
}
