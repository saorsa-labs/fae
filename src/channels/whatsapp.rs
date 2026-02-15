use crate::channels::traits::{ChannelAdapter, ChannelInboundMessage, ChannelOutboundMessage};
use crate::config::WhatsAppChannelConfig;
use async_trait::async_trait;
use tokio::sync::mpsc;

/// WhatsApp Business Cloud API adapter.
///
/// Inbound messages are webhook-driven (push). The adapter exposes payload
/// parsing and outbound send APIs; the manager's gateway owns webhook routes.
#[derive(Clone)]
pub struct WhatsAppAdapter {
    access_token: String,
    phone_number_id: String,
    verify_token: String,
    allowed_numbers: Vec<String>,
    client: reqwest::Client,
}

impl WhatsAppAdapter {
    pub fn new(config: &WhatsAppChannelConfig) -> Self {
        Self {
            access_token: config.access_token.clone(),
            phone_number_id: config.phone_number_id.clone(),
            verify_token: config.verify_token.clone(),
            allowed_numbers: config.allowed_numbers.clone(),
            client: reqwest::Client::new(),
        }
    }

    pub fn verify_token(&self) -> &str {
        &self.verify_token
    }

    fn is_number_allowed(&self, number: &str) -> bool {
        if self.allowed_numbers.is_empty() {
            return false;
        }
        self.allowed_numbers
            .iter()
            .any(|n| n == "*" || n.as_str() == number)
    }

    /// Parse WhatsApp webhook payload into channel-agnostic inbound messages.
    #[must_use]
    pub fn parse_webhook_payload(&self, payload: &serde_json::Value) -> Vec<ChannelInboundMessage> {
        let mut inbound = Vec::new();
        let Some(entries) = payload.get("entry").and_then(serde_json::Value::as_array) else {
            return inbound;
        };

        for entry in entries {
            let Some(changes) = entry.get("changes").and_then(serde_json::Value::as_array) else {
                continue;
            };

            for change in changes {
                let Some(value) = change.get("value") else {
                    continue;
                };
                let Some(messages) = value.get("messages").and_then(serde_json::Value::as_array)
                else {
                    continue;
                };

                for msg in messages {
                    let from = msg
                        .get("from")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    if from.is_empty() {
                        continue;
                    }

                    let sender = if from.starts_with('+') {
                        from.to_owned()
                    } else {
                        format!("+{from}")
                    };
                    if !self.is_number_allowed(&sender) {
                        continue;
                    }

                    let text = msg
                        .get("text")
                        .and_then(|v| v.get("body"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .trim()
                        .to_owned();
                    if text.is_empty() {
                        continue;
                    }

                    inbound.push(ChannelInboundMessage {
                        channel: self.id().to_owned(),
                        sender: sender.clone(),
                        reply_target: sender,
                        text,
                    });
                }
            }
        }

        inbound
    }
}

#[async_trait]
impl ChannelAdapter for WhatsAppAdapter {
    fn id(&self) -> &'static str {
        "whatsapp"
    }

    async fn send(&self, message: ChannelOutboundMessage) -> anyhow::Result<()> {
        if self.access_token.trim().is_empty() {
            anyhow::bail!("whatsapp access token is empty");
        }
        if self.phone_number_id.trim().is_empty() {
            anyhow::bail!("whatsapp phone_number_id is empty");
        }

        let to = message
            .reply_target
            .strip_prefix('+')
            .unwrap_or(message.reply_target.as_str());
        let url = format!(
            "https://graph.facebook.com/v18.0/{}/messages",
            self.phone_number_id
        );
        let body = serde_json::json!({
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": to,
            "type": "text",
            "text": {
                "preview_url": false,
                "body": message.text
            }
        });
        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.access_token))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("whatsapp send failed ({status}): {body}");
        }

        Ok(())
    }

    async fn run(&self, _inbound_tx: mpsc::Sender<ChannelInboundMessage>) -> anyhow::Result<()> {
        // Webhook-only adapter: keep the task alive so the manager treats the
        // adapter as active while inbound traffic arrives through the gateway.
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
        }
    }

    async fn health_check(&self) -> anyhow::Result<bool> {
        if self.access_token.trim().is_empty() || self.phone_number_id.trim().is_empty() {
            return Ok(false);
        }
        let url = format!("https://graph.facebook.com/v18.0/{}", self.phone_number_id);
        let response = self
            .client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.access_token))
            .send()
            .await?;
        Ok(response.status().is_success())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn make_adapter() -> WhatsAppAdapter {
        let cfg = WhatsAppChannelConfig {
            access_token: "token".to_owned(),
            phone_number_id: "123".to_owned(),
            verify_token: "verify".to_owned(),
            allowed_numbers: vec!["+1234567890".to_owned()],
        };
        WhatsAppAdapter::new(&cfg)
    }

    #[test]
    fn parse_webhook_filters_unauthorized_numbers() {
        let adapter = make_adapter();
        let payload = serde_json::json!({
            "entry": [{
                "changes": [{
                    "value": {
                        "messages": [{
                            "from": "9999999999",
                            "text": { "body": "hello" }
                        }]
                    }
                }]
            }]
        });
        let msgs = adapter.parse_webhook_payload(&payload);
        assert!(msgs.is_empty());
    }

    #[test]
    fn parse_webhook_accepts_allowed_number() {
        let adapter = make_adapter();
        let payload = serde_json::json!({
            "entry": [{
                "changes": [{
                    "value": {
                        "messages": [{
                            "from": "1234567890",
                            "text": { "body": "hello" }
                        }]
                    }
                }]
            }]
        });
        let msgs = adapter.parse_webhook_payload(&payload);
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].reply_target, "+1234567890");
        assert_eq!(msgs[0].text, "hello");
    }
}
