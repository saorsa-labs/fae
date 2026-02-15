use crate::channels::traits::{ChannelAdapter, ChannelInboundMessage, ChannelOutboundMessage};
use crate::config::DiscordChannelConfig;
use async_trait::async_trait;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

/// Discord channel adapter using the official gateway websocket + REST API.
pub struct DiscordAdapter {
    bot_token: String,
    guild_id: Option<String>,
    allowed_user_ids: Vec<String>,
    allowed_channel_ids: Vec<String>,
    client: reqwest::Client,
}

impl DiscordAdapter {
    pub fn new(config: &DiscordChannelConfig) -> Self {
        Self {
            bot_token: config.bot_token.clone(),
            guild_id: config.guild_id.clone(),
            allowed_user_ids: config.allowed_user_ids.clone(),
            allowed_channel_ids: config.allowed_channel_ids.clone(),
            client: reqwest::Client::new(),
        }
    }

    fn is_user_allowed(&self, user_id: &str) -> bool {
        if self.allowed_user_ids.is_empty() {
            return false;
        }
        self.allowed_user_ids
            .iter()
            .any(|u| u == "*" || u.as_str() == user_id)
    }

    fn is_channel_allowed(&self, channel_id: &str) -> bool {
        if self.allowed_channel_ids.is_empty() {
            return true;
        }
        self.allowed_channel_ids
            .iter()
            .any(|c| c == "*" || c.as_str() == channel_id)
    }

    fn bot_user_id_from_token(token: &str) -> Option<String> {
        let first = token.split('.').next()?;
        let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(first)
            .ok()?;
        String::from_utf8(decoded).ok()
    }
}

