//! External communication channels (Discord, WhatsApp, webhook gateway).
//!
//! Design goal: channel-specific adapters are pluggable. The manager owns
//! routing, model invocation, and cross-channel policy checks.

mod brain;
mod gateway;
pub mod history;
pub mod rate_limit;
pub mod skill_adapter;
pub mod traits;

use crate::channels::brain::ChannelBrain;
use crate::channels::gateway::run_gateway;
use crate::channels::history::{ChannelHistory, ChannelMessage, MessageDirection};
use crate::channels::rate_limit::ChannelRateLimiters;
use crate::channels::skill_adapter::ChannelSkillAdapter;
use crate::channels::traits::{ChannelAdapter, ChannelInboundMessage, ChannelOutboundMessage};
use crate::config::SpeechConfig;
use crate::skills::channel_templates::ChannelType;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::task::JoinSet;

/// Runtime event emitted by channel manager.
#[derive(Debug, Clone)]
pub enum ChannelRuntimeEvent {
    Started {
        active_channels: Vec<String>,
    },
    Stopped,
    Inbound {
        channel: String,
        sender: String,
    },
    Outbound {
        channel: String,
        reply_target: String,
    },
    MessageRecorded {
        message: ChannelMessage,
    },
    Warning(String),
    Error(String),
}

/// Configuration validation issue for channels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelValidationSeverity {
    Warning,
    Error,
}

/// Validation issue surfaced to doctor/UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelValidationIssue {
    pub id: String,
    pub title: String,
    pub severity: ChannelValidationSeverity,
    pub summary: String,
}

/// Runtime handle for the detached channels thread.
pub struct ChannelRuntimeHandle {
    stop_tx: Option<tokio::sync::oneshot::Sender<()>>,
}

impl ChannelRuntimeHandle {
    /// Request runtime shutdown.
    pub fn abort(&mut self) {
        if let Some(stop_tx) = self.stop_tx.take() {
            let _ = stop_tx.send(());
        }
    }
}

/// Launch channel runtime if channels are enabled and auto-start is on.
///
/// Returns `None` when channels are disabled or auto-start is disabled.
pub fn start_runtime(
    config: SpeechConfig,
) -> Option<(
    ChannelRuntimeHandle,
    tokio::sync::mpsc::UnboundedReceiver<ChannelRuntimeEvent>,
)> {
    if !config.channels.enabled || !config.channels.auto_start {
        return None;
    }

    let (event_tx, event_rx) = tokio::sync::mpsc::unbounded_channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let spawn_res = std::thread::Builder::new()
        .name("fae-channels-runtime".to_owned())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            match runtime {
                Ok(rt) => {
                    rt.block_on(async move {
                        tokio::select! {
                            result = run_runtime(config, event_tx.clone()) => {
                                if let Err(err) = result {
                                    let _ = event_tx.send(ChannelRuntimeEvent::Error(err.to_string()));
                                    tracing::error!("channels runtime failed: {err}");
                                }
                            }
                            _ = stop_rx => {}
                        }
                        let _ = event_tx.send(ChannelRuntimeEvent::Stopped);
                    });
                }
                Err(err) => {
                    let _ = event_tx.send(ChannelRuntimeEvent::Error(format!(
                        "failed to create channels runtime: {err}"
                    )));
                }
            }
        });

    match spawn_res {
        Ok(_) => Some((
            ChannelRuntimeHandle {
                stop_tx: Some(stop_tx),
            },
            event_rx,
        )),
        Err(err) => {
            tracing::error!("failed to spawn channels runtime thread: {err}");
            None
        }
    }
}

fn extension_channel_type(
    extension: &crate::config::ChannelExtensionConfig,
) -> Option<ChannelType> {
    match extension.kind.trim().to_ascii_lowercase().as_str() {
        "discord" | "channel-discord" => Some(ChannelType::Discord),
        "whatsapp" | "channel-whatsapp" => Some(ChannelType::WhatsApp),
        _ => None,
    }
}

fn configured_channel_types(config: &SpeechConfig) -> Vec<ChannelType> {
    let mut types = Vec::new();
    if config.channels.discord.is_some() {
        types.push(ChannelType::Discord);
    }
    if config.channels.whatsapp.is_some() {
        types.push(ChannelType::WhatsApp);
    }
    for extension in &config.channels.extensions {
        if let Some(channel_type) = extension_channel_type(extension)
            && !types.contains(&channel_type)
        {
            types.push(channel_type);
        }
    }
    types
}

/// Validate channel configuration without network calls.
#[must_use]
pub fn validate_config(config: &SpeechConfig) -> Vec<ChannelValidationIssue> {
    let mut issues = Vec::new();
    if !config.channels.enabled {
        return issues;
    }

    if configured_channel_types(config).is_empty() {
        issues.push(ChannelValidationIssue {
            id: "channels-enabled-without-adapters".to_owned(),
            title: "Channels enabled with no adapters".to_owned(),
            severity: ChannelValidationSeverity::Warning,
            summary: "Enable at least one channel adapter or disable external channels.".to_owned(),
        });
    }

    for (index, extension) in config.channels.extensions.iter().enumerate() {
        let kind = extension.kind.trim();
        if kind.is_empty() {
            issues.push(ChannelValidationIssue {
                id: format!("extension-missing-kind-{index}"),
                title: "Channel extension missing kind".to_owned(),
                severity: ChannelValidationSeverity::Warning,
                summary: format!(
                    "Channel extension `{}` is missing a kind and will be ignored.",
                    extension.id
                ),
            });
            continue;
        }

        if extension_channel_type(extension).is_none() {
            issues.push(ChannelValidationIssue {
                id: format!("extension-unsupported-kind-{index}"),
                title: "Channel extension kind unsupported".to_owned(),
                severity: ChannelValidationSeverity::Warning,
                summary: format!(
                    "Channel extension kind `{kind}` is unsupported; supported kinds: discord, whatsapp."
                ),
            });
        }
    }

    if let Some(discord) = &config.channels.discord {
        if !discord.bot_token.is_set() {
            issues.push(ChannelValidationIssue {
                id: "discord-missing-token".to_owned(),
                title: "Discord token missing".to_owned(),
                severity: ChannelValidationSeverity::Error,
                summary: "Discord is enabled but bot token is empty.".to_owned(),
            });
        }
        if discord.allowed_user_ids.is_empty() {
            issues.push(ChannelValidationIssue {
                id: "discord-empty-allowlist".to_owned(),
                title: "Discord allowlist is empty".to_owned(),
                severity: ChannelValidationSeverity::Warning,
                summary: "Inbound Discord messages will be denied until allowed user IDs are set."
                    .to_owned(),
            });
        }
    }

    if let Some(whatsapp) = &config.channels.whatsapp {
        if !whatsapp.access_token.is_set() {
            issues.push(ChannelValidationIssue {
                id: "whatsapp-missing-access-token".to_owned(),
                title: "WhatsApp access token missing".to_owned(),
                severity: ChannelValidationSeverity::Error,
                summary: "WhatsApp is enabled but access token is empty.".to_owned(),
            });
        }
        if whatsapp.phone_number_id.trim().is_empty() {
            issues.push(ChannelValidationIssue {
                id: "whatsapp-missing-phone-number-id".to_owned(),
                title: "WhatsApp phone number ID missing".to_owned(),
                severity: ChannelValidationSeverity::Error,
                summary: "WhatsApp is enabled but phone number ID is empty.".to_owned(),
            });
        }
        if !whatsapp.verify_token.is_set() {
            issues.push(ChannelValidationIssue {
                id: "whatsapp-missing-verify-token".to_owned(),
                title: "WhatsApp verify token missing".to_owned(),
                severity: ChannelValidationSeverity::Error,
                summary: "WhatsApp webhook verification requires a verify token.".to_owned(),
            });
        }
        if whatsapp.allowed_numbers.is_empty() {
            issues.push(ChannelValidationIssue {
                id: "whatsapp-empty-allowlist".to_owned(),
                title: "WhatsApp allowlist is empty".to_owned(),
                severity: ChannelValidationSeverity::Warning,
                summary: "Inbound WhatsApp messages will be denied until allowed numbers are set."
                    .to_owned(),
            });
        }
    }

    if config.channels.gateway.enabled {
        let host = config.channels.gateway.host.trim();
        let bearer_missing = config
            .channels
            .gateway
            .bearer_token
            .as_ref()
            .is_none_or(|token| match token {
                crate::credentials::CredentialRef::None => true,
                crate::credentials::CredentialRef::Plaintext(value) => value.trim().is_empty(),
                crate::credentials::CredentialRef::Keychain { .. } => false,
            });
        if host == "0.0.0.0" && bearer_missing {
            issues.push(ChannelValidationIssue {
                id: "gateway-public-without-auth".to_owned(),
                title: "Gateway is public without bearer auth".to_owned(),
                severity: ChannelValidationSeverity::Warning,
                summary:
                    "Binding to 0.0.0.0 without a bearer token can expose inbound webhook routes."
                        .to_owned(),
            });
        }
    }

    issues
}