#[async_trait]
impl ChannelAdapter for DiscordAdapter {
    fn id(&self) -> &'static str {
        "discord"
    }

    async fn send(&self, message: ChannelOutboundMessage) -> anyhow::Result<()> {
        let url = format!(
            "https://discord.com/api/v10/channels/{}/messages",
            message.reply_target
        );
        let body = json!({
            "content": message.text
        });
        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bot {}", self.bot_token))
            .json(&body)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("discord send failed ({status}): {body}");
        }
        Ok(())
    }

    async fn run(&self, inbound_tx: mpsc::Sender<ChannelInboundMessage>) -> anyhow::Result<()> {
        if self.bot_token.trim().is_empty() {
            anyhow::bail!("discord bot token is empty");
        }

        let bot_user_id = Self::bot_user_id_from_token(&self.bot_token).unwrap_or_default();

        let gateway_resp: serde_json::Value = self
            .client
            .get("https://discord.com/api/v10/gateway/bot")
            .header("Authorization", format!("Bot {}", self.bot_token))
            .send()
            .await?
            .json()
            .await?;

        let gateway_url = gateway_resp
            .get("url")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("wss://gateway.discord.gg");
        let ws_url = format!("{gateway_url}/?v=10&encoding=json");

        let (stream, _) = tokio_tungstenite::connect_async(&ws_url).await?;
        let (mut write, mut read) = stream.split();

        let hello = read
            .next()
            .await
            .ok_or_else(|| anyhow::anyhow!("no hello"))??;
        let hello_text = match hello {
            Message::Text(text) => text.to_string(),
            _ => anyhow::bail!("unexpected discord hello payload"),
        };
        let hello_json: serde_json::Value = serde_json::from_str(&hello_text)?;
        let heartbeat_interval_ms = hello_json
            .get("d")
            .and_then(|v| v.get("heartbeat_interval"))
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(41_250);

        let identify = json!({
            "op": 2,
            "d": {
                "token": self.bot_token,
                // GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT | DIRECT_MESSAGES
                "intents": 33281,
                "properties": {
                    "os": "macos",
                    "browser": "fae",
                    "device": "fae"
                }
            }
        });
        write.send(Message::Text(identify.to_string())).await?;

        let (hb_tx, mut hb_rx) = mpsc::channel::<()>(1);
        tokio::spawn(async move {
            let mut interval =
                tokio::time::interval(std::time::Duration::from_millis(heartbeat_interval_ms));
            loop {
                interval.tick().await;
                if hb_tx.send(()).await.is_err() {
                    break;
                }
            }
        });

        loop {
            tokio::select! {
                _ = hb_rx.recv() => {
                    let heartbeat = json!({"op": 1, "d": serde_json::Value::Null});
                    if write.send(Message::Text(heartbeat.to_string())).await.is_err() {
                        anyhow::bail!("discord heartbeat failed");
                    }
                }
                maybe_msg = read.next() => {
                    let raw = match maybe_msg {
                        Some(Ok(Message::Text(text))) => text.to_string(),
                        Some(Ok(Message::Close(_))) | None => {
                            anyhow::bail!("discord websocket closed");
                        }
                        Some(Ok(_)) => continue,
                        Some(Err(err)) => anyhow::bail!("discord websocket error: {err}"),
                    };

                    let payload: serde_json::Value = match serde_json::from_str(&raw) {
                        Ok(v) => v,
                        Err(_) => continue,
                    };

                    let event_name = payload.get("t").and_then(serde_json::Value::as_str).unwrap_or_default();
                    if event_name != "MESSAGE_CREATE" {
                        continue;
                    }

                    let Some(data) = payload.get("d") else {
                        continue;
                    };

                    let author_id = data
                        .get("author")
                        .and_then(|a| a.get("id"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    if author_id.is_empty() || author_id == bot_user_id {
                        continue;
                    }

                    let author_is_bot = data
                        .get("author")
                        .and_then(|a| a.get("bot"))
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false);
                    if author_is_bot {
                        continue;
                    }

                    if !self.is_user_allowed(author_id) {
                        continue;
                    }

                    if let Some(ref required_guild) = self.guild_id {
                        let msg_guild_id = data
                            .get("guild_id")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or_default();
                        if msg_guild_id != required_guild {
                            continue;
                        }
                    }

                    let channel_id = data
                        .get("channel_id")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    if channel_id.is_empty() || !self.is_channel_allowed(channel_id) {
                        continue;
                    }

                    let content = data
                        .get("content")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .trim();
                    if content.is_empty() {
                        continue;
                    }

                    let inbound = ChannelInboundMessage {
                        channel: self.id().to_owned(),
                        sender: author_id.to_owned(),
                        reply_target: channel_id.to_owned(),
                        text: content.to_owned(),
                    };
                    if inbound_tx.send(inbound).await.is_err() {
                        anyhow::bail!("discord inbound channel closed");
                    }
                }
            }
        }
    }

    async fn health_check(&self) -> anyhow::Result<bool> {
        if self.bot_token.trim().is_empty() {
            return Ok(false);
        }
        let response = self
            .client
            .get("https://discord.com/api/v10/users/@me")
            .header("Authorization", format!("Bot {}", self.bot_token))
            .send()
            .await?;
        Ok(response.status().is_success())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn empty_allowlist_denies_users() {
        let adapter = DiscordAdapter {
            bot_token: String::new(),
            guild_id: None,
            allowed_user_ids: vec![],
            allowed_channel_ids: vec![],
            client: reqwest::Client::new(),
        };
        assert!(!adapter.is_user_allowed("123"));
    }

    #[test]
    fn wildcard_user_allowlist_allows_all() {
        let adapter = DiscordAdapter {
            bot_token: String::new(),
            guild_id: None,
            allowed_user_ids: vec!["*".to_owned()],
            allowed_channel_ids: vec![],
            client: reqwest::Client::new(),
        };
        assert!(adapter.is_user_allowed("123"));
    }

    #[test]
    fn empty_channel_allowlist_allows_all() {
        let adapter = DiscordAdapter {
            bot_token: String::new(),
            guild_id: None,
            allowed_user_ids: vec!["*".to_owned()],
            allowed_channel_ids: vec![],
            client: reqwest::Client::new(),
        };
        assert!(adapter.is_channel_allowed("chan"));
    }
}