/// Best-effort async health checks for configured adapters.
///
/// Health checks are delegated to the Python skill backing each channel.
pub async fn check_health(config: &SpeechConfig) -> HashMap<String, bool> {
    let mut health = HashMap::new();

    for channel_type in configured_channel_types(config) {
        let adapter = ChannelSkillAdapter::new(channel_type);
        let id = adapter.id().to_owned();
        match adapter.health_check().await {
            Ok(ok) => {
                health.insert(id, ok);
            }
            Err(_) => {
                health.insert(id, false);
            }
        }
    }

    health
}

/// Register a skill-based channel adapter for the given channel type.
#[must_use]
pub fn register_skill_channel(channel_type: ChannelType) -> (String, Arc<dyn ChannelAdapter>) {
    let adapter = ChannelSkillAdapter::new(channel_type);
    let id = adapter.id().to_owned();
    (id, Arc::new(adapter))
}

async fn run_runtime(
    config: SpeechConfig,
    event_tx: tokio::sync::mpsc::UnboundedSender<ChannelRuntimeEvent>,
) -> anyhow::Result<()> {
    let validation = validate_config(&config);
    let has_error = validation
        .iter()
        .any(|issue| issue.severity == ChannelValidationSeverity::Error);
    for issue in validation {
        let message = format!("{}: {}", issue.title, issue.summary);
        match issue.severity {
            ChannelValidationSeverity::Warning => {
                let _ = event_tx.send(ChannelRuntimeEvent::Warning(message.clone()));
                tracing::warn!("{message}");
            }
            ChannelValidationSeverity::Error => {
                let _ = event_tx.send(ChannelRuntimeEvent::Error(message.clone()));
                tracing::error!("{message}");
            }
        }
    }
    if has_error {
        anyhow::bail!("channel configuration has blocking errors");
    }

    let brain = ChannelBrain::from_config(&config).await?;

    let rate_limiters = Arc::new(Mutex::new(ChannelRateLimiters::new(
        &config.channels.rate_limits,
    )));

    let history = Arc::new(Mutex::new(ChannelHistory::default()));

    let mut adapters: HashMap<String, Arc<dyn ChannelAdapter>> = HashMap::new();
    let mut active_channels = Vec::new();

    // Register skill-based channel adapters driven by config and extension kinds.
    for channel_type in configured_channel_types(&config) {
        let (id, adapter) = register_skill_channel(channel_type);
        adapters.insert(id.clone(), adapter);
        active_channels.push(id);
    }

    if active_channels.is_empty() && !config.channels.gateway.enabled {
        anyhow::bail!("channels are enabled but no adapters are active");
    }

    let queue_size = config.channels.inbound_queue_size.max(8);
    let (inbound_tx, mut inbound_rx) =
        tokio::sync::mpsc::channel::<ChannelInboundMessage>(queue_size);
    let _ = event_tx.send(ChannelRuntimeEvent::Started {
        active_channels: active_channels.clone(),
    });
    tracing::info!(
        "channels runtime started with [{}]",
        active_channels.join(", ")
    );

    let mut workers = JoinSet::new();

    for adapter in adapters.values() {
        let adapter = Arc::clone(adapter);
        let tx = inbound_tx.clone();
        let event_tx = event_tx.clone();
        workers.spawn(async move {
            let mut backoff_secs = 2u64;
            loop {
                match adapter.run(tx.clone()).await {
                    Ok(()) => {
                        let warning = format!("channel {} stopped; restarting", adapter.id());
                        let _ = event_tx.send(ChannelRuntimeEvent::Warning(warning.clone()));
                        tracing::warn!("{warning}");
                    }
                    Err(err) => {
                        let warning = format!(
                            "channel {} failed: {err}; retrying in {backoff_secs}s",
                            adapter.id()
                        );
                        let _ = event_tx.send(ChannelRuntimeEvent::Warning(warning.clone()));
                        tracing::warn!("{warning}");
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(backoff_secs)).await;
                backoff_secs = (backoff_secs.saturating_mul(2)).min(60);
            }
        });
    }

    if config.channels.gateway.enabled {
        let gateway_cfg = config.channels.gateway.clone();
        let gateway_tx = inbound_tx.clone();
        let gateway_manager = crate::credentials::create_manager();
        workers.spawn(async move {
            if let Err(err) = run_gateway(gateway_cfg, gateway_tx, gateway_manager).await {
                tracing::error!("channels gateway stopped: {err}");
            }
        });
    }

    while let Some(message) = inbound_rx.recv().await {
        let _ = event_tx.send(ChannelRuntimeEvent::Inbound {
            channel: message.channel.clone(),
            sender: message.sender.clone(),
        });

        // Record inbound message
        let inbound_msg = ChannelMessage {
            id: String::new(),
            channel: message.channel.clone(),
            direction: MessageDirection::Inbound,
            sender: message.sender.clone(),
            text: message.text.clone(),
            timestamp: chrono::Utc::now(),
            reply_target: message.reply_target.clone(),
        };
        if let Ok(mut hist) = history.lock() {
            hist.push(inbound_msg.clone());
            let _ = event_tx.send(ChannelRuntimeEvent::MessageRecorded {
                message: inbound_msg,
            });
        }

        let prompt = format!(
            "[channel:{}]\n[sender:{}]\n{}",
            message.channel, message.sender, message.text
        );
        let response = match brain.respond(prompt).await {
            Ok(text) => text,
            Err(err) => {
                let error = format!("failed to generate channel response: {err}");
                let _ = event_tx.send(ChannelRuntimeEvent::Error(error.clone()));
                tracing::error!("{error}");
                "I hit an internal error while processing that message.".to_owned()
            }
        };

        if let Some(adapter) = adapters.get(&message.channel) {
            // Check rate limit before sending
            let rate_limit_check = {
                let mut limiters = rate_limiters
                    .lock()
                    .map_err(|_| anyhow::anyhow!("rate limiter lock poisoned"))?;
                limiters.try_send(&message.channel)
            };

            match rate_limit_check {
                Ok(()) => {
                    let send_result = adapter
                        .send(ChannelOutboundMessage {
                            reply_target: message.reply_target.clone(),
                            text: response.clone(),
                        })
                        .await;
                    match send_result {
                        Ok(()) => {
                            let _ = event_tx.send(ChannelRuntimeEvent::Outbound {
                                channel: message.channel.clone(),
                                reply_target: message.reply_target.clone(),
                            });

                            // Record outbound message
                            let outbound_msg = ChannelMessage {
                                id: String::new(),
                                channel: message.channel.clone(),
                                direction: MessageDirection::Outbound,
                                sender: "fae".to_owned(),
                                text: response,
                                timestamp: chrono::Utc::now(),
                                reply_target: message.reply_target,
                            };
                            if let Ok(mut hist) = history.lock() {
                                hist.push(outbound_msg.clone());
                                let _ = event_tx.send(ChannelRuntimeEvent::MessageRecorded {
                                    message: outbound_msg,
                                });
                            }
                        }
                        Err(err) => {
                            let warning =
                                format!("failed to send {} response: {err}", adapter.id());
                            let _ = event_tx.send(ChannelRuntimeEvent::Warning(warning.clone()));
                            tracing::warn!("{warning}");
                        }
                    }
                }
                Err(err) => {
                    let warning = format!("rate limit exceeded for {}: {}", message.channel, err);
                    let _ = event_tx.send(ChannelRuntimeEvent::Warning(warning.clone()));
                    tracing::warn!("{warning}");
                }
            }
        } else {
            let warning = format!("no adapter found for channel `{}`", message.channel);
            let _ = event_tx.send(ChannelRuntimeEvent::Warning(warning.clone()));
            tracing::warn!("{warning}");
        }
    }

    workers.abort_all();
    while workers.join_next().await.is_some() {}
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::config::{
        ChannelExtensionConfig, ChannelGatewayConfig, ChannelsConfig, DiscordChannelConfig,
        SpeechConfig,
    };
    use crate::credentials::CredentialRef;

    #[test]
    fn validation_flags_missing_discord_token() {
        let config = SpeechConfig {
            channels: ChannelsConfig {
                enabled: true,
                auto_start: true,
                inbound_queue_size: 128,
                gateway: Default::default(),
                discord: Some(DiscordChannelConfig::default()),
                whatsapp: None,
                rate_limits: Default::default(),
                extensions: Vec::new(),
            },
            ..Default::default()
        };

        let issues = validate_config(&config);
        assert!(issues.iter().any(|i| i.id == "discord-missing-token"));
    }

    #[test]
    fn validation_flags_public_gateway_without_bearer_token() {
        let config = SpeechConfig {
            channels: ChannelsConfig {
                enabled: true,
                gateway: ChannelGatewayConfig {
                    enabled: true,
                    host: "0.0.0.0".to_owned(),
                    port: 4088,
                    bearer_token: None,
                },
                ..Default::default()
            },
            ..Default::default()
        };

        let issues = validate_config(&config);
        assert!(issues.iter().any(|i| i.id == "gateway-public-without-auth"));
    }

    #[test]
    fn validation_allows_public_gateway_with_keychain_bearer_reference() {
        let config = SpeechConfig {
            channels: ChannelsConfig {
                enabled: true,
                gateway: ChannelGatewayConfig {
                    enabled: true,
                    host: "0.0.0.0".to_owned(),
                    port: 4088,
                    bearer_token: Some(CredentialRef::Keychain {
                        service: "com.saorsalabs.fae".to_owned(),
                        account: "channels.gateway.bearer".to_owned(),
                    }),
                },
                ..Default::default()
            },
            ..Default::default()
        };

        let issues = validate_config(&config);
        assert!(!issues.iter().any(|i| i.id == "gateway-public-without-auth"));
    }

    #[test]
    fn validation_accepts_supported_extension_kind() {
        let config = SpeechConfig {
            channels: ChannelsConfig {
                enabled: true,
                extensions: vec![ChannelExtensionConfig {
                    id: "discord-ext".to_owned(),
                    kind: "discord".to_owned(),
                    config: serde_json::json!({}),
                }],
                ..Default::default()
            },
            ..Default::default()
        };

        let issues = validate_config(&config);
        assert!(
            !issues
                .iter()
                .any(|i| i.id == "channels-enabled-without-adapters")
        );
        assert!(
            !issues
                .iter()
                .any(|i| i.id.starts_with("extension-unsupported-kind-"))
        );
    }

    #[test]
    fn validation_flags_unsupported_extension_kind() {
        let config = SpeechConfig {
            channels: ChannelsConfig {
                enabled: true,
                extensions: vec![ChannelExtensionConfig {
                    id: "slack-ext".to_owned(),
                    kind: "slack".to_owned(),
                    config: serde_json::json!({}),
                }],
                ..Default::default()
            },
            ..Default::default()
        };

        let issues = validate_config(&config);
        assert!(
            issues
                .iter()
                .any(|i| i.id == "channels-enabled-without-adapters")
        );
        assert!(
            issues
                .iter()
                .any(|i| i.id.starts_with("extension-unsupported-kind-"))
        );
    }

    #[tokio::test]
    async fn check_health_includes_supported_extension_kind() {
        let config = SpeechConfig {
            channels: ChannelsConfig {
                enabled: true,
                extensions: vec![ChannelExtensionConfig {
                    id: "wa-ext".to_owned(),
                    kind: "whatsapp".to_owned(),
                    config: serde_json::json!({}),
                }],
                ..Default::default()
            },
            ..Default::default()
        };

        let health = check_health(&config).await;
        assert_eq!(health.get("whatsapp"), Some(&true));
    }
}
